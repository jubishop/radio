import CryptoKit
import Foundation
import RadioCore
import Synchronization

/// An HTTP client that answers from registered routes and records requests.
final class FakeHTTP: HTTPClient {
    typealias Responder = @Sendable (HTTPRequest) -> HTTPResponse
    private let state = Mutex<(routes: [(prefix: String, respond: Responder)], requests: [HTTPRequest])>(([], []))
    /// Simulated network delay, so concurrent work interleaves as it would live.
    let latency: Duration

    init(latency: Duration = .zero) {
        self.latency = latency
    }

    /// Answers requests whose "METHOD url" starts with `prefix`. Later routes win.
    func on(_ prefix: String, _ respond: @escaping Responder) {
        state.withLock { $0.routes.append((prefix, respond)) }
    }

    func requests(_ prefix: String) -> [HTTPRequest] {
        state.withLock { $0.requests }.filter { "\($0.method) \($0.url.absoluteString)".hasPrefix(prefix) }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if latency > .zero { try await Task.sleep(for: latency) }
        let line = "\(request.method) \(request.url.absoluteString)"
        let responder = state.withLock { state -> Responder? in
            state.requests.append(request)
            return state.routes.last(where: { line.hasPrefix($0.prefix) })?.respond
        }
        return responder?(request) ?? HTTPResponse(status: 404, body: Data("no route for \(line)".utf8))
    }
}

func json(_ object: Any, status: Int = 200) -> HTTPResponse {
    HTTPResponse(status: status, body: try! JSONSerialization.data(withJSONObject: object))
}

/// A settable clock.
final class TestClock: Sendable {
    private let value = Mutex(Date(timeIntervalSince1970: 1_791_900_000))
    var now: Date { value.withLock { $0 } }
    func advance(hours: Double) { value.withLock { $0 += hours * 3600 } }
    func advance(days: Double) { advance(hours: days * 24) }
}

/// Audacy's station pages and now-playing feed.
final class FakeAudacy: Sendable {
    private let plays = Mutex<[String: [(id: Int, time: Date, artist: String, title: String)]]>([:])
    private let failing = Mutex<Set<String>>([])
    private let nextID = Mutex(1000)

    init(http: FakeHTTP) {
        http.on("GET https://www.audacy.com/") { request in
            let slug = request.url.lastPathComponent
            guard slug == "alt1021rva" || slug == "rock" else { return HTTPResponse(status: 404, body: Data()) }
            let (id, title) = slug == "alt1021rva"
                ? ("101-1041", "Richmond’s Alternative Rock Radio - WRXL-FM | Alt 102.1")
                : ("101-2000", "Rock Station | Rock 99")
            let html = "<html><head><title>\(title)</title></head><body><script>window.STATION_ROC_ID = '\(id)';</script></body></html>"
            return HTTPResponse(status: 200, body: Data(html.utf8))
        }
        http.on("GET https://api.audacy.com/experience/v2/stations/") { [self] request in
            let feedID = request.url.pathComponents[request.url.pathComponents.count - 2]
            if failing.withLock({ $0.contains(feedID) }) { return HTTPResponse(status: 503, body: Data()) }
            let count = Int(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "count" }?.value ?? "") ?? 0
            guard count <= 50 else { return json(["performances": []]) }
            let recent = plays.withLock { $0[feedID] ?? [] }.suffix(count).reversed()
            return json(["performances": recent.map {
                ["id": $0.id, "time": $0.time.formatted(.iso8601), "artist": $0.artist, "title": $0.title,
                 "album": "", "label": "", "isrc": ""]
            }])
        }
    }

    func play(_ artist: String, _ title: String, on feedID: String = "101-1041", at time: Date) {
        let id = nextID.withLock { value in defer { value += 1 }; return value }
        plays.withLock { $0[feedID, default: []].append((id, time, artist, title)) }
    }

    func setFailing(_ feedID: String, _ isFailing: Bool) {
        failing.withLock { if isFailing { $0.insert(feedID) } else { $0.remove(feedID) } }
    }
}

/// The parts of the Apple Music API Radio uses, with library state.
final class FakeAppleMusic: Sendable {
    struct Playlist { var name: String; var songIDs: [String] }
    private let catalog = Mutex<[CatalogSong]>([])
    private let library = Mutex<(playlists: [String: Playlist], order: [String])>(([:], []))
    private let userStatus = Mutex(200)

