import AVFoundation
import Foundation
import PocketMindCore

enum RecorderError: Error, LocalizedError {
    case microphoneDenied
    case lowStorage
    case couldNotStart
    case alreadyRecording

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Microphone access is turned off. Enable it in Settings → Privacy & Security → Microphone."
        case .lowStorage: "There is not enough free storage to start a recording."
        case .couldNotStart: "The recording could not be started."
        case .alreadyRecording: "A recording is already in progress."
        }
    }
}

/// Records AAC audio to an .m4a file in the capture directory. The service only captures;
/// encrypting the result and adding it to the library is done by `RecordingImporter`, so
/// a normal stop and a recovery after an interruption share one code path.
@MainActor
final class AudioRecorderService: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum State: Equatable { case idle, recording, paused }

    @Published private(set) var state: State = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    /// Recent input levels (0...1), newest last, for the waveform.
    @Published private(set) var levels: [Float] = []
    /// Why the recording was paused by the system, if it was.
    @Published private(set) var notice: String?
    @Published private(set) var inputName: String = "iPhone Microphone"
    @Published var title: String = ""
    @Published var kind: RecordingKind = .meeting
    @Published var tags: [String] = []
    private(set) var quality: RecordingQuality = .standard

    static let levelCount = 90

    private let captureDirectory: URL
    private var recorder: AVAudioRecorder?
    private var journal: RecoveryJournal?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pausedBySystem = false

    init(captureDirectory: URL) {
        self.captureDirectory = captureDirectory
        super.init()
        observeSession()
    }

    var isActive: Bool { state != .idle }
    var activeRecordingID: String? { journal?.recordingID }

    // MARK: Permission

    static var permissionGranted: Bool { AVAudioApplication.shared.recordPermission == .granted }
    static var permissionDenied: Bool { AVAudioApplication.shared.recordPermission == .denied }

    /// Asks for microphone access the first time. iOS shows its own prompt and its own
    /// recording indicator; the app never records without both.
    func requestPermission() async -> Bool {
        if Self.permissionGranted { return true }
        return await AVAudioApplication.requestRecordPermission()
    }

    // MARK: Control

    func start(title: String, kind: RecordingKind, quality: RecordingQuality, tags: [String] = [],
               freeDiskSpace: Int64) async throws {
        guard state == .idle else { throw RecorderError.alreadyRecording }
        guard await requestPermission() else { throw RecorderError.microphoneDenied }
        // Roughly ten minutes at the chosen quality plus headroom for encryption.
        guard freeDiskSpace > 150_000_000 else { throw RecorderError.lowStorage }

        let session = AVAudioSession.sharedInstance()
        // .allowBluetooth lets a connected Bluetooth headset microphone be used as input.
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetooth, .defaultToSpeaker])
        try session.setActive(true)

        let id = UUID().uuidString
        let fileName = id + ".m4a"
        let url = captureDirectory.appendingPathComponent(fileName)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: quality.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: quality.bitRate,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        let journal = RecoveryJournal(recordingID: id, title: title, startedAt: Date(), audioFileName: fileName,
                                      quality: quality, kind: kind, tags: tags)
        try journal.write(to: captureDirectory)

        guard recorder.prepareToRecord(), recorder.record() else {
            RecoveryJournal.remove(recordingID: id, from: captureDirectory)
            try? FileManager.default.removeItem(at: url)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw RecorderError.couldNotStart
        }

        self.recorder = recorder
        self.journal = journal
        self.title = title
        self.kind = kind
        self.tags = tags
        self.quality = quality
        elapsed = 0
        levels = []
        notice = nil
        pausedBySystem = false
        state = .recording
        updateInputName()
        startTimer()
    }

    func pause() {
        guard state == .recording, let recorder else { return }
        recorder.pause()
        pausedBySystem = false
        state = .paused
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            notice = "The microphone is in use by another app."
            return
        }
        if recorder.record() {
            notice = nil
            pausedBySystem = false
            state = .recording
        }
    }

    /// Stops capturing and finalises the audio file. The journal is rewritten with the
    /// latest title, kind and tags and left in place for `RecordingImporter` to pick up.
    func stop() {
        guard state != .idle, let recorder else { return }
        if var journal {
            journal.title = title
            journal.kind = kind
            journal.tags = tags
            try? journal.write(to: captureDirectory)
        }
        recorder.stop()
        finish()
    }

    /// Stops and throws the audio away.
    func discard() {
        guard state != .idle, let recorder, let journal else { return }
        recorder.stop()
        recorder.deleteRecording()
        RecoveryJournal.remove(recordingID: journal.recordingID, from: captureDirectory)
        finish()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        journal = nil
        state = .idle
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Metering

    private func startTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let recorder else { return }
        elapsed = recorder.currentTime
        guard state == .recording else { return }
        recorder.updateMeters()
        // averagePower is in dBFS (-160...0). Map -50...0 dB onto 0...1.
        let power = recorder.averagePower(forChannel: 0)
        let level = max(0, min(1, (power + 50) / 50))
        levels.append(level)
        if levels.count > Self.levelCount { levels.removeFirst(levels.count - Self.levelCount) }
    }

    // MARK: Interruptions and routes

    private func observeSession() {
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()

        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] note in
            let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let optionsValue = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in self?.handleInterruption(typeValue: typeValue, optionsValue: optionsValue) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.updateInputName() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
            // The audio server restarted; the recorder object is dead. Keep what was captured.
            Task { @MainActor [weak self] in
                guard let self, self.state != .idle else { return }
                self.stop()
                self.notice = "Recording ended because the audio system restarted. The audio captured so far was saved."
            }
        })
    }

    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard state != .idle, let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            // A phone call, Siri or an alarm took the microphone. iOS has already paused
            // the recorder; reflect that instead of pretending to record.
            if state == .recording {
                state = .paused
                pausedBySystem = true
                notice = "Paused: another app or a call is using the microphone."
            }
        case .ended:
            guard pausedBySystem else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            if options.contains(.shouldResume) {
                resume()
            } else {
                notice = "The interruption ended. Tap resume to continue recording."
            }
        @unknown default:
            break
        }
    }

    private func updateInputName() {
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        inputName = input?.portName ?? "iPhone Microphone"
    }

    // MARK: AVAudioRecorderDelegate

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            guard let self, self.state != .idle else { return }
            self.stop()
            self.notice = "Recording stopped because of an encoding error. The audio captured so far was saved."
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            // Finished without us asking (for example the disk filled up).
            guard let self, self.state != .idle, self.recorder === recorder else { return }
            self.finish()
            self.notice = "Recording ended unexpectedly. The audio captured so far was saved."
        }
    }
}
