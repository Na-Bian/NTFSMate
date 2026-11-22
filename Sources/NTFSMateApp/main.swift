import SwiftUI
import ServiceManagement
import DiskArbitration
import UserNotifications
import NTFSShared

// 入口 (main.swift 顶层调用, SwiftPM 可执行目标)
NTFSMateApp.main()

// MARK: - App 场景 (菜单栏形态)

struct NTFSMateApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("NTFSMate", systemImage: "externaldrive.connected.to.line.below") {
            PanelView()
                .frame(width: 380)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 注意: 不要在此调用 setActivationPolicy(.accessory) —— LSUIElement 已声明菜单栏形态,
        // 运行时再切换策略会让 macOS 26/27 的窗口走旧版 chrome (红绿灯失去新样式)
        // 关键: 卷监控必须在启动时激活, 不能等用户首次打开面板
        // (MenuBarExtra 窗格内容是懒加载的, 不点面板 AppModel 就不存在)
        _ = AppModel.shared
    }
}

// MARK: - DiskArbitration 卷监控 (用户态)

/// 监控 NTFS 卷接入/移除。自动挂载的"触发源"; 手动操作与它共用 busyBSDs 去重。
final class VolumeMonitor {
    private var session: DASession?
    private let queue = DispatchQueue(label: "com.ntfsmate.app.da-monitor")

    var onNTFSAppeared: ((String) -> Void)?      // BSD 名 (disk4s2 / disk4)
    var onDiskAppeared: ((String, String, String?) -> Void)?  // bsd, fsKind — 全量观测 (日志)
    var onVolumeChanged: (() -> Void)?

    func start() {
        guard session == nil else { return }
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return }
        DASessionSetDispatchQueue(s, queue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, { disk, ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<VolumeMonitor>.fromOpaque(ctx).takeUnretainedValue()
            monitor.handleAppeared(disk)
        }, ctx)
        DARegisterDiskDisappearedCallback(s, nil, { _, ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<VolumeMonitor>.fromOpaque(ctx).takeUnretainedValue()
            DispatchQueue.main.async { monitor.onVolumeChanged?() }
        }, ctx)
        session = s
    }

    private func handleAppeared(_ disk: DADisk) {
        guard let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }
        let kind = (desc[kDADiskDescriptionVolumeKindKey as String] as? String ?? "").lowercased()
        // BSD 设备名须用 DADiskGetBSDName; MediaNameKey 是人类可读介质名 ("Apple 读/写 Media")
        let bsd = DADiskGetBSDName(disk).map { String(cString: $0) } ?? ""
        guard !bsd.isEmpty else { return }
        DispatchQueue.main.async {
            self.onDiskAppeared?(bsd, kind, nil)
            if kind.hasPrefix("ntfs") { self.onNTFSAppeared?(bsd) }
        }
    }
}

// MARK: - 应用模型 (MainActor 状态机)

@MainActor
final class AppModel: ObservableObject {
    /// 共享实例: 应用启动即创建 (AppDelegate 触发), 监控与面板共用
    static let shared = AppModel()

    @Published var helperStatusText: String = "未查询"
    /// FUSE-T 运行时状态: nil=未检测, true=已安装, false=缺失
    @Published var fuseTRuntimeOK: Bool?
    @Published var helperOK: Bool = false
    @Published var volumes: [HelperVolume] = []
    @Published var autoLog: String = ""
    @Published var lastDiagnose: String = ""
    @Published var showDiagnostics: Bool = false
    @Published var busyBSDs: Set<String> = []      // 操作去重: 手动+自动共用 (修订计划 M4)
    @Published var lastErrors: [String: String] = [:]   // bsd → 最近一次操作失败原因 (成功时清除)

    @AppStorage("autoMountEnabled") var autoMountEnabled: Bool = false   // 默认关闭 (修订计划 §一)
    @Published var launchAtLogin: Bool = AppModel.currentLoginItemState()

    private let client = HelperClient.shared
    private let daemonService = SMAppService.daemon(plistName: HelperConfig.helperPlistName)
    private let mainAppService = SMAppService.mainApp
    private let monitor = VolumeMonitor()

