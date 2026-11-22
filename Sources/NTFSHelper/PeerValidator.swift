import Foundation
import NTFSShared
import Security
import Darwin

/// xpc_connection_get_audit_token 在 macOS 13+ 是公开符号 (libxpc), Swift 覆盖层未导出, 手动桥接
@_silgen_name("xpc_connection_get_audit_token")
func xpc_connection_get_audit_token(_ connection: xpc_connection_t,
                                    _ token: UnsafeMutablePointer<audit_token_t>)

/// XPC 对端校验。
///
/// M2 (开发级): 有效性 + 包标识 + 应用包内主程序路径比对, 并从 audit token
/// 取真实 euid/egid/auid (绝不采信调用方自报)。
/// M5 (发行级): 改用/追加 Designated Requirement (team ID) 断言, 见 docs/M1-FINDINGS.md §五。
enum PeerValidator {
    struct PeerIdentity {
        let euid: uid_t
        let egid: gid_t
        let auid: uid_t       // 会话所属登录用户 (audit uid), -1 表示无会话
        let pid: Int32
        let bundlePath: String?
        let codeIdentifier: String?
    }

    enum ValidationError: Error, CustomStringConvertible {
        case noAuditToken
        case noCode
        case invalidSignature(String)
        case notOurApp
        var description: String {
            switch self {
            case .noAuditToken: return "无法获取对端 audit token"
            case .noCode: return "无法解析对端代码签名"
            case .invalidSignature(let why): return "对端签名无效: \(why)"
            case .notOurApp: return "对端不是本应用的代码"
            }
        }
    }

    /// 期望的对端可执行文件路径 (主应用包内)
    static func expectedAppExecutablePath() -> String? {
        guard let bundle = helperOwnBundleURL() else { return nil }
        return bundle.appendingPathComponent("Contents/MacOS/\(HelperConfig.appExecutableName)").path
    }

    /// helper 自身可执行文件路径 (原始值, 未经规范化 — 供诊断 BundleProgram 路径形态)
    static func rawExecutablePath() -> String? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: Int(size))
        defer { buffer.deallocate() }
        guard _NSGetExecutablePath(buffer, &size) == 0 else { return nil }
        return FileManager.default.string(withFileSystemRepresentation: buffer, length: Int(size))
    }

    /// helper 自身所在的应用包 (通过自身可执行文件路径反推, 不依赖 Bundle.main)
    static func helperOwnBundleURL() -> URL? {
        guard let selfPath = rawExecutablePath() else { return nil }
        // <bundle>/Contents/MacOS/<name>
        let url = URL(fileURLWithPath: selfPath).resolvingSymlinksInPath()
        guard url.deletingLastPathComponent().lastPathComponent == "MacOS",
              url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "Contents" else {
            return nil
        }
        return url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    static func validate(connection: xpc_connection_t) throws -> PeerIdentity {
        var token = audit_token_t()
        withUnsafeMutablePointer(to: &token) { ptr in
            xpc_connection_get_audit_token(connection, ptr)
        }

        // audit_token_t 布局: val[0]=auid, val[1]=euid, val[2]=egid, val[5]=pid
        let auid = uid_t(token.val.0)
        let euid = uid_t(token.val.1)
        let egid = gid_t(token.val.2)
        let pid = Int32(bitPattern: token.val.5)

        let tokenBytes = withUnsafeBytes(of: &token) { Data($0) }
        var guest: SecCode?
        let st = SecCodeCopyGuestWithAttributes(nil,
            [kSecGuestAttributeAudit: tokenBytes] as CFDictionary, [], &guest)
        guard st == errSecSuccess, let code = guest else {
            throw (st == errSecSuccess) ? ValidationError.noCode : ValidationError.invalidSignature("SecCodeCopyGuestWithAttributes: \(st)")
        }

        // 签名有效且未撤销 (nil requirement = 仅验证自身签名链完整)
        let validity = SecCodeCheckValidity(code, SecCSFlags(), nil)
        guard validity == errSecSuccess else {
            throw ValidationError.invalidSignature("SecCodeCheckValidity: \(validity)")
        }

        var staticCode: SecStaticCode?
        let stStatic = SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode)
        var pathURL: CFURL?
        if stStatic == errSecSuccess, let sc = staticCode {
            SecCodeCopyPath(sc, SecCSFlags(), &pathURL)
        }
        var info: CFDictionary?
        if let sc = staticCode {
            SecCodeCopySigningInformation(sc, SecCSFlags(), &info)
        }
        let ident = (info as? [String: Any])?[kSecCodeInfoIdentifier as String] as? String

        // 开发级校验: 对端必须是本 helper 所属应用包的代码。
        // 注意: 对 bundle 签名的主程序, SecCodeCopyPath 返回的是【包根路径】(非可执行文件路径),
        // 实测 /Applications/NTFSMate.app → /Applications/NTFSMate.app。
        guard let expectedBundle = helperOwnBundleURL() else {
            LogHelper.error("无法确定本 helper 所属应用包, 拒绝对端")
            throw ValidationError.notOurApp
        }
        let expectedPath = expectedBundle.resolvingSymlinksInPath().path
        let actualPath: String? = pathURL.map { ($0 as URL).resolvingSymlinksInPath().path }
        guard actualPath == expectedPath else {
            LogHelper.warn("对端路径不匹配: 期望 \(expectedPath) 实际 \(actualPath ?? "nil")")
            throw ValidationError.notOurApp
        }
        guard ident == HelperConfig.appBundleIdentifier else {
            LogHelper.warn("对端标识不符: \(ident ?? "nil") ≠ \(HelperConfig.appBundleIdentifier)")
            throw ValidationError.notOurApp
        }

        return PeerIdentity(euid: euid, egid: egid, auid: auid, pid: pid,
                            bundlePath: actualPath, codeIdentifier: ident)
    }
}
