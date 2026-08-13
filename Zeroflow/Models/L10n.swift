import Foundation

/// 语言设置。默认跟随系统；zh/ja 之外的地区一律回退英文。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = "system"
    case zhHans = "zh-Hans"
    case en = "en"
    case ja = "ja"

    var id: String { rawValue }

    /// 实际生效的语言（跟随系统时解析系统首选语言）
    var effective: AppLanguage {
        guard self == .system else { return self }
        // 用 preferredLanguages 而非 Bundle.preferredLocalizations：本 app 无 .lproj，
        // 后者恒返回开发语言（en），无法反映系统真实语言
        guard let preferred = Locale.preferredLanguages.first?.lowercased() else {
            return .en
        }
        if preferred.hasPrefix("zh") { return .zhHans }
        if preferred.hasPrefix("ja") { return .ja }
        return .en
    }

    /// 跟随系统时用于设置窗口，否则使用所选语言
    var locale: Locale {
        switch effective {
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .ja: return Locale(identifier: "ja")
        default: return Locale(identifier: "en")
        }
    }

    var displayName: String {
        switch self {
        case .system: return L10n.tr("跟随系统")
        case .zhHans: return "简体中文"
        case .en: return "English"
        case .ja: return "日本語"
        }
    }
}

/// 国际化：从打包进 bundle 的 Translations.json 按 key 取词。
/// 中文文案作 key，键缺失时回退返回 key 本身。
enum L10n {
    /// 语言切换通知；AppKit 菜单等无法响应 SwiftUI 环境变化的界面监听它重建。
    static let didChangeNotification = Notification.Name("zeroflow.languageDidChange")

    static func tr(_ key: String, arguments: CVarArg...) -> String {
        let template = load(key: key)
        if arguments.isEmpty { return template }
        return String(format: template, locale: SettingsStore.shared.appLanguage.locale, arguments: arguments)
    }

    private static func load(key: String) -> String {
        let lang = SettingsStore.shared.appLanguage.effective.rawValue
        if let table = cachedTable[lang], let value = table[key] {
            return value
        }
        if let table = cachedTable[AppLanguage.zhHans.rawValue], let value = table[key] {
            return value
        }
        return key
    }

    private static let cachedTable: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "Translations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]]
        else {
            ZSLog("L10n: failed to load Translations.json")
            return [:]
        }
        var result: [String: [String: String]] = [:]
        for (key, entry) in root {
            for (lang, value) in entry where lang.hasPrefix("zh") {
                if result["zh-Hans"] == nil { result["zh-Hans"] = [:] }
                result["zh-Hans"]?[key] = value
            }
            for (lang, value) in entry where lang == "en" {
                if result["en"] == nil { result["en"] = [:] }
                result["en"]?[key] = value
            }
            for (lang, value) in entry where lang == "ja" {
                if result["ja"] == nil { result["ja"] = [:] }
                result["ja"]?[key] = value
            }
        }
        return result
    }()
}
