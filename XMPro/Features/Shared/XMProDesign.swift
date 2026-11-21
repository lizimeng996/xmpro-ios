// SPDX-License-Identifier: AGPL-3.0-or-later

import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - 设计原则（v3）
//
// 1. 内容优先：卡片、列表、封面属于「内容层」，使用实色表面与留白建立层级，不使用玻璃。
// 2. 玻璃只用于「控制层」：Tab 栏、工具栏、迷你播放器、浮动操作按钮、播放器控制条。
//    （遵循 iOS 26 / 27 Liquid Glass HIG：玻璃浮于内容之上，避免玻璃叠玻璃）
// 3. 色彩克制：主题色只用于可交互元素与当前状态，正文保持中性色。
// 4. 所有尺寸、圆角、间距统一取自 XMMetrics，所有颜色取自 XMPalette。

// MARK: - 度量

enum XMMetrics {
    static let pagePadding: CGFloat = 20
    static let sectionSpacing: CGFloat = 28
    static let itemSpacing: CGFloat = 12
    static let cardRadius: CGFloat = 22
    static let coverRadius: CGFloat = 12
    static let smallCoverRadius: CGFloat = 8
    static let rowCover: CGFloat = 56
    static let tileCover: CGFloat = 132
    /// 底部为 Tab 栏 / 迷你播放器预留的滚动留白
    static func bottomInset(hasTrack: Bool) -> CGFloat { hasTrack ? 132 : 84 }
}

// MARK: - 调色板

struct XMPalette: Equatable {
    var accent: Color
    var background: Color
    var surface: Color
    var fill: Color
    var separator: Color
    var isDark: Bool

    /// 主题色柔和底（选中态 / 标签底）
    var accentSoft: Color { accent.opacity(isDark ? 0.24 : 0.12) }

    init(theme: AppTheme, colorScheme: ColorScheme) {
        let dark = colorScheme == .dark
        isDark = dark
        accent = XMDesign.accent(for: theme, colorScheme: colorScheme)
        background = XMDesign.pageBackground(for: theme, colorScheme: colorScheme)
        surface = XMDesign.cardSurface(for: theme, colorScheme: colorScheme)
        fill = XMDesign.subtlePillFill(colorScheme: colorScheme)
        separator = dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
    }

    static let fallback = XMPalette(theme: .system, colorScheme: .light)
}

private struct XMPaletteKey: EnvironmentKey {
    static let defaultValue = XMPalette.fallback
}

extension EnvironmentValues {
    var xmPalette: XMPalette {
        get { self[XMPaletteKey.self] }
        set { self[XMPaletteKey.self] = newValue }
    }
}

/// 根据当前主题与（已生效的）配色方案注入调色板与 tint
struct XMThemeModifier: ViewModifier {
    @ObservedObject var themeStore: ThemeStore
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let palette = XMPalette(theme: themeStore.theme, colorScheme: colorScheme)
        content
            .environment(\.xmPalette, palette)
            .tint(palette.accent)
    }
}

extension View {
    func xmThemed(_ store: ThemeStore) -> some View {
        modifier(XMThemeModifier(themeStore: store))
    }
}

// MARK: - 原有 XMDesign（保留 API，作为调色板与格式化的底层）

enum XMDesign {
    static let crimson = Color(red: 0.70, green: 0.13, blue: 0.17)
    static let crimsonLight = Color(red: 0.96, green: 0.40, blue: 0.42)

    static func accent(for theme: AppTheme, colorScheme: ColorScheme) -> Color {
        switch theme {
        case .system:
            return colorScheme == .dark ? crimsonLight : crimson
        case .light:
            return crimson
        case .dark:
            return crimsonLight
        case .warmPaper:
            return Color(red: 0.62, green: 0.27, blue: 0.13)
        case .midnight:
            return Color(red: 0.38, green: 0.80, blue: 1.0)
        }
    }

