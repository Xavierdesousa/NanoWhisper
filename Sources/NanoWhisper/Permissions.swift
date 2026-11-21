import AppKit
import AVFoundation

/// A system permission NanoWhisper asks for.
enum Permission: CaseIterable, Identifiable {
    case microphone
    case accessibility

    var id: Self { self }

    /// Privacy pane of System Settings where the permission is changed.
    var settingsURL: URL {
        switch self {
        case .microphone:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        }
    }
}

/// Live state of a permission, mapped to one action everywhere:
/// `.notDetermined` offers "Allow…" (the system shows its own request), `.denied` offers
/// "Open System Settings" (only System Settings can change it), `.granted` shows a check
/// (`Permission.actionTitle(for:)`).
enum PermissionStatus: Equatable {
    case granted
    case notDetermined
    case denied

    var isGranted: Bool { self == .granted }

    static func microphone(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        case .denied, .restricted: return .denied
        @unknown default: return .denied
        }
    }

    /// Accessibility trust has no "not asked yet" state. The first request shows the system
    /// prompt; once it was shown (this session), the remaining way is System Settings.
    static func accessibility(trusted: Bool, promptShown: Bool) -> PermissionStatus {
        if trusted { return .granted }
        return promptShown ? .denied : .notDetermined
    }
}

/// Polls permission status while a settings screen is visible, so a permission granted in
/// System Settings shows up within a second without reopening the window.
@MainActor
final class PermissionMonitor: ObservableObject {
    @Published private(set) var microphone: PermissionStatus
    @Published private(set) var accessibility: PermissionStatus

    private var accessibilityPromptShown = false
    private var pollTask: Task<Void, Never>?

    init() {
        microphone = PermissionStatus.microphone(AVCaptureDevice.authorizationStatus(for: .audio))
        accessibility = PermissionStatus.accessibility(
            trusted: PasteManager.checkAccessibility(prompt: false), promptShown: false
        )
    }

    var allGranted: Bool { microphone.isGranted && accessibility.isGranted }

    func refresh() {
        let mic = PermissionStatus.microphone(AVCaptureDevice.authorizationStatus(for: .audio))
        let ax = PermissionStatus.accessibility(
            trusted: PasteManager.checkAccessibility(prompt: false),
            promptShown: accessibilityPromptShown
        )
        // Assign only on change so polling does not re-render the screen every second.
        if mic != microphone { microphone = mic }
        if ax != accessibility { accessibility = ax }
    }

    /// Start polling (call when the screen appears). Safe to call repeatedly.
    func start() {
        refresh()
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                self.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Perform the action matching the permission's current status.
    func request(_ permission: Permission) {
        switch (permission, status(of: permission)) {
        case (_, .granted):
            return
        case (.microphone, .notDetermined):
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        case (.accessibility, .notDetermined):
            accessibilityPromptShown = true
            _ = PasteManager.checkAccessibility(prompt: true)
            refresh()
        case (_, .denied):
            NSWorkspace.shared.open(permission.settingsURL)
        }
    }

    func status(of permission: Permission) -> PermissionStatus {
        switch permission {
        case .microphone: return microphone
        case .accessibility: return accessibility
        }
    }
}
