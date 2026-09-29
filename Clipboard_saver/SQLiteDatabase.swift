import Foundation
import SQLite3

/// A thin, safe wrapper over the SQLite C API.
///
/// This exists because the C API fails silently by default. A missing
/// `sqlite3_finalize` leaks a statement, a string bound without `SQLITE_TRANSIENT`
/// can be read after its Swift storage is gone, and a step that returns an error
/// looks exactly like a step that found no row. All three of those are silent
/// corruption rather than a crash, so they are closed here rather than left to
/// every call site.
///
/// Scope is deliberately small: open, execute, prepare, bind, step. There is no
/// query builder and no ORM, because the archive's schema is fixed and the
/// statements that use it are few.
final class SQLiteDatabase {

    enum Failure: Error, CustomStringConvertible {
        case cannotOpen(String, String)
        case cannotPrepare(String, String)
        case cannotStep(String, String)
        case cannotBind(String)
        case misconfigured(String)

        var description: String {
            switch self {
            case .cannotOpen(let path, let why):
                return "Could not open the archive database at \(path): \(why)"
            case .cannotPrepare(let sql, let why):
                return "Could not prepare: \(sql.prefix(80)) — \(why)"
            case .cannotStep(let sql, let why):
                return "Could not run: \(sql.prefix(80)) — \(why)"
            case .cannotBind(let sql):
                return "Could not bind a value to: \(sql.prefix(80))"
            case .misconfigured(let why):
                return why
            }
        }
    }

    private var handle: OpaquePointer?

    /// Opens the database, creating it if needed.
    ///
    /// - Parameter inMemory: used by the tests, and by `--index-check`, so a
    ///   broken rebuild never touches the user's real archive.
    init(path: String, inMemory: Bool = false) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let status = sqlite3_open_v2(path, &handle, flags, nil)
        guard status == SQLITE_OK, let handle else {
            let why = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "status \(status)"
            sqlite3_close_v2(handle)
            throw Failure.cannotOpen(path, why)
        }
        self.handle = handle
        if inMemory { try execute("PRAGMA journal_mode = MEMORY") }
        // Wait rather than fail if another process holds a write lock. The
        // archive can be open in the Services app and a rebuild at once.
        sqlite3_busy_timeout(handle, 5_000)
    }

    deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &error) == SQLITE_OK else {
            let why = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw Failure.cannotStep(sql, why)
        }
        sqlite3_free(error)
    }

    /// Runs a statement that returns no rows.
    func run(_ sql: String, _ parameters: [SQLValue] = []) throws {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll(parameters)
        try statement.run()
    }

    /// Runs a query and hands each row to `body`.
    ///
    /// Rows are streamed rather than collected: an index rebuild reads every
    /// message of every document, and materialising that would be a memory
    /// spike on a large archive.
    func query<T>(_ sql: String, _ parameters: [SQLValue] = [], _ body: (Row) throws -> T) throws -> [T] {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll(parameters)
        var results: [T] = []
        while try statement.step() {
            results.append(try body(Row(statement: statement)))
        }
        return results
    }

    /// The single value of a one-column, one-row query.
    func scalarInt(_ sql: String, _ parameters: [SQLValue] = []) throws -> Int64 {
        let statement = try prepare(sql)
        defer { statement.finalize() }
        try statement.bindAll(parameters)
        guard try statement.step() else { return 0 }
        return statement.int(at: 0)
    }

    private func prepare(_ sql: String) throws -> Statement {
        var raw: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &raw, nil) == SQLITE_OK, let raw else {
            throw Failure.cannotPrepare(sql, lastError)
        }
        return Statement(raw: raw, sql: sql, database: self)
    }

    var lastError: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    var changes: Int { Int(sqlite3_changes(handle)) }
}

/// A value that can be bound to a statement.
enum SQLValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case null

    static func text(_ value: String?) -> SQLValue { value.map { .text($0) } ?? .null }
    static func integer(_ value: Int?) -> SQLValue { value.map { .integer(Int64($0)) } ?? .null }
}

final class Statement {
    private let raw: OpaquePointer
    private let sql: String
    private unowned let database: SQLiteDatabase

    init(raw: OpaquePointer, sql: String, database: SQLiteDatabase) {
        self.raw = raw
        self.sql = sql
        self.database = database
    }

    func finalize() { sqlite3_finalize(raw) }

    func bindAll(_ values: [SQLValue]) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32
            switch value {
            case .integer(let v): status = sqlite3_bind_int64(raw, index, v)
            case .real(let v): status = sqlite3_bind_double(raw, index, v)
            case .null: status = sqlite3_bind_null(raw, index)
            case .text(let v):
                // SQLITE_TRANSIENT tells SQLite to copy the bytes immediately.
                // Without it SQLite keeps the pointer, and the Swift string this
                // pointer refers to can be deallocated before the step.
                status = v.withCString { pointer in
                    sqlite3_bind_text(raw, index, pointer, -1, sqliteTransient)
                }
            }
            guard status == SQLITE_OK else { throw SQLiteDatabase.Failure.cannotBind(sql) }
        }
    }

    @discardableResult
    func step() throws -> Bool {
        let status = sqlite3_step(raw)
        switch status {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw SQLiteDatabase.Failure.cannotStep(sql, database.lastError)
        }
    }

    func run() throws { while try step() {} }

    func string(at column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(raw, column) else { return nil }
        return String(cString: pointer)
    }

    func int(at column: Int32) -> Int64 { sqlite3_column_int64(raw, column) }

    func double(at column: Int32) -> Double { sqlite3_column_double(raw, column) }

    var columnCount: Int32 { sqlite3_column_count(raw) }
}

/// One row of a result set.
struct Row {
    let statement: Statement

    func string(_ column: Int32) -> String? { statement.string(at: column) }
    func string(_ column: Int32, default fallback: String) -> String {
        statement.string(at: column) ?? fallback
    }
    func int(_ column: Int32) -> Int64 { statement.int(at: column) }
    func double(_ column: Int32) -> Double { statement.double(at: column) }
}

/// `SQLITE_TRANSIENT` is a C macro, not an exported symbol, so Swift cannot see
/// it. Its value is the documented sentinel, so it is reconstructed here.
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
