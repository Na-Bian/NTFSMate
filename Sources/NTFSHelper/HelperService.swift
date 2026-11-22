import Foundation
import NTFSShared
import Darwin

/// 卷操作服务: 串行化每块盘上的操作, 托管 ntfs-3g 进程, 维护真实挂载状态。
/// 全部操作执行 M1 已验证的流程 (docs/M1-FINDINGS.md §六):
///   挂载:  复核设备 → (已挂载则先非强制卸载) → 受控挂载点 → root 启动 ntfs-3g
///          (no_detach/norecover) → 轮询挂载表核实 (nfs + 非只读) → 记录状态
///   卸载:  非强制 diskutil unmount → 轮询驱动退出 (SIGTERM 仅作孤儿清理) → 清理挂载点
///   弹出:  逐卷非强制卸载 → 整盘 diskutil eject → 核实
final class HelperService {
    private struct VolumeState {
        let bsdName: String
        let wholeDiskBSD: String
        let mountPoint: String
        var ntfs3gProcess: Process?
        var ntfs3gPID: pid_t?
    }

    private let statesLock = NSLock()
    private var states: [String: VolumeState] = [:]   // bsdName → state
    private var diskQueues: [String: DispatchQueue] = [:]  // wholeDiskBSD → 串行队列
    private let queuesLock = NSLock()

    /// 应用包内 ntfs-3g 位置
    private lazy var ntfs3gPath: String? = {
        guard let bundle = PeerValidator.helperOwnBundleURL() else { return nil }
        let p = bundle.appendingPathComponent("Contents/Resources/\(HelperConfig.ntfs3gResourceDirName)/ntfs-3g").path
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }()

    private func diskQueue(for wholeDisk: String) -> DispatchQueue {
        queuesLock.lock()
        defer { queuesLock.unlock() }
        if let q = diskQueues[wholeDisk] { return q }
        let q = DispatchQueue(label: "com.ntfsmate.helper.disk.\(wholeDisk)")
        diskQueues[wholeDisk] = q
        return q
    }

    // MARK: - list

    func listVolumes() -> [[String: Any]] {
        statesLock.lock(); defer { statesLock.unlock() }
        var result: [[String: Any]] = []
        let imageMap = DeviceResolver.backingImageMap()

        let r = ProcessRunner.run(executable: "/usr/sbin/diskutil", arguments: ["list", "-plist"])
        guard r.succeeded, let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let root = plist as? [String: Any],
              let allDisks = root["AllDisksAndPartitions"] as? [[String: Any]] else {
            LogHelper.error("diskutil list -plist 解析失败: \(r.failureDescription)")
            return result
        }
        for disk in allDisks {
            let wholeDiskBSD = disk["DeviceIdentifier"] as? String ?? ""
            let backingImage = imageMap[wholeDiskBSD]
            var entries: [[String: Any]] = []
            // 分区条目
            if let partitions = disk["Partitions"] as? [[String: Any]] {
                for part in partitions {
                    if let fs = part["FilesystemType"] as? String, fs.lowercased().hasPrefix("ntfs") {
                        entries.append(volumeDict(bsd: part["DeviceIdentifier"] as? String ?? "",
                                                  wholeDisk: wholeDiskBSD,
                                                  name: part["VolumeName"] as? String,
                                                  mountPoint: part["MountPoint"] as? String,
                                                  backingImage: backingImage))
                    }
                }
            }
            // 整盘含 FS 的镜像卷 (raw 镜像无分区表)
            if let fs = disk["FilesystemType"] as? String, fs.lowercased().hasPrefix("ntfs") {
                entries.append(volumeDict(bsd: wholeDiskBSD, wholeDisk: wholeDiskBSD,
                                          name: disk["VolumeName"] as? String,
                                          mountPoint: disk["MountPoint"] as? String,
                                          backingImage: backingImage))
            }
            // diskutil list 对无分区表的整盘 FS 不输出 FilesystemType, 补一次 info 复核
            if entries.isEmpty, !wholeDiskBSD.isEmpty, disk["VolumeName"] != nil {
                if let facts = try? DeviceResolver.resolve(bsd: wholeDiskBSD),
                   facts.filesystemType.lowercased().hasPrefix("ntfs") {
                    entries.append(volumeDict(bsd: wholeDiskBSD, wholeDisk: wholeDiskBSD,
                                              name: facts.volumeName,
                                              mountPoint: facts.mountPoint,
                                              backingImage: backingImage))
                }
            }
            result.append(contentsOf: entries)
        }
        // helper 托管但 diskutil 未上报的 (理论上不该出现; 防御性补充)
        for (bsd, st) in states where !result.contains(where: { $0[VolumeDictKey.bsdName] as? String == bsd }) {
            // 死挂载防护: 挂载点不在当前挂载表的托管条目不展示
            guard let e = DeviceResolver.mountEntry(atPath: st.mountPoint), e.filesystem == "nfs" else {
                continue
            }
            result.append(volumeDict(bsd: bsd, wholeDisk: st.wholeDiskBSD,
                                     name: (st.mountPoint as NSString).lastPathComponent,
                                     mountPoint: st.mountPoint, backingImage: nil))
        }
        return result
    }

