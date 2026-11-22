import Foundation
import NTFSShared
import Darwin

/// XPC_CONNECTION_MACH_SERVICE_LISTENER 宏未导出到 Swift, 手动定义 (1ULL << 0)
private let XPC_CONNECTION_MACH_SERVICE_LISTENER: UInt64 = 1

/// Swift 字典 → XPC 字典。
/// 关键: 先把键复制到 NSArray 常量, 保证 utf8String 指针在 xpc_dictionary_create 调用期间有效。
private func makeXPCDict(_ swiftDict: [String: xpc_object_t]) -> xpc_object_t {
    let nsKeys: [NSString] = swiftDict.keys.map { NSString(string: $0) }
    let keyPtrs: [UnsafePointer<CChar>] = nsKeys.map { $0.utf8String! }
    let valuePtrs: [xpc_object_t?] = swiftDict.values.map { $0 }
    return keyPtrs.withUnsafeBufferPointer { kbuf in
        valuePtrs.withUnsafeBufferPointer { vbuf in
            xpc_dictionary_create(kbuf.baseAddress!, vbuf.baseAddress!, swiftDict.count)
        }
    }
}

/// NTFSMate 特权 helper (launchd LaunchDaemon, root)。
/// 通过 MachServices 的 mach service 接收主程序 XPC 请求。
/// 每个新连接先做对端签名/路径校验, 再处理字典消息。
final class HelperXPCServer {
    private let service = HelperService()
    private let serverQueue = DispatchQueue(label: "com.ntfsmate.helper.server", qos: .userInitiated)
    private var listener: xpc_connection_t?
    /// 活跃对端连接数 (空闲退出: launchd 按需重启, 保证升级后首次连接即新代码)
    private var peerCount = 0
    private var idleTimer: DispatchSourceTimer?
    /// 本进程启动时自身二进制的 mtime; 新连接时比对, 二进制已被更新则自杀重启
    private var startBinaryMtime: Date?

    func run() {
        LogHelper.bootstrap()
        service.recoverState()

        listener = HelperConfig.machServiceName.withCString { name in
            xpc_connection_create_mach_service(name, serverQueue, XPC_CONNECTION_MACH_SERVICE_LISTENER)
        }
        guard let listener else {
            LogHelper.error("无法创建 mach service 监听"); return
        }
        xpc_connection_set_event_handler(listener) { [weak self] event in
            guard let self else { return }
            if xpc_get_type(event) == XPC_TYPE_CONNECTION {
                self.accept(peer: event)
            }
        }
        xpc_connection_resume(listener)
        startBinaryMtime = currentBinaryMtime()
        LogHelper.info("XPC 监听就绪: \(HelperConfig.machServiceName)")

        // 空闲退出看门狗: 15s 无对端连接则退出, 由 launchd 按需重启
        let timer = DispatchSource.makeTimerSource(queue: serverQueue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self, self.peerCount == 0 else { return }
            LogHelper.info("空闲退出, 待 launchd 按需重启")
            exit(0)
        }
        timer.resume()
        idleTimer = timer

        dispatchMain() // launchd 生命周期内常驻
    }

