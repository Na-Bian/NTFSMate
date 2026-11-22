import Foundation

/// 以固定可执行文件 + 参数数组运行外部工具 (绝不经过 shell)。
/// helper 是 root, 这里运行的每一个二进制都来自固定系统路径或应用包内受控位置。
enum ProcessRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
        var succeeded: Bool { exitCode == 0 }
        /// 供错误回传用的紧凑描述
        var failureDescription: String {
            let tail = (stderr.isEmpty ? stdout : stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty ? "退出码 \(exitCode)" : String(tail.suffix(400))
        }
    }

    static func run(executable: String, arguments: [String],
                    timeout: TimeInterval = 30,
                    environment: [String: String]? = nil) -> Result {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        if let environment { proc.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        var outData = Data(), errData = Data()
        outPipe.fileHandleForReading.readabilityHandler = { h in outData.append(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in errData.append(h.availableData) }

        do {
            try proc.run()
        } catch {
            return Result(exitCode: -1, stdout: "", stderr: "无法启动 \(executable): \(error)")
        }

        let stateLock = NSLock()
        var timedOut = false
        let watchdog = DispatchWorkItem {
            stateLock.lock(); timedOut = true; stateLock.unlock()
            if proc.isRunning { proc.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()
        stateLock.lock(); let wasTimeout = timedOut; stateLock.unlock()

        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        outData.append(outPipe.fileHandleForReading.readDataToEndOfFile())
        errData.append(errPipe.fileHandleForReading.readDataToEndOfFile())

        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        if wasTimeout {
            return Result(exitCode: proc.terminationStatus,
                          stdout: stdout, stderr: stderr + "\n[ProcessRunner] 超时(\(timeout)s)已终止")
        }
        return Result(exitCode: proc.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