    init(http: FakeHTTP) {
        http.on("GET https://api.music.apple.com/v1/catalog/us/search") { [self] request in
            let term = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "term" }?.value?.lowercased() ?? ""
            let words = term.split(separator: " ")
            let results = catalog.withLock { $0 }.filter { song in
                let text = "\(song.artistName) \(song.name)".lowercased()
                return words.allSatisfy { text.contains($0) }
            }
            return json(["results": ["songs": ["data": results.map(Self.resource)]]])
        }
        http.on("GET https://api.music.apple.com/v1/catalog/us/songs/") { [self] request in
            let id = request.url.lastPathComponent
            guard let song = catalog.withLock({ $0.first { $0.id == id } }) else { return json(["data": []], status: 404) }
            return json(["data": [Self.resource(song)]])
        }
        http.on("GET https://api.music.apple.com/v1/me/storefront") { [self] _ in
            let status = userStatus.withLock { $0 }
            return status == 200 ? json(["data": [["id": "us", "type": "storefronts"]]]) : json([:], status: status)
        }
        http.on("POST https://api.music.apple.com/v1/me/library/playlists") { [self] request in
            let status = userStatus.withLock { $0 }
            guard status == 200 else { return json([:], status: status) }
            let body = try! JSONSerialization.jsonObject(with: request.body!) as! [String: Any]
            if request.url.lastPathComponent == "tracks" {
                let id = request.url.deletingLastPathComponent().lastPathComponent
                let ids = (body["data"] as! [[String: String]]).map { $0["id"]! }
                let found = library.withLock { library -> Bool in
                    guard library.playlists[id] != nil else { return false }
                    library.playlists[id]!.songIDs += ids
                    return true
                }
                return found ? HTTPResponse(status: 204, body: Data()) : json([:], status: 404)
            }
            let name = (body["attributes"] as! [String: String])["name"]!
            let tracks = ((body["relationships"] as? [String: Any])?["tracks"] as? [String: Any])?["data"] as? [[String: String]] ?? []
            let id = library.withLock { library -> String in
                let id = "p.\(library.order.count + 1)"
                library.playlists[id] = Playlist(name: name, songIDs: tracks.map { $0["id"]! })
                library.order.append(id)
                return id
            }
            return json(["data": [["id": id, "type": "library-playlists"]]], status: 201)
        }
    }

    @discardableResult
    func addToCatalog(_ artist: String, _ title: String, album: String = "Album", explicit: Bool = false) -> CatalogSong {
        catalog.withLock { catalog in
            let song = CatalogSong(
                id: String(1_000_000 + catalog.count), name: title, artistName: artist, albumName: album,
                url: "https://music.apple.com/us/album/x/1?i=\(1_000_000 + catalog.count)", isExplicit: explicit
            )
            catalog.append(song)
            return song
        }
    }

    /// The library playlists Radio created, by name, with song titles in order.
    func playlists() -> [String: [String]] {
        let titles = Dictionary(uniqueKeysWithValues: catalog.withLock { $0 }.map { ($0.id, $0.name) })
        return library.withLock { library in
            Dictionary(library.playlists.values.map { ($0.name, $0.songIDs.map { titles[$0] ?? $0 }) }, uniquingKeysWith: { first, _ in first })
        }
    }

    /// Playlists by name, counting duplicates that `playlists()` would merge.
    func playlistNames() -> [String] {
        library.withLock { library in library.order.compactMap { library.playlists[$0]?.name } }
    }

    func deleteAllPlaylists() {
        library.withLock { $0.playlists = [:] }
    }

    func setUserTokenStatus(_ status: Int) {
        userStatus.withLock { $0 = status }
    }

    private static func resource(_ song: CatalogSong) -> [String: Any] {
        ["id": song.id, "type": "songs", "attributes": [
            "name": song.name, "artistName": song.artistName, "albumName": song.albumName,
            "url": song.url, "contentRating": song.isExplicit ? "explicit" : "clean",
        ]]
    }
}

/// Everything a Radio needs, wired to fakes and a temporary directory.
struct Harness {
    let http: FakeHTTP
    let clock = TestClock()
    let audacy: FakeAudacy
    let music: FakeAppleMusic
    let home: RadioHome
    let radio: Radio

    init(pushover: Bool = true, http: FakeHTTP = FakeHTTP()) throws {
        self.http = http
        audacy = FakeAudacy(http: http)
        music = FakeAppleMusic(http: http)
        http.on("POST https://api.pushover.net/") { _ in json(["status": 1]) }
        home = RadioHome(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-tests-\(UUID().uuidString)"))
        let clock = clock
        radio = try Radio(
            home: home,
            http: http,
            sources: [AudacySource(http: http)],
            notifier: PushoverNotifier(http: http, userKey: pushover ? "user" : nil, apiKey: pushover ? "app" : nil),
            now: { clock.now }
        )
    }

    /// Configures a MusicKit key and signs in.
    func signIn() async throws {
        try await radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        try await radio.saveUserToken("user-token")
    }

    func play(_ artist: String, _ title: String, on feedID: String = "101-1041", minutesAgo: Double = 0) {
        audacy.play(artist, title, on: feedID, at: clock.now.addingTimeInterval(-minutesAgo * 60))
    }

    var pushes: [String] {
        http.requests("POST https://api.pushover.net/").map { request in
            let fields = URLComponents(string: "?" + String(decoding: request.body ?? Data(), as: UTF8.self))?.queryItems ?? []
            return fields.first { $0.name == "title" }?.value ?? ""
        }
    }
}
