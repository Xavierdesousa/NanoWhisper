import AppKit
import SwiftUI

/// Where the recording overlay ("the recorder") appears on the screen, chosen in Settings.
///
/// The overlay is placed 12 pt inside the visible frame (below the menu bar, above the Dock)
/// of the screen that has the pointer when the recording starts. When its content grows
/// (live text), it grows away from the edges it is pinned to, so the part the user was
/// looking at does not move: top positions keep their top edge, Bottom Center its bottom
/// edge; Left keeps the left edge, Right the right edge, Center the horizontal center.
enum RecorderPosition: String, CaseIterable, Identifiable, Sendable {
    case topLeft
    case topCenter
    case topRight
    case bottomCenter

    /// `UserDefaults` key of the setting.
    static let defaultsKey = "recorderPosition"
    /// Today's behavior, and the value when nothing (or something unknown) is stored.
    static let defaultPosition: RecorderPosition = .topCenter
    /// Distance from the screen's visible frame, in points.
    static let screenInset: CGFloat = 12

    var id: String { rawValue }

    /// Name shown in Settings.
    var title: String {
        switch self {
        case .topLeft: return "Top Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .bottomCenter: return "Bottom Center"
        }
    }

    /// The stored position, or the default when none or an unknown value is stored.
    static func load(from defaults: UserDefaults) -> RecorderPosition {
        defaults.string(forKey: defaultsKey).flatMap(RecorderPosition.init(rawValue:)) ?? defaultPosition
    }

    func save(to defaults: UserDefaults) {
        defaults.set(rawValue, forKey: Self.defaultsKey)
    }

    // MARK: - Anchors

    enum HorizontalAnchor: Sendable { case left, center, right }
    enum VerticalAnchor: Sendable { case top, bottom }

    var horizontalAnchor: HorizontalAnchor {
        switch self {
        case .topLeft: return .left
        case .topCenter, .bottomCenter: return .center
        case .topRight: return .right
        }
    }

    var verticalAnchor: VerticalAnchor {
        self == .bottomCenter ? .bottom : .top
    }

    /// True when the overlay grows upward (its bottom edge stays in place).
    var growsUpward: Bool { verticalAnchor == .bottom }

    /// The pinned point of the overlay in SwiftUI coordinates (y down), used as the anchor of
    /// its appear animation.
    var unitPoint: UnitPoint {
        switch self {
        case .topLeft: return .topLeading
        case .topCenter: return .top
        case .topRight: return .topTrailing
        case .bottomCenter: return .bottom
        }
    }

    // MARK: - Placement (AppKit screen coordinates, y up)

    /// Frame of an overlay of `size` when a recording starts, in `visible` (the screen's
    /// visible frame).
    func initialFrame(size: NSSize, in visible: NSRect) -> NSRect {
        let inset = Self.screenInset
        let x: CGFloat
        switch horizontalAnchor {
        case .left: x = visible.minX + inset
        case .center: x = (visible.midX - size.width / 2).rounded()
        case .right: x = visible.maxX - inset - size.width
        }
        let y: CGFloat
        switch verticalAnchor {
        case .top: y = visible.maxY - inset - size.height
        case .bottom: y = visible.minY + inset
        }
        return Self.clamp(NSRect(origin: NSPoint(x: x, y: y), size: size), within: visible)
    }

    /// Frame of `size` that keeps the pinned edges of `current` (the overlay may have been
    /// dragged), moved back inside `visible` if it would stick out.
    func frame(fitting size: NSSize, from current: NSRect, within visible: NSRect?) -> NSRect {
        let x: CGFloat
        switch horizontalAnchor {
        case .left: x = current.minX
        case .center: x = (current.midX - size.width / 2).rounded()
        case .right: x = current.maxX - size.width
        }
        let y: CGFloat
        switch verticalAnchor {
        case .top: y = current.maxY - size.height
        case .bottom: y = current.minY
        }
        let frame = NSRect(origin: NSPoint(x: x, y: y), size: size)
        guard let visible else { return frame }
        return Self.clamp(frame, within: visible)
    }

    private static func clamp(_ frame: NSRect, within visible: NSRect) -> NSRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        return frame
    }
}
