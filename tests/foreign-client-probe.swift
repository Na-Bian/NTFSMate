// foreign-client-probe.swift — M2 负向测试: 未授权进程连接 helper 应被拒绝
// 用法: swiftc -o /tmp/foreign-client-probe tests/foreign-client-probe.swift && /tmp/foreign-client-probe
// 预期: 3 秒内收不到任何应答 (helper 校验对端路径/签名后断开连接)
import Foundation

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

let semaphore = DispatchSemaphore(value: 0)
var gotReply = false

let conn = "com.ntfsmate.helper".withCString {
    xpc_connection_create_mach_service($0, DispatchQueue.global(), 0)
}
xpc_connection_set_event_handler(conn) { message in
    if xpc_get_type(message) == XPC_TYPE_DICTIONARY {
        gotReply = true
        semaphore.signal()
    } else if xpc_get_type(message) == XPC_TYPE_ERROR {
        // XPC_ERROR_CONNECTION_INVALID 等: 连接被对端/launchd 终止
        let desc = xpc_dictionary_get_string(message, XPC_ERROR_KEY_DESCRIPTION)
        print("连接错误事件: \(desc.map { String(cString: $0) } ?? "?")")
        gotReply = false
        semaphore.signal()
    }
}
xpc_connection_resume(conn)

let msg = makeXPCDict([
    "op": xpc_string_create("version"),
    "seq": xpc_uint64_create(1),
])
xpc_connection_send_message(conn, msg)

let result = semaphore.wait(timeout: .now() + 3)
if gotReply {
    print("❌ FAIL: 未授权客户端竟收到应答 — helper 的对端校验失效!")
    exit(1)
} else if result == .timedOut {
    print("✅ PASS: 未授权客户端 3 秒内无应答 (连接被 helper 校验拒绝)")
    exit(0)
} else {
    print("✅ PASS: 连接被终止 (XPC error), 未授权客户端被拒绝")
    exit(0)
}
