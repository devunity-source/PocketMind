import AppIntents
import Foundation
import LocalAuthentication

/// Gates the interface behind Face ID / Touch ID with the device passcode as fallback.
/// This protects against someone picking up the unlocked phone; the data itself is
/// additionally protected at rest by iOS Data Protection and the vault key.
@MainActor
final class AppLock: ObservableObject {
    @Published private(set) var isLocked: Bool
    @Published private(set) var lastError: String?
    private var isAuthenticating = false

    init(enabled: Bool) {
        isLocked = enabled
    }

    static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Passcode"
        }
    }

    /// False when the device has no passcode at all; the lock cannot work then.
    static var deviceCanAuthenticate: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func lock() {
        isLocked = true
    }

    func unlock() async {
        guard isLocked, !isAuthenticating else { return }
        isAuthenticating = true
        defer { isAuthenticating = false }

        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            // No passcode is set on the device. There is nothing to authenticate against,
            // so the lock is not enforced; Settings explains this to the user.
            lastError = nil
            isLocked = false
            return
        }
        do {
            let success = try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: "Unlock your recordings")
            if success {
                lastError = nil
                isLocked = false
            }
        } catch {
            let code = (error as? LAError)?.code
            lastError = (code == .userCancel || code == .systemCancel || code == .appCancel) ? nil : error.localizedDescription
        }
    }
}

/// Carries requests from outside the view hierarchy (App Intents) to the interface.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var startRecordingRequested = false
    @Published var selectedTab: AppTab = .home
}

enum AppTab: Hashable {
    case home, recordings, memory, tasks
}

/// "Start Recording" as a system action. Assign it to the iPhone Action Button
/// (Settings → Action Button → Shortcut → PocketMind → Start Recording), run it from
/// Shortcuts, or ask Siri. It opens the app and starts a visible recording; it cannot
/// record in the background without the app coming to the front.
struct StartRecordingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Recording"
    static let description = IntentDescription("Opens PocketMind and starts a new recording.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        AppRouter.shared.startRecordingRequested = true
        return .result()
    }
}

struct PocketMindShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: ["Start recording in \(.applicationName)", "Record with \(.applicationName)"],
            shortTitle: "Start Recording",
            systemImageName: "waveform")
    }
}
