// swift-tools-version:6.2
// NTFSMate — macOS 菜单栏 NTFS 读写工具
// 目标: NTFSShared(XPC 协议) / NTFSMateApp(菜单栏应用) / NTFSHelper(特权 daemon)
import PackageDescription

let package = Package(
    name: "NTFSMate",
    platforms: [.macOS(.v26)],
    targets: [
        .target(name: "NTFSShared"),
        .executableTarget(name: "NTFSMateApp", dependencies: ["NTFSShared"]),
        .executableTarget(name: "NTFSHelper", dependencies: ["NTFSShared"]),
    ],
    swiftLanguageModes: [.v5]
)
