import CryptoKit
import Foundation

/// Signs Apple Music developer tokens: ES256 JWTs made with a MusicKit key.
public struct DeveloperTokenSigner: Sendable {
    let keyID: String
    let teamID: String
    let privateKey: P256.Signing.PrivateKey

    public init(keyID: String, teamID: String, pem: String) throws {
        self.keyID = keyID
        self.teamID = teamID
        self.privateKey = try P256.Signing.PrivateKey(pemRepresentation: pem)
    }

    public func token(issuedAt: Date, lifetime: TimeInterval) throws -> String {
        let header = ["alg": "ES256", "kid": keyID]
        let issued = Int(issuedAt.timeIntervalSince1970)
        let claims: [String: Any] = ["iss": teamID, "iat": issued, "exp": issued + Int(lifetime)]
        let signingInput = try base64URL(JSONSerialization.data(withJSONObject: header, options: .sortedKeys))
            + "." + base64URL(JSONSerialization.data(withJSONObject: claims, options: .sortedKeys))
        let signature = try privateKey.signature(for: Data(signingInput.utf8))
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

/// Apple Music refused the credentials. For library calls this usually means
/// the Music User Token expired and the user must sign in again.
public struct AppleMusicAuthError: Error, CustomStringConvertible {
    public let status: Int
    public var description: String { "Apple Music rejected the credentials (HTTP \(status))" }
}

/// The parts of the Apple Music API that Radio uses.
public struct AppleMusicClient: Sendable {
    let http: HTTPClient
    let developerToken: String
    let userToken: String?
    let storefront: String

    static let base = "https://api.music.apple.com/v1"
    /// Apple's documented maximum page size for song search.
    static let searchLimit = 25
    /// Tracks per add request, to keep request bodies modest.
    static let batchSize = 100

    public init(http: HTTPClient, developerToken: String, userToken: String?, storefront: String) {
        self.http = http
        self.developerToken = developerToken
        self.userToken = userToken
        self.storefront = storefront
    }

    public func searchSongs(_ term: String) async throws -> [CatalogSong] {
        var components = URLComponents(string: "\(Self.base)/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: String(Self.searchLimit)),
        ]
        let response: SearchResponse = try await request("GET", components.url!)
        return response.results.songs?.data.map(\.catalogSong) ?? []
    }

    public func song(id: String) async throws -> CatalogSong? {
        let url = URL(string: "\(Self.base)/catalog/\(storefront)/songs/\(id)")!
        let response: Resources = try await request("GET", url)
        return response.data.first?.catalogSong
    }

    public func userStorefront() async throws -> String {
        let response: Resources = try await request("GET", URL(string: "\(Self.base)/me/storefront")!)
        guard let id = response.data.first?.id else {
            throw SourceError(description: "Apple Music returned no storefront")
        }
        return id
    }

    /// Creates a library playlist holding the given catalog songs and returns
    /// its library ID.
    public func createPlaylist(name: String, description: String, songIDs: [String]) async throws -> String {
        let body: [String: Any] = [
            "attributes": ["name": name, "description": description],
            "relationships": ["tracks": ["data": songIDs.map { ["id": $0, "type": "songs"] }]],
        ]
        let response: Resources = try await request(
            "POST", URL(string: "\(Self.base)/me/library/playlists")!,
            body: try JSONSerialization.data(withJSONObject: body)
        )
        guard let id = response.data.first?.id else {
            throw SourceError(description: "Apple Music created a playlist but returned no ID")
        }
        return id
    }

    public func addSongs(_ songIDs: [String], toPlaylist playlistID: String) async throws {
        let body = ["data": songIDs.map { ["id": $0, "type": "songs"] }]
        let url = URL(string: "\(Self.base)/me/library/playlists/\(playlistID)/tracks")!
        _ = try await send("POST", url, body: try JSONSerialization.data(withJSONObject: body))
    }

    private func request<T: Decodable>(_ method: String, _ url: URL, body: Data? = nil) async throws -> T {
        try JSONDecoder().decode(T.self, from: try await send(method, url, body: body))
    }

    private func send(_ method: String, _ url: URL, body: Data? = nil) async throws -> Data {
        var headers = ["Authorization": "Bearer \(developerToken)"]
        if let userToken { headers["Music-User-Token"] = userToken }
        if body != nil { headers["Content-Type"] = "application/json" }
        let response = try await http.send(HTTPRequest(method: method, url: url, headers: headers, body: body))
        if response.status == 401 || response.status == 403 {
            throw AppleMusicAuthError(status: response.status)
        }
        return try response.requireSuccess(for: url)
    }

    private struct SearchResponse: Decodable {
        struct Results: Decodable { let songs: Resources? }
        let results: Results
    }

    private struct Resources: Decodable {
        let data: [Resource]
    }

    private struct Resource: Decodable {
        struct Attributes: Decodable {
            let name: String?
            let artistName: String?
            let albumName: String?
            let url: String?
            let contentRating: String?
        }
        let id: String
        let attributes: Attributes?

        var catalogSong: CatalogSong {
            CatalogSong(
                id: id,
                name: attributes?.name ?? "",
                artistName: attributes?.artistName ?? "",
                albumName: attributes?.albumName ?? "",
                url: attributes?.url ?? "",
                isExplicit: attributes?.contentRating == "explicit"
            )
        }
    }
}

/// Extracts a catalog song ID from an Apple Music song or album-track link.
public func catalogSongID(fromLink link: String) -> String? {
    let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.allSatisfy(\.isNumber), !trimmed.isEmpty { return trimmed }
    guard let components = URLComponents(string: trimmed), components.host?.hasSuffix("music.apple.com") == true else {
        return nil
    }
    if let track = components.queryItems?.first(where: { $0.name == "i" })?.value, track.allSatisfy(\.isNumber) {
        return track
    }
    let parts = components.path.split(separator: "/")
    if let index = parts.firstIndex(of: "song"), let last = parts.last, index < parts.count - 1, last.allSatisfy(\.isNumber) {
        return String(last)
    }
    return nil
}
