import Foundation
import SQLite3

// Connections are short-lived and confined to the calling thread, never shared across tasks.
final class IndexDatabase {
    private var handle: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]

    init(url: URL, writable: Bool = false) throws {
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "ouverture impossible"
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw DocumentError.indexStorage(message)
        }
        sqlite3_busy_timeout(handle, 3000)
        do { try execute("PRAGMA foreign_keys=ON; PRAGMA cache_size=-8192; PRAGMA temp_store=FILE;") }
        catch {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw error
        }
    }

    deinit {
        for statement in statements.values { sqlite3_finalize(statement) }
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    @discardableResult
    func rows(_ sql: String, _ parameters: [String] = []) throws -> [[String]] {
        let statement: OpaquePointer
        if let cached = statements[sql] { statement = cached }
        else {
            var prepared: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw failure() }
            statement = prepared
            statements[sql] = prepared
        }
        defer {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
        }
        for (index, value) in parameters.enumerated() {
            let result = value.withCString {
                sqlite3_bind_text(statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            guard result == SQLITE_OK else { throw failure() }
        }
        var result: [[String]] = []
        while true {
            try Task.checkCancellation()
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw failure() }
            result.append((0..<sqlite3_column_count(statement)).map { column in
                sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
            })
        }
    }

    func count(_ sql: String, _ parameters: [String] = []) throws -> Int {
        guard let first = try rows(sql, parameters).first?.first, let value = Int(first) else { throw failure() }
        return value
    }

    private func failure() -> DocumentError {
        .indexStorage(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "connexion fermée")
    }
}
