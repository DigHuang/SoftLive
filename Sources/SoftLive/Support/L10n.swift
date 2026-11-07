import Foundation
import Observation

/// User-selectable interface language preference.
enum AppLanguage: String, CaseIterable, Sendable {
    case system
    case zhHans = "zh-Hans"
    case en

    var displayName: String {
        switch self {
        case .system: L10n.tr("跟随系统", "System")
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }

    /// Resolves `.system` against `preferredLanguages` (defaults to `Locale.preferredLanguages`).
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> ResolvedLanguage {
        switch self {
        case .zhHans:
            return .zhHans
        case .en:
            return .en
        case .system:
            for identifier in preferredLanguages {
                let lower = identifier.lowercased()
                if lower.hasPrefix("zh") { return .zhHans }
                if lower.hasPrefix("en") { return .en }
            }
            return .zhHans
        }
    }
}

/// Concrete language after resolving `.system`.
enum ResolvedLanguage: String, Equatable, Sendable {
    case zhHans = "zh-Hans"
    case en
}

/// Observable language store so SwiftUI views and `Observations` streams automatically
/// refresh when the user switches the interface language at runtime without restarting.
@Observable
final class LocalizationStore {
    var language: AppLanguage = .system {
        didSet {
            let next = language.resolved()
            if resolved != next {
                resolved = next
            }
        }
    }

    private(set) var resolved: ResolvedLanguage = AppLanguage.system.resolved()

    func sync(language newLanguage: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        if language != newLanguage {
            language = newLanguage
        }
        let next = newLanguage.resolved(preferredLanguages: preferredLanguages)
        if resolved != next {
            resolved = next
        }
    }
}

/// Zero-dependency, compile-time safe bilingual (`zh-Hans` / `en`) localization helper.
enum L10n {
    static let store = LocalizationStore()

    static var language: AppLanguage {
        get { store.language }
        set { store.sync(language: newValue) }
    }

    static var resolved: ResolvedLanguage {
        store.resolved
    }

    static var isEnglish: Bool {
        store.resolved == .en
    }

    static func tr(_ zh: String, _ en: String) -> String {
        store.resolved == .en ? en : zh
    }
}
