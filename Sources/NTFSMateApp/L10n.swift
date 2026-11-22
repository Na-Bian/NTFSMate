import Foundation

/// 应用侧本地化: Bundle.main 下的 <lang>.lproj/Localizable.strings
/// (由 build-app.sh 从 Resources/l10n/ 复制进应用包)
enum L10n {
    static func t(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: nil)
    }

    static func f(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    /// 当前界面语言 (随系统偏好), 供随 XPC 请求发给 helper 组装错误消息
    static var preferredLanguage: String {
        let available = Bundle.main.localizations   // 包内实际存在的 lproj
        for p in Locale.preferredLanguages {
            if available.contains(p) { return p }
            if let m = available.first(where: { p.hasPrefix($0 + "-") }) { return m }
            if let m = available.first(where: { p.hasPrefix($0) }) { return m }
        }
        return available.first ?? "en"
    }

    /// helper 错误前缀映射 (errKind 已在 helper 侧本地化, 此处兜底处理
    /// 客户端自身的连接类错误)
    static func localizeClientError(_ raw: String) -> String {
        raw // HelperClient 生成时即用 L10n 组装
    }
}