    static func pageBackground(for theme: AppTheme, colorScheme: ColorScheme) -> Color {
        switch theme {
        case .warmPaper:
            return Color(red: 0.973, green: 0.953, blue: 0.914)
        case .midnight:
            return Color(red: 0.02, green: 0.03, blue: 0.06)
        default:
            return colorScheme == .dark
                ? Color(red: 0.0, green: 0.0, blue: 0.0)
                : Color(red: 0.965, green: 0.961, blue: 0.965)
        }
    }

    static func cardSurface(for theme: AppTheme, colorScheme: ColorScheme) -> Color {
        switch theme {
        case .warmPaper:
            return Color(red: 0.995, green: 0.985, blue: 0.962)
        case .midnight:
            return Color(red: 0.08, green: 0.10, blue: 0.15)
        default:
            return colorScheme == .dark
                ? Color(red: 0.11, green: 0.11, blue: 0.12)
                : Color.white
        }
    }

    static func softTintFill(accent: Color, colorScheme: ColorScheme) -> Color {
        accent.opacity(colorScheme == .dark ? 0.24 : 0.12)
    }

    static func subtlePillFill(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.05)
    }

    static func cardBorder(colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.03)
    }

    static func formatCount(_ value: Int64) -> String {
        if value >= 100_000_000 {
            return String(format: "%.1f亿", Double(value) / 100_000_000.0)
        }
        if value >= 10_000 {
            return String(format: "%.1f万", Double(value) / 10_000.0)
        }
        return "\(value)"
    }

    static func formatShortDuration(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3_600
        let mins = (clamped % 3_600) / 60
        if hours > 0 {
            return "\(hours) 小时 \(mins) 分"
        }
        return "\(mins) 分"
    }

    /// 时长文本：m:ss 或 h:mm:ss
    static func clock(_ seconds: Int) -> String {
        let total = max(0, seconds)
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func qualityLabel(_ code: String) -> String {
        switch code.lowercased() {
        case "auto": return "自动"
        case "m4a_128": return "高清"
        case "m4a_64": return "标准"
        case "mp3_64": return "标准"
        case "mp3_32": return "省流"
        case "m4a_24": return "流畅"
        default: return code
        }
    }

    static func qualityCodecText(_ code: String) -> String {
        switch code.lowercased() {
        case "m4a_128": return "AAC 128k"
        case "m4a_64": return "AAC 64k"
        case "mp3_64": return "MP3 64k"
        case "mp3_32": return "MP3 32k"
        case "m4a_24": return "AAC 24k"
        default: return "AAC 自动"
        }
    }
}

/// 音效预设（对齐原版 5 档，持久化在 settings["soundEffect"]）
enum SoundEffectPreset: String, CaseIterable, Equatable, Sendable, Identifiable {
    case off = "off"
    case vocal = "vocal"
    case bass = "bass"
    case surround3D = "surround_3d"
    case loudness = "loudness"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "关闭"
        case .vocal: return "人声增强"
        case .bass: return "重低音"
        case .surround3D: return "3D 环绕"
        case .loudness: return "音量均衡"
        }
    }

    static func normalized(_ raw: String?) -> SoundEffectPreset {
        guard let raw else { return .off }
        return SoundEffectPreset(rawValue: raw) ?? .off
    }
}

// MARK: - 图片管线（内存缓存 + 去重 + 预解码，替代 AsyncImage 的无缓存加载）

@MainActor
final class XMImagePipeline {
    static let shared = XMImagePipeline()

