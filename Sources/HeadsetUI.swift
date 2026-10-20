/**
 * [INPUT]: 依赖 AppKit/SwiftUI 原生控件与 TargetStore 的主题文件和保存通知；颜色映射 Web 的经典蓝/米白令牌。
 * [OUTPUT]: 对外提供只读主题观察、原生主题容器及耳机设置与操作录制共用的语义颜色和控件。
 * [POS]: Sources 的耳机展示层；两个窗口跟随产品主题，配置与执行仍由原有运行时负责。
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
import AppKit
import SwiftUI

// MARK: - 产品主题映射

struct HeadsetPalette {
    let canvas, card, control, line, lineStrong: Color
    let foreground, muted, accent, accentInk, accentSoft, accentLine, danger: Color
    let cardRadius, controlRadius: CGFloat

    static let classic = make(muji: false)
    static let muji = make(muji: true)

    private static func color(_ hex: UInt32) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 255) / 255,
              green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
    private static func make(muji: Bool) -> Self {
        // 原生绘制不能消费 CSS；集中镜像 style.css 与 app-extras.css，不另建一套配色。
        let ink = color(muji ? 0x1a1a1a : 0x171c2c)
        let border = color(muji ? 0x1a1a1a : 0x0f1e44)
        let accent = color(muji ? 0xb74127 : 0x1f6bff)
        return Self(
            canvas: color(muji ? 0xf5f3ee : 0xeef1f7), card: color(0xffffff),
            control: color(muji ? 0xefede7 : 0xeef2fb),
            line: border.opacity(0.10), lineStrong: border.opacity(muji ? 0.22 : 0.24),
            foreground: ink, muted: color(muji ? 0x666666 : 0x4a5266),
            accent: accent, accentInk: color(0xffffff), accentSoft: accent.opacity(muji ? 0.08 : 0.10),
            accentLine: accent.opacity(muji ? 0.40 : 0.38), danger: color(muji ? 0xb74127 : 0xcf2b36),
            cardRadius: muji ? 6 : 16, controlRadius: muji ? 4 : 9)
    }
}

final class HeadsetAppearance: ObservableObject {
    static let shared = HeadsetAppearance()
    @Published private(set) var theme: String
    var palette: HeadsetPalette { theme == "muji" ? .muji : .classic }
    private var observer: NSObjectProtocol?

    private init() {
        let saved = try? String(contentsOf: TargetStore.themeFile, encoding: .utf8)
        theme = saved?.trimmingCharacters(in: .whitespacesAndNewlines) == "muji" ? "muji" : "classic"
        // 控制台保存运行在服务队列，原生主题只在主线程更新。
        observer = NotificationCenter.default.addObserver(forName: TargetStore.themeDidChange, object: nil, queue: .main) { [weak self] notification in
            guard let name = notification.userInfo?["theme"] as? String, name == "classic" || name == "muji" else { return }
            if self?.theme != name { self?.theme = name }
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
}

private struct HeadsetPaletteKey: EnvironmentKey {
    static let defaultValue = HeadsetPalette.classic
}
extension EnvironmentValues {
    var headsetPalette: HeadsetPalette {
        get { self[HeadsetPaletteKey.self] }
        set { self[HeadsetPaletteKey.self] = newValue }
    }
}

struct HeadsetThemeSurface<Content: View>: View {
    @ObservedObject private var appearance = HeadsetAppearance.shared
    weak var window: NSWindow?
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().environment(\.headsetPalette, appearance.palette)
            .foregroundStyle(appearance.palette.foreground).tint(appearance.palette.accent)
            .accentColor(appearance.palette.accent)
            .background(appearance.palette.canvas).preferredColorScheme(.light)
            .onReceive(appearance.$theme) { theme in
                window?.backgroundColor = NSColor(theme == "muji" ? HeadsetPalette.muji.canvas : HeadsetPalette.classic.canvas)
            }
    }
}

// MARK: - 共享控件

struct HeadsetCard<Content: View>: View {
    @Environment(\.headsetPalette) private var palette
    @ViewBuilder let content: () -> Content
    var body: some View {
        content().padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.card).clipShape(RoundedRectangle(cornerRadius: palette.cardRadius))
            .overlay(RoundedRectangle(cornerRadius: palette.cardRadius).stroke(palette.line, lineWidth: 1))
    }
}

struct HeadsetPrimaryButton: ButtonStyle {
    @Environment(\.headsetPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 18).padding(.vertical, 10)
            .foregroundStyle(enabled ? palette.accentInk : palette.muted)
            .background(enabled ? palette.accent : palette.control)
            .clipShape(RoundedRectangle(cornerRadius: palette.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: palette.controlRadius).fill(palette.foreground.opacity(enabled && (configuration.isPressed || hovering) ? (configuration.isPressed ? 0.16 : 0.08) : 0)).allowsHitTesting(false))
            .onHover { hovering = $0 }
    }
}

struct HeadsetSecondaryButton: ButtonStyle {
    @Environment(\.headsetPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(enabled ? palette.foreground : palette.muted)
            .background(enabled && (hovering || configuration.isPressed) ? palette.control : palette.card)
            .clipShape(RoundedRectangle(cornerRadius: palette.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: palette.controlRadius).stroke(enabled && hovering ? palette.accentLine : palette.lineStrong, lineWidth: 1))
            .opacity(enabled ? 1 : 0.55).onHover { hovering = $0 }
    }
}

struct HeadsetMessage: View {
    @Environment(\.headsetPalette) private var palette
    let text: String
    var error = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error ? "exclamationmark.circle" : "info.circle")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 12)).foregroundStyle(error ? palette.danger : palette.muted)
            .accessibilityElement(children: .combine)
    }
}

struct HeadsetSectionTitle: View {
    @Environment(\.headsetPalette) private var palette
    let text: String
    var body: some View { Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.muted) }
}

struct HeadsetChoice<Value: Hashable>: View {
    @Environment(\.headsetPalette) private var palette
    @Environment(\.isEnabled) private var enabled
    let label: String
    @Binding var selection: Value
    let options: [(Value, String)]
    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { index in
                Button { selection = options[index].0 } label: {
                    if selection == options[index].0 { Label(options[index].1, systemImage: "checkmark") }
                    else { Text(options[index].1) }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(options.first { $0.0 == selection }?.1 ?? label).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }.font(.system(size: 13)).foregroundStyle(enabled ? palette.foreground : palette.muted)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .padding(.horizontal, 12).padding(.vertical, 9).background(palette.control)
            .clipShape(RoundedRectangle(cornerRadius: palette.controlRadius))
            .overlay(RoundedRectangle(cornerRadius: palette.controlRadius).stroke(palette.line, lineWidth: 1))
            .opacity(enabled ? 1 : 0.55).accessibilityLabel(label)
    }
}
