import SwiftUI

/// The recorder position control from the Settings design: a small dark screen showing the
/// recorder at the selected position, with a spot for each other position (clicking one
/// selects it), beside the four positions as a radio group.
///
/// Standalone, so Settings can place it in its Recorder pane:
///
///     RecorderPositionPicker(selection: $appState.recorderPosition)
struct RecorderPositionPicker: View {
    @Binding var selection: RecorderPosition

    /// Caption under the radio group.
    static let caption = "Top Right is also where notifications appear."
    /// Note for the section footer (the design places it under the group).
    static let footnote = "The recorder appears while you dictate, on the screen with the pointer. "
        + "Dragging it moves it for that recording only."

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            RecorderPositionScreen(selection: $selection)
            VStack(alignment: .leading, spacing: 4) {
                Picker("Recorder position", selection: $selection) {
                    ForEach(RecorderPosition.allCases) { position in
                        Self.label(for: position).tag(position)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(Self.caption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(.top, 2)
        }
    }

    private static func label(for position: RecorderPosition) -> Text {
        guard position == .defaultPosition else { return Text(position.title) }
        return Text(position.title) + Text(" (default)").foregroundStyle(.secondary)
    }
}

/// The mini screen: 300 × 186 pt, the recorder drawn at 0.555 of its size.
struct RecorderPositionScreen: View {
    @Binding var selection: RecorderPosition

    static let size = CGSize(width: 300, height: 186)
    static let scale: CGFloat = 0.555
    static let menuBarHeight: CGFloat = 12
    /// Distance of the recorder from the mini screen's edges (below the menu bar at the top).
    static let inset: CGFloat = 6
    static let bottomInset: CGFloat = 12

    /// A neutral dark desktop, so the only colors are the recorder's and the accent.
    private static let background = OverlayPalette.rgb(0x2C2C30)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack(alignment: .topLeading) {
            shape.fill(Self.background)
            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: Self.size.width, height: Self.menuBarHeight)
            ForEach(RecorderPosition.allCases.filter { $0 != selection }) { position in
                PositionSpot { selection = position }
                    .position(Self.spotCenter(for: position))
            }
            RecordingOverlayPreview()
                .scaleEffect(Self.scale, anchor: .topLeading)
                .frame(width: Self.recorderSize.width, height: Self.recorderSize.height, alignment: .topLeading)
                .offset(x: Self.recorderOrigin(for: selection).x, y: Self.recorderOrigin(for: selection).y)
                .allowsHitTesting(false)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.2), value: selection)
        .accessibilityHidden(true) // The radio group beside it is the accessible control.
    }

    /// The compact recorder, scaled.
    static var recorderSize: CGSize {
        CGSize(width: OverlayMetrics.compactWidth * scale, height: OverlayMetrics.headerHeight * scale)
    }

    /// Top-left corner of the scaled recorder for `position` (y down).
    static func recorderOrigin(for position: RecorderPosition) -> CGPoint {
        let width = recorderSize.width, height = recorderSize.height
        let top = menuBarHeight + inset
        switch position {
        case .topLeft: return CGPoint(x: inset, y: top)
        case .topCenter: return CGPoint(x: ((size.width - width) / 2).rounded(), y: top)
        case .topRight: return CGPoint(x: size.width - inset - width, y: top)
        case .bottomCenter: return CGPoint(x: ((size.width - width) / 2).rounded(), y: size.height - bottomInset - height)
        }
    }

    /// Center of the spot drawn for an unselected position.
    static func spotCenter(for position: RecorderPosition) -> CGPoint {
        let spot = PositionSpot.size
        switch position {
        case .topLeft: return CGPoint(x: 10 + spot / 2, y: 20 + spot / 2)
        case .topCenter: return CGPoint(x: size.width / 2, y: 20 + spot / 2)
        case .topRight: return CGPoint(x: size.width - 10 - spot / 2, y: 20 + spot / 2)
        case .bottomCenter: return CGPoint(x: size.width / 2, y: size.height - 12 - spot / 2)
        }
    }
}

/// An empty position: a ring, filled in the system accent color under the pointer.
private struct PositionSpot: View {
    var action: () -> Void
    @State private var isHovering = false

    static let size: CGFloat = 20

    var body: some View {
        Button(action: action) {
            ZStack {
                if isHovering {
                    Circle().fill(Color.accentColor)
                    Circle().strokeBorder(Color.white, lineWidth: 3)
                } else {
                    Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1.5)
                }
            }
            .frame(width: 12, height: 12)
            .frame(width: Self.size, height: Self.size)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// A still recorder (recording, a fixed waveform, 0:07) for previews such as the position
/// picker. Not interactive, no timers.
struct RecordingOverlayPreview: View {
    @StateObject private var model: RecordingOverlayViewModel = {
        let model = RecordingOverlayViewModel(waveform: OverlayWaveform(staticHistory: RecordingOverlayPreview.history))
        model.state = .recording
        model.elapsedSeconds = 7
        return model
    }()

    /// A speech-like level history (the design's "rec" sample).
    static let history = LevelHistory(values: [
        0.02, 0.03, 0.04, 0.3, 0.55, 0.72, 0.46, 0.2, 0.05, 0.03, 0.38, 0.82, 0.95,
        0.62, 0.78, 0.5, 0.24, 0.08, 0.04, 0.42, 0.66, 0.9, 0.7, 0.44, 0.58, 0.32,
    ])

    var body: some View {
        RecordingOverlayView(viewModel: model, onStop: {})
            .fixedSize()
            .transaction { $0.animation = nil }
    }
}
