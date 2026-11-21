import SwiftUI

// MARK: - Pages

/// The onboarding window's content: one page at a time (Welcome, setup page, Try it), fading
/// in over 0.3 s on Continue. Reads plain values (`SettingsContext`, `TryItInputs`), so the
/// render tests draw every page and state without a running app.
struct OnboardingContent: View {
    @ObservedObject var model: OnboardingModel
    /// Not observed: only the recorder follows its steps (`WelcomeRecorderContent`).
    let demo: WelcomeRecorderDemo
    /// The welcome's opening scene.
    let scene: OpeningSceneClock
    let context: SettingsContext
    let tryIt: TryItInputs
    let appIcon: NSImage
    /// The model choice sheet (Change… on the Model row).
    let modelChoice: () -> AnyView
    /// Renders only (see `SetupPage`).
    var revealsModelChange = false
    var recordsShortcut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // On the window's own background (not painted, see `GroupedStyle.windowNSColor`).
        ZStack {
            page
                .id(model.page)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
        }
        .frame(width: OnboardingWindowPlacement.size.width, height: OnboardingWindowPlacement.size.height)
        // The content runs under the transparent title bar, as drawn (traffic lights over it).
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: model.page)
        .sheet(isPresented: $model.showsModelChoice) { modelChoice() }
    }

    @ViewBuilder
    private var page: some View {
        switch model.page {
        case .welcome:
            WelcomePage(demo: demo, scene: scene, appIcon: appIcon, onContinue: model.goForward)
        case .setup:
            SetupPage(
                context: context, appIcon: appIcon,
                onChangeModel: { model.showsModelChoice = true },
                onContinue: model.goForward,
                revealsModelChange: revealsModelChange,
                recordsShortcut: recordsShortcut
            )
        case .tryIt:
            TryItPage(
                inputs: tryIt,
                onBack: model.goBack,
                onFinish: { model.finish(stage: tryIt.stage) }
            )
        }
    }
}

// MARK: - Bound to the app

/// The content bound to the running app: permissions polled while the window is open, the
/// Try it state from the recording in progress.
struct OnboardingView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var model: OnboardingModel
    @StateObject private var permissions = PermissionMonitor()
    @StateObject private var demo = WelcomeRecorderDemo()
    @StateObject private var scene = OpeningSceneClock()

    var body: some View {
        let context = appState.settingsContext(permissions: permissions)
        OnboardingContent(
            model: model, demo: demo, scene: scene, context: context, tryIt: tryItInputs(context),
            appIcon: OnboardingAppIcon.image,
            modelChoice: {
                AnyView(LiveModelChoiceSheet(appState: appState, permissions: permissions) {
                    model.showsModelChoice = false
                })
            }
        )
        .onAppear {
            permissions.start()
            model.start()
        }
        .onDisappear {
            permissions.stop()
            demo.stop()
            appState.capturesTestTranscription = false
        }
    }

    private func tryItInputs(_ context: SettingsContext) -> TryItInputs {
        TryItInputs(
            stage: TryItStage.resolve(
                microphone: permissions.microphone, modelStatus: context.modelStatus,
                isEngineReady: appState.isEngineReady, isRecording: appState.isRecording,
                isFinishing: appState.isFinishingRecording, isTranscribing: appState.isTranscribing,
                transcript: appState.testTranscription
            ),
            shortcut: appState.shortcut,
            recorderPosition: appState.recorderPosition,
            showsLiveWords: LiveTranscriptionSupport.startsSession(
                enabled: appState.liveTranscriptionEnabled, flavor: .current, configuration: appState.engineConfiguration
            ),
            model: appState.engineConfiguration,
            toggleRecording: { appState.toggleRecording() },
            tryAgain: { appState.clearTestTranscription() },
            requestMicrophone: { permissions.request(.microphone) },
            retryModel: { appState.switchModel(to: appState.selectedModelType) }
        )
    }
}

