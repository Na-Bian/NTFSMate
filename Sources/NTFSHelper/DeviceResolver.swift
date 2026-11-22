import Foundation
import Darwin

/// 设备解析与复核。客户端只提交 BSD 名, 这里完成全部识别工作:
/// diskutil 复核 → NTFS 类型校验 → 原生挂载点探测 → 镜像来源比对 (测试期准入)。
enum DeviceResolver {
    struct VolumeFacts {
        let bsdName: String          // disk4s2 / disk4
        let deviceNode: String       // /dev/disk4s2
        let wholeDiskBSD: String     // disk4
        let volumeName: String
        let mountPoint: String?      // 系统当前挂载点 (可能为只读原生挂载)
        let filesystemType: String   // "ntfs"
        let isWholeDisk: Bool
        let isInternal: Bool         // 内置盘
        let isRemovableOrExternal: Bool
        let isWritableMedia: Bool    // 介质可写 (与当前挂载读写状态无关)
    }

    /// 生产介质准入 (修订计划 §二): 只接管【外接可移除且介质可写】的 NTFS 数据卷。
    /// 磁盘镜像 (raw dmg 附载) 天然满足 Internal=false/Removable=true/WritableMedia=true。
    static func isAllowedMedia(_ facts: VolumeFacts) -> Bool {
        !facts.isInternal && facts.isRemovableOrExternal && facts.isWritableMedia
    }

    enum ResolutionError: Error, CustomStringConvertible {
        case notFound(String)
        case notNTFS(String)
        case malformed(String)
        var description: String {
            switch self {
            case .notFound(let dev):   return "设备不存在或已分离: \(dev)"
            case .notNTFS(let dev):    return "设备不是 NTFS 卷: \(dev)"
            case .malformed(let what): return "diskutil 输出异常: \(what)"
            }
        }
    }

    /// diskutil info -plist 解析 + 复核
    static func resolve(bsd rawBSD: String) throws -> VolumeFacts {
        // 入参加固: 只允许合法 BSD 名字符, 防注入
        let bsd = rawBSD.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bsd.isEmpty, bsd.count <= 32,
              bsd.allSatisfy({ ($0.isLetter && $0.isASCII) || $0.isNumber }) else {
            throw ResolutionError.malformed("非法设备名: \(rawBSD)")
        }
        let r = ProcessRunner.run(executable: "/usr/sbin/diskutil", arguments: ["info", "-plist", bsd])
        guard r.succeeded, let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any] else {
            throw ResolutionError.notFound(bsd)
        }
        guard let node = dict["DeviceNode"] as? String,
              let fsType = dict["FilesystemType"] as? String else {
            throw ResolutionError.malformed("DeviceNode/FilesystemType 缺失")
        }
        guard fsType.lowercased().hasPrefix("ntfs") else {
            throw ResolutionError.notNTFS(bsd)
        }
        let wholeDisk = (dict["WholeDisk"] as? Bool == true) ? bsd : parentDisk(of: bsd)
        return VolumeFacts(bsdName: bsd,
                           deviceNode: node,
                           wholeDiskBSD: wholeDisk,
                           volumeName: (dict["VolumeName"] as? String) ?? bsd,
                           mountPoint: dict["MountPoint"] as? String,
                           filesystemType: fsType,
                           isWholeDisk: dict["WholeDisk"] as? Bool == true,
                           isInternal: dict["Internal"] as? Bool ?? true,
                           isRemovableOrExternal: dict["RemovableMediaOrExternalDevice"] as? Bool ?? false,
                           isWritableMedia: dict["WritableMedia"] as? Bool ?? false)
    }

    static func parentDisk(of bsd: String) -> String {
        // disk4s2 → disk4; disk4 → disk4
        // 必须锚定"结尾的 s+数字"——朴素搜索首个 "s" 会命中 "disk" 里的 s,
        // 导致 wholeDiskBSD 误判为切片自身 (同盘串行化/整盘弹出全部失效)
        if let range = bsd.range(of: "s[0-9]+$", options: .regularExpression) {
            return String(bsd[..<range.lowerBound])
        }
        return bsd
    }

    // MARK: - 挂载表 (getmntinfo, 无需外部进程)

    struct MountEntry {
        let mountPoint: String
        let fromName: String      // nfs 的 localhost:/xxx 或 /dev/diskXsY
        let filesystem: String
        let isReadOnly: Bool
    }

    static func currentMounts() -> [MountEntry] {
        let needed = getfsstat(nil, 0, MNT_WAIT)
        guard needed > 0 else { return [] }
        let buf = UnsafeMutablePointer<statfs>.allocate(capacity: Int(needed))
        defer { buf.deallocate() }
        let count = getfsstat(buf, needed * Int32(MemoryLayout<statfs>.stride), MNT_WAIT)
        guard count > 0 else { return [] }
        var entries: [MountEntry] = []
        for i in 0..<Int(count) {
            let fs = buf[i]
            entries.append(MountEntry(
                mountPoint: cString(of: fs.f_mntonname),
                fromName: cString(of: fs.f_mntfromname),
                filesystem: cString(of: fs.f_fstypename),
                isReadOnly: fs.f_flags & UInt32(MNT_RDONLY) != 0))
        }
        return entries
    }

    /// statfs 的定长 CChar 元组字段 → Swift String (读到首个 NUL)
    private static func cString<T>(of field: T) -> String {
        withUnsafeBytes(of: field) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    static func mountEntry(atPath path: String) -> MountEntry? {
        currentMounts().first { $0.mountPoint == path }
    }

    // MARK: - 磁盘镜像来源 (hdiutil info -plist)

    /// dev → image 路径映射
    /// dev → image 路径映射。
    /// macOS 27 实测 plist 结构: images[].image-path + images[].system-entities[].dev-entry
    /// (旧文档的 dev-entries 键不存在); image 条目另含 owner-uid (附载会话属主), root 可见。
    static func backingImageMap() -> [String: String] {
        let r = ProcessRunner.run(executable: "/usr/bin/hdiutil", arguments: ["info", "-plist"])
        guard r.succeeded, let data = r.stdout.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = plist as? [String: Any],
              let images = dict["images"] as? [[String: Any]] else {
            LogHelper.warn("hdiutil info -plist 解析失败: " + r.failureDescription)
            return [:]
        }
        var map: [String: String] = [:]
        for image in images {
            guard let imagePath = image["image-path"] as? String else { continue }
            if let entities = image["system-entities"] as? [[String: Any]] {
                for e in entities {
                    if let dev = e["dev-entry"] as? String {
                        map[dev] = imagePath
                        map[dev.replacingOccurrences(of: "/dev/", with: "")] = imagePath
                    }
                }
            }
        }
        return map
    }

    // MARK: - go-nfsv4 (fuse-t 后端) 定位

    /// 返回应设置到 ntfs-3g 环境的 FUSE_NFSSRV_PATH (系统安装存在时返回 nil 表示不需要)
    static func goNfsv4Path(forUserHome userHome: String?) -> String? {
        if FileManager.default.isExecutableFile(atPath: "/usr/local/bin/go-nfsv4") { return nil }
        if let userHome {
            let candidate = URL(fileURLWithPath: userHome)
                .appendingPathComponent(".fuse-t/usr/local/bin/go-nfsv4").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func consoleUserHome(forUID uid: uid_t) -> String? {
        guard let pw = getpwuid(uid_t(uid)) else { return nil }
        let home = String(cString: pw.pointee.pw_dir)
        return home.isEmpty ? nil : home
    }
}
