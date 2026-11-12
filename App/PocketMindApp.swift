import SwiftUI
import PocketMindCore

@main
struct PocketMindApp: App {
    @StateObject private var launcher = Launcher()

    var body: some Scene {
        WindowGroup {
            Group {
                if let environment = launcher.environment {
                    RootView()
                        .environmentObject(environment)
                        .environmentObject(environment.settings)
                        .environmentObject(environment.recorder)
                        .environmentObject(environment.player)
                        .environmentObject(environment.models)
                        .environmentObject(environment.pipeline)
                        .environmentObject(environment.lock)
                        .environmentObject(AppRouter.shared)
                } else {
                    LaunchFailureView(message: launcher.failure, retry: launcher.start)
                }
            }
            .preferredColorScheme(.dark)
            .tint(Theme.Palette.accent)
        }
    }
}

/// Builds the app environment. Opening the vault can fail when the app is launched while
/// the phone is still locked (the key and database are unreadable then), so failure is a
/// state the interface can retry from rather than a crash.
@MainActor
final class Launcher: ObservableObject {
    @Published private(set) var environment: AppEnvironment?
    @Published private(set) var failure: String?

    init() { start() }

    func start() {
        guard environment == nil else { return }
        do {
            environment = try AppEnvironment()
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}

struct LaunchFailureView: View {
    let message: String?
    let retry: () -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        VStack(spacing: Theme.Spacing.l) {
            Image(systemName: "lock.shield")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.Palette.accent)
            Text("PocketMind can't open its vault yet")
                .font(.headline)
            Text(message ?? "Unlock your iPhone and try again.")
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: retry)
                .buttonStyle(PrimaryButtonStyle())
                .frame(maxWidth: 220)
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.background.ignoresSafeArea())
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { retry() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var lock: AppLock
    @EnvironmentObject private var router: AppRouter
    @EnvironmentObject private var recorder: AudioRecorderService
    @EnvironmentObject private var pipeline: ProcessingPipeline
    @Environment(\.scenePhase) private var scenePhase
    @State private var showRecorder = false

    var body: some View {
        ZStack {
            TabView(selection: $router.selectedTab) {
                HomeView(startRecording: startRecording)
                    .tabItem { Label("Home", systemImage: "house.fill") }
                    .tag(AppTab.home)
                LibraryView()
                    .tabItem { Label("Recordings", systemImage: "waveform") }
                    .tag(AppTab.recordings)
                MemoryView()
                    .tabItem { Label("Memory", systemImage: "bubble.left.and.text.bubble.right") }
                    .tag(AppTab.memory)
                TasksView()
                    .tabItem { Label("Tasks", systemImage: "checklist") }
                    .tag(AppTab.tasks)
            }
            .fullScreenCover(isPresented: $showRecorder) {
                RecordingView()
            }

            // Covers the interface whenever the app is not frontmost, so the app switcher
            // snapshot never shows recording titles or transcript text.
            if scenePhase != .active || lock.isLocked {
                PrivacyCover(showUnlock: lock.isLocked && scenePhase == .active)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: lock.isLocked)
        .alert("PocketMind", isPresented: Binding(
            get: { environment.banner != nil }, set: { if !$0 { environment.banner = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(environment.banner ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                Task {
                    await lock.unlock()
                    await environment.didBecomeActive()
                    consumeRouterRequest()
                }
            case .background:
                environment.didEnterBackground()
            default:
                break
            }
        }
        .onChange(of: router.startRecordingRequested) { _, _ in consumeRouterRequest() }
        .onChange(of: lock.isLocked) { _, _ in consumeRouterRequest() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            pipeline.handleMemoryWarning()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willTerminateNotification)) { _ in
            // Finalise the audio file so a recording in progress is not lost when the app is closed.
            if recorder.isActive { recorder.stop() }
        }
        .task {
            await lock.unlock()
            await environment.didBecomeActive()
            consumeRouterRequest()
        }
    }

    private func startRecording() {
        Task {
            await environment.startRecording()
            if recorder.isActive { showRecorder = true }
        }
    }

    /// Starts the recording requested by the Action Button / Shortcuts intent, once the
    /// app is unlocked and visible.
    private func consumeRouterRequest() {
        guard router.startRecordingRequested, !lock.isLocked, scenePhase == .active else { return }
        router.startRecordingRequested = false
        if recorder.isActive {
            showRecorder = true
        } else {
            startRecording()
        }
    }
}

struct PrivacyCover: View {
    let showUnlock: Bool
    @EnvironmentObject private var lock: AppLock

    var body: some View {
        ZStack {
            Theme.Palette.background.ignoresSafeArea()
            VStack(spacing: Theme.Spacing.l) {
                Image(systemName: "waveform")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(Theme.Palette.accent)
                Text("PocketMind")
                    .font(.title2.weight(.semibold))
                if showUnlock {
                    if let error = lock.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.Palette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    Button {
                        Task { await lock.unlock() }
                    } label: {
                        Label("Unlock with \(AppLock.biometryName)", systemImage: "lock.open.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 260)
                }
            }
            .padding(Theme.Spacing.xl)
        }
    }
}
