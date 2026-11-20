import AppKit
import SwiftUI

// MARK: - Brand colors

extension Color {
    /// Brand violet for selection and prominent controls (design token `accent-fill`).
    static let nwAccent = Color(nsColor: NSColor(name: "nwAccent") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x76 / 255, green: 0x50 / 255, blue: 0xE6 / 255, alpha: 1)
            : NSColor(srgbRed: 0x66 / 255, green: 0x33 / 255, blue: 0xD6 / 255, alpha: 1)
    })

    /// Brand violet for text and small marks (design token `accent`): lighter on dark.
    static let nwAccentText = Color(nsColor: NSColor(name: "nwAccentText") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0xB3 / 255, green: 0x9B / 255, blue: 0xFF / 255, alpha: 1)
            : NSColor(srgbRed: 0x66 / 255, green: 0x33 / 255, blue: 0xD6 / 255, alpha: 1)
    })
}

// MARK: - Rows

/// A Settings row: title and optional caption on the left, a control on the right.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var caption: String?
    var titleColor: Color?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .foregroundStyle(titleColor ?? .primary)
                if let caption, !caption.isEmpty {
                    SettingsCaption(caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
    }
}

/// Secondary text under a row title or below a group.
struct SettingsCaption: View {
    let text: String
    var color: Color?

    init(_ text: String, color: Color? = nil) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color ?? .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A switch row with an optional caption.
struct SettingsToggle: View {
    let title: String
    var caption: String?
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(isOn: isOn) {
            Text(title)
            if let caption {
                Text(caption)
            }
        }
        .toggleStyle(.switch)
    }
}

/// Small rounded label after a section title ("Beta").
struct SettingsBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.nwAccentText)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.nwAccent.opacity(0.12)))
    }
}

/// A pane of the Settings window: a grouped form that is as tall as its content, so the
/// window fits each pane (see `SettingsTabViewController`).
struct SettingsPaneForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .tint(.nwAccent)
            .frame(width: SettingsPane.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}