    private func volumeDict(bsd: String, wholeDisk: String, name: String?, mountPoint: String?,
                            backingImage: String?) -> [String: Any] {
        var d: [String: Any] = [
            VolumeDictKey.bsdName: bsd,
            VolumeDictKey.wholeDiskBSD: wholeDisk,
            VolumeDictKey.volumeName: name ?? bsd,
            VolumeDictKey.isReadOnly: false,
            VolumeDictKey.isManagedRW: false,
        ]
        // 托管状态的挂载点优先 (diskutil 对 NFS 挂载可能不回填 MountPoint)
        let managed = states[bsd]
        let effectiveMountPoint = managed?.mountPoint ?? mountPoint
        if let mp = effectiveMountPoint, !mp.isEmpty {
            d[VolumeDictKey.mountPoint] = mp
            if let e = DeviceResolver.mountEntry(atPath: mp) {
                d[VolumeDictKey.isReadOnly] = e.isReadOnly
            }
        }
        if managed != nil { d[VolumeDictKey.isManagedRW] = true }
        if let backingImage {
            d[VolumeDictKey.backingImagePath] = backingImage
            d[VolumeDictKey.kind] = "image"
        } else {
            d[VolumeDictKey.kind] = "disk"
        }
        return d
    }

    // MARK: - mount

    func mountVolumeReadWrite(bsd: String, euid: uid_t, egid: gid_t, lang: String, reply: @escaping (String?, String?) -> Void) {
        guard let ntfs3g = ntfs3gPath else {
            reply(nil, HelperL10n.t(lang, "err.internal.noNTFS3G")); return
        }
        let q: DispatchQueue
        do {
            let facts = try DeviceResolver.resolve(bsd: bsd)
            q = diskQueue(for: facts.wholeDiskBSD)
        } catch {
            reply(nil, self.localizedOperationError(lang, error)); return
        }
        q.async {
            do {
                let mountPoint = try self.doMount(bsd: bsd, ntfs3g: ntfs3g, euid: euid, egid: egid, lang: lang)
                reply(mountPoint, nil)
            } catch {
                LogHelper.error("挂载 \(bsd) 失败: \(error)")
                reply(nil, self.localizedOperationError(lang, error))
            }
        }
    }

