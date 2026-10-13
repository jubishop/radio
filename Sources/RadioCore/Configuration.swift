import Foundation

/// Where Radio keeps its database and credentials.
public struct RadioHome: Sendable {
    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// `RADIO_HOME`, or ~/Library/Application Support/Radio.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> RadioHome {
        if let path = environment["RADIO_HOME"], !path.isEmpty {
            return RadioHome(directory: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return RadioHome(directory: support.appendingPathComponent("Radio"))
    }

    var databaseURL: URL { directory.appendingPathComponent("radio.sqlite") }
    var credentialsURL: URL { directory.appendingPathComponent("credentials.json") }
    var syncLockURL: URL { directory.appendingPathComponent("sync.lock") }

    func keyURL(keyID: String) -> URL { directory.appendingPathComponent("AuthKey_\(keyID).p8") }

    func create() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

/// Apple Music credentials, stored in owner-only files.
public struct Credentials: Codable, Equatable, Sendable {
    public var keyID: String
    public var teamID: String
    public var musicUserToken: String?
    public var storefront: String?
    public var userTokenSavedAt: Date?
}

public struct CredentialsError: Error, CustomStringConvertible {
    public let description: String
}

struct CredentialStore {
    let home: RadioHome

    func load() throws -> Credentials? {
        let url = home.credentialsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try requireOwnerOnly(url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Credentials.self, from: Data(contentsOf: url))
    }

    func save(_ credentials: Credentials) throws {
        try home.create()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try writeOwnerOnly(try encoder.encode(credentials), to: home.credentialsURL)
    }

    func loadKey(keyID: String) throws -> String {
        let url = home.keyURL(keyID: keyID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw CredentialsError(description: "Missing MusicKit key \(url.path). Run `radio credentials set`.")
        }
        try requireOwnerOnly(url)
        return try String(contentsOf: url, encoding: .utf8)
    }

    func saveKey(_ pem: String, keyID: String) throws {
        try home.create()
        try writeOwnerOnly(Data(pem.utf8), to: home.keyURL(keyID: keyID))
    }

    private func writeOwnerOnly(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func requireOwnerOnly(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
        guard permissions & 0o077 == 0 else {
            throw CredentialsError(description: "\(url.path) is readable by other users. Run `chmod 600 '\(url.path)'`.")
        }
    }
}

/// Reads `KEY=value` lines from an env file such as ~/.env, without
/// executing it.
public func readEnvFile(at url: URL) -> [String: String] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
    var values: [String: String] = [:]
    for rawLine in text.split(whereSeparator: \.isNewline) {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("#") { continue }
        if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
        guard let separator = line.firstIndex(of: "=") else { continue }
        let key = line[..<separator].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast())
        }
        values[key] = value
    }
    return values
}

/// An exclusive advisory lock on a file, held until released or the process
/// exits. Each instance opens its own descriptor, so it also excludes other
/// holders in the same process.
final class ProcessLock {
    private var descriptor: Int32

    /// Returns nil, without waiting, when another holder has the lock.
    init?(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw RadioError("Can't open lock file \(url.path): \(String(cString: strerror(errno)))")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit {
        release()
    }
}
