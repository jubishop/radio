import Foundation
import SQLite3

/// A value bound to or read from an SQLite statement.
public enum SQLValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)

    var string: String? {
        switch self {
        case .text(let value): value
        case .integer(let value): String(value)
        case .real(let value): String(value)
        case .null: nil
        }
    }

    var int: Int64? {
        switch self {
        case .integer(let value): value
        case .real(let value): Int64(value)
        case .text(let value): Int64(value)
        case .null: nil
        }
    }

    var double: Double? {
        switch self {
        case .integer(let value): Double(value)
        case .real(let value): value
        case .text(let value): Double(value)
        case .null: nil
        }
    }
}

extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .integer(value) }
}

/// One result row, addressed by column name.
struct Row {
    let values: [String: SQLValue]

    subscript(_ column: String) -> SQLValue { values[column] ?? .null }
    func string(_ column: String) -> String? { self[column].string }
    func int(_ column: String) -> Int64? { self[column].int }
    func double(_ column: String) -> Double? { self[column].double }
}

struct DatabaseError: Error, CustomStringConvertible {
    let description: String
}

/// A small wrapper over the system SQLite library. Not shared across threads;
/// the owning actor serializes access.
final class Database {
    private var handle: OpaquePointer?

    init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw DatabaseError(description: "Can't open database at \(path): \(message)")
        }
        sqlite3_busy_timeout(handle, Int32(Self.busyTimeout * 1000))
        try enableWAL()
        try execute("PRAGMA foreign_keys = ON")
    }

    static let busyTimeout: TimeInterval = 10

    /// SQLite returns SQLITE_BUSY at once, without waiting, when another
    /// connection is writing during a journal-mode change, so retry here.
    private func enableWAL() throws {
        let deadline = Date().addingTimeInterval(Self.busyTimeout)
        while true {
            if sqlite3_exec(handle, "PRAGMA journal_mode = WAL", nil, nil, nil) == SQLITE_OK { return }
            guard sqlite3_errcode(handle) == SQLITE_BUSY, Date() < deadline else {
                throw error("enable WAL", "PRAGMA journal_mode = WAL")
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    func execute(_ sql: String, _ parameters: [SQLValue] = []) throws {
        _ = try query(sql, parameters)
    }

    @discardableResult
    func query(_ sql: String, _ parameters: [SQLValue] = []) throws -> [Row] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw error("prepare", sql)
        }
        defer { sqlite3_finalize(statement) }
        for (index, parameter) in parameters.enumerated() {
            let position = Int32(index + 1)
            let result: Int32
            switch parameter {
            case .null: result = sqlite3_bind_null(statement, position)
            case .integer(let value): result = sqlite3_bind_int64(statement, position, value)
            case .real(let value): result = sqlite3_bind_double(statement, position, value)
            case .text(let value):
                result = sqlite3_bind_text(statement, position, value, -1, transient)
            }
            guard result == SQLITE_OK else { throw error("bind", sql) }
        }
        var rows: [Row] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error("step", sql) }
            var values: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                switch sqlite3_column_type(statement, column) {
                case SQLITE_INTEGER: values[name] = .integer(sqlite3_column_int64(statement, column))
                case SQLITE_FLOAT: values[name] = .real(sqlite3_column_double(statement, column))
                case SQLITE_NULL: values[name] = .null
                default: values[name] = .text(String(cString: sqlite3_column_text(statement, column)))
                }
            }
            rows.append(Row(values: values))
        }
        return rows
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
    var lastInsertID: Int64 { sqlite3_last_insert_rowid(handle) }

    func transaction<T>(_ body: () throws -> T) throws -> T {
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

    private func error(_ stage: String, _ sql: String) -> DatabaseError {
        DatabaseError(description: "SQLite \(stage) failed: \(String(cString: sqlite3_errmsg(handle))) in \(sql)")
    }
}

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
