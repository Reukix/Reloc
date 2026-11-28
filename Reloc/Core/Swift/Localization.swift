import Foundation

public enum AppLanguage: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case en
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case ja
    case ko

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .system: return L10n.tr("settings.language.system")
        case .en: return "English"
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .ja: return "日本語"
        case .ko: return "한국어"
        }
    }

    public var locale: Locale {
        switch self {
        case .system: return .autoupdatingCurrent
        case .en: return Locale(identifier: "en")
        case .zhHans: return Locale(identifier: "zh-Hans")
        case .zhHant: return Locale(identifier: "zh-Hant")
        case .ja: return Locale(identifier: "ja")
        case .ko: return Locale(identifier: "ko")
        }
    }
}

public enum L10n {
    public static let languageDefaultsKey = "reloc.language"

    public static var currentLanguage: AppLanguage {
        if let raw = UserDefaults.standard.string(forKey: languageDefaultsKey),
           let lang = AppLanguage(rawValue: raw) {
            return lang
        }
        return .system
    }

    public static var resolvedLanguageCode: String {
        switch currentLanguage {
        case .en:
            return "en"
        case .zhHans:
            return "zh-Hans"
        case .zhHant:
            return "zh-Hant"
        case .ja:
            return "ja"
        case .ko:
            return "ko"
        case .system:
            let preferred = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
            let lower = preferred.lowercased()
            if lower.hasPrefix("zh") {
                if lower.contains("hant") || lower.contains("tw") || lower.contains("hk") || lower.contains("mo") {
                    return "zh-Hant"
                }
                return "zh-Hans"
            }
            if lower.hasPrefix("ja") {
                return "ja"
            }
            if lower.hasPrefix("ko") {
                return "ko"
            }
            return "en"
        }
    }

    public static var isChinese: Bool {
        resolvedLanguageCode.lowercased().hasPrefix("zh")
    }

    public static var nominatimAcceptLanguage: String {
        switch resolvedLanguageCode {
        case "zh-Hans": return "zh-CN,en"
        case "zh-Hant": return "zh-TW,zh-HK,en"
        case "ja": return "ja,en"
        case "ko": return "ko,en"
        default: return "en,zh-CN"
        }
    }

    public static var bigDataCloudLanguage: String {
        switch resolvedLanguageCode {
        case "zh-Hans": return "zh"
        case "zh-Hant": return "zh-Hant"
        case "ja": return "ja"
        case "ko": return "ko"
        default: return "en"
        }
    }

    public static var activeBundle: Bundle {
        let code = resolvedLanguageCode
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
           let bundle = Bundle(path: path) {
            return bundle
        }
        return .main
    }

    public static func tr(_ key: String) -> String {
        activeBundle.localizedString(forKey: key, value: nil, table: nil)
    }

    public static func format(_ key: String, _ args: CVarArg...) -> String {
        let template = tr(key)
        return String(format: template, locale: currentLanguage.locale, arguments: args)
    }
}
