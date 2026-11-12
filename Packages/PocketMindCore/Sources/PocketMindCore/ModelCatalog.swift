import Foundation

public enum ModelKind: String, Codable, Sendable {
    case whisper, languageModel
}

/// A model the app knows how to download, verify and run. URLs are pinned to an exact
/// repository revision and every file is verified against its SHA-256 before use.
public struct ModelDescriptor: Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: ModelKind
    public var name: String
    public var fileName: String
    public var url: URL
    public var sizeBytes: Int64
    public var sha256: String
    /// Approximate resident memory needed while the model is running.
    public var workingMemoryBytes: Int64
    public var speed: String
    public var accuracy: String
    public var notes: String
    public var license: String

    public var sizeDescription: String { ModelCatalog.format(bytes: sizeBytes) }
}

public enum ModelCompatibility: Equatable, Sendable {
    case compatible
    /// Will run, with a caveat the UI should show.
    case warning(String)
    case incompatible(String)

    public var isInstallable: Bool {
        if case .incompatible = self { return false }
        return true
    }
}

public enum ModelCatalog {
    private static let whisperBase = "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/"

    public static let whisper: [ModelDescriptor] = [
        ModelDescriptor(
            id: "whisper-base", kind: .whisper, name: "Whisper Base (multilingual)",
            fileName: "ggml-base.bin", url: URL(string: whisperBase + "ggml-base.bin")!,
            sizeBytes: 147_951_465,
            sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe",
            workingMemoryBytes: 400_000_000,
            speed: "Fastest", accuracy: "Basic",
            notes: "Good for clear English. Noticeably weaker for Arabic and Ukrainian.",
            license: "MIT"),
        ModelDescriptor(
            id: "whisper-small-q5", kind: .whisper, name: "Whisper Small (quantized)",
            fileName: "ggml-small-q5_1.bin", url: URL(string: whisperBase + "ggml-small-q5_1.bin")!,
            sizeBytes: 190_085_487,
            sha256: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb",
            workingMemoryBytes: 650_000_000,
            speed: "Fast", accuracy: "Good",
            notes: "Recommended starting point: a good balance for all five supported languages.",
            license: "MIT"),
        ModelDescriptor(
            id: "whisper-large-v3-turbo-q5", kind: .whisper, name: "Whisper Large v3 Turbo (quantized)",
            fileName: "ggml-large-v3-turbo-q5_0.bin", url: URL(string: whisperBase + "ggml-large-v3-turbo-q5_0.bin")!,
            sizeBytes: 574_041_195,
            sha256: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2",
            workingMemoryBytes: 1_700_000_000,
            speed: "Slower", accuracy: "Best",
            notes: "Highest accuracy, especially for Arabic and Ukrainian. Uses the most memory and battery.",
            license: "MIT"),
    ]