    private let cache = NSCache<NSURL, UIImage>()
    private let colorCache = NSCache<NSURL, UIColor>()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]
    private let session: URLSession
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private init() {
        cache.countLimit = 400
        cache.totalCostLimit = 120 * 1024 * 1024
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)
        session = URLSession(configuration: config)
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    func image(for url: URL) async -> UIImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        if let running = inflight[url] { return await running.value }
        let session = self.session
        let task = Task<UIImage?, Never>.detached(priority: .userInitiated) {
            guard let (data, _) = try? await session.data(from: url),
                  let raw = UIImage(data: data) else { return nil }
            return await raw.byPreparingForDisplay() ?? raw
        }
        inflight[url] = task
        let result = await task.value
        inflight[url] = nil
        if let result {
            let cost = Int(result.size.width * result.size.height * result.scale * result.scale * 4)
            cache.setObject(result, forKey: url as NSURL, cost: cost)
        }
        return result
    }

    /// 封面主色（用于播放器与专辑页氛围背景）
    func dominantColor(for url: URL) async -> UIColor? {
        if let hit = colorCache.object(forKey: url as NSURL) { return hit }
        guard let image = await image(for: url), let cg = image.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        let filter = CIFilter.areaAverage()
        filter.inputImage = input
        filter.extent = input.extent
        guard let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &px, rowBytes: 4,
                         bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                         format: .RGBA8, colorSpace: nil)
        let color = UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255,
                            blue: CGFloat(px[2]) / 255, alpha: 1)
        colorCache.setObject(color, forKey: url as NSURL)
        return color
    }
}

// MARK: - 封面

/// 统一封面视图：缓存加载、淡入、占位渐变、细描边。尺寸由调用方 frame 决定。
struct XMArtwork: View {
    let url: String?
    var cornerRadius: CGFloat = XMMetrics.coverRadius
    var symbol: String = "waveform"

    @Environment(\.xmPalette) private var palette
    @State private var image: UIImage?

    private var resolved: URL? { url.flatMap { $0.isEmpty ? nil : URL(string: $0) } }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            LinearGradient(
                colors: [palette.accent.opacity(0.22), palette.accent.opacity(0.08)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(palette.accent.opacity(0.55))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
        .contentShape(shape)
        .task(id: resolved) {
            guard let resolved else { image = nil; return }
            if let hit = XMImagePipeline.shared.cached(resolved) {
                image = hit
                return
            }
            let loaded = await XMImagePipeline.shared.image(for: resolved)
            withAnimation(.easeOut(duration: 0.25)) { image = loaded }
        }
    }
}

/// 封面氛围背景：模糊放大的封面 + 主色渐变（播放器 / 专辑头部）
struct XMArtworkBackdrop: View {
    let url: String?
    var dimming: Double = 0.35

    @Environment(\.xmPalette) private var palette
    @State private var image: UIImage?
    @State private var tint: Color?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                (tint ?? palette.accent.opacity(0.6))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .blur(radius: 60, opaque: true)
                        .saturation(1.35)
                        .opacity(0.9)
                        .transition(.opacity)
                }
                LinearGradient(
                    colors: [Color.black.opacity(dimming * 0.5), Color.black.opacity(dimming + 0.25)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .task(id: url) {
            guard let url, let resolved = URL(string: url) else { return }
            async let img = XMImagePipeline.shared.image(for: resolved)
            async let color = XMImagePipeline.shared.dominantColor(for: resolved)
            let (loadedImage, loadedColor) = await (img, color)
            withAnimation(.easeInOut(duration: 0.5)) {
                image = loadedImage
                tint = loadedColor.map { Color(uiColor: $0) }
            }
        }
    }
}

// MARK: - 玻璃（控制层）

/// iOS 26 / 27 原生 GlassEffectContainer 兼容封装（允许相邻玻璃控件产生真实光学融合）
struct XMGlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    init(spacing: CGFloat = 10, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}

/// iOS 26 / 27 原生 Liquid Glass 胶囊修饰器（支持染色与按压交互光晕）
struct LiquidGlassCapsuleModifier: ViewModifier {
    var tint: Color? = nil
    var interactive: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: .capsule)
        } else {
            content
                .background {
                    if let tint { Capsule().fill(tint) } else { Capsule().fill(.regularMaterial) }
                }
                .overlay(
                    Capsule().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.6), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08), radius: 12, y: 4)
        }
    }
}

/// iOS 26 / 27 原生 Liquid Glass 圆形修饰器
struct LiquidGlassCircleModifier: ViewModifier {
    var tint: Color? = nil
    var interactive: Bool = true
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint).interactive(interactive), in: .circle)
        } else {
            content
                .background {
                    if let tint { Circle().fill(tint) } else { Circle().fill(.regularMaterial) }
                }
                .overlay(
                    Circle().strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.6), lineWidth: 0.5)
                )
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.25 : 0.07), radius: 10, y: 4)
        }
    }
}

