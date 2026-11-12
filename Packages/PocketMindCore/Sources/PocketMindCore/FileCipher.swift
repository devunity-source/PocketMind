import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum CipherError: Error, LocalizedError, Sendable {
    case invalidKey
    case invalidFormat
    case truncated
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKey: "The encryption key is not 256 bits long."
        case .invalidFormat: "The file is not a PocketMind encrypted file."
        case .truncated: "The encrypted file is incomplete."
        case .authenticationFailed: "The encrypted file is damaged or was written with a different key."
        }
    }
}

/// Authenticated file encryption: AES-256-GCM over fixed-size chunks so that hours of
/// audio can be encrypted and decrypted without holding the whole file in memory.
///
/// Layout: `"PME1"` · chunk size (UInt32 BE) · 8-byte random nonce prefix, then for each
/// chunk `ciphertext ‖ 16-byte tag`. The nonce is prefix ‖ chunk counter (UInt32 BE); the
/// chunk's additional authenticated data is the counter plus a "final chunk" flag, which
/// makes reordering, dropping and truncating chunks detectable.
public struct FileCipher: Sendable {
    static let magic = Data("PME1".utf8)
    static let headerLength = 16
    static let tagLength = 16
    public static let defaultChunkSize = 1 << 20

    // Kept as Data (which is Sendable on every platform) and wrapped on use.
    private let keyData: Data
    private var key: SymmetricKey { SymmetricKey(data: keyData) }

    /// - Parameter keyData: exactly 32 bytes.
    public init(keyData: Data) throws {
        guard keyData.count == 32 else { throw CipherError.invalidKey }
        self.keyData = keyData
    }

    public static func generateKey() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    // MARK: Chunk primitives

    private static func nonce(prefix: Data, counter: UInt32) throws -> AES.GCM.Nonce {
        var bytes = prefix
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try AES.GCM.Nonce(data: bytes)
    }

    private static func aad(counter: UInt32, isFinal: Bool) -> Data {
        var bytes = Data()
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        bytes.append(isFinal ? 1 : 0)
        return bytes
    }

    private func sealChunk(_ plain: Data, prefix: Data, counter: UInt32, isFinal: Bool) throws -> Data {
        let box = try AES.GCM.seal(plain, using: key, nonce: FileCipher.nonce(prefix: prefix, counter: counter),
                                   authenticating: FileCipher.aad(counter: counter, isFinal: isFinal))
        return box.ciphertext + box.tag
    }

    private func openChunk(_ sealed: Data, prefix: Data, counter: UInt32, isFinal: Bool) throws -> Data {
        guard sealed.count >= FileCipher.tagLength else { throw CipherError.truncated }
        let split = sealed.count - FileCipher.tagLength
        do {
            let box = try AES.GCM.SealedBox(
                nonce: FileCipher.nonce(prefix: prefix, counter: counter),
                ciphertext: sealed.prefix(split), tag: sealed.suffix(FileCipher.tagLength))
            return try AES.GCM.open(box, using: key, authenticating: FileCipher.aad(counter: counter, isFinal: isFinal))
        } catch {
            throw CipherError.authenticationFailed
        }
    }

    private static func header(chunkSize: Int, prefix: Data) -> Data {
        var header = magic
        withUnsafeBytes(of: UInt32(chunkSize).bigEndian) { header.append(contentsOf: $0) }
        header.append(prefix)
        return header
    }

    private static func randomPrefix() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<8).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    // MARK: In-memory

    public func seal(_ plain: Data, chunkSize: Int = FileCipher.defaultChunkSize) throws -> Data {
        let prefix = FileCipher.randomPrefix()
        var output = FileCipher.header(chunkSize: chunkSize, prefix: prefix)
        var offset = 0
        var counter: UInt32 = 0
        repeat {
            let end = min(plain.count, offset + chunkSize)
            let isFinal = end == plain.count
            output.append(try sealChunk(plain.subdata(in: offset..<end), prefix: prefix, counter: counter, isFinal: isFinal))
            offset = end
            counter += 1
        } while offset < plain.count
        return output
    }

    public func open(_ sealed: Data) throws -> Data {
        let (chunkSize, prefix) = try FileCipher.parseHeader(sealed.prefix(FileCipher.headerLength))
        let sealedChunk = chunkSize + FileCipher.tagLength
        var output = Data()
        var offset = FileCipher.headerLength
        var counter: UInt32 = 0
        guard sealed.count > offset else { throw CipherError.truncated }
        while offset < sealed.count {
            let end = min(sealed.count, offset + sealedChunk)
            let isFinal = end == sealed.count
            let slice = sealed.subdata(in: offset..<end)
            output.append(try openChunk(slice, prefix: prefix, counter: counter, isFinal: isFinal))
            offset = end
            counter += 1
        }
        return output
    }

    private static func parseHeader(_ header: Data) throws -> (chunkSize: Int, prefix: Data) {
        let bytes = [UInt8](header)
        guard bytes.count == headerLength, Data(bytes[0..<4]) == magic else { throw CipherError.invalidFormat }
        let size = bytes[4..<8].reduce(0) { ($0 << 8) | Int($1) }
        guard size > 0, size <= 64 << 20 else { throw CipherError.invalidFormat }
        return (size, Data(bytes[8..<16]))
    }

    // MARK: Files

    /// Reads exactly `count` bytes unless the end of the file comes first. A single
    /// `read(upToCount:)` is allowed to return fewer bytes, which would misalign chunks.
    private static func readFully(_ handle: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let more = try handle.read(upToCount: count - data.count), !more.isEmpty else { break }
            data.append(more)
        }
        return data
    }

    /// Encrypts `source` into `destination` (which is created or replaced).
    public func encryptFile(at source: URL, to destination: URL, chunkSize: Int = FileCipher.defaultChunkSize) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        let prefix = FileCipher.randomPrefix()
        try output.write(contentsOf: FileCipher.header(chunkSize: chunkSize, prefix: prefix))

        var counter: UInt32 = 0
        var current = try FileCipher.readFully(input, count: chunkSize)
        while true {
            // Read one chunk ahead so the last chunk can be flagged as final.
            let next = try FileCipher.readFully(input, count: chunkSize)
            let isFinal = next.isEmpty
            try output.write(contentsOf: sealChunk(current, prefix: prefix, counter: counter, isFinal: isFinal))
            if isFinal { break }
            current = next
            counter += 1
        }
    }

    /// Decrypts `source` into `destination`. On failure the partial output is removed.
    public func decryptFile(at source: URL, to destination: URL) throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try streamDecrypt(source) { try output.write(contentsOf: $0) }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Decrypts a file fully into memory (used for playback, which never touches disk).
    public func decryptFile(at source: URL) throws -> Data {
        var data = Data()
        try streamDecrypt(source) { data.append($0) }
        return data
    }

    private func streamDecrypt(_ source: URL, sink: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let header = try FileCipher.readFully(input, count: FileCipher.headerLength)
        let (chunkSize, prefix) = try FileCipher.parseHeader(header)
        let sealedChunk = chunkSize + FileCipher.tagLength

        var counter: UInt32 = 0
        var current = try FileCipher.readFully(input, count: sealedChunk)
        guard !current.isEmpty else { throw CipherError.truncated }
        while true {
            let next = try FileCipher.readFully(input, count: sealedChunk)
            let isFinal = next.isEmpty
            try sink(openChunk(current, prefix: prefix, counter: counter, isFinal: isFinal))
            if isFinal { break }
            current = next
            counter += 1
        }
    }
}

public enum Checksum {
    /// Streaming SHA-256 of a file, as lowercase hex.
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 4 << 20) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
