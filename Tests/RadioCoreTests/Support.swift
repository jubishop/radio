import CryptoKit
import Foundation
import RadioCore
import SQLite3
import Synchronization
import Testing

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

/// Changes a test database directly, to set up what an earlier release stored.
func executeSQL(_ statements: [String], in home: RadioHome) {
    var db: OpaquePointer?
    #expect(sqlite3_open(home.directory.appendingPathComponent("radio.sqlite").path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    for statement in statements {
        #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
    }
}

/// Takes a test database back from schema 12 to schema 11, which had no
/// release dates or "Radio (New)" of the newest releases.
let undoSchemaTwelve = [
    "DROP TABLE release_dates", "DELETE FROM playlist_tracks WHERE playlist = 'newest'",
    "DELETE FROM playlists WHERE kind = 'newest'", "DELETE FROM meta WHERE key = 'playlist.rename'",
]

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

/// Hubbard Radio's listen-live player settings and cue history.
final class FakeHubbard: Sendable {
    private let cues = Mutex<[(id: Int, time: Date, type: String, artist: String, title: String)]>([])
    private let nextID = Mutex(40_200_000)

    init(http: FakeHTTP) {
        http.on("GET https://live.movin925.com/wp-json/hll/v1/hll_settings_get") { _ in
            json(["success": true, "data": ["hll-station-name": "MOViN 92.5", "hll-station-call-letters": "KQMV"]])
        }
        // A WordPress site answers an unknown route with an empty 200.
        http.on("GET https://live.nosuchstation.com/") { _ in HTTPResponse(status: 200, body: Data()) }
        http.on("POST https://live.movin925.com/wp-json/hll/v1/hll_cues_get") { [self] request in
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            let limit = body?["limit"] as? Int ?? 6
            let recent = cues.withLock { $0 }.suffix(min(limit, 300)).reversed()
            return json(["success": true, "data": ["code": 200, "response": recent.map {
                ["id": String($0.id), "application": "25", "timestamp": String(Int($0.time.timeIntervalSince1970)),
                 "type": $0.type, "cut_id": "cut", "likes": 0, "itunes_url": "",
                 "data": ["cut_id": "cut", "description": $0.title, "artist": $0.artist, "album": "", "time": "180000"]]
            }]])
        }
    }

    func play(_ artist: String, _ title: String, at time: Date, type: String = "song") {
        let id = nextID.withLock { value in defer { value += 1 }; return value }
        cues.withLock { $0.append((id, time, type, artist, title)) }
    }
}

/// TypeSafe's System One endpoint, answering Jev's Choice question with the
/// probability set for each option's title, 0 unless set, and the rest on
/// "none".
final class FakeJev: Sendable {
    private let scores = Mutex<[String: Double]>([:])
    private let failing = Mutex(false)
    private let model = Mutex("jev-1.14.0")

    init(http: FakeHTTP) {
        http.on("POST https://api.typesafe.ai/v1/systemone") { [self] request in
            if failing.withLock({ $0 }) { return json(["detail": "unavailable"], status: 500) }
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
            let questions = body["questions"] as? [String: [String: Any]] ?? [:]
            var answers: [String: Any] = [:]
            for (id, question) in questions {
                let criteria = question["criteria"] as? [String: Any] ?? [:]
                var probabilities: [String: Double] = [:]
                for (option, value) in criteria where option != "none" {
                    let title = (value as? [String: Any])?["title"] as? String ?? ""
                    probabilities[option] = scores.withLock { $0[title] } ?? 0
                }
                probabilities["none"] = max(0, 1 - probabilities.values.reduce(0, +))
                let choice = probabilities.max { $0.value < $1.value }?.key ?? "none"
                answers[id] = ["type": "choice", "choice": choice, "probabilities": probabilities, "confidence": 0.5]
            }
            return json(["model": model.withLock { $0 }, "answers": answers, "usage": ["input_tokens": 100, "output_tokens": 10]])
        }
    }

    func score(_ title: String, _ value: Double) {
        scores.withLock { $0[title] = value }
    }

    func setFailing(_ isFailing: Bool) {
        failing.withLock { $0 = isFailing }
    }

    /// The model the alias points to, as each answer names it.
    func setModel(_ name: String) {
        model.withLock { $0 = name }
    }

