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

/// iHeartRadio's station sites, station API, and track history.
final class FakeIHeart: Sendable {
    private let plays = Mutex<[String: [(time: Date, artist: String, title: String)]]>([:])

    init(http: FakeHTTP) {
        http.on("GET https://hits1061seattle.iheart.com/") { _ in
            let html = #"<html><body><script>window.__PRELOADED_STATE__ = {"tags":["stream:4257"],"#
                + #""stream":{"id":4257,"primaryPronouncement":"hits one oh six point one"}};</script></body></html>"#
            return HTTPResponse(status: 200, body: Data(html.utf8))
        }
        http.on("GET https://us.api.iheart.com/api/v2/content/liveStations/") { request in
            guard request.url.lastPathComponent == "4257" else {
                return json(["error": ["description": "Not found", "code": 5, "httpCode": 404]], status: 404)
            }
            return json(["hits": [["id": 4257, "name": "Hits 106.1", "callLetters": "KBKS-FM", "freq": "106.1"]]])
        }
        http.on("GET https://us.api.iheart.com/api/v3/live-meta/stream/") { [self] request in
            let streamID = request.url.pathComponents[request.url.pathComponents.count - 2]
            let limit = Int(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "limit" }?.value ?? "") ?? 0
            let recent = plays.withLock { $0[streamID] ?? [] }.suffix(min(limit, 200)).reversed()
            return json(["data": recent.map {
                ["artist": $0.artist, "title": $0.title, "startTime": Int($0.time.timeIntervalSince1970),
                 "endTime": Int($0.time.timeIntervalSince1970) + 180, "dataSource": "Pnp"]
            }, "meta": ["offset": 0, "pageSize": limit, "totalSize": recent.count]])
        }
    }

    func play(_ artist: String, _ title: String, on streamID: String = "4257", at time: Date) {
        plays.withLock { $0[streamID, default: []].append((time, artist, title)) }
    }
}

