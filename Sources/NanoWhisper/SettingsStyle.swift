import AppKit
import SwiftUI

// Settings, onboarding and the menu use the system accent color (the user's choice in System
// Settings › Appearance), never the brand violet: the maintainer's feedback of 2026-11-20.
// The brand colors stay in the recording overlay (`OverlayPalette`).

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
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
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
            .frame(width: SettingsPane.width)
            .fixedSize(horizontal: false, vertical: true)
    }
}
