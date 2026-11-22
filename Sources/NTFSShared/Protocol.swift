import Foundation

/// NTFSMate 主程序与特权 helper 之间的共享定义 (原生 XPC 字典协议)。
/// 客户端只能提交"意图 + 卷标识"; helper 自行解析设备、复核权限并执行。

public enum HelperConfig {
    /// launchd MachServices 注册名 = XPC mach service 名
    public static let machServiceName = "com.ntfsmate.helper"
    /// Contents/Library/LaunchDaemons/ 内的 plist 文件名
    public static let helperPlistName = "com.ntfsmate.helper.plist"
    public static let appBundleIdentifier = "com.ntfsmate.app"
    public static let appExecutableName = "NTFSMate"
    public static let helperExecutableName = "ntfs-helper"
    /// .app 内 ntfs-3g 套件的资源目录名
    public static let ntfs3gResourceDirName = "ntfs3g"
    /// helper 日志目录 (root 可写)
    public static let helperLogDir = "/Library/Logs/NTFSMate"
}

public enum HelperMessageKey {
    public static let op = "op"
    public static let bsd = "bsd"
    public static let seq = "seq"
    public static let lang = "lang"
    public static let ok = "ok"
    public static let error = "error"
    public static let version = "version"
    public static let volumes = "volumes"
    public static let mountPoint = "mountPoint"
    public static let detail = "detail"
}

public enum HelperOp {
    public static let version = "version"
    public static let list = "list"
    public static let mount = "mount"
    public static let unmount = "unmount"
    public static let eject = "eject"
    public static let diagnose = "diagnose"
}

/// 卷条目字典的键 (helper → client)
public enum VolumeDictKey {
    public static let bsdName = "bsdName"           // 分区/卷设备名, 如 disk4s2 或 disk4
    public static let wholeDiskBSD = "wholeDiskBSD" // 整盘设备名, 如 disk4
    public static let volumeName = "volumeName"
    public static let mountPoint = "mountPoint"     // nil/无键 = 未挂载
    public static let isReadOnly = "isReadOnly"
    public static let isManagedRW = "isManagedRW"   // 由 helper 托管的读写挂载
    public static let backingImagePath = "backingImagePath" // 磁盘镜像来源路径 (仅镜像卷)
    public static let kind = "kind"                 // "image" | "disk"
}
