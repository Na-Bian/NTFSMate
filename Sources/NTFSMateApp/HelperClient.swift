import Foundation
import NTFSShared

/// 原生 XPC 客户端封装: mach service 连接 + 序号匹配的请求/应答。
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

struct HelperVolume {
    let bsdName: String
    let wholeDiskBSD: String
    let volumeName: String
    let mountPoint: String?
    let isReadOnly: Bool
    let isManagedRW: Bool
    let backingImagePath: String?
    let kind: String

    static func from(_ dict: [String: Any]) -> HelperVolume {
        HelperVolume(bsdName: dict[VolumeDictKey.bsdName] as? String ?? "",
                     wholeDiskBSD: dict[VolumeDictKey.wholeDiskBSD] as? String ?? "",
                     volumeName: dict[VolumeDictKey.volumeName] as? String ?? "",
                     mountPoint: dict[VolumeDictKey.mountPoint] as? String,
                     isReadOnly: dict[VolumeDictKey.isReadOnly] as? Bool ?? false,
                     isManagedRW: dict[VolumeDictKey.isManagedRW] as? Bool ?? false,
                     backingImagePath: dict[VolumeDictKey.backingImagePath] as? String,
                     kind: dict[VolumeDictKey.kind] as? String ?? "")
    }
}

enum HelperClientError: Error, LocalizedError {
    case notConnected
    case requestFailed(String)
    var errorDescription: String? {
        switch self {
        case .notConnected: return L10n.t("err.connInterrupted")
        case .requestFailed(let m): return m
        }
    }
}

final class HelperClient {
    static let shared = HelperClient()

