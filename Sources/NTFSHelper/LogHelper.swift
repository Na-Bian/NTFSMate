import Foundation
import NTFSShared
import os

/// helper 日志: 统一日志(os_log) + 文件 (/Library/Logs/NTFSMate/helper.log)
/// launchd 下的 stdout/stderr 另由 plist 的 StandardErrorPath 捕获。
/// helper 侧本地化: 客户端随请求携带语言, 这里按语言加载应用包内对应 lproj。
/// (helper 的 Bundle.main 就是应用包, lproj 已随包)
enum HelperL10n {
    static func bundle(for lang: String) -> Bundle {
        if let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
           let b = Bundle(path: path) { return b }
        return Bundle.main
    }
    static func t(_ lang: String, _ key: String) -> String {
        bundle(for: lang).localizedString(forKey: key, value: key, table: nil)
    }
    static func f(_ lang: String, _ key: String, _ args: CVarArg...) -> String {
        String(format: t(lang, key), arguments: args)
    }
}

enum LogHelper {
    private static let logger = Logger(subsystem: "com.ntfsmate.helper", category: "daemon")
    private static let logFileURL = URL(fileURLWithPath: "\(HelperConfig.helperLogDir)/helper.log")
    private static let fileLock = NSLock()

    static func bootstrap() {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: HelperConfig.helperLogDir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o755])
        info("helper 启动, pid=\(getpid())")
    }

    static func info(_ msg: String)  { log("INFO ", msg) }
    static func warn(_ msg: String)  { log("WARN ", msg) }
    static func error(_ msg: String) { log("ERROR", msg) }

    private static func log(_ level: String, _ msg: String) {
        let line = "\(level) \(DateFormatter.helperTimestamp.string(from: Date())) [\(getpid())] \(msg)"
        switch level {
        case "ERROR": logger.error("\(msg, privacy: .public)")
        case "WARN":  logger.warning("\(msg, privacy: .public)")
        default:      logger.info("\(msg, privacy: .public)")
        }
        fileLock.lock()
        defer { fileLock.unlock() }
        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil,
                          attributes: [.posixPermissions: 0o644])
        }
        if let h = try? FileHandle(forWritingTo: logFileURL) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: Data((line + "\n").utf8))
        }
    }
}

private extension DateFormatter {
    static let helperTimestamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