    private func doMount(bsd: String, ntfs3g: String, euid: uid_t, egid: gid_t, lang: String) throws -> String {
        let facts = try DeviceResolver.resolve(bsd: bsd)
        LogHelper.info("挂载请求: \(bsd) (\(facts.deviceNode)) 卷名=\(facts.volumeName) euid=\(euid)")

        // 守卫: 该设备可能已被孤儿 ntfs-3g 挂载中 (helper 重启后状态丢失) — 先尝试采纳
        recoverState()
        statesLock.lock()
        let adopted = states[bsd]
        statesLock.unlock()
        if let ad = adopted, let entry = DeviceResolver.mountEntry(atPath: ad.mountPoint),
           entry.filesystem == "nfs" {
            LogHelper.info("\(bsd) 已有存活托管挂载 (孤儿采纳): \(ad.mountPoint)")
            return ad.mountPoint
        }

        // 生产介质准入: 外接可移除且介质可写的 NTFS 数据卷 (磁盘镜像天然满足)
        guard DeviceResolver.isAllowedMedia(facts) else {
            throw MountError.policyDenied(HelperL10n.t(lang, "err.policy.denied"))
        }
        let userHome = DeviceResolver.consoleUserHome(forUID: euid)

        // 1) 若已挂载: 已托管(四重验证) → 直接返回; 原生只读 → 非强制卸载
        if let native = facts.mountPoint, !native.isEmpty {
            if let st = states[bsd] {
                // 陈旧状态防护: 挂载点必须存活 + nfs + 非只读 + 驱动进程存活,
                // 否则视为死状态清除 (审计: 严禁把原生只读挂载误报为读写成功)
                let pidAlive = st.ntfs3gPID.map { kill($0, 0) == 0 } ?? false
                if let e = DeviceResolver.mountEntry(atPath: st.mountPoint),
                   e.filesystem == "nfs", !e.isReadOnly, pidAlive {
                    LogHelper.info("\(bsd) 已由本 helper 托管于 \(st.mountPoint)")
                    return st.mountPoint
                }
                LogHelper.warn("\(bsd) 托管状态已陈旧 (挂载点 \(st.mountPoint) 已死或降级), 清除后重新挂载")
                statesLock.lock(); states[bsd] = nil; statesLock.unlock()
            }
            if let entry = DeviceResolver.mountEntry(atPath: native), entry.filesystem == "ntfs" {
                LogHelper.info("卸载原生只读挂载 \(native)")
                let r = ProcessRunner.run(executable: "/usr/sbin/diskutil",
                                          arguments: ["unmount", native], timeout: 15)
                guard r.succeeded else {
                    throw MountError.busy(HelperL10n.f(lang, "err.busy.unmountNative", r.failureDescription))
                }
            } else {
                throw MountError.busy(HelperL10n.f(lang, "err.busy.nativeNotNTFS", native))
            }
        }

        // 2) 复核介质仍在线
        let reFacts: DeviceResolver.VolumeFacts
        do { reFacts = try DeviceResolver.resolve(bsd: bsd) }
        catch { throw MountError.mediaGone(HelperL10n.f(lang, "err.mediaGone.afterUnmount", bsd)) }
        let deviceNode = reFacts.deviceNode

        // 3) 受控挂载点
        let mountPoint = try createMountPoint(for: reFacts, lang: lang)
        LogHelper.info("挂载点: \(mountPoint)")

        // 4) 启动 ntfs-3g (前台 no_detach, norecover), helper 托管进程
        var env: [String: String] = ProcessInfo.processInfo.environment
        if let nfssrv = DeviceResolver.goNfsv4Path(forUserHome: userHome) {
            env["FUSE_NFSSRV_PATH"] = nfssrv
        }
        let logPath = "\(HelperConfig.helperLogDir)/ntfs-3g-\(bsd).log"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ntfs3g)
        proc.arguments = [deviceNode, mountPoint,
                          "-o", "norecover,no_detach,uid=\(euid),gid=\(egid),noatime"]
        proc.environment = env
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil,
                                           attributes: [.posixPermissions: 0o644])
        }
        let logFile = FileHandle(forWritingAtPath: logPath) ?? FileHandle.nullDevice
        proc.standardOutput = logFile
        proc.standardError = logFile
        do { try proc.run() }
        catch { try? FileManager.default.removeItem(atPath: mountPoint)
                throw MountError.internalError(HelperL10n.f(lang, "err.internal.spawnFail", "\(error)")) }

        // 5) 轮询挂载表: 类型 nfs 且非只读 (不只因进程存活而判定成功)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if proc.isRunning == false {
                let tail = lastLines(of: logPath, 5)
                try? FileManager.default.removeItem(atPath: mountPoint)
                throw MountError.internalError(HelperL10n.f(lang, "err.internal.earlyExit", tail))
            }
            if let entry = DeviceResolver.mountEntry(atPath: mountPoint),
               entry.filesystem == "nfs", !entry.isReadOnly {
                let st = VolumeState(bsdName: bsd, wholeDiskBSD: reFacts.wholeDiskBSD,
                                     mountPoint: mountPoint,
                                     ntfs3gProcess: proc, ntfs3gPID: proc.processIdentifier)
                statesLock.lock(); states[bsd] = st; statesLock.unlock()
                LogHelper.info("挂载成功: \(bsd) → \(mountPoint) pid=\(proc.processIdentifier)")
                return mountPoint
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // 超时: 异常清理 (SIGTERM 仅用于异常路径)
        if proc.isRunning { proc.terminate() }
        try? FileManager.default.removeItem(atPath: mountPoint)
        throw MountError.internalError(HelperL10n.f(lang, "err.internal.timeout", lastLines(of: logPath, 5)))
    }

    private func createMountPoint(for facts: DeviceResolver.VolumeFacts, lang: String) throws -> String {
        let fm = FileManager.default
        let base = sanitizeName(facts.volumeName.isEmpty ? facts.bsdName : facts.volumeName)
        var candidate = "/Volumes/\(base)"
        var n = 1
        while true {
            switch fm.fileExists(atPath: candidate) {
            case false:
                do {
                    try fm.createDirectory(atPath: candidate, withIntermediateDirectories: false,
                                           attributes: [.posixPermissions: 0o755])
                    return candidate
                } catch {
                    throw MountError.internalError(HelperL10n.f(lang, "err.internal.mountpointFail", "\(candidate): \(error)"))
                }
            case true:
                // 已存在: 仅当为 root 属主且为空目录时复用, 否则换名
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue,
                   (try? fm.contentsOfDirectory(atPath: candidate))?.isEmpty == true {
                    let attrs = try? fm.attributesOfItem(atPath: candidate)
                    if let owner = attrs?[FileAttributeKey(rawValue: "NSFileOwnerAccountID")] as? NSNumber, owner.uint32Value == 0 {
                        return candidate
                    }
                }
                n += 1
                candidate = "/Volumes/\(base)-NTFSMate\(n)"
                if n > 32 { throw MountError.internalError(HelperL10n.t(lang, "err.internal.tooMany")) }
            }
        }
    }

    /// 卷标只作显示来源; 挂载点名做严格消毒 (修订计划: 不把卷标原样拼进路径)
    private func sanitizeName(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_. ")
        let filtered = raw.unicodeScalars.filter { allowed.contains($0) }
        var name = String(String.UnicodeScalarView(filtered)).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "NTFS-Volume" }
        if name.hasPrefix(".") { name = "_" + name }
        return String(name.prefix(64))
    }

    // MARK: - unmount

    func unmountVolume(bsd: String, lang: String, reply: @escaping (String?, String?) -> Void) {
        let q: DispatchQueue
        do {
            let facts = try DeviceResolver.resolve(bsd: bsd)
            q = diskQueue(for: facts.wholeDiskBSD)
        } catch {
            reply(nil, self.localizedOperationError(lang, error)); return
        }
        q.async {
            do {
                try self.doUnmount(bsd: bsd, lang: lang)
                reply(HelperL10n.t(lang, "unmount.done"), nil)
            } catch {
                LogHelper.error("卸载 \(bsd) 失败: \(error)")
                reply(nil, self.localizedOperationError(lang, error))
            }
        }
    }

    private func doUnmount(bsd: String, lang: String) throws {
        statesLock.lock()
        let st = states[bsd]
        statesLock.unlock()
        guard let state = st else {
            // helper 重启后的孤儿挂载: 尝试恢复识别
            if recoverSingle(bsd: bsd) {
                return try doUnmount(bsd: bsd, lang: lang)
            }
            // 未托管卷 (原生只读挂载): 回退为普通非强制卸载
            let facts = try DeviceResolver.resolve(bsd: bsd)
            guard let mnt = facts.mountPoint, !mnt.isEmpty else {
                throw MountError.notManaged(HelperL10n.f(lang, "err.notManaged.mounted", bsd))
            }
            let r = ProcessRunner.run(executable: "/usr/sbin/diskutil",
                                      arguments: ["unmount", mnt], timeout: 20)
            guard r.succeeded else {
                throw MountError.busy(HelperL10n.f(lang, "err.busy.unmountRW", r.failureDescription))
            }
            LogHelper.info("卸载 (未托管回退): \(bsd) → \(mnt)")
            return
        }

        let r = ProcessRunner.run(executable: "/usr/sbin/diskutil",
                                  arguments: ["unmount", state.mountPoint], timeout: 20)
        guard r.succeeded else {
            throw MountError.busy(HelperL10n.f(lang, "err.busy.unmountRW", r.failureDescription))
        }

        // 等驱动退出 (fuse-t: 卸载完成后文件系统进程自行退出)
        let proc = state.ntfs3gProcess
        let deadline = Date().addingTimeInterval(10)
        var exited = false
        while Date() < deadline {
            if let proc { if proc.isRunning == false { exited = true; break } }
            else if let pid = state.ntfs3gPID { if kill(pid, 0) != 0 { exited = true; break } }
            else { exited = true; break }
            Thread.sleep(forTimeInterval: 0.3)
        }
        if !exited {
            // 孤儿清理 (SIGTERM 仅用于异常路径, 不作为正常弹盘手段)
            if let proc { proc.terminate() }
            else if let pid = state.ntfs3gPID { kill(pid, SIGTERM) }
            LogHelper.warn("卸载后驱动未退出, 已 SIGTERM 清理: \(bsd)")
            Thread.sleep(forTimeInterval: 1)
        }

        // 清理受控挂载点 (为空时)
        let fm = FileManager.default
        if let contents = try? fm.contentsOfDirectory(atPath: state.mountPoint), contents.isEmpty {
            try? fm.removeItem(atPath: state.mountPoint)
        }
        statesLock.lock(); states[bsd] = nil; statesLock.unlock()
        LogHelper.info("卸载完成: \(bsd) (驱动退出=\(exited ? "是" : "已强制清理"))")
    }

    // MARK: - eject (整盘)

    func ejectWholeDisk(bsd: String, lang: String, reply: @escaping (String?, String?) -> Void) {
        let q: DispatchQueue
        do {
            let facts = try DeviceResolver.resolve(bsd: bsd)
            q = diskQueue(for: facts.wholeDiskBSD)
        } catch {
            reply(nil, self.localizedOperationError(lang, error)); return
        }
        q.async {
            do {
                let wholeDisk = try DeviceResolver.resolve(bsd: bsd).wholeDiskBSD
                // 同盘所有 NTFS 卷先逐一非强制卸载 (其余分区由 diskutil eject 处理)
                let managed = self.statesLock.withLock {
                    let keys = self.states.filter { $1.wholeDiskBSD == wholeDisk }.keys.sorted()
                    LogHelper.info("整盘弹出开始: \(wholeDisk), 托管卷: \(keys)")
                    return keys
                }
                for b in managed {
                    LogHelper.info("弹出流程: 卸载 \(b)")
                    try? self.doUnmount(bsd: b, lang: lang)
                }
                LogHelper.info("弹出流程: diskutil eject \(wholeDisk)")
                let r = ProcessRunner.run(executable: "/usr/sbin/diskutil", arguments: ["eject", wholeDisk], timeout: 30)
                guard r.succeeded else {
                    LogHelper.error("整盘弹出失败: \(r.failureDescription)")
                    throw MountError.busy(HelperL10n.t(lang, "err.busy.eject"))
                }
                // 核实设备消失
                Thread.sleep(forTimeInterval: 0.5)
                if (try? DeviceResolver.resolve(bsd: wholeDisk)) != nil {
                    throw MountError.internalError(HelperL10n.f(lang, "err.internal.deviceStillThere", wholeDisk))
                }
                reply(HelperL10n.f(lang, "eject.done", wholeDisk), nil)
            } catch {
                reply(nil, self.localizedOperationError(lang, error))
            }
        }
    }

    // MARK: - diagnose / 恢复

    func diagnose(lang: String) -> String {
        let present = HelperL10n.t(lang, "diag.present")
        let missing = HelperL10n.t(lang, "diag.missing")
        var lines: [String] = []
        lines.append("helper: pid=\(getpid()), uid=\(getuid())")

        // 自身与应用包定位 (排查 BundleProgram 相对路径问题)
        let rawExec = PeerValidator.rawExecutablePath() ?? "?"
        lines.append("\(HelperL10n.t(lang, "diag.selfExec")): \(rawExec)")
        let bundle = PeerValidator.helperOwnBundleURL()
        lines.append("\(HelperL10n.t(lang, "diag.bundle")): \(bundle?.path ?? "nil")")
        if let b = bundle {
            let resDir = b.appendingPathComponent("Contents/Resources").path
            let ntfsDir = b.appendingPathComponent("Contents/Resources/\(HelperConfig.ntfs3gResourceDirName)").path
            let candidate = ntfsDir + "/ntfs-3g"
            let fm = FileManager.default
            lines.append("\(HelperL10n.t(lang, "diag.resourcesDir")): \(fm.fileExists(atPath: resDir) ? present : missing)")
            lines.append("\(HelperL10n.t(lang, "diag.ntfsDir")): \(fm.fileExists(atPath: ntfsDir) ? present : missing)")
            lines.append("\(HelperL10n.t(lang, "diag.candidate")): \(candidate) \(HelperL10n.t(lang, "diag.executable")): \(fm.isExecutableFile(atPath: candidate) ? present : missing)")
        }
        lines.append("\(HelperL10n.t(lang, "diag.parsed")): \(ntfs3gPath ?? missing)")
        if let p = ntfs3gPath {
            let v = ProcessRunner.run(executable: p, arguments: ["--version"], timeout: 10)
            lines.append("ntfs-3g --version: \(v.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) (\(HelperL10n.t(lang, "diag.exit")) \(v.exitCode))")
        }
        lines.append("go-nfsv4 \(HelperL10n.t(lang, "diag.systemPath")): \(FileManager.default.isExecutableFile(atPath: "/usr/local/bin/go-nfsv4") ? present : missing)")
        lines.append("fuse-t dylib (/usr/local/lib): \(FileManager.default.fileExists(atPath: "/usr/local/lib/libfuse-t.dylib") ? present : missing)")
        let imageMapDesc = DeviceResolver.backingImageMap()
        lines.append("\(HelperL10n.t(lang, "diag.imageMap")): \(imageMapDesc)")
        statesLock.lock()
        lines.append("\(HelperL10n.t(lang, "diag.managed")): \(states.keys.sorted().joined(separator: ", "))")
        statesLock.unlock()
        return lines.joined(separator: "\n")
    }

    /// daemon 启动时扫描重建状态 (ntfs-3g 进程存活即挂载存活)
    func recoverState() {
        let bundle = PeerValidator.helperOwnBundleURL()?.path ?? ""
        guard !bundle.isEmpty else { return }
        let r = ProcessRunner.run(executable: "/bin/ps", arguments: ["-axo", "pid=,command="])
        guard r.succeeded else { LogHelper.warn("恢复扫描 ps 失败: \(r.failureDescription)"); return }
        let prefix = bundle + "/Contents/Resources/\(HelperConfig.ntfs3gResourceDirName)/ntfs-3g"
        for line in r.stdout.split(separator: "\n") {
            let s = String(line).trimmingCharacters(in: .whitespaces)
            // ps -axo pid=,command= 输出: "<pid> <command...>"
            guard let firstSpace = s.firstIndex(of: " ") else { continue }
            guard let pid = pid_t(s[..<firstSpace]) else { continue }
            let command = String(s[s.index(after: firstSpace)...])
            guard command.hasPrefix(prefix + " ") else { continue }
            let parts = command.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // <path> <device> <mountPoint> -o <opts>
            guard parts.count >= 4, parts[3] == "-o", parts[1].hasPrefix("/dev/") else { continue }
            // 孤儿进程存活核验 (防僵尸/竞态)
            guard kill(pid, 0) == 0 else { continue }
            let device = String(parts[1].dropFirst(5))
            let mnt = parts[2]
            // 挂载点存活核验: BSD 名可能被新设备重用, 死挂载条目不得采纳
            guard let entry = DeviceResolver.mountEntry(atPath: mnt),
                  entry.filesystem == "nfs" else {
                LogHelper.warn("跳过陈旧孤儿: \(device) → \(mnt) (挂载点已不存在)")
                continue
            }
            // 设备一致性核验: 进程参数里的设备必须仍是当前挂载条目的来源
            let facts = try? DeviceResolver.resolve(bsd: device)
            statesLock.lock()
            if states[device] == nil {
                states[device] = VolumeState(bsdName: device,
                                             wholeDiskBSD: facts?.wholeDiskBSD ?? device,
                                             mountPoint: mnt, ntfs3gProcess: nil, ntfs3gPID: pid)
                LogHelper.info("恢复托管状态: \(device) → \(mnt) pid=\(pid)")
            }
            statesLock.unlock()
        }
        // 状态对账: 挂载点已死的托管条目清除 (防僵尸状态滞留)
        statesLock.lock()
        let dead = states.filter { DeviceResolver.mountEntry(atPath: $1.mountPoint)?.filesystem != "nfs" }
        for (bsd, _) in dead { states[bsd] = nil }
        statesLock.unlock()
        if !dead.isEmpty { LogHelper.warn("对账清除死状态: \(dead.keys.sorted())") }
    }

    private func recoverSingle(bsd: String) -> Bool {
        let before = statesLock.withLock { states.count }
        recoverState()
        let after = statesLock.withLock { states.count }
        return after > before
    }

    private func lastLines(of path: String, _ n: Int) -> String {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return content.split(separator: "\n").suffix(n).joined(separator: "\n")
    }
}

extension HelperService {
    /// 解析错误 → 按语言组装; MountError 已是组装好的本地化文本, 直接透传
    func localizedOperationError(_ lang: String, _ error: Error) -> String {
        if let me = error as? MountError { return me.description }
        switch error as? DeviceResolver.ResolutionError {
        case .notFound(let d):   return HelperL10n.f(lang, "err.resolve.notFound", d)
        case .notNTFS(let d):    return HelperL10n.f(lang, "err.resolve.notNTFS", d)
        case .malformed(let w):  return HelperL10n.f(lang, "err.resolve.malformed", w)
        default:                 return "\(error)"
        }
    }
}

enum MountError: Error, CustomStringConvertible {
    case policyDenied(String)
    case busy(String)
    case notManaged(String)
    case mediaGone(String)
    case internalError(String)
    var description: String {
        switch self {
        case .policyDenied(let m):  return "策略拒绝: \(m)"
        case .busy(let m):          return "卷被占用: \(m)"
        case .notManaged(let m):    return "未托管: \(m)"
        case .mediaGone(let m):     return "介质消失: \(m)"
        case .internalError(let m): return "内部错误: \(m)"
        }
    }
}

extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