    private func currentBinaryMtime() -> Date? {
        guard let path = PeerValidator.rawExecutablePath() else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func accept(peer peerConn: xpc_connection_t) {
        // 二进制已被替换 (重装/升级): 立即退出, launchd 用新代码响应本次及后续连接。
        // 客户端会收到连接中断并自动重建连接重试 (HelperClient.failAllPending)。
        if let start = startBinaryMtime, let now = currentBinaryMtime(), now != start {
            LogHelper.info("检测到 helper 二进制已更新, 重启以加载新代码")
            exit(0)
        }
        let identity: PeerValidator.PeerIdentity
        do {
            identity = try PeerValidator.validate(connection: peerConn)
        } catch {
            LogHelper.error("拒绝连接: \(error)")
            xpc_connection_cancel(peerConn)
            return
        }
        LogHelper.info("接受连接: pid=\(identity.pid) euid=\(identity.euid) auid=\(identity.auid) ident=\(identity.codeIdentifier ?? "?")")
        peerCount += 1

        xpc_connection_set_event_handler(peerConn) { [weak self] message in
            guard let self else { return }
            let t = xpc_get_type(message)
            if t == XPC_TYPE_DICTIONARY {
                self.handle(connection: peerConn, identity: identity, message: message)
            } else if t == XPC_TYPE_ERROR {
                // 对端断开/连接失效
                self.peerCount = max(0, self.peerCount - 1)
            }
        }
        xpc_connection_resume(peerConn)
    }

    private func handle(connection: xpc_connection_t, identity: PeerValidator.PeerIdentity, message: xpc_object_t) {
        let op = xpc_dictionary_get_string(message, HelperMessageKey.op).map(String.init)
        let bsd = xpc_dictionary_get_string(message, HelperMessageKey.bsd).map(String.init)
        let seq = xpc_dictionary_get_uint64(message, HelperMessageKey.seq)
        // 客户端随请求携带界面语言, helper 错误消息按此组装
        let lang = xpc_dictionary_get_string(message, HelperMessageKey.lang).map(String.init) ?? "en"

        // 会话校验: 请求必须来自登录会话用户, 且 euid 与 auid 一致 (防止越会话/服务侧请求)
        // audit uid 的哨兵值: 0xFFFFFFFF (-1 无会话) 与 0xFFFFFFFE (未设置)
        guard identity.auid != 0xFFFFFFFF, identity.auid != 0xFFFFFFFE, identity.auid != 0,
              identity.euid == identity.auid else {
            LogHelper.error("拒绝请求: 会话身份异常 auid=\(identity.auid) euid=\(identity.euid)")
            sendReply(connection: connection, seq: seq, ok: false,
                      error: "请求者会话身份异常, 已拒绝", extra: [:])
            return
        }

        func reply(_ ok: Bool, error: String? = nil, extra: [String: Any] = [:]) {
            sendReply(connection: connection, seq: seq, ok: ok, error: error, extra: extra)
        }

        switch op {
        case HelperOp.version:
            reply(true, extra: [HelperMessageKey.version: "M2-0.2.0"])

        case HelperOp.list:
            reply(true, extra: [HelperMessageKey.volumes: service.listVolumes()])

        case HelperOp.mount:
            guard let bsd else { reply(false, error: "缺少 bsd 参数"); break }
            service.mountVolumeReadWrite(bsd: bsd, euid: identity.euid, egid: identity.egid, lang: lang) { mnt, err in
                self.sendReply(connection: connection, seq: seq, ok: err == nil,
                               error: err,
                               extra: mnt.map { [HelperMessageKey.mountPoint: $0] } ?? [:])
            }

        case HelperOp.unmount:
            guard let bsd else { reply(false, error: "缺少 bsd 参数"); break }
            service.unmountVolume(bsd: bsd, lang: lang) { _, err in
                self.sendReply(connection: connection, seq: seq, ok: err == nil, error: err, extra: [:])
            }

        case HelperOp.eject:
            guard let bsd else { reply(false, error: "缺少 bsd 参数"); break }
            service.ejectWholeDisk(bsd: bsd, lang: lang) { result, err in
                self.sendReply(connection: connection, seq: seq, ok: err == nil, error: err,
                               extra: result.map { [HelperMessageKey.detail: $0] } ?? [:])
            }

        case HelperOp.diagnose:
            reply(true, extra: [HelperMessageKey.detail: service.diagnose(lang: lang)])

        default:
            reply(false, error: "未知操作: \(op ?? "nil")")
        }
    }

    private func sendReply(connection: xpc_connection_t, seq: UInt64, ok: Bool,
                           error: String?, extra: [String: Any]) {
        var out: [String: xpc_object_t] = [
            HelperMessageKey.seq: xpc_uint64_create(seq),
            HelperMessageKey.ok: xpc_bool_create(ok),
        ]
        if let error { out[HelperMessageKey.error] = xpc_string_create(error) }
        for (key, value) in extra {
            switch value {
            case let s as String:
                // macOS 27.3 beta 实测: xpc_string 传输长文本会被截断 (~85 字符),
                // 改用 xpc_data (显式长度) 编码所有顶层字符串字段
                let d = Data(s.utf8)
                d.withUnsafeBytes { raw in
                    out[key] = xpc_data_create(raw.baseAddress, d.count)
                }
            case let arr as [[String: Any]]:
                var items: [xpc_object_t] = []
                for item in arr {
                    var inner: [String: xpc_object_t] = [:]
                    for (k, v) in item {
                        switch v {
                        case let s as String: inner[k] = xpc_string_create(s)
                        case let b as Bool:   inner[k] = xpc_bool_create(b)
                        default:              inner[k] = xpc_string_create("\(v)")
                        }
                    }
                    items.append(makeXPCDict(inner))
                }
                out[key] = xpc_array_create(items, items.count)
            default:
                out[key] = xpc_string_create("\(value)")
                LogHelper.warn("回包字段 \(key) 按字符串编码: \(type(of: value))")
            }
        }
        xpc_connection_send_message(connection, makeXPCDict(out))
    }
}

// MARK: - 入口

let server = HelperXPCServer()
server.run()
