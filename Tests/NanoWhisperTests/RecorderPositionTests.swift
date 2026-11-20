import AppKit
import Testing
@testable import NanoWhisper

@Suite("Recorder position")
struct RecorderPositionTests {
    private func makeDefaults() -> UserDefaults {
        let name = "RecorderPositionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Four positions in the order shown in Settings, with their names")
    func cases() {
        #expect(RecorderPosition.allCases == [.topLeft, .topCenter, .topRight, .bottomCenter])
        #expect(RecorderPosition.allCases.map(\.title) == ["Top Left", "Top Center", "Top Right", "Bottom Center"])
        #expect(RecorderPosition.allCases.map(\.rawValue) == ["topLeft", "topCenter", "topRight", "bottomCenter"])
    }

    @Test("Top Center when nothing or an unknown value is stored")
    func defaultValue() {
        let defaults = makeDefaults()
        #expect(RecorderPosition.defaultsKey == "recorderPosition")
        #expect(RecorderPosition.load(from: defaults) == .topCenter)
        defaults.set("middle", forKey: RecorderPosition.defaultsKey)
        #expect(RecorderPosition.load(from: defaults) == .topCenter)
    }

    @Test("Each position survives a save and load", arguments: RecorderPosition.allCases)
    func persistence(position: RecorderPosition) {
        let defaults = makeDefaults()
        position.save(to: defaults)
        #expect(defaults.string(forKey: "recorderPosition") == position.rawValue)
        #expect(RecorderPosition.load(from: defaults) == position)
    }

    // MARK: - Placement

    /// A 1512 × 982 pt screen with a 33 pt menu bar and a 70 pt Dock.
    private let visible = NSRect(x: 0, y: 70, width: 1512, height: 879)
    private let compact = NSSize(width: 184, height: 36)

    @Test("Initial frame: 12 pt inside the visible frame, at each position")
    func initialFrames() {
        #expect(RecorderPosition.topLeft.initialFrame(size: compact, in: visible)
                == NSRect(x: 12, y: 949 - 12 - 36, width: 184, height: 36))
        #expect(RecorderPosition.topCenter.initialFrame(size: compact, in: visible)
                == NSRect(x: 664, y: 901, width: 184, height: 36))
        #expect(RecorderPosition.topRight.initialFrame(size: compact, in: visible)
                == NSRect(x: 1512 - 12 - 184, y: 901, width: 184, height: 36))
        #expect(RecorderPosition.bottomCenter.initialFrame(size: compact, in: visible)
                == NSRect(x: 664, y: 70 + 12, width: 184, height: 36))
    }

    @Test("Initial frame on a secondary screen left of the main one")
    func initialFrameOnSecondaryScreen() {
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1055)
        for position in RecorderPosition.allCases {
            let frame = position.initialFrame(size: compact, in: secondary)
            #expect(secondary.contains(frame), "\(position)")
        }
        #expect(RecorderPosition.topLeft.initialFrame(size: compact, in: secondary).minX == -1908)
        #expect(RecorderPosition.topRight.initialFrame(size: compact, in: secondary).maxX == -12)
    }

    @Test("Growth keeps the pinned edges", arguments: RecorderPosition.allCases)
    func growth(position: RecorderPosition) {
        let current = position.initialFrame(size: compact, in: visible)
        let card = NSSize(width: 380, height: 87)
        let grown = position.frame(fitting: card, from: current, within: visible)
        #expect(grown.size == card)
        #expect(visible.contains(grown))
        switch position {
        case .topLeft:
            #expect(grown.minX == current.minX && grown.maxY == current.maxY)
        case .topCenter:
            #expect(grown.midX == current.midX && grown.maxY == current.maxY)
        case .topRight:
            #expect(grown.maxX == current.maxX && grown.maxY == current.maxY)
        case .bottomCenter:
            #expect(grown.midX == current.midX && grown.minY == current.minY)
        }
        // And back: shrinking returns to the same frame.
        #expect(position.frame(fitting: compact, from: grown, within: visible) == current)
    }

    @Test("Growth direction: only Bottom Center grows upward")
    func growthDirection() {
        #expect(RecorderPosition.allCases.filter(\.growsUpward) == [.bottomCenter])
        #expect(RecorderPosition.topLeft.horizontalAnchor == .left)
        #expect(RecorderPosition.topCenter.horizontalAnchor == .center)
        #expect(RecorderPosition.topRight.horizontalAnchor == .right)
        #expect(RecorderPosition.bottomCenter.horizontalAnchor == .center)
    }

    @Test("A dragged overlay grows from where it is, kept inside its screen")
    func draggedOverlay() {
        // Dragged near the right edge while pinned left: it would stick out, so it moves back.
        let current = NSRect(x: 1300, y: 500, width: 184, height: 36)
        let grown = RecorderPosition.topLeft.frame(fitting: NSSize(width: 380, height: 87), from: current, within: visible)
        #expect(grown.maxX == visible.maxX)
        #expect(grown.maxY == current.maxY)
        // Without a screen, no clamping.
        let free = RecorderPosition.bottomCenter.frame(fitting: NSSize(width: 380, height: 87), from: current, within: nil)
        #expect(free.minY == current.minY && free.midX == current.midX)
    }

    // MARK: - Picker geometry

    @Test("The picker's mini screen draws the recorder inside it at every position")
    @MainActor func pickerGeometry() {
        let bounds = CGRect(origin: .zero, size: RecorderPositionScreen.size)
        for position in RecorderPosition.allCases {
            let origin = RecorderPositionScreen.recorderOrigin(for: position)
            let rect = CGRect(origin: origin, size: RecorderPositionScreen.recorderSize)
            #expect(bounds.contains(rect), "\(position)")
            #expect(rect.minY >= RecorderPositionScreen.menuBarHeight, "\(position) under the menu bar")
            #expect(bounds.contains(RecorderPositionScreen.spotCenter(for: position)), "\(position)")
        }
        #expect(RecorderPositionScreen.recorderOrigin(for: .bottomCenter).y
                > RecorderPositionScreen.recorderOrigin(for: .topCenter).y)
    }
}
