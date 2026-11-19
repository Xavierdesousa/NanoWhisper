import Foundation

// MARK: - Steps

/// The onboarding steps, in order. Every step can be left with Continue (or Skip Setup):
/// a step that is not done yet is marked in the step indicator, never blocking.
enum OnboardingStep: Int, CaseIterable, Identifiable, Comparable {
    case welcome
    case model
    case permissions
    case shortcut
    case done

    var id: Self { self }

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Short name shown in the step indicator.
    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .model: return "Model"
        case .permissions: return "Permissions"
        case .shortcut: return "Shortcut"
        case .done: return "Done"
        }
    }

    var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    /// Title of the button that moves forward from this step.
    var primaryButtonTitle: String {
        switch self {
        case .welcome: return "Get Started"
        case .model, .permissions, .shortcut: return "Continue"
        case .done: return "Finish"
        }
    }

    var canGoBack: Bool { previous != nil }
    /// "Skip Setup" closes onboarding from any step but the last, where Finish does the same.
    var canSkip: Bool { self != .done }
}

// MARK: - Completion

/// What the app already has, which decides which steps count as done.
struct OnboardingProgress: Equatable {
    var modelReady: Bool
    var microphoneGranted: Bool
    var accessibilityGranted: Bool

    /// Whether the step's goal is met. Welcome and Shortcut have nothing to fulfil
    /// (a default shortcut always exists); Done is the end of the flow.
    func isComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome, .shortcut: return true
        case .model: return modelReady
        case .permissions: return microphoneGranted && accessibilityGranted
        case .done: return false
        }
    }

    /// Steps whose goal is not met, listed on the Done step.
    var pendingSteps: [OnboardingStep] {
        [.model, .permissions].filter { !isComplete($0) }
    }

    /// How a step appears in the step indicator while `current` is shown.
    /// Model and Permissions show as done as soon as their goal is met, even before the user
    /// reaches them (model already downloaded, permissions already granted); the others only
    /// once passed. A passed step whose goal is not met is flagged.
    func indicatorState(of step: OnboardingStep, current: OnboardingStep) -> StepIndicatorState {
        if step == current { return .current }
        switch step {
        case .model, .permissions:
            if isComplete(step) { return .complete }
            return step < current ? .needsAttention : .upcoming
        case .welcome, .shortcut, .done:
            return step < current ? .complete : .upcoming
        }
    }
}

enum StepIndicatorState: Equatable {
    case current
    case complete
    case needsAttention
    case upcoming
}

// MARK: - Launch arguments

/// Command-line switches for testing onboarding (`open -a NanoWhisper --args --onboarding`).
struct LaunchOptions: Equatable {
    /// `--onboarding`: show onboarding at launch even if it was completed. Settings are kept.
    var showOnboarding = false
    /// `--reset-onboarding`: clear only the "onboarding completed" flag, so onboarding shows
    /// at this launch and every launch until it is finished again.
    var resetOnboarding = false

    static let showOnboardingArgument = "--onboarding"
    static let resetOnboardingArgument = "--reset-onboarding"

    init(showOnboarding: Bool = false, resetOnboarding: Bool = false) {
        self.showOnboarding = showOnboarding
        self.resetOnboarding = resetOnboarding
    }

    /// Unknown arguments (including the `-Key value` pairs macOS and Xcode pass) are ignored.
    init(arguments: [String]) {
        let args = Set(arguments.dropFirst())
        showOnboarding = args.contains(Self.showOnboardingArgument)
        resetOnboarding = args.contains(Self.resetOnboardingArgument)
    }

    static let current = LaunchOptions(arguments: CommandLine.arguments)

    /// Whether onboarding opens at launch.
    func showsOnboardingAtLaunch(onboardingComplete: Bool) -> Bool {
        !onboardingComplete || showOnboarding || resetOnboarding
    }
}