    static func currentLoginItemState() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    private init() {
        checkEnvironment()
        monitor.onDiskAppeared = { [weak self] bsd, kind, mnt in
            self?.appendLog(L10n.f("log.diskAppeared", bsd, kind))
        }
        monitor.onNTFSAppeared = { [weak self] bsd in
            self?.handleNTFSAppeared(bsd: bsd)
        }
        monitor.onVolumeChanged = { [weak self] in
            self?.refreshVolumesQuiet()
        }
        monitor.start()
        refreshVolumesQuiet()
    }

    // MARK: 环境检测 (FUSE-T 运行时)

    static let fuseTReleasesURL = URL(string: "https://github.com/macos-fuse-t/fuse-t/releases")!
    static let brewCommand = "brew tap macos-fuse-t/homebrew-cask && brew install --cask fuse-t"

    /// 检测 FUSE-T 运行时: 系统安装或用户级安装任一布局即可
    func checkEnvironment() {
        let fm = FileManager.default
        let sentinels = [
            "/usr/local/bin/go-nfsv4",                                   // 系统安装 (root)
            NSHomeDirectory() + "/.fuse-t/usr/local/bin/go-nfsv4",       // 用户级安装
            "/Library/Application Support/fuse-t",
            NSHomeDirectory() + "/Library/Application Support/fuse-t",
        ]
        fuseTRuntimeOK = sentinels.contains { fm.fileExists(atPath: $0) }
    }

    func openFuseTDownload() {
        NSWorkspace.shared.open(AppModel.fuseTReleasesURL)
    }

