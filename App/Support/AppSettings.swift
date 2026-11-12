import Foundation
import PocketMindCore

/// User preferences. Only non-sensitive switches live in UserDefaults; recordings,
/// transcripts and keys never do.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    @Published var appLockEnabled: Bool { didSet { defaults.set(appLockEnabled, forKey: "appLockEnabled") } }
    @Published var quality: RecordingQuality { didSet { defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var defaultKind: RecordingKind { didSet { defaults.set(defaultKind.rawValue, forKey: "defaultKind") } }
    @Published var autoTranscribe: Bool { didSet { defaults.set(autoTranscribe, forKey: "autoTranscribe") } }
    @Published var autoSummarize: Bool { didSet { defaults.set(autoSummarize, forKey: "autoSummarize") } }
    /// ISO 639-1 code, or empty for automatic detection.
    @Published var transcriptionLanguage: String { didSet { defaults.set(transcriptionLanguage, forKey: "transcriptionLanguage") } }
    @Published var whisperModelID: String { didSet { defaults.set(whisperModelID, forKey: "whisperModelID") } }
    @Published var languageModelID: String { didSet { defaults.set(languageModelID, forKey: "languageModelID") } }
    @Published var trashDays: Int { didSet { defaults.set(trashDays, forKey: "trashDays") } }
    /// 0 keeps recordings forever.
    @Published var retentionDays: Int { didSet { defaults.set(retentionDays, forKey: "retentionDays") } }
    @Published var wifiOnlyDownloads: Bool { didSet { defaults.set(wifiOnlyDownloads, forKey: "wifiOnlyDownloads") } }
    @Published var keepAwakeWhileProcessing: Bool { didSet { defaults.set(keepAwakeWhileProcessing, forKey: "keepAwake") } }
    @Published var notifyWhenProcessed: Bool { didSet { defaults.set(notifyWhenProcessed, forKey: "notifyWhenProcessed") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "appLockEnabled": true, "autoTranscribe": true, "autoSummarize": true,
            "trashDays": 30, "retentionDays": 0, "wifiOnlyDownloads": true, "keepAwake": true,
            "notifyWhenProcessed": true,
        ])
        appLockEnabled = defaults.bool(forKey: "appLockEnabled")
        quality = RecordingQuality(rawValue: defaults.string(forKey: "quality") ?? "") ?? .standard
        defaultKind = RecordingKind(rawValue: defaults.string(forKey: "defaultKind") ?? "") ?? .meeting
        autoTranscribe = defaults.bool(forKey: "autoTranscribe")
        autoSummarize = defaults.bool(forKey: "autoSummarize")
        transcriptionLanguage = defaults.string(forKey: "transcriptionLanguage") ?? ""
        whisperModelID = defaults.string(forKey: "whisperModelID") ?? ""
        languageModelID = defaults.string(forKey: "languageModelID") ?? ""
        trashDays = defaults.integer(forKey: "trashDays")
        retentionDays = defaults.integer(forKey: "retentionDays")
        wifiOnlyDownloads = defaults.bool(forKey: "wifiOnlyDownloads")
        keepAwakeWhileProcessing = defaults.bool(forKey: "keepAwake")
        notifyWhenProcessed = defaults.bool(forKey: "notifyWhenProcessed")
    }

    func resetToDefaults() {
        if let domain = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: domain) }
    }
}

enum Format {
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// "45 min", "58 s"
    static func shortDuration(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min" }
        return String(format: "%d h %02d min", total / 3600, (total % 3600) / 60)
    }

    static func bytes(_ value: Int64) -> String { ModelCatalog.format(bytes: value) }

    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: Date()).day, days < 7 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }
}
