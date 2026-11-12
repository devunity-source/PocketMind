import Foundation
import Security
import PocketMindCore

enum VaultError: Error, LocalizedError {
    case keychain(OSStatus)
    case protectedDataUnavailable
    case missingAudio

    var errorDescription: String? {
        switch self {
        case .keychain(let status): "The encryption key could not be accessed (Keychain status \(status))."
        case .protectedDataUnavailable: "The iPhone is locked, so protected data cannot be read yet."
        case .missingAudio: "The audio file for this recording is missing."
        }
    }
}

/// Stores the 256-bit vault key in the Keychain. The item is readable only while the
/// device is unlocked and never leaves this device (it is excluded from backups and
/// from iCloud Keychain).
enum KeychainKeyStore {
    private static let service = "app.pocketmind.vault"
    private static let account = "master-key-v1"

    private static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func load() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
        return item as? Data
    }

    static func store(_ key: Data) throws {
        var attributes = baseQuery
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw VaultError.keychain(status) }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    static func loadOrCreate() throws -> Data {
        if let existing = try load() { return existing }
        let key = FileCipher.generateKey()
        try store(key)
        return key
    }
}

/// Owns every file the app writes: directory layout, iOS Data Protection classes,
/// backup exclusion and the AES-GCM encryption of audio.
final class Vault: @unchecked Sendable {
    let root: URL
    let databaseDirectory: URL
    let audioDirectory: URL
    /// Recordings in progress. Uses "complete unless open" so recording can continue
    /// after the phone locks.
    let captureDirectory: URL
    let modelsDirectory: URL
    /// Short-lived decrypted files (decoding for transcription, exports). Wiped at launch.
    let scratchDirectory: URL

    private(set) var cipher: FileCipher

    var databaseURL: URL { databaseDirectory.appendingPathComponent("pocketmind.sqlite") }

    init(root: URL? = nil, keyData: Data? = nil) throws {
        let fileManager = FileManager.default
        let base = try root ?? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
            .appendingPathComponent("PocketMind", isDirectory: true)
        self.root = base
        databaseDirectory = base.appendingPathComponent("db", isDirectory: true)
        audioDirectory = base.appendingPathComponent("audio", isDirectory: true)
        captureDirectory = base.appendingPathComponent("capture", isDirectory: true)
        modelsDirectory = base.appendingPathComponent("models", isDirectory: true)
        scratchDirectory = base.appendingPathComponent("scratch", isDirectory: true)

        cipher = try FileCipher(keyData: try keyData ?? KeychainKeyStore.loadOrCreate())

        try Vault.prepare(base, protection: .complete)
        try Vault.prepare(databaseDirectory, protection: .complete)
        try Vault.prepare(audioDirectory, protection: .complete)
        try Vault.prepare(captureDirectory, protection: .completeUnlessOpen)
        try Vault.prepare(scratchDirectory, protection: .complete)
        // Models are public downloads, not personal data.
        try Vault.prepare(modelsDirectory, protection: .completeUntilFirstUserAuthentication)

        // Nothing under the vault goes into iCloud or computer backups: an unencrypted
        // backup would otherwise contain the transcript database in the clear.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableBase = base
        try? mutableBase.setResourceValues(values)

        wipeScratch()
    }

    private static func prepare(_ directory: URL, protection: FileProtectionType) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.protectionKey: protection])
        // Also applies the class when the directory already existed; new files inherit it.
        try? FileManager.default.setAttributes([.protectionKey: protection], ofItemAtPath: directory.path)
    }

    // MARK: Audio

    func audioURL(fileName: String) -> URL { audioDirectory.appendingPathComponent(fileName) }

    /// Encrypts a finished capture (or imported file) into the vault and removes the
    /// plaintext original. Returns the stored file name and encrypted size.
    func sealAudio(at plainURL: URL, recordingID: String, removeOriginal: Bool = true) throws -> (fileName: String, size: Int64) {
        // The original container type is kept in the name ("<id>.m4a.pmenc") so imported
        // MP3/WAV files are decoded and exported with the right extension.
        let originalExtension = plainURL.pathExtension.isEmpty ? "m4a" : plainURL.pathExtension.lowercased()
        let fileName = "\(recordingID).\(originalExtension).pmenc"
        let destination = audioURL(fileName: fileName)
        try cipher.encryptFile(at: plainURL, to: destination)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
        if removeOriginal { try? FileManager.default.removeItem(at: plainURL) }
        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
        return (fileName, size)
    }

    /// Decrypted audio in memory, for playback. Nothing is written to disk.
    func audioData(for recording: Recording) throws -> Data {
        let url = audioURL(fileName: recording.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw VaultError.missingAudio }
        return try cipher.decryptFile(at: url)
    }

    /// Decrypts audio to a scratch file for APIs that need a file URL, and deletes it
    /// when `body` returns or throws.
    func withDecryptedAudio<T>(for recording: Recording, body: (URL) async throws -> T) async throws -> T {
        let source = audioURL(fileName: recording.fileName)
        guard FileManager.default.fileExists(atPath: source.path) else { throw VaultError.missingAudio }
        let scratch = scratchDirectory.appendingPathComponent(UUID().uuidString + "." + Vault.audioExtension(of: recording.fileName))
        try cipher.decryptFile(at: source, to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }
        return try await body(scratch)
    }

    /// "abc.mp3.pmenc" → "mp3".
    static func audioExtension(of storedFileName: String) -> String {
        let inner = (storedFileName as NSString).deletingPathExtension
        let ext = (inner as NSString).pathExtension
        return ext.isEmpty ? "m4a" : ext
    }

    func deleteAudio(fileName: String) {
        try? FileManager.default.removeItem(at: audioURL(fileName: fileName))
    }

    // MARK: Scratch

    func scratchURL(named name: String) -> URL {
        let directory = scratchDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    func wipeScratch() {
        let fileManager = FileManager.default
        for url in (try? fileManager.contentsOfDirectory(at: scratchDirectory, includingPropertiesForKeys: nil)) ?? [] {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: Storage

    static func directorySize(_ directory: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    var freeDiskSpace: Int64 {
        let values = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    var totalDiskSpace: Int64 {
        Int64((try? root.resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity) ?? 0)
    }

    // MARK: Erase

    /// Deletes every recording and capture, then destroys the vault key and creates a
    /// new one. Without the old key, any encrypted audio that survived elsewhere
    /// (for example in an old device backup) can no longer be decrypted.
    func eraseAllUserData() throws {
        let fileManager = FileManager.default
        for directory in [audioDirectory, captureDirectory, scratchDirectory] {
            for url in (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
                try? fileManager.removeItem(at: url)
            }
        }
        KeychainKeyStore.delete()
        cipher = try FileCipher(keyData: try KeychainKeyStore.loadOrCreate())
    }
}