    public static let languageModels: [ModelDescriptor] = [
        ModelDescriptor(
            id: "qwen2.5-1.5b-instruct-q4", kind: .languageModel, name: "Qwen 2.5 1.5B Instruct (Q4_K_M)",
            fileName: "qwen2.5-1.5b-instruct-q4_k_m.gguf",
            url: URL(string: "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/91cad51170dc346986eccefdc2dd33a9da36ead9/qwen2.5-1.5b-instruct-q4_k_m.gguf")!,
            sizeBytes: 1_117_320_736,
            sha256: "6a1a2eb6d15622bf3c96857206351ba97e1af16c30d7a74ee38970e434e9407e",
            workingMemoryBytes: 1_800_000_000,
            speed: "Fast", accuracy: "Good",
            notes: "Smallest option. Multilingual. Summaries are shorter and miss more detail than the 3–4B models.",
            license: "Apache-2.0"),
        ModelDescriptor(
            id: "llama-3.2-3b-instruct-q4", kind: .languageModel, name: "Llama 3.2 3B Instruct (Q4_K_M)",
            fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/5ab33fa94d1d04e903623ae72c95d1696f09f9e8/Llama-3.2-3B-Instruct-Q4_K_M.gguf")!,
            sizeBytes: 2_019_377_696,
            sha256: "6c1a2b41161032677be168d354123594c0e6e67d2b9227c84f296ad037c728ff",
            workingMemoryBytes: 3_000_000_000,
            speed: "Medium", accuracy: "Better",
            notes: "Recommended on 8 GB devices. Strongest in English, French and Dutch.",
            license: "Llama 3.2 Community License"),
        ModelDescriptor(
            id: "phi-4-mini-instruct-q4", kind: .languageModel, name: "Phi-4 mini Instruct (Q4_K_M)",
            fileName: "microsoft_Phi-4-mini-instruct-Q4_K_M.gguf",
            url: URL(string: "https://huggingface.co/bartowski/microsoft_Phi-4-mini-instruct-GGUF/resolve/7ff82c2aaa4dde30121698a973765f39be5288c0/microsoft_Phi-4-mini-instruct-Q4_K_M.gguf")!,
            sizeBytes: 2_491_874_688,
            sha256: "01999f17c39cc3074afae5e9c539bc82d45f2dd7faa3917c66cbef76fce8c0c2",
            workingMemoryBytes: 3_600_000_000,
            speed: "Slower", accuracy: "Best",
            notes: "Most capable option here, with the widest language coverage. Needs the most memory.",
            license: "MIT"),
    ]

    public static var all: [ModelDescriptor] { whisper + languageModels }

    public static func descriptor(id: String) -> ModelDescriptor? { all.first { $0.id == id } }

    /// The only hosts the app may ever contact: the model host and the CDN domains it
    /// redirects file downloads to. The downloader refuses every other host, including
    /// redirects, and the tests assert that every catalog URL passes this check.
    public static func isAllowedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host.hasSuffix(".hf.co")
    }

    /// Decides whether a model may be installed on this device.
    /// - Parameters:
    ///   - physicalMemory: total device RAM in bytes.
    ///   - freeDisk: free space in bytes.
    public static func compatibility(of model: ModelDescriptor, physicalMemory: UInt64, freeDisk: Int64,
                                     isInstalled: Bool = false) -> ModelCompatibility {
        // iOS terminates apps well before they reach total RAM; about half is a realistic ceiling.
        let usable = Int64(physicalMemory / 2)
        if model.workingMemoryBytes > usable {
            return .incompatible("Needs about \(format(bytes: model.workingMemoryBytes)) of memory while running; this device can give an app roughly \(format(bytes: usable)).")
        }
        // Keep a margin so the download cannot fill the disk.
        let required = model.sizeBytes + 500_000_000
        if !isInstalled, freeDisk < required {
            return .incompatible("Needs \(format(bytes: required)) of free storage; only \(format(bytes: freeDisk)) is available.")
        }
        if Double(model.workingMemoryBytes) > Double(usable) * 0.8 {
            return .warning("Close to this device's memory limit. Other apps may be closed while it runs.")
        }
        return .compatible
    }

    public static func format(bytes: Int64) -> String {
        let value = Double(bytes)
        if value >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
        if value >= 1_000_000 { return String(format: "%.0f MB", value / 1_000_000) }
        return String(format: "%.0f KB", max(1, value / 1_000))
    }
}

/// Languages the app is tested and tuned for. Whisper itself supports many more.
public enum SupportedLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en", arabic = "ar", ukrainian = "uk", dutch = "nl", french = "fr"

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .english: "English"
        case .arabic: "Arabic"
        case .ukrainian: "Ukrainian"
        case .dutch: "Dutch"
        case .french: "French"
        }
    }

    public static func name(for code: String?) -> String {
        guard let code else { return "Unknown" }
        return SupportedLanguage(rawValue: code)?.name ?? code.uppercased()
    }
}
