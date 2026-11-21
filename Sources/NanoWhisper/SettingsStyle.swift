import AppKit
import SwiftUI

// Settings, onboarding and the menu use the system accent color (the user's choice in System
// Settings › Appearance), never the brand violet: the maintainer's feedback of 2026-11-20.
// The brand colors stay in the recording overlay (`OverlayPalette`).

// MARK: - Grouped cards (Settings and onboarding)

/// The grouped look Settings and onboarding share: rows on a card with no border, on the
/// onboarding design's window color. One definition, so the two cannot drift apart again
/// (maintainer's feedback of 2026-11-21: different radii and colors side by side, and a 1 px
/// line around the native grouped form's cards, clipped at the corners on a 1x display).
enum GroupedStyle {
    /// The radius of the cards of a native grouped `Form` on macOS 26/27 (measured on its
    /// render: 12 pt, continuous), which Apple's System Settings also uses.
    static let cornerRadius: CGFloat = 12
    /// Leading and trailing inset of a row's content, and of the lines between rows.
    static let rowInset: CGFloat = 12

    private static func dynamic(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Behind the cards: the system window background, as in Finder's and Apple's own settings
    /// windows (maintainer, 2026-11-21: "use Finder's colours").
    static let windowNSColor = NSColor.windowBackgroundColor
    static let window = Color(nsColor: windowNSColor)
    /// A card: white / #2A2A2D.
    static let card = Color(nsColor: dynamic("nwGroupedCard", light: .white, dark: hex(0x2A2A2D)))
    /// The line between two rows of a card.
    static let separator = Color(nsColor: dynamic(
        "nwGroupedSeparator", light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.09)))
}

/// The card behind a group of rows. No stroke: Apple's grouped cards have none.
struct GroupedCard: ViewModifier {
    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: GroupedStyle.cornerRadius, style: .continuous).fill(GroupedStyle.card)
        )
    }
}

extension View {
    /// Puts the view on the shared grouped card (`GroupedStyle`).
    func groupedCard() -> some View { modifier(GroupedCard()) }
}

/// The line between two rows of a card: one device pixel, inset like the rows' content
/// (`inset: 0` for a full-width line, above a footer).
struct GroupedRowDivider: View {
    var inset: CGFloat = GroupedStyle.rowInset
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(GroupedStyle.separator)
            .frame(height: 1 / max(displayScale, 1))
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
    }
}

// MARK: - Settings sections

/// A Settings group: its title, the rows on a card, and an optional footnote under it.
/// Rows are separated with `GroupedRowDivider` where they need a line.
struct SettingsSection<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header, @ViewBuilder footer: () -> Footer) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            header
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, GroupedStyle.rowInset)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .groupedCard()
            footer
                .padding(.horizontal, GroupedStyle.rowInset)
        }
    }
}

extension SettingsSection where Header == Text, Footer == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(content: content, header: { Text(title) }, footer: { EmptyView() })
    }
}

extension SettingsSection where Footer == EmptyView {
    init(@ViewBuilder content: () -> Content, @ViewBuilder header: () -> Header) {
        self.init(content: content, header: header, footer: { EmptyView() })
    }
}

extension View {
    /// The padding of a row on a Settings card.
    func settingsRow() -> some View {
        padding(.horizontal, GroupedStyle.rowInset)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
    }
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
        SettingsRow(title: title, caption: caption) {
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
        .accessibilityElement(children: .combine)
    }
}

/// A menu picker row: the title on the left, the menu on the right.
struct SettingsPickerRow<Item: Hashable>: View {
    let title: String
    let selection: Binding<Item>
    let items: [Item]
    let itemTitle: (Item) -> String

    var body: some View {
        SettingsRow(title: title) {
            Picker(title, selection: selection) {
                ForEach(items, id: \.self) { Text(itemTitle($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
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

/// A pane of the Settings window: its sections on the grouped window color, as tall as its
/// content, so the window fits each pane (see `SettingsTabViewController`). Not a grouped
/// `Form`: its cards have a hairline border (clipped at the corners on a 1x display) and
/// their color cannot be changed, so Settings and onboarding drew two different cards.
struct SettingsPaneForm<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) { content }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 22)
            .frame(width: SettingsPane.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(GroupedStyle.window)
    }
}