/// The parts of the Apple Music API Radio uses, with two copies of the
/// library: Apple's, which the API changes, and Music.app's on the Mac. A
/// sync uploads each playlist Music.app changed, replacing Apple's copy, and
/// downloads everything else, so a Music.app edit would wipe out songs added
/// on Apple's side that Music.app hadn't downloaded yet. Every change syncs
/// at once unless syncing is delayed.
final class FakeAppleMusic: Sendable {
    struct Playlist { var name: String; var songIDs: [String] }
    struct Library {
        var playlists: [String: Playlist] = [:]
        var order: [String] = []
        /// Catalog songs in the library.
        var songIDs: Set<String> = []
    }
    struct State {
        var apple = Library()
        var mac = Library()
        /// Playlists Music.app changed since the last sync.
        var edited: Set<String> = []
        var syncDelayed = false
        /// Catalog songs that don't reach Music.app.
        var withheld: Set<String> = []
        var playlistsCreated = 0
        /// Music.app's comments, by catalog song.
        var comments: [String: String] = [:]
    }
    private let catalog = Mutex<[CatalogSong]>([])
    private let state = Mutex(State())
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
        http.on("GET https://api.music.apple.com/v1/catalog/us/songs?") { [self] request in
            let ids = Set((URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "ids" }?.value ?? "").split(separator: ",").map(String.init))
            return json(["data": catalog.withLock { $0 }.filter { ids.contains($0.id) }.map(Self.resource)])
        }
        http.on("GET https://api.music.apple.com/v1/me/storefront") { [self] _ in
            let status = userStatus.withLock { $0 }
            return status == 200 ? json(["data": [["id": "us", "type": "storefronts"]]]) : json([:], status: status)
        }
        http.on("POST https://api.music.apple.com/v1/me/library?") { [self] request in
            let status = userStatus.withLock { $0 }
            guard status == 200 else { return json([:], status: status) }
            let ids = (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "ids[songs]" }?.value ?? "").split(separator: ",").map(String.init)
            let known = Set(catalog.withLock { $0 }.map(\.id))
            change { $0.apple.songIDs.formUnion(ids.filter(known.contains)) }
            return HTTPResponse(status: 202, body: Data())
        }
    }

    /// Makes a change, then syncs unless syncing is delayed.
    private func change<T>(_ body: (inout State) -> T) -> T {
        state.withLock { state in
            let result = body(&state)
            if !state.syncDelayed { Self.sync(&state) }
            return result
        }
    }

    private static func sync(_ state: inout State) {
        for id in state.edited {
            state.apple.playlists[id] = state.mac.playlists[id]
            if !state.apple.order.contains(id) { state.apple.order.append(id) }
        }
        for (id, playlist) in state.apple.playlists where !state.edited.contains(id) {
            state.mac.playlists[id] = Playlist(name: playlist.name, songIDs: playlist.songIDs.filter { !state.withheld.contains($0) })
        }
        state.mac.songIDs = state.apple.songIDs.subtracting(state.withheld)
        state.edited = []
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

    /// Apple's copy of the playlists, by name, with song titles in order.
    func playlists() -> [String: [String]] {
        let titles = Dictionary(uniqueKeysWithValues: catalog.withLock { $0 }.map { ($0.id, $0.name) })
        return state.withLock { state in
            Dictionary(state.apple.playlists.values.map { ($0.name, $0.songIDs.map { titles[$0] ?? $0 }) },
                       uniquingKeysWith: { first, _ in first })
        }
    }

    /// Playlists by name, counting duplicates that `playlists()` would merge.
    func playlistNames() -> [String] {
        state.withLock { state in state.apple.order.compactMap { state.apple.playlists[$0]?.name } }
    }

    /// Adds a playlist to Apple's copy, as if an earlier version of Radio
    /// created it through the API.
    func seedPlaylist(name: String, songIDs: [String]) -> String {
        change { state in
            state.playlistsCreated += 1
            let id = "p.\(state.playlistsCreated)"
            state.apple.playlists[id] = Playlist(name: name, songIDs: songIDs)
            state.apple.order.append(id)
            state.apple.songIDs.formUnion(songIDs)
            return id
        }
    }

    /// While delayed, changes stay where they were made until `syncMusicApp`.
    func setSyncDelayed(_ delayed: Bool) {
        state.withLock { $0.syncDelayed = delayed }
    }

    func syncMusicApp() {
        state.withLock { Self.sync(&$0) }
    }

    /// Keeps a song's library track and entries from reaching Music.app.
    func setReachesMusicApp(_ title: String, _ reaches: Bool) {
        let ids = catalog.withLock { $0 }.filter { $0.name == title }.map(\.id)
        change { state in
            if reaches { state.withheld.subtract(ids) } else { state.withheld.formUnion(ids) }
        }
    }

    /// Removes a song from a playlist the way a person would in Music.
    func removeByHand(_ title: String, from name: String) {
        let ids = Set(catalog.withLock { $0 }.filter { $0.name == title }.map(\.id))
        editByHand { library in
            for (id, playlist) in library.playlists where playlist.name == name {
                library.playlists[id]!.songIDs.removeAll(where: ids.contains)
            }
        }
    }

    func renamePlaylist(_ name: String, to newName: String) {
        editByHand { library in
            for (id, playlist) in library.playlists where playlist.name == name {
                library.playlists[id]!.name = newName
            }
        }
    }

    func deleteAllPlaylists() {
        editByHand { $0.playlists = [:] }
    }

    /// A song's comment in Music.app.
    func comment(of title: String) -> String? {
        let ids = catalog.withLock { $0 }.filter { $0.name == title }.map(\.id)
        return state.withLock { state in ids.compactMap { state.comments[$0] }.first }
    }

    /// Writes a song's comment the way a person would in Get Info.
    func writeCommentByHand(_ text: String, on title: String) {
        let ids = catalog.withLock { $0 }.filter { $0.name == title }.map(\.id)
        state.withLock { state in for id in ids { state.comments[id] = text } }
    }

    /// A person's edit, which reaches both copies.
    private func editByHand(_ edit: (inout Library) -> Void) {
        state.withLock { state in
            edit(&state.apple)
            edit(&state.mac)
        }
    }

    /// Music.app working on its copy: its own persistent IDs, and entries and
    /// library tracks found by the catalog song's title and artist.
    func musicAppPerform(_ action: MusicAppAction, playlist target: MusicAppPlaylist, song: MusicAppSong) -> MusicAppResult {
        let matching = catalog.withLock { $0 }.filter {
            $0.name.lowercased() == song.name.lowercased() && $0.artistName.lowercased() == song.artist.lowercased()
        }
        return change { state in
            var found = state.mac.playlists.filter { id, _ in target.id == "M-\(id)" }
            if found.isEmpty { found = state.mac.playlists.filter { $0.value.name == target.name } }
            if found.count > 1 { return .ambiguousPlaylist }
            let id: String
            if let existing = found.first {
                id = existing.key
            } else if action != .place {
                return .playlistNotFound
            } else {
                state.playlistsCreated += 1
                id = "p.\(state.playlistsCreated)"
                state.mac.playlists[id] = Playlist(name: target.name, songIDs: [])
                state.edited.insert(id)
            }
            let musicID = "M-\(id)"
            let ids = Set(matching.map(\.id))
            let entry = state.mac.playlists[id]!.songIDs.first(where: ids.contains)
            let library = matching.filter { state.mac.songIDs.contains($0.id) }
            let track = entry ?? (library.first { $0.albumName == song.album } ?? library.first)?.id
            switch action {
            case .remove:
                guard let entry else { return .trackNotFound(playlistID: musicID) }
                state.mac.playlists[id]!.songIDs.removeAll { $0 == entry }
            case .place:
                guard let track, state.mac.songIDs.contains(track) else { return .notInLibrary(playlistID: musicID) }
                state.mac.playlists[id]!.songIDs.removeAll { $0 == track }
                state.mac.playlists[id]!.songIDs.append(track)
            case .comment(let text, let mark):
                // A track's details aren't part of the playlist, so this
                // isn't an edit that uploads it.
                guard let track, state.mac.songIDs.contains(track) else { return .notInLibrary(playlistID: musicID) }
                let current = state.comments[track] ?? ""
                if current.isEmpty || current.hasPrefix(mark) { state.comments[track] = text }
                return .commented(playlistID: musicID)
            }
            state.edited.insert(id)
            return action == .remove ? .removed(playlistID: musicID) : .placed(playlistID: musicID)
        }
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

/// Music.app on the Mac, editing the fake library.
final class FakeMusicApp: MusicApp {
    let music: FakeAppleMusic
    private let state = Mutex<(failure: String?, calls: Int)>((nil, 0))

    init(music: FakeAppleMusic) {
        self.music = music
    }

    var calls: Int { state.withLock { $0.calls } }

    func fail(with message: String?) {
        state.withLock { $0.failure = message }
    }

    func perform(_ action: MusicAppAction, playlist: MusicAppPlaylist, song: MusicAppSong) async throws -> MusicAppResult {
        if let failure = state.withLock({ state -> String? in state.calls += 1; return state.failure }) {
            throw RadioError(failure)
        }
        return music.musicAppPerform(action, playlist: playlist, song: song)
    }
}

/// Everything a Radio needs, wired to fakes and a temporary directory.
struct Harness {
    let http: FakeHTTP
    let clock = TestClock()
    let audacy: FakeAudacy
    let iheart: FakeIHeart
    let music: FakeAppleMusic
    let musicApp: FakeMusicApp
    let home: RadioHome
    let radio: Radio

    init(pushover: Bool = true, playlistLimit: Int = 100, archiveLimit: Int = 10_000, http: FakeHTTP = FakeHTTP()) throws {
        self.http = http
        audacy = FakeAudacy(http: http)
        iheart = FakeIHeart(http: http)
        music = FakeAppleMusic(http: http)
        musicApp = FakeMusicApp(music: music)
        http.on("POST https://api.pushover.net/") { _ in json(["status": 1]) }
        home = RadioHome(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-tests-\(UUID().uuidString)"))
        let clock = clock
        radio = try Radio(
            home: home,
            http: http,
            sources: [AudacySource(http: http), IHeartSource(http: http)],
            notifier: PushoverNotifier(http: http, userKey: pushover ? "user" : nil, apiKey: pushover ? "app" : nil),
            musicApp: musicApp,
            playlistLimit: playlistLimit,
            archiveLimit: archiveLimit,
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
