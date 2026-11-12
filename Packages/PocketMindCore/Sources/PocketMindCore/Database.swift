import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif

public enum DBValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    public static func optional(_ value: String?) -> DBValue { value.map { .text($0) } ?? .null }
    public static func optional(_ value: Double?) -> DBValue { value.map { .double($0) } ?? .null }
    public static func optional(_ value: Date?) -> DBValue { value.map { .double($0.timeIntervalSince1970) } ?? .null }
    public static func date(_ value: Date) -> DBValue { .double(value.timeIntervalSince1970) }
    public static func bool(_ value: Bool) -> DBValue { .int(value ? 1 : 0) }
}

public struct DBRow: Sendable {
    let values: [String: DBValue]

    public func string(_ column: String) -> String? {
        if case .text(let v)? = values[column] { return v }
        return nil
    }

    public func int(_ column: String) -> Int64? {
        switch values[column] {
        case .int(let v)?: return v
        case .double(let v)?: return Int64(v)
        default: return nil
        }
    }

    public func double(_ column: String) -> Double? {
        switch values[column] {
        case .double(let v)?: return v
        case .int(let v)?: return Double(v)
        default: return nil
        }
    }

    public func bool(_ column: String) -> Bool { (int(column) ?? 0) != 0 }

    public func date(_ column: String) -> Date? {
        double(column).map { Date(timeIntervalSince1970: $0) }
    }
}

public struct DatabaseError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public var description: String { "SQLite error \(code): \(message)" }
}

/// A deliberately small synchronous SQLite wrapper. All access is serialised with a
/// recursive lock, so a single instance can be shared between actors.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public let path: String

    /// - Parameter path: file path, or ":memory:" for a private in-memory database.
    public init(path: String) throws {
        self.path = path
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open database"
            if let db { sqlite3_close(db) }
            throw DatabaseError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 5_000)
        // secure_delete overwrites freed pages with zeros so deleted transcript text does
        // not linger in the database file.
        try execute("PRAGMA secure_delete = ON")
        try execute("PRAGMA foreign_keys = ON")
        if path != ":memory:" {
            _ = try query("PRAGMA journal_mode = WAL")
        }
    }

    deinit { close() }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    public var changes: Int {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    public func execute(_ sql: String, _ params: [DBValue] = []) throws {
        _ = try run(sql, params, collect: false)
    }

    /// Runs several semicolon-separated statements without parameters.
    public func executeScript(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw DatabaseError(code: SQLITE_MISUSE, message: "database is closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        if rc != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError(code: rc, message: message)
        }
    }

    public func query(_ sql: String, _ params: [DBValue] = []) throws -> [DBRow] {
        try run(sql, params, collect: true)
    }

    public func scalarInt(_ sql: String, _ params: [DBValue] = []) throws -> Int64 {
        let rows = try query(sql, params)
        guard let first = rows.first, let value = first.values.values.first else { return 0 }
        switch value {
        case .int(let v): return v
        case .double(let v): return Int64(v)
        default: return 0
        }
    }

    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func run(_ sql: String, _ params: [DBValue], collect: Bool) throws -> [DBRow] {
        lock.lock(); defer { lock.unlock() }
        guard let handle else { throw DatabaseError(code: SQLITE_MISUSE, message: "database is closed") }

        var statement: OpaquePointer?
        var rc = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard rc == SQLITE_OK, let statement else {
            throw DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        for (offset, value) in params.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .null:
                rc = sqlite3_bind_null(statement, index)
            case .int(let v):
                rc = sqlite3_bind_int64(statement, index, v)
            case .double(let v):
                rc = sqlite3_bind_double(statement, index, v)
            case .text(let v):
                rc = sqlite3_bind_text(statement, index, v, -1, Database.transient)
            case .blob(let v):
                rc = v.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(statement, index, buffer.baseAddress, Int32(buffer.count), Database.transient)
                }
            }
            guard rc == SQLITE_OK else {
                throw DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
            }
        }

        var rows: [DBRow] = []
        while true {
            rc = sqlite3_step(statement)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else {
                throw DatabaseError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
            }
            guard collect else { continue }
            var values: [String: DBValue] = [:]
            let count = sqlite3_column_count(statement)
            for column in 0..<count {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER:
                    values[name] = .int(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT:
                    values[name] = .double(sqlite3_column_double(statement, column))
                case SQLITE_TEXT:
                    if let text = sqlite3_column_text(statement, column) {
                        values[name] = .text(String(cString: text))
                    } else {
                        values[name] = .null
                    }
                case SQLITE_BLOB:
                    let length = Int(sqlite3_column_bytes(statement, column))
                    if let bytes = sqlite3_column_blob(statement, column), length > 0 {
                        values[name] = .blob(Data(bytes: bytes, count: length))
                    } else {
                        values[name] = .blob(Data())
                    }
                default:
                    values[name] = .null
                }
            }
            rows.append(DBRow(values: values))
        }
        return rows
    }
}
