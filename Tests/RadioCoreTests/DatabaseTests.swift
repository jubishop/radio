import Foundation
import RadioCore
import SQLite3
import Testing

@Suite struct DatabaseTests {
    /// launchd starts `radio run` and `radio serve` together, so one process can
    /// open the database while the other is still creating it.
    @Test func openingWaitsForAnotherProcessCreatingTheDatabase() async throws {
        let home = RadioHome(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-tests-\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true)
        var other: OpaquePointer?
        #expect(sqlite3_open(home.directory.appendingPathComponent("radio.sqlite").path, &other) == SQLITE_OK)
        #expect(sqlite3_exec(other, "BEGIN IMMEDIATE; CREATE TABLE creating (id INTEGER);", nil, nil, nil) == SQLITE_OK)
        let release = Task.detached {
            try await Task.sleep(for: .milliseconds(300))
            sqlite3_exec(other, "COMMIT", nil, nil, nil)
            sqlite3_close(other)
        }

        let radio = try Radio(home: home, http: FakeHTTP(), sources: [], notifier: PushoverNotifier(http: FakeHTTP(), userKey: nil, apiKey: nil))

        try await release.value
        #expect(try await radio.stations().isEmpty)
    }

    /// After a deploy, both processes can find an old schema; the one that
    /// waits for the other's upgrade must not upgrade again.
    @Test func openingWaitsForAnotherProcessUpgradingTheDatabase() async throws {
        let home = RadioHome(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-tests-\(UUID().uuidString)"))
        func open() throws -> Radio {
            try Radio(home: home, http: FakeHTTP(), sources: [], notifier: PushoverNotifier(http: FakeHTTP(), userKey: nil, apiKey: nil))
        }
        var version: Int32 = 0
        do {
            _ = try open()
        }
        var other: OpaquePointer?
        #expect(sqlite3_open(home.directory.appendingPathComponent("radio.sqlite").path, &other) == SQLITE_OK)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(other, "PRAGMA user_version", -1, &statement, nil)
        if sqlite3_step(statement) == SQLITE_ROW { version = sqlite3_column_int(statement, 0) }
        sqlite3_finalize(statement)
        // The other process has upgraded the tables but not yet committed.
        #expect(sqlite3_exec(other, "PRAGMA user_version = \(version - 1)", nil, nil, nil) == SQLITE_OK)
        #expect(sqlite3_exec(other, "BEGIN IMMEDIATE; PRAGMA user_version = \(version);", nil, nil, nil) == SQLITE_OK)
        let release = Task.detached {
            try await Task.sleep(for: .milliseconds(300))
            sqlite3_exec(other, "COMMIT", nil, nil, nil)
            sqlite3_close(other)
        }

        let radio = try open()

        try await release.value
        #expect(try await radio.stations().isEmpty)
    }
}
