// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation
import SwiftUI

enum AppTheme: String, CaseIterable, Equatable, Sendable, Identifiable {
    case system
    case light
    case dark
    case warmPaper = "warm_paper"
    case midnight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "绯红浅色"
        case .dark: return "绯红深色"
        case .warmPaper: return "暖纸护眼"
        case .midnight: return "午夜高对比"
        }
    }

    var subtitle: String {
        switch self {
        case .system: return "自动适配浅色与深色模式"
        case .light: return "温润暖白基底与绯红点缀"
        case .dark: return "低亮度墨玉深色护眼呈现"
        case .warmPaper: return "纸感米白底色，久看柔和"
        case .midnight: return "高对比夜空蓝，夜间清晰"
        }
    }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light, .warmPaper: return .light
        case .dark, .midnight: return .dark
        }
    }

    var accentColor: Color {
        switch self {
        case .system: return XMDesign.crimson
        case .light: return XMDesign.crimson
        case .dark: return XMDesign.crimsonLight
        case .warmPaper: return Color(red: 0.58, green: 0.24, blue: 0.14)
        case .midnight: return Color(red: 0.36, green: 0.78, blue: 0.98)
        }
    }

    var backgroundColor: Color? {
        switch self {
        case .system, .light, .dark:
            return nil
        case .warmPaper:
            return Color(red: 0.975, green: 0.955, blue: 0.92)
        case .midnight:
            return Color(red: 0.04, green: 0.05, blue: 0.08)
        }
    }

    /// 主题是否为高对比预设。
    var prefersHighContrast: Bool {
        self == .midnight
    }

    static func normalized(_ raw: String?) -> AppTheme {
        guard let raw else { return .system }
        return AppTheme(rawValue: raw.lowercased()) ?? .system
    }
}

@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var theme: AppTheme = .system
    @Published private(set) var soundEffect: SoundEffectPreset = .off

    private let repository: StateRepository?

    init(repository: StateRepository?) {
        self.repository = repository
    }

    func load() async {
        guard let repository else { return }
        let document = await repository.state()
        theme = AppTheme.normalized(document.settings["theme"] as? String)
        soundEffect = SoundEffectPreset.normalized(document.settings["soundEffect"] as? String)
    }

    func select(_ newTheme: AppTheme) async {
        theme = newTheme
        guard let repository else { return }
        _ = try? await repository.transaction { document in
            var settings = document.settings
            settings["theme"] = newTheme.rawValue
            try document.setSettings(settings)
        }
    }

    func selectSoundEffect(_ preset: SoundEffectPreset) async {
        soundEffect = preset
        guard let repository else { return }
        _ = try? await repository.transaction { document in
            var settings = document.settings
            settings["soundEffect"] = preset.rawValue
            try document.setSettings(settings)
        }
    }
}