    private var connection: xpc_connection_t?
    private let lock = NSLock()
    private var pending: [UInt64: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextSeq: UInt64 = 1

    private let replyQueue = DispatchQueue(label: "com.ntfsmate.app.helper.reply")

    /// 建立连接 (每次请求前调用, 连接惰性复用)
    private func ensureConnection() throws -> xpc_connection_t {
        lock.lock()
        defer { lock.unlock() }
        if let connection { return connection }
        let conn: xpc_connection_t = HelperConfig.machServiceName.withCString {
            xpc_connection_create_mach_service($0, replyQueue, 0)
        }
        xpc_connection_set_event_handler(conn) { [weak self] message in
            guard let self else { return }
            let t = xpc_get_type(message)
            if t == XPC_TYPE_DICTIONARY {
                self.routeReply(message)
            } else if t == XPC_TYPE_ERROR {
                // 连接被对端拒绝/中断 (helper 校验失败、退出、launchd 无此服务):
                // 立即让所有挂起请求失败, 不等看门狗 (否则 UI 会长时间无响应)
                let desc = xpc_dictionary_get_string(message, XPC_ERROR_KEY_DESCRIPTION)
                    .map { String(cString: $0) } ?? "未知 XPC 错误"
                self.failAllPending(reason: L10n.f("err.connInterrupted") + " (\(desc))")
            }
        }
        xpc_connection_resume(conn)
        connection = conn
        return conn
    }

    /// helper 不可达时清理连接, 下次请求重建 (对应 "helper 重启有明确结果")
    private func invalidateConnection() {
        lock.lock()
        defer { lock.unlock() }
        if let connection {
            xpc_connection_cancel(connection)
            self.connection = nil
        }
        failAllPendingLocked()
    }

    /// 连接异常 (被拒/中断) 时让全部挂起请求立即失败
    private func failAllPending(reason: String) {
        lock.lock()
        defer { lock.unlock() }
        failAllPendingLocked(reason: reason)
    }

    /// 调用方须已持锁。同时废弃当前连接, 下次请求重建 (对应 "helper 重启有明确结果")
    private func failAllPendingLocked(reason: String = "helper 连接中断 (可能已重启或未批准)") {
        if let c = connection {
            xpc_connection_cancel(c)
            connection = nil
        }
        for (_, cont) in pending {
            cont.resume(returning: [HelperMessageKey.ok: false,
                                    HelperMessageKey.error: reason])
        }
        pending.removeAll()
    }

    /// 顶层字符串字段: helper 以 xpc_data 编码 (规避 macOS 27.3 beta 的 xpc_string 长文本截断),
    /// 读取时优先 data、兼容 string
    private func readStringField(_ message: xpc_object_t, _ key: String) -> String? {
        var len: Int = 0
        if let p = xpc_dictionary_get_data(message, key, &len), len > 0 {
            let data = Data(bytes: p, count: len)
            return String(data: data, encoding: .utf8)
        }
        if let c = xpc_dictionary_get_string(message, key) { return String(cString: c) }
        return nil
    }

    private func routeReply(_ message: xpc_object_t) {
        let seq = xpc_dictionary_get_uint64(message, HelperMessageKey.seq)
        var dict: [String: Any] = [:]
        dict[HelperMessageKey.ok] = xpc_dictionary_get_bool(message, HelperMessageKey.ok)
        if let err = readStringField(message, HelperMessageKey.error) { dict[HelperMessageKey.error] = err }
        if let v = readStringField(message, HelperMessageKey.version) { dict[HelperMessageKey.version] = v }
        if let m = readStringField(message, HelperMessageKey.mountPoint) { dict[HelperMessageKey.mountPoint] = m }
        if let d = readStringField(message, HelperMessageKey.detail) { dict[HelperMessageKey.detail] = d }
        if let arr = xpc_dictionary_get_array(message, HelperMessageKey.volumes) {
            var vols: [[String: Any]] = []
            let count = xpc_array_get_count(arr)
            for i in 0..<count {
                guard let item = xpc_array_get_dictionary(arr, i) else { continue }
                var vol: [String: Any] = [:]
                if let s = xpc_dictionary_get_string(item, VolumeDictKey.bsdName) { vol[VolumeDictKey.bsdName] = String(cString: s) }
                if let s = xpc_dictionary_get_string(item, VolumeDictKey.wholeDiskBSD) { vol[VolumeDictKey.wholeDiskBSD] = String(cString: s) }
                if let s = xpc_dictionary_get_string(item, VolumeDictKey.volumeName) { vol[VolumeDictKey.volumeName] = String(cString: s) }
                if let s = xpc_dictionary_get_string(item, VolumeDictKey.mountPoint) { vol[VolumeDictKey.mountPoint] = String(cString: s) }
                if let s = xpc_dictionary_get_string(item, VolumeDictKey.backingImagePath) { vol[VolumeDictKey.backingImagePath] = String(cString: s) }
                if let s = xpc_dictionary_get_string(item, VolumeDictKey.kind) { vol[VolumeDictKey.kind] = String(cString: s) }
                vol[VolumeDictKey.isReadOnly] = xpc_dictionary_get_bool(item, VolumeDictKey.isReadOnly)
                vol[VolumeDictKey.isManagedRW] = xpc_dictionary_get_bool(item, VolumeDictKey.isManagedRW)
                vols.append(vol)
            }
            dict[HelperMessageKey.volumes] = vols
        }
        lock.lock()
        let cont = pending.removeValue(forKey: seq)
        lock.unlock()
        cont?.resume(returning: dict)
    }

    @discardableResult
    private func request(op: String, bsd: String? = nil, timeout: TimeInterval = 45) async throws -> [String: Any] {
        let conn = try ensureConnection()
        let seq: UInt64 = lock.withLock {
            let s = nextSeq; nextSeq += 1; return s
        }
        var dict: [String: xpc_object_t] = [
            HelperMessageKey.op: xpc_string_create(op),
            HelperMessageKey.seq: xpc_uint64_create(seq),
            HelperMessageKey.lang: xpc_string_create(L10n.preferredLanguage),
        ]
        if let bsd { dict[HelperMessageKey.bsd] = xpc_string_create(bsd) }

        // 注册应答续体; 超时者由看门狗恢复 (pending.removeValue 保证单次恢复)
        let result: [String: Any] = try await withCheckedThrowingContinuation { cont in
            lock.lock()
            pending[seq] = cont
            lock.unlock()
            xpc_connection_send_message(conn, makeXPCDict(dict))
            let watchdog = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let c = self.pending.removeValue(forKey: seq)
                self.lock.unlock()
                c?.resume(throwing: HelperClientError.requestFailed("\(L10n.t("err.timeout")) (\(op), \(timeout)s)"))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        }
        return result
    }

    // MARK: - 对外 API (异步)

    func version() async throws -> String {
        let r = try await request(op: HelperOp.version)
        if r[HelperMessageKey.ok] as? Bool == true, let v = r[HelperMessageKey.version] as? String { return v }
        throw HelperClientError.requestFailed(r[HelperMessageKey.error] as? String ?? L10n.t("helper.status.unknown"))
    }

    func listVolumes() async throws -> [HelperVolume] {
        let r = try await request(op: HelperOp.list)
        if r[HelperMessageKey.ok] as? Bool == true,
           let vols = r[HelperMessageKey.volumes] as? [[String: Any]] {
            return vols.map(HelperVolume.from)
        }
        throw HelperClientError.requestFailed(r[HelperMessageKey.error] as? String ?? L10n.t("helper.status.unknown"))
    }

    func mountReadWrite(bsd: String) async throws -> String {
        let r = try await request(op: HelperOp.mount, bsd: bsd, timeout: 60)
        if r[HelperMessageKey.ok] as? Bool == true, let m = r[HelperMessageKey.mountPoint] as? String { return m }
        throw HelperClientError.requestFailed(r[HelperMessageKey.error] as? String ?? L10n.t("helper.status.unknown"))
    }

    func unmount(bsd: String) async throws {
        let r = try await request(op: HelperOp.unmount, bsd: bsd, timeout: 45)
        if r[HelperMessageKey.ok] as? Bool != true {
            throw HelperClientError.requestFailed(r[HelperMessageKey.error] as? String ?? L10n.t("diag.empty"))
        }
    }

    func eject(bsd: String) async throws -> String {
        let r = try await request(op: HelperOp.eject, bsd: bsd, timeout: 60)
        if r[HelperMessageKey.ok] as? Bool == true, let d = r[HelperMessageKey.detail] as? String { return d }
        throw HelperClientError.requestFailed(r[HelperMessageKey.error] as? String ?? L10n.t("helper.status.unknown"))
    }

    func diagnose() async throws -> String {
        let r = try await request(op: HelperOp.diagnose)
        if r[HelperMessageKey.ok] as? Bool == true, let d = r[HelperMessageKey.detail] as? String { return d }
        throw HelperClientError.requestFailed(r[HelperMessageKey.error] as? String ?? L10n.t("helper.status.unknown"))
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