// MARK: - Window Controller

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var onClose: (() -> Void)?

    /// - Parameters:
    ///   - restart: an open window starts again from the opening scene (the debug build's
    ///     "Open Onboarding"); otherwise it is brought to the front as it is.
    ///   - onFinish: Finish Setup was clicked.
    ///   - onClose: the window closed, by any means (also after `onFinish`).
    func show(appState: AppState, restart: Bool = false, onFinish: @escaping () -> Void, onClose: @escaping () -> Void) {
        show(restart: restart, recorder: appState.recorderPosition, onClose: onClose) {
            // New content each time, so a replay starts again from the opening scene.
            let model = OnboardingModel(actions: .init(
                pageDidAppear: { [weak appState] page in appState?.onboardingPageDidAppear(page) },
                finish: onFinish
            ))
            return AnyView(OnboardingView(appState: appState, model: model))
        }
    }

    /// Opens the window with `makeContent`, brings it to the front, or restarts it with new
    /// content (`OnboardingPresentation`). Internal for the tests.
    func show(restart: Bool, recorder: RecorderPosition, onClose: @escaping () -> Void, makeContent: () -> AnyView) {
        self.onClose = onClose
        switch OnboardingPresentation.resolve(isOpen: window?.isVisible == true, restart: restart) {
        case .bringToFront:
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .restart:
            guard let window else { return }
            // The model sheet belongs to the old content.
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            // The old content goes with its hosting view: its permission polling and the
            // welcome's recorder stop (both hold their owner weakly).
            Self.setContent(makeContent(), in: window)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        case .open:
            let w = Self.makeWindow(content: makeContent())
            w.delegate = self
            Self.place(w, recorder: recorder)
            window = w
            Self.present(w)
        }
    }

    /// The window while it is open (internal for the tests).
    var openWindow: NSWindow? { window?.isVisible == true ? window : nil }

    func close() {
        window?.close()
    }

    /// The window: 580 × 640 pt for every page, a transparent title bar with no title over the
    /// content (traffic lights only), the design's background. Internal for the render tests.
    static func makeWindow(content: some View) -> NSWindow {
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: OnboardingWindowPlacement.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // Not shown in the title bar; named in the Window menu, Mission Control and VoiceOver.
        w.title = BuildFlavor.current.displayName
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        // No `backgroundColor`: the system draws the window's background, the same as the
        // Settings window's content and Finder's settings (`GroupedStyle.windowNSColor`).
        // The whole window is 580 × 640, title bar included: the content runs under it. Left to
        // size the window, the hosting view would add the title bar's safe area (672 pt). With
        // the macOS 26+ design it still did, even with `sizingOptions = []`: as the window's
        // content view it resizes the window after a layout (`NSHostingView.windowDidLayout`,
        // during the welcome's entrance, 2026-11-21). In a plain container it cannot.
        w.contentView = NSView(frame: NSRect(origin: .zero, size: OnboardingWindowPlacement.size))
        setContent(AnyView(content), in: w)
        w.setFrame(NSRect(origin: .zero, size: OnboardingWindowPlacement.size), display: false)
        w.isReleasedWhenClosed = false
        w.isRestorable = false
        w.restorationClass = nil
        w.collectionBehavior = [.moveToActiveSpace]
        return w
    }

    /// Puts `content` in the window's container, replacing what was there.
    static func setContent(_ content: AnyView, in window: NSWindow) {
        guard let container = window.contentView else { return }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.subviews.forEach { $0.removeFromSuperview() }
        container.addSubview(hosting)
    }

    /// On the screen with the pointer (where the recorder will appear), centred, moved away
    /// from the recorder's place (`OnboardingWindowPlacement`).
    static func place(_ window: NSWindow, recorder: RecorderPosition, on screen: NSScreen? = nil) {
        let mouse = NSEvent.mouseLocation
        guard let screen = screen
                ?? NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
                ?? NSScreen.main ?? NSScreen.screens.first else { return }
        window.setFrame(OnboardingWindowPlacement.frame(in: screen.visibleFrame, recorder: recorder), display: true)
    }

    /// Opens with a 0.25 s fade (none with Reduce Motion).
    private static func present(_ window: NSWindow) {
        let fades = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if fades { window.alphaValue = 0 }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard fades else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 1
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // Tear the SwiftUI view down with the window (a closed window keeps its content
        // view), so its permission polling and the welcome's recorder stop.
        window?.contentView = NSView()
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }
}
