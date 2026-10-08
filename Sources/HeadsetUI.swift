import AppKit
import SwiftUI

/// Shared neutral cards and compact rows, based on the observed local Magpie UI.
enum HeadsetUI {
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.10, alpha: 1) : NSColor(white: 0.965, alpha: 1)
    })
    static let card = Color(nsColor: .controlBackgroundColor)
    static let control = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.945, alpha: 1)
    })
    static let line = Color(nsColor: .separatorColor).opacity(0.35)
}
struct HeadsetCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View { content().padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(HeadsetUI.card).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(HeadsetUI.line, lineWidth: 1)) }
}
struct HeadsetPrimaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 18).padding(.vertical, 10)
            .foregroundStyle(HeadsetUI.card)
            .background(Color(nsColor: .labelColor).opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
struct HeadsetMessage: View {
    let text: String
    var error = false
    var body: some View { HStack(alignment: .top, spacing: 8) {
        Image(systemName: error ? "exclamationmark.circle" : "info.circle")
        Text(text).fixedSize(horizontal: false, vertical: true)
    }.font(.system(size: 12)).foregroundStyle(error ? Color.red : Color.secondary).accessibilityElement(children: .combine) }
}
struct HeadsetSectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary) }
}

struct HeadsetSecondaryButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .medium)).padding(.horizontal, 14).padding(.vertical, 9)
            .foregroundStyle(Color.primary).background(HeadsetUI.control.opacity(configuration.isPressed ? 0.65 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 9))
    }
}
struct HeadsetChoice<Value: Hashable>: View {
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
            HStack(spacing: 8) { Text(options.first { $0.0 == selection }?.1 ?? label).lineLimit(1); Spacer(minLength: 4); Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
                .font(.system(size: 13)).foregroundStyle(.primary)
        }.menuStyle(.borderlessButton).menuIndicator(.hidden)
            .padding(.horizontal, 12).padding(.vertical, 9).background(HeadsetUI.control)
            .clipShape(RoundedRectangle(cornerRadius: 9)).accessibilityLabel(label)
    }
}