/// 圆角矩形玻璃（浮动面板）
struct LiquidGlassRectModifier: ViewModifier {
    var cornerRadius: CGFloat
    var tint: Color? = nil

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(iOS 26.0, *) {
            content.glassEffect(Glass.regular.tint(tint), in: shape)
        } else {
            content
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
        }
    }
}

// MARK: - 按钮样式

/// 主操作按钮：iOS 26+ 使用 `.glassProminent`，旧系统使用实色胶囊
struct XMProminentButtonModifier: ViewModifier {
    @Environment(\.xmPalette) private var palette

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .buttonStyle(.glassProminent)
                .tint(palette.accent)
        } else {
            content
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(palette.accent)
        }
    }
}

/// 次要操作按钮：iOS 26+ 使用 `.glass`，旧系统使用 bordered 胶囊
struct XMGlassButtonModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
        }
    }
}

/// 轻按缩放反馈（用于封面、卡片等内容层可点击元素）
struct XMPressableStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == XMPressableStyle {
    static var xmPressable: XMPressableStyle { XMPressableStyle() }
}

// MARK: - 内容层表面

/// 内容卡片：实色表面 + 极淡描边，无玻璃
struct XMCardModifier: ViewModifier {
    @Environment(\.xmPalette) private var palette
    var cornerRadius: CGFloat = XMMetrics.cardRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(palette.surface, in: shape)
            .overlay(shape.strokeBorder(palette.separator.opacity(0.5), lineWidth: 0.5))
    }
}

extension View {
    func xmLiquidGlassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(LiquidGlassCapsuleModifier(tint: tint, interactive: interactive))
    }

    func xmLiquidGlassCircle(tint: Color? = nil, interactive: Bool = true) -> some View {
        modifier(LiquidGlassCircleModifier(tint: tint, interactive: interactive))
    }

    func xmLiquidGlassRect(cornerRadius: CGFloat = 24, tint: Color? = nil) -> some View {
        modifier(LiquidGlassRectModifier(cornerRadius: cornerRadius, tint: tint))
    }

    func xmCard(cornerRadius: CGFloat = XMMetrics.cardRadius) -> some View {
        modifier(XMCardModifier(cornerRadius: cornerRadius))
    }

    func xmProminentButton() -> some View {
        modifier(XMProminentButtonModifier())
    }

    func xmGlassButton() -> some View {
        modifier(XMGlassButtonModifier())
    }

    /// 统一页面底色
    func xmPageBackground() -> some View {
        modifier(XMPageBackgroundModifier())
    }

    /// iOS 26+ 顶部柔和滚动边缘效果
    @ViewBuilder
    func xmSoftScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            self
        }
    }
}

struct XMPageBackgroundModifier: ViewModifier {
    @Environment(\.xmPalette) private var palette

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(palette.background.ignoresSafeArea())
    }
}

// MARK: - 基础组件