    func copyBrewCommand() -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(AppModel.brewCommand, forType: .string)
    }

    func appendLog(_ line: String) {
        let stamp = DateFormatter.logStamp.string(from: Date())
        autoLog += "[\(stamp)] \(line)\n"
    }

    // MARK: helper 生命周期

    func refreshSMStatus() {
        let text: String
        switch daemonService.status {
        case .notRegistered:    text = L10n.t("helper.status.initial")
        case .enabled:          text = L10n.t("helper.status.enabled")
        case .requiresApproval: text = L10n.t("helper.status.pending")
        case .notFound:         text = L10n.t("helper.status.notFound")
        @unknown default:       text = L10n.t("helper.status.unknown")
        }
        helperStatusText = text
        helperOK = (daemonService.status == .enabled)
    }

    func registerHelper() {
        do { try daemonService.register() } catch { appendLog(L10n.f("log.register.fail", error.localizedDescription)) }
        refreshSMStatus()
    }

    func unregisterHelper() {
        do { try daemonService.unregister() } catch { appendLog(L10n.f("log.unregister.fail", error.localizedDescription)) }
        refreshSMStatus()
    }

    func pingHelper() {
        Task {
            do {
                _ = try await client.version()
                helperOK = true
                helperStatusText = "已批准运行"
            } catch {
                helperOK = false
                helperStatusText = L10n.t("helper.status.noResponse")
                appendLog(L10n.f("log.helper.noresponse", error.localizedDescription))
            }
        }
    }

    // MARK: 卷列表与状态

    func refreshVolumesQuiet() {
        Task {
            if let vols = try? await client.listVolumes() {
                volumes = vols
            }
        }
    }

    func refreshVolumes() {
        Task {
            do {
                volumes = try await client.listVolumes()
            } catch {
                appendLog(L10n.f("log.list.fail", error.localizedDescription))
            }
        }
    }

    // MARK: 挂载意图 (自动 + 手动共用, 按 BSD 去重)

    func handleNTFSAppeared(bsd: String) {
        appendLog(L10n.f("log.detected", bsd))
        guard autoMountEnabled else {
            appendLog(L10n.t("log.automount.off"))
            return
        }
        startMountIntent(bsd: bsd, isAutomatic: true)
    }

    func startMountIntent(bsd: String, isAutomatic: Bool) {
        guard !busyBSDs.contains(bsd) else { return }   // 手动+自动同时到达只执行一次
        busyBSDs.insert(bsd)
        Task {
            defer { busyBSDs.remove(bsd) }
            do {
                let mnt = try await client.mountReadWrite(bsd: bsd)
                lastErrors[bsd] = nil
                appendLog(L10n.f("log.mount.ok", mnt))
                if isAutomatic { sendNotification(title: L10n.t("notify.title"), body: L10n.t("notify.mount.ok")) }
            } catch {
                lastErrors[bsd] = error.localizedDescription
                appendLog(L10n.f("log.mount.fail", error.localizedDescription))
                if isAutomatic { sendNotification(title: L10n.t("notify.title"), body: L10n.f("notify.mount.fail", error.localizedDescription)) }
            }
            refreshVolumesQuiet()
        }
    }

    func unmount(_ vol: HelperVolume) {
        guard !busyBSDs.contains(vol.bsdName) else { return }
        busyBSDs.insert(vol.bsdName)
        Task {
            defer { busyBSDs.remove(vol.bsdName) }
            do {
                try await client.unmount(bsd: vol.bsdName)
                lastErrors[vol.bsdName] = nil
                appendLog(L10n.f("log.unmount.ok", vol.bsdName))
            } catch {
                lastErrors[vol.bsdName] = error.localizedDescription
                appendLog(L10n.f("log.unmount.fail", error.localizedDescription))
            }
            refreshVolumesQuiet()
        }
    }

    /// 安全弹出整盘: helper 内部先逐卷非强制卸载 → 确认驱动退出 → 整盘弹出
    func ejectWholeDisk(_ vol: HelperVolume) {
        guard !busyBSDs.contains(vol.wholeDiskBSD) else { return }
        busyBSDs.insert(vol.wholeDiskBSD)
        Task {
            defer { busyBSDs.remove(vol.wholeDiskBSD) }
            do {
                let result = try await client.eject(bsd: vol.bsdName)
                // 整盘弹出成功: 清除同盘各卷的错误标记
                for v in volumes where v.wholeDiskBSD == vol.wholeDiskBSD { lastErrors[v.bsdName] = nil }
                appendLog(L10n.f("log.eject.ok", result))
                sendNotification(title: L10n.t("notify.title"), body: L10n.t("notify.eject.ok"))
            } catch {
                lastErrors[vol.bsdName] = error.localizedDescription
                appendLog(L10n.f("log.eject.fail", error.localizedDescription))
            }
            refreshVolumesQuiet()
        }
    }

    // MARK: 设置

    func setAutoMount(_ on: Bool) {
        autoMountEnabled = on
        appendLog(L10n.t(on ? "log.automount.on" : "log.automount.disabled"))
        if on {
            requestNotificationPermission()
            // 补偿扫描: 开关打开前已接入的 NTFS 卷 (只读/未挂载) 立即接管
            for vol in volumes where !vol.isManagedRW {
                appendLog(L10n.f("log.compensate", vol.bsdName))
                startMountIntent(bsd: vol.bsdName, isAutomatic: true)
            }
        }
    }

    func toggleLoginItem() {
        do {
            if launchAtLogin {
                try mainAppService.unregister()
            } else {
                try mainAppService.register()
            }
        } catch {
            appendLog(L10n.f("log.loginitem.fail", error.localizedDescription))
        }
        launchAtLogin = AppModel.currentLoginItemState()
    }

    func runDiagnose() {
        Task {
            do {
                lastDiagnose = try await client.diagnose()
            } catch {
                lastDiagnose = L10n.f("log.diag.fail", error.localizedDescription)
            }
        }
    }

    // MARK: 通知

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - 菜单面板 UI (macOS 27 Liquid Glass 设计)