    /// The played titles Jev was asked about, in order.
    static func askedTitles(_ http: FakeHTTP) -> [String] {
        http.requests("POST https://api.typesafe.ai/v1/systemone").compactMap { request in
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
            return ((body?["state"] as? [String: Any])?["played"] as? [String: String])?["title"]
        }
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
        /// The user's plays and skips in Music.app, by catalog song.
        var listens: [String: (plays: Int, skips: Int)] = [:]
    }
    private let catalog = Mutex<[CatalogSong]>([])
    /// Release dates by catalog song, for songs given one.
    private let releaseDates = Mutex<[String: String]>([:])
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
            return json(["results": ["songs": ["data": results.map(resource)]]])
        }
        http.on("GET https://api.music.apple.com/v1/catalog/us/songs/") { [self] request in
            let id = request.url.lastPathComponent
            guard let song = catalog.withLock({ $0.first { $0.id == id } }) else { return json(["data": []], status: 404) }
            return json(["data": [resource(song)]])
        }
        http.on("GET https://api.music.apple.com/v1/catalog/us/songs?") { [self] request in
            let ids = Set((URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "ids" }?.value ?? "").split(separator: ",").map(String.init))
            return json(["data": catalog.withLock { $0 }.filter { ids.contains($0.id) }.map(resource)])
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
    /// Each song gets its own ISRC and a length seven seconds from the last
    /// one's, so it's a separate recording unless the test says otherwise.
    func addToCatalog(_ artist: String, _ title: String, album: String = "Album", explicit: Bool = false,
                      isrc: String? = nil, seconds: Int? = nil, released: String? = nil) -> CatalogSong {
        let song = catalog.withLock { catalog in
            let id = 1_000_000 + catalog.count
            let song = CatalogSong(
                id: String(id), name: title, artistName: artist, albumName: album,
                url: "https://music.apple.com/us/album/x/1?i=\(id)", isExplicit: explicit,
                isrc: isrc ?? "TEST\(id)", durationMillis: (seconds ?? 180 + catalog.count * 7) * 1000
            )
            catalog.append(song)
            return song
        }
        if let released { releaseDates.withLock { $0[song.id] = released } }
        return song
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

    func deletePlaylist(_ name: String) {
        editByHand { library in library.playlists = library.playlists.filter { $0.value.name != name } }
    }

    func deleteAllPlaylists() {
        editByHand { $0.playlists = [:] }
    }

    /// A song's comment in Music.app.
    func comment(of title: String) -> String? {
        let ids = catalog.withLock { $0 }.filter { $0.name == title }.map(\.id)
        return state.withLock { state in ids.compactMap { state.comments[$0] }.first }
    }

    /// Puts a song in the library, as if the user added it before Radio did.
    func addToLibrary(_ title: String) {
        let ids = catalog.withLock { $0 }.filter { $0.name == title }.map(\.id)
        change { $0.apple.songIDs.formUnion(ids) }
    }

    /// Sets how often the user played and skipped a song in Music.
    func setListens(_ title: String, plays: Int = 0, skips: Int = 0) {
        let ids = catalog.withLock { $0 }.filter { $0.name == title }.map(\.id)
        state.withLock { state in for id in ids { state.listens[id] = (plays, skips) } }
    }

    /// Music.app's plays and skips of every library track.
    func musicAppListens() -> [TrackListens] {
        let catalog = catalog.withLock { $0 }
        return state.withLock { state in
            catalog.filter { state.mac.songIDs.contains($0.id) }.map { song in
                let listens = state.listens[song.id] ?? (0, 0)
                return TrackListens(name: song.name, artist: song.artistName, plays: listens.plays, skips: listens.skips)
            }
        }
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
            case .rename:
                state.mac.playlists[id]!.name = target.name
                state.edited.insert(id)
                return .renamed(playlistID: musicID)
            }
            state.edited.insert(id)
            return action == .remove ? .removed(playlistID: musicID) : .placed(playlistID: musicID)
        }
    }

    func setUserTokenStatus(_ status: Int) {
        userStatus.withLock { $0 = status }
    }

    private func resource(_ song: CatalogSong) -> [String: Any] {
        var attributes: [String: Any] = [
            "name": song.name, "artistName": song.artistName, "albumName": song.albumName,
            "url": song.url, "contentRating": song.isExplicit ? "explicit" : "clean",
            "isrc": song.isrc ?? "", "durationInMillis": song.durationMillis ?? 0,
        ]
        attributes["releaseDate"] = releaseDates.withLock { $0[song.id] }
        return ["id": song.id, "type": "songs", "attributes": attributes]
    }
}