/// 板块标题：大号粗体 + 可选副标题 / 角标 / 尾部操作
struct XMSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var badge: String? = nil
    var trailing: AnyView? = nil

    @Environment(\.xmPalette) private var palette

    init(title: String, subtitle: String? = nil, badge: String? = nil, trailing: AnyView? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.badge = badge
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let badge {
                        Text(badge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(palette.accentSoft, in: Capsule())
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let trailing {
                trailing
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 内容层选择胶囊（筛选 / 频道 / 分类）
struct XMChip: View {
    let title: String
    let selected: Bool
    var systemImage: String? = nil
    let action: () -> Void

    @Environment(\.xmPalette) private var palette

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage).font(.caption.weight(.semibold))
                }
                Text(title)
                    .font(.subheadline.weight(selected ? .semibold : .medium))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .foregroundStyle(selected ? Color.white : Color.primary.opacity(0.8))
            .background(selected ? palette.accent : palette.fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.xmPressable)
        .animation(.snappy(duration: 0.22), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 小号标签（评分 / 付费 / 状态）
struct XMTag: View {
    let text: String
    var prominent: Bool = false

    @Environment(\.xmPalette) private var palette

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .foregroundStyle(prominent ? Color.white : palette.accent)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(prominent ? palette.accent : palette.accentSoft,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// 正在播放指示（iOS 17+ 符号动效）
struct XMNowPlayingIndicator: View {
    var isPlaying: Bool
    @Environment(\.xmPalette) private var palette

    var body: some View {
        Image(systemName: "waveform")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(palette.accent)
            .symbolEffect(.variableColor.iterative, isActive: isPlaying)
            .accessibilityLabel(isPlaying ? "正在播放" : "已暂停")
    }
}

/// 统一空状态 / 错误态
struct XMEmptyState<Actions: View>: View {
    let systemImage: String
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        } actions: {
            actions()
        }
    }
}

extension XMEmptyState where Actions == EmptyView {
    init(systemImage: String, title: String, message: String? = nil) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.actions = { EmptyView() }
    }
}

/// 通用列表行：封面 + 标题 + 副标题 + 尾部
struct XMMediaRow<Trailing: View>: View {
    let coverUrl: String?
    let title: String
    var subtitle: String? = nil
    var detail: String? = nil
    var highlighted: Bool = false
    var coverSize: CGFloat = XMMetrics.rowCover
    /// 0...1 的进度（历史续播），nil 则不显示
    var progress: Double? = nil
    @ViewBuilder var trailing: () -> Trailing

    @Environment(\.xmPalette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            XMArtwork(url: coverUrl, cornerRadius: XMMetrics.smallCoverRadius + 2)
                .frame(width: coverSize, height: coverSize)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(highlighted ? .semibold : .regular))
                    .foregroundStyle(highlighted ? palette.accent : Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if let progress {
                    ProgressView(value: min(max(progress, 0), 1))
                        .tint(palette.accent)
                        .scaleEffect(x: 1, y: 0.7, anchor: .center)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 6)
            trailing()
        }
        .contentShape(Rectangle())
    }
}

extension XMMediaRow where Trailing == EmptyView {
    init(coverUrl: String?, title: String, subtitle: String? = nil, detail: String? = nil,
         highlighted: Bool = false, coverSize: CGFloat = XMMetrics.rowCover, progress: Double? = nil) {
        self.init(coverUrl: coverUrl, title: title, subtitle: subtitle, detail: detail,
                  highlighted: highlighted, coverSize: coverSize, progress: progress) { EmptyView() }
    }
}

/// 竖向封面瓦片（横滑书架）
struct XMCoverTile: View {
    let coverUrl: String?
    let title: String
    var subtitle: String? = nil
    var width: CGFloat = XMMetrics.tileCover
    var badge: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            XMArtwork(url: coverUrl)
                .frame(width: width, height: width)
                .overlay(alignment: .bottomLeading) {
                    if let badge {
                        Label(badge, systemImage: "play.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(6)
                    }
                }
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
    }
}

/// 设置风格的彩色图标方块
struct XMIconBadge: View {
    let systemImage: String
    var color: Color
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
    }
}

/// 自动换行布局（热搜词 / 标签）
struct XMFlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Toast（玻璃浮层提示，替代页面内联提示文字）

struct XMToastModifier: ViewModifier {
    @Binding var message: String?
    @Environment(\.xmPalette) private var palette
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(palette.accent)
                        Text(message)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .xmLiquidGlassCapsule(interactive: false)
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { self.message = nil }
                    .accessibilityAddTraits(.isStaticText)
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: message)
            .onChange(of: message) { _, newValue in
                dismissTask?.cancel()
                guard newValue != nil else { return }
                dismissTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_400_000_000)
                    if !Task.isCancelled { message = nil }
                }
            }
    }
}

extension View {
    func xmToast(_ message: Binding<String?>) -> some View {
        modifier(XMToastModifier(message: message))
    }
}
