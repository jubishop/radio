import Foundation
import RadioCore
import Testing

/// Nothing bounded the LaunchAgent logs in ~/Library/Logs/Radio until
/// 2026-10-29, so each `radio run` now keeps them under a limit, with one
/// previous copy.
@Suite struct LogTests {
    func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("logs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func contents(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// The `serve` agent holds its log open for appending as long as it runs,
    /// the way launchd opened it, so the log is emptied in place, not
    /// renamed, and the next line lands at its start.
    @Test func rotatesALogAWriterHoldsOpenForAppending() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("com.jubishop.radio.serve.log")
        let descriptor = open(log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        try #require(descriptor >= 0)
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let old = String(repeating: "an old line\n", count: 10)
        try writer.write(contentsOf: Data(old.utf8))

        #expect(try rotateLogs(in: directory, limit: 100) == ["com.jubishop.radio.serve.log"])
        try writer.write(contentsOf: Data("a new line\n".utf8))

        #expect(try contents(log) == "a new line\n")
        #expect(try contents(directory.appendingPathComponent("com.jubishop.radio.serve.log.0")) == old)
    }

    @Test func leavesALogUnderTheLimitAlone() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("com.jubishop.radio.run.log")
        try Data("a line\n".utf8).write(to: log)

        #expect(try rotateLogs(in: directory, limit: 100).isEmpty)

        #expect(try contents(log) == "a line\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["com.jubishop.radio.run.log"])
    }

    /// A second rotation replaces the previous copy, which isn't itself
    /// rotated, and files that aren't logs stay as they are.
    @Test func keepsOnePreviousCopy() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("com.jubishop.radio.run.log")
        let other = directory.appendingPathComponent("notes.txt")
        let first = String(repeating: "first\n", count: 20)
        let second = String(repeating: "second\n", count: 20)
        try Data(first.utf8).write(to: log)
        try Data(first.utf8).write(to: other)

        #expect(try rotateLogs(in: directory, limit: 100) == ["com.jubishop.radio.run.log"])
        try Data(second.utf8).write(to: log)
        #expect(try rotateLogs(in: directory, limit: 100) == ["com.jubishop.radio.run.log"])

        #expect(try contents(log) == "")
        #expect(try contents(directory.appendingPathComponent("com.jubishop.radio.run.log.0")) == second)
        #expect(try contents(other) == first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            == ["com.jubishop.radio.run.log", "com.jubishop.radio.run.log.0", "notes.txt"])
    }
}