/// Music.app on the Mac, editing the fake library.
final class FakeMusicApp: MusicApp {
    let music: FakeAppleMusic
    private let state = Mutex<(failure: String?, calls: Int, behind: Bool?)>((nil, 0, false))

    init(music: FakeAppleMusic) {
        self.music = music
    }

    var calls: Int { state.withLock { $0.calls } }

    func fail(with message: String?) {
        state.withLock { $0.failure = message }
    }

    /// Whether Music.app is behind its library; nil when its log can't be
    /// read.
    func setBehind(_ behind: Bool?) {
        state.withLock { $0.behind = behind }
    }

    func fellBehind(since date: Date) async throws -> Bool {
        guard let behind = state.withLock({ $0.behind }) else { throw RadioError("log failed") }
        return behind
    }

    func perform(_ action: MusicAppAction, playlist: MusicAppPlaylist, song: MusicAppSong) async throws -> MusicAppResult {
        if let failure = state.withLock({ state -> String? in state.calls += 1; return state.failure }) {
            throw RadioError(failure)
        }
        return music.musicAppPerform(action, playlist: playlist, song: song)
    }

    /// Reading plays and skips fails along with edits, but isn't counted
    /// in `calls`, which counts edits.
    func listens() async throws -> [TrackListens] {
        if let failure = state.withLock({ $0.failure }) { throw RadioError(failure) }
        return music.musicAppListens()
    }
}

/// Everything a Radio needs, wired to fakes and a temporary directory.
struct Harness {
    let http: FakeHTTP
    let clock = TestClock()
    let audacy: FakeAudacy
    let iheart: FakeIHeart
    let hubbard: FakeHubbard
    let jev: FakeJev
    let music: FakeAppleMusic
    let musicApp: FakeMusicApp
    let home: RadioHome
    let radio: Radio

    init(pushover: Bool = true, email: Bool = true, jevAPIKey: String? = "jev-key", playlistLimit: Int = 100,
         archiveLimit: Int = 10_000, dashboardURL: String? = nil, http: FakeHTTP = FakeHTTP()) throws {
        self.http = http
        audacy = FakeAudacy(http: http)
        iheart = FakeIHeart(http: http)
        hubbard = FakeHubbard(http: http)
        jev = FakeJev(http: http)
        music = FakeAppleMusic(http: http)
        musicApp = FakeMusicApp(music: music)
        http.on("POST https://api.pushover.net/") { _ in json(["status": 1]) }
        http.on("POST https://api.resend.com/") { _ in json(["id": "email-1"]) }
        home = RadioHome(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-tests-\(UUID().uuidString)"))
        let clock = clock
        radio = try Radio(
            home: home,
            http: http,
            sources: [AudacySource(http: http), IHeartSource(http: http), HubbardSource(http: http)],
            notifier: PushoverNotifier(http: http, userKey: pushover ? "user" : nil, apiKey: pushover ? "app" : nil),
            mailer: ResendMailer(http: http, apiKey: email ? "resend-key" : nil, recipient: email ? "me@example.com" : nil),
            musicApp: musicApp,
            jevAPIKey: jevAPIKey,
            playlistLimit: playlistLimit,
            archiveLimit: archiveLimit,
            dashboardURL: dashboardURL,
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

    var pushes: [String] { pushFields("title") }

    var pushLinks: [String] { pushFields("url") }

    private func pushFields(_ name: String) -> [String] {
        http.requests("POST https://api.pushover.net/").map { request in
            let fields = URLComponents(string: "?" + String(decoding: request.body ?? Data(), as: UTF8.self))?.queryItems ?? []
            return fields.first { $0.name == name }?.value ?? ""
        }
    }

    /// Each email request's JSON body, including ones Resend refused.
    var emails: [[String: Any]] {
        http.requests("POST https://api.resend.com/emails").map { request in
            (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
        }
    }
}
