import AVFoundation
import Foundation
import PocketMindCore

/// Plays a recording from decrypted bytes held in memory; no plaintext audio is written
/// to disk for playback.
@MainActor
final class AudioPlayerService: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var loadedRecordingID: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published var currentTime: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0
    @Published var rate: Float = 1 { didSet { player?.rate = rate } }
    @Published private(set) var errorMessage: String?

    private let vault: Vault
    private var player: AVAudioPlayer?
    private var timer: Timer?

    init(vault: Vault) {
        self.vault = vault
        super.init()
    }

    func load(_ recording: Recording) async {
        guard loadedRecordingID != recording.id else { return }
        unload()
        isLoading = true
        errorMessage = nil
        let vault = self.vault
        do {
            // Decryption of a long recording takes a moment; keep it off the main thread.
            let data = try await Task.detached(priority: .userInitiated) { try vault.audioData(for: recording) }.value
            let player = try AVAudioPlayer(data: data)
            player.delegate = self
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            loadedRecordingID = recording.id
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func unload() {
        stopTimer()
        player?.stop()
        player = nil
        loadedRecordingID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        player.rate = rate
        if player.play() {
            isPlaying = true
            startTimer()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTimer()
    }

    func seek(to time: TimeInterval, autoplay: Bool = false) {
        guard let player else { return }
        player.currentTime = max(0, min(time, max(0, player.duration - 0.05)))
        currentTime = player.currentTime
        if autoplay, !isPlaying { play() }
    }

    func skip(_ seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    private func startTimer() {
        stopTimer()
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.stopTimer()
            self.currentTime = 0
            self.player?.currentTime = 0
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

/// Streams any audio file AVFoundation can read as 16 kHz mono Float32 PCM — the format
/// Whisper expects — a bounded number of seconds at a time.
final class AudioWindowReader {
    static let sampleRate = 16_000

    private let file: AVAudioFile
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private(set) var isAtEnd = false

    /// Duration of the whole file in seconds.
    let duration: Double

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url)
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Self.sampleRate),
                                               channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
            throw EngineError.inferenceFailed("This audio format cannot be converted for transcription.")
        }
        self.outputFormat = outputFormat
        self.converter = converter
        let rate = file.processingFormat.sampleRate
        duration = rate > 0 ? Double(file.length) / rate : 0
    }

    static func duration(of url: URL) -> Double {
        (try? AudioWindowReader(url: url).duration) ?? 0
    }

    /// Moves the read position, used to resume a transcription that was paused.
    func seek(toSeconds seconds: Double) {
        let frame = AVAudioFramePosition(seconds * file.processingFormat.sampleRate)
        file.framePosition = max(0, min(frame, file.length))
        converter.reset()
        isAtEnd = file.framePosition >= file.length
    }

    /// Reads up to `seconds` of audio. Returns fewer samples (possibly none) at the end.
    func read(seconds: Double) throws -> [Float] {
        let wanted = Int(seconds * Double(Self.sampleRate))
        var samples: [Float] = []
        samples.reserveCapacity(max(0, wanted))
        let inputFormat = file.processingFormat

        while samples.count < wanted, !isAtEnd {
            let capacity = AVAudioFrameCount(min(Self.sampleRate, wanted - samples.count))
            guard capacity > 0, let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { break }

            var conversionError: NSError?
            var readError: Error?
            let status = converter.convert(to: output, error: &conversionError) { [file] packetCount, inputStatus in
                let remaining = file.length - file.framePosition
                guard remaining > 0,
                      let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: packetCount) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input, frameCount: min(packetCount, AVAudioFrameCount(min(remaining, Int64(UInt32.max)))))
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                guard input.frameLength > 0 else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return input
            }

            if let readError { throw readError }
            if let conversionError { throw conversionError }
            if let channel = output.floatChannelData, output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || (status != .haveData && output.frameLength == 0) {
                isAtEnd = true
            }
        }
        return samples
    }
}