struct PanelView: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if model.fuseTRuntimeOK == false {
                EnvironmentWarningCard(model: model)
            }
            volumeSection
            Divider()
            controlsSection
            footer
        }
        .padding(.leading, 20)
        .padding(.trailing, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(width: 400)
        .onAppear {
            model.refreshSMStatus()
            model.refreshVolumes()
        }
        .sheet(isPresented: $model.showDiagnostics) {
            DiagnosticsSheet(model: model)
        }
    }

    // 顶栏: helper 状态胶囊 + 诊断入口
    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.helperOK ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(model.helperStatusText)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(model.helperOK ? .primary : .secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .glassSurfaceBackground(cornerRadius: 14)

            Spacer()
            Button {
                model.showDiagnostics = true
            } label: {
                Label(L10n.t("diag.title"), systemImage: "stethoscope")
                    .labelStyle(.titleAndIcon)
            }
            .ntfsGlassButton()
            .controlSize(.small)
            .focusable(false)
        }
    }

    // 卷列表: 玻璃卡片行
    private var volumeSection: some View {
        VStack(spacing: 8) {
                if model.volumes.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "externaldrive.badge.questionmark")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text(L10n.t("volume.empty.title"))
                            .font(.callout.weight(.medium))
                        Text(L10n.t("volume.empty.subtitle"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                } else {
                    ForEach(model.volumes, id: \.bsdName) { vol in
                        VolumeCard(vol: vol, model: model)
                    }
                }
        }
    }

    // 设置区: 统一开关样式
    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.autoMountEnabled },
                set: { model.setAutoMount($0) })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.automount.title"))
                        .font(.callout.weight(.medium))
                    Text(L10n.t("settings.automount.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { _ in model.toggleLoginItem() })) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.t("settings.login.title"))
                        .font(.callout.weight(.medium))
                    Text(L10n.t("settings.login.subtitle"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var footer: some View {
        HStack {
            Button(L10n.t("footer.about")) { showAboutPanel() }
                .ntfsGlassButton()
                .controlSize(.small)
                .focusable(false)
            Spacer()
            Button(L10n.t("footer.quit")) { NSApp.terminate(nil) }
                .ntfsGlassButton()
                .controlSize(.small)
                .focusable(false)
        }
    }

    /// 标准 AppKit 关于面板 (MarkLeaf 式布局: 图标/名称/版本/版权/致谢)
    private func showAboutPanel() {
        // LSUIElement 后台应用默认未激活, 窗口会被创建但不显示 —— 先激活
        NSApp.activate(ignoringOtherApps: true)
        // 显式加载包内图标 (AppKit 对后台应用不保证自动加载 CFBundleIconFile)
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        let credits = NSAttributedString(string: L10n.t("about.tagline") + "\n" + L10n.t("about.attribution"), attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .init(rawValue: "Copyright"): L10n.t("about.copyright"),
            .credits: credits,
        ]
        if let icon = NSApp.applicationIconImage { options[.applicationIcon] = icon }

        // 记录既有窗口, 创建后定位关于窗口: 抬升层级到菜单栏面板之上并抢 key
        // (抢 key 会让 MenuBarExtra 面板自动收起)
        // 记录既有窗口, 创建后定位关于窗口: 抢 key (MenuBarExtra 面板会自动收起)
        let before = Set(NSApp.windows.map { ObjectIdentifier($0) })
        NSApp.orderFrontStandardAboutPanel(options: options)
        DispatchQueue.main.async {
            if let about = NSApp.windows.first(where: {
                !before.contains(ObjectIdentifier($0)) && $0.isVisible
            }) {
                about.makeKeyAndOrderFront(nil)
            }
        }
    }
}

// MARK: - 环境引导卡片 (FUSE-T 缺失时)

struct EnvironmentWarningCard: View {
    @ObservedObject var model: AppModel
    @State private var brewCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(L10n.t("env.missing.title"))
                    .font(.callout.weight(.semibold))
            }
            Text(L10n.t("env.missing.subtitle"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button {
                    model.openFuseTDownload()
                } label: {
                    Label(L10n.t("env.download"), systemImage: "arrow.down.circle")
                }
                .ntfsGlassProminentButton()
                .controlSize(.small)
                .focusable(false)

                Button {
                    if model.copyBrewCommand() { brewCopied = true }
                } label: {
                    Label(brewCopied ? L10n.t("env.brew.copied") : L10n.t("env.brew.copy"),
                          systemImage: brewCopied ? "checkmark" : "doc.on.doc")
                }
                .ntfsGlassButton()
                .controlSize(.small)
                .focusable(false)

                Spacer()
                Button(L10n.t("env.recheck")) { model.checkEnvironment() }
                    .ntfsGlassButton()
                    .controlSize(.small)
                    .focusable(false)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .ntfsStrokeBorder(RoundedRectangle(cornerRadius: 12), Color.orange.opacity(0.35))
    }
}

// MARK: - 卷卡片

struct VolumeCard: View {
    let vol: HelperVolume
    @ObservedObject var model: AppModel

    private var isMounted: Bool { vol.isManagedRW || vol.mountPoint != nil }

    private var stateBadge: some View {
        Text(vol.isManagedRW ? L10n.t("volume.state.rw") : (vol.mountPoint != nil ? L10n.t("volume.state.ro") : L10n.t("volume.state.unmounted")))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(badgeColor.opacity(0.16), in: Capsule())
            .ntfsStrokeBorder(Capsule(), badgeColor.opacity(0.35))
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        if vol.isManagedRW { return .green }
        if vol.mountPoint != nil { return .orange }
        return .gray
    }

    var body: some View {
        HStack(spacing: 10) {
            // 图标: 按状态着色
            Image(systemName: vol.kind == "image" ? "opticaldiscdrive" : "externaldrive")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(badgeColor)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(badgeColor.opacity(0.10))
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(vol.volumeName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    if vol.kind == "image" {
                        Text(L10n.t("volume.badge.image"))
                            .font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                            .foregroundStyle(.blue)
                    }
                }
                HStack(spacing: 4) {
                    Text(vol.bsdName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    stateBadge
                }
                if let err = model.lastErrors[vol.bsdName] {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(err)
                }
            }

            Spacer(minLength: 6)

            // 操作区: glass 按钮, 主操作突出; 弹出/卸载进行中显示转圈
            if model.busyBSDs.contains(vol.bsdName) || model.busyBSDs.contains(vol.wholeDiskBSD) {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 2)
            }
            HStack(spacing: 6) {
                if isMounted {
                    Button(L10n.t("volume.action.unmount")) { model.unmount(vol) }
                        .ntfsGlassButton()
                        .disabled(model.busyBSDs.contains(vol.bsdName))
                } else {
                    Button(L10n.t("volume.action.mount")) { model.startMountIntent(bsd: vol.bsdName, isAutomatic: false) }
                        .ntfsGlassProminentButton()
                        .disabled(model.busyBSDs.contains(vol.bsdName))
                }
                Button {
                    model.ejectWholeDisk(vol)
                } label: {
                    Image(systemName: "eject")
                }
                .accessibilityLabel(L10n.t("volume.action.eject.icon.accessibility"))
                .ntfsGlassButton()
                .disabled(model.busyBSDs.contains(vol.wholeDiskBSD))
            }
            .controlSize(.small)
            .focusable(false)
        }
        .padding(10)
        .glassSurfaceBackground(cornerRadius: 12)
    }
}

// MARK: - 诊断 sheet

struct DiagnosticsSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L10n.t("diag.title")).font(.headline)
                Spacer()
                Button(L10n.t("diag.refresh")) { model.runDiagnose() }
                    .ntfsGlassProminentButton()
                    .controlSize(.small)
                    .focusable(false)
                Button(L10n.t("diag.close")) { dismiss() }
                    .ntfsGlassButton()
                    .controlSize(.small)
                    .focusable(false)
            }
            HStack(alignment: .top, spacing: 10) {
                // helper 状态
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("diag.helperState")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollView {
                        Text(model.lastDiagnose.isEmpty ? L10n.t("diag.tapRefresh") : model.lastDiagnose)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .background(Color.primary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .frame(width: 280)

                // 运行日志
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("diag.runLog")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(model.autoLog.isEmpty ? L10n.t("diag.empty") : model.autoLog)
                                .font(.system(size: 10, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .id("logBottom")
                        }
                        .background(Color.primary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .onChange(of: model.autoLog) { _ in
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: 300)
        }
        .padding()
        .frame(width: 620, height: 400)
        .onAppear { model.runDiagnose() }
    }
}

private extension DateFormatter {
    static let logStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
