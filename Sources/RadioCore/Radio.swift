import Foundation

public struct RadioError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The outcome of polling one station.
public struct PollResult: Sendable {
    public var station: String
    public var newPlays: Int
    public var error: String?
}

/// What one sync changed in one playlist.
public struct PlaylistChanges: Equatable, Sendable {
    public var added = 0
    public var moved = 0
    /// Songs removed because more recently played songs filled the playlist.
    public var dropped = 0
}

public struct SyncReport: Sendable {
    public var skippedReason: String?
    public var matched = 0
    public var held = 0
    /// Changes by playlist name.
    public var playlists: [String: PlaylistChanges] = [:]
    /// Songs whose earlier automatic match the current rules reject, removed
    /// from the playlists to be matched again.
    public var replaced = 0
    public var error: String?
}

/// Apple Music's state, as the dashboard and `radio status` report it.
public enum AppleMusicState: Equatable, Sendable {
    case notConfigured
    case needsSignIn
    case rejected(since: Date)
    case connected(storefront: String, signedInAt: Date?)
}

public struct StationSummary: Sendable {
    public var station: Station
    public var playCount: Int
    public var recentPlays: [PlayEntry]
    /// Songs this station's plays added to "Radio".
    public var recentlyAdded: [AddedTrack]
}

public struct RadioStatus: Sendable {
    public var stations: [StationSummary]
    /// Songs in "Radio" and in "Radio Archive".
    public var playlistCount: Int
    public var archiveCount: Int
    public var appleMusic: AppleMusicState
    public var lastSyncAt: Date?
    public var lastSyncError: String?
    /// Why Music.app couldn't move or remove a playlist entry, until it can.
    public var musicAppError: String?
    public var heldCount: Int
}

/// A choice made while reviewing a held-back song.
public enum ReviewChoice: Sendable {
    /// One of the stored candidates, by position (0 for `a`).
    case candidate(Int)
    /// Any Apple Music song link or catalog ID.
    case link(String)
}

/// Polls stations, keeps the playlists in sync, and raises alerts.
public actor Radio {
    let home: RadioHome
    let store: Store
    let credentials: CredentialStore
    let http: HTTPClient
    let sources: [String: PlaySource]
    let notifier: PushoverNotifier
    let musicApp: MusicApp?
    let now: @Sendable () -> Date
    /// "Radio" keeps this many of the most recently played songs.
    public nonisolated let playlistLimit: Int
    public nonisolated let dashboardURL: String
    public nonisolated let signInURL: String

    /// Alert when a feed has failed for this long. The feed keeps about four
    /// hours of plays.
    static let feedAlertDelay: TimeInterval = 2 * 60 * 60
    /// Alert when Apple Music has rejected the sign-in for this long. A new
    /// MusicKit key answers 401 intermittently for minutes while it rolls out.
    static let authAlertDelay: TimeInterval = 60 * 60
    static let nudgeInterval: TimeInterval = 7 * 24 * 60 * 60

    public init(
        home: RadioHome,
        http: HTTPClient,
        sources: [PlaySource],
        notifier: PushoverNotifier,
        musicApp: MusicApp? = nil,
        playlistLimit: Int = 100,
        dashboardURL: String = "http://jubi.local:8102",
        signInURL: String = "http://localhost:8102/auth",
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        try home.create()
        self.home = home
        self.store = try Store(url: home.databaseURL)
        self.credentials = CredentialStore(home: home)
        self.http = http
        self.sources = Dictionary(uniqueKeysWithValues: sources.map { ($0.name, $0) })
        self.notifier = notifier
        self.musicApp = musicApp
        self.playlistLimit = playlistLimit
        self.dashboardURL = dashboardURL
        self.signInURL = signInURL
        self.now = now
    }

    // MARK: Stations

    public func addStation(slug: String, source sourceName: String = "audacy", name: String? = nil) async throws -> Station {
        guard let source = sources[sourceName] else { throw RadioError("Unknown source \(sourceName)") }
        if try store.station(slug: slug) != nil { throw RadioError("Station \(slug) is already added") }
        var info = try await source.lookUp(slug: slug)
        if let name { info.name = name }
        return try store.insertStation(info, at: now())
    }

    public func stations() throws -> [Station] {
        try store.stations()
    }

    // MARK: Polling

    public func poll() async throws -> [PollResult] {
        var results: [PollResult] = []
        for station in try store.stations() {
            guard let source = sources[station.source] else {
                results.append(PollResult(station: station.name, newPlays: 0, error: "Unknown source \(station.source)"))
                continue
            }
            do {
                let plays = try await source.recentPlays(feedID: station.feedID)
                var added = 0
                for play in plays.sorted(by: { $0.playedAt < $1.playedAt }) where isSong(play, on: station) {
                    if try store.recordPlay(play, stationID: station.id) { added += 1 }
                }
                try store.recordPollSuccess(stationID: station.id, at: now())
                results.append(PollResult(station: station.name, newPlays: added))
            } catch {
                try store.recordPollFailure(stationID: station.id, error: String(describing: error), at: now())
                results.append(PollResult(station: station.name, newPlays: 0, error: String(describing: error)))
            }
        }
        return results
    }

    /// Skips blank entries and station IDs that some feeds report as plays.
    private func isSong(_ play: FeedPlay, on station: Station) -> Bool {
        guard !play.artist.isEmpty, !play.title.isEmpty else { return false }
        let artist = SongIdentity.normalize(play.artist)
        return artist != SongIdentity.normalize(station.name) && artist != SongIdentity.normalize(station.slug)
    }

    // MARK: Apple Music

    public func setCredentials(keyID: String, teamID: String, keyPEM: String) throws {
        _ = try DeveloperTokenSigner(keyID: keyID, teamID: teamID, pem: keyPEM)
        try credentials.saveKey(keyPEM, keyID: keyID)
        var saved = try credentials.load() ?? Credentials(keyID: keyID, teamID: teamID)
        saved.keyID = keyID
        saved.teamID = teamID
        try credentials.save(saved)
    }

    public func savedCredentials() throws -> Credentials? {
        try credentials.load()
    }

    /// A short-lived developer token for the sign-in page.
    public func developerToken(lifetime: TimeInterval = 60 * 60) throws -> String {
        guard let saved = try credentials.load() else {
            throw RadioError("Apple Music isn't configured. Run `radio credentials set` first.")
        }
        let signer = try DeveloperTokenSigner(keyID: saved.keyID, teamID: saved.teamID, pem: try credentials.loadKey(keyID: saved.keyID))
        return try signer.token(issuedAt: now(), lifetime: lifetime)
    }

    /// Saves a Music User Token from the sign-in page and looks up its
    /// storefront to prove it works.
    public func saveUserToken(_ token: String) async throws {
        guard var saved = try credentials.load() else {
            throw RadioError("Apple Music isn't configured. Run `radio credentials set` first.")
        }
        let client = AppleMusicClient(http: http, developerToken: try developerToken(), userToken: token, storefront: "us")
        saved.storefront = try await client.userStorefront()
        saved.musicUserToken = token
        saved.userTokenSavedAt = now()
        try credentials.save(saved)
        try store.setMetaDate("auth.rejected_at", nil)
        try store.setMetaDate("auth.alert_sent_at", nil)
    }

    public func appleMusicState() throws -> AppleMusicState {
        guard let saved = try credentials.load() else { return .notConfigured }
        guard saved.musicUserToken != nil else { return .needsSignIn }
        if let rejected = try store.metaDate("auth.rejected_at") { return .rejected(since: rejected) }
        return .connected(storefront: saved.storefront ?? "us", signedInAt: saved.userTokenSavedAt)
    }

    private func client(requireUser: Bool) throws -> AppleMusicClient? {
        guard let saved = try credentials.load() else { return nil }
        if requireUser && saved.musicUserToken == nil { return nil }
        return AppleMusicClient(
            http: http,
            developerToken: try developerToken(),
            userToken: saved.musicUserToken,
            storefront: saved.storefront ?? "us"
        )
    }

    // MARK: Syncing

    /// Matches new songs, adds them to the playlists, and moves re-played
    /// songs to the end. See PlaylistSync.swift.
    public func sync() async throws -> SyncReport {
        var report = SyncReport()
        guard let client = try client(requireUser: true) else {
            report.skippedReason = "Apple Music isn't set up. Run `radio credentials set` and sign in at \(signInURL)."
            return report
        }
        // Another process (launchd's run or a manual sync) may be syncing; two
        // syncs could create duplicate playlists, which the API can't delete.
        guard let lock = try ProcessLock(url: home.syncLockURL) else {
            report.skippedReason = "Another sync is running."
            return report
        }
        defer { lock.release() }
        defer { try? store.setMetaDate("sync.last_at", now()) }
        var music = MusicAppSession()
        do {
            try await fillCatalogDetails(client: client)
            report.replaced = try await replaceRejectedMatches(music: &music)
            for song in try store.songs(status: .pending) {
                let results = try await client.searchSongs(SongIdentity.searchTerm(artist: song.artist, title: song.title))
                if let match = chooseMatch(artist: song.artist, title: song.title, candidates: results) {
                    try store.markMatched(songID: song.id, catalog: match, by: "auto", at: now())
                    report.matched += 1
                } else {
                    try store.markHeld(songID: song.id, candidates: Array(results.prefix(3)), at: now())
                    report.held += 1
                }
            }
            report.playlists = try await syncPlaylists(client: client, music: &music)
            try store.setMetaDate("auth.rejected_at", nil)
            try store.setMetaDate("auth.alert_sent_at", nil)
            try store.setMeta("sync.last_error", nil)
        } catch let error as AppleMusicAuthError {
            if try store.metaDate("auth.rejected_at") == nil { try store.setMetaDate("auth.rejected_at", now()) }
            try store.setMeta("sync.last_error", error.description)
            report.error = error.description
        } catch {
            try store.setMeta("sync.last_error", String(describing: error))
            report.error = String(describing: error)
        }
        try finish(music)
        return report
    }

    // MARK: Scheduled runs

    /// Polls, syncs, and sends any alerts. launchd runs this every 15 minutes.
    public func run() async throws -> (polls: [PollResult], sync: SyncReport) {
        let polls = try await poll()
        let sync = try await sync()
        try await sendFeedAlerts()
        try await sendAuthAlert()
        try await sendReviewNudge()
        return (polls, sync)
    }

    private func sendFeedAlerts() async throws {
        for station in try store.stations() {
            guard let since = station.pollFailingSince, station.feedAlertSentAt == nil,
                  now().timeIntervalSince(since) >= Self.feedAlertDelay
            else { continue }
            let sent = try await notifier.send(
                title: "Radio: \(station.name) feed is down",
                message: "Radio hasn't read \(station.name)'s feed since \(displayTime(since)). "
                    + "Plays more than about four hours old can't be recovered. "
                    + "Last error: \(station.lastPollError ?? "unknown")",
                link: dashboardURL
            )
            if sent { try store.markFeedAlertSent(stationID: station.id, at: now()) }
        }
    }

    private func sendAuthAlert() async throws {
        guard let rejected = try store.metaDate("auth.rejected_at"), try store.metaDate("auth.alert_sent_at") == nil,
              now().timeIntervalSince(rejected) >= Self.authAlertDelay
        else { return }
        let sent = try await notifier.send(
            title: "Radio: Apple Music sign-in needed",
            message: "Apple Music rejected Radio's sign-in, so the playlists aren't updating. "
                + "On the Mac mini, open \(signInURL) to sign in again.",
            link: signInURL
        )
        if sent { try store.setMetaDate("auth.alert_sent_at", now()) }
    }

    private func sendReviewNudge() async throws {
        guard let lastCheck = try store.metaDate("nudge.last_check_at") else {
            try store.setMetaDate("nudge.last_check_at", now())
            return
        }
        guard now().timeIntervalSince(lastCheck) >= Self.nudgeInterval else { return }
        let count = try store.heldCount(since: lastCheck)
        if count > 0 {
            let songs = count == 1 ? "1 new song needs" : "\(count) new songs need"
            let sent = try await notifier.send(
                title: "Radio: songs to review",
                message: "\(songs) review before \(count == 1 ? "it" : "they") can join the playlists.",
                link: "\(dashboardURL)/review"
            )
            guard sent else { return }
        }
        try store.setMetaDate("nudge.last_check_at", now())
    }

    // MARK: Review

    public func heldSongs() throws -> [HeldSong] {
        try store.heldSongs()
    }

    /// Resolves a held-back song. The next sync adds it to the playlists.
    public func match(songID: Int64, choice: ReviewChoice) async throws -> CatalogSong {
        guard let song = try store.song(id: songID), song.status == .unmatched || song.status == .ignored else {
            throw RadioError("Song \(songID) isn't waiting for review")
        }
        let catalog: CatalogSong
        switch choice {
        case .candidate(let index):
            guard song.candidates.indices.contains(index) else {
                throw RadioError("Song \(songID) has no candidate \(candidateLetter(index))")
            }
            catalog = song.candidates[index]
        case .link(let link):
            guard let id = catalogSongID(fromLink: link) else {
                throw RadioError("That isn't an Apple Music song link")
            }
            guard let client = try client(requireUser: false) else {
                throw RadioError("Apple Music isn't configured. Run `radio credentials set` first.")
            }
            guard let found = try await client.song(id: id) else {
                throw RadioError("Apple Music has no song \(id)")
            }
            catalog = found
        }
        try store.markMatched(songID: songID, catalog: catalog, by: "manual", at: now())
        return catalog
    }

    public func ignore(songID: Int64) throws {
        guard let song = try store.song(id: songID), song.status == .unmatched else {
            throw RadioError("Song \(songID) isn't waiting for review")
        }
        try store.markIgnored(songID: songID, at: now())
    }

    // MARK: Reporting

    public func status(recentPlays: Int = 15, recentlyAdded: Int = 10) throws -> RadioStatus {
        let summaries = try store.stations().map { station in
            StationSummary(
                station: station,
                playCount: try store.playCount(stationID: station.id),
                recentPlays: try store.recentPlays(stationID: station.id, limit: recentPlays),
                recentlyAdded: try store.recentlyAdded(stationID: station.id, limit: recentlyAdded)
            )
        }
        return RadioStatus(
            stations: summaries,
            playlistCount: try store.playlistCount(.recent),
            archiveCount: try store.playlistCount(.archive),
            appleMusic: try appleMusicState(),
            lastSyncAt: try store.metaDate("sync.last_at"),
            lastSyncError: try store.meta("sync.last_error"),
            musicAppError: try store.meta("music.last_error"),
            heldCount: try store.heldCount(since: nil)
        )
    }

    /// Every logged play as CSV, oldest first.
    public func exportCSV(stationSlug: String? = nil) throws -> String {
        var stationID: Int64?
        if let stationSlug {
            guard let station = try store.station(slug: stationSlug) else { throw RadioError("No station \(stationSlug)") }
            stationID = station.id
        }
        var lines = ["station,played_at,artist,title,play_id"]
        for play in try store.allPlays(stationID: stationID) {
            lines.append([play.station, play.playedAt, play.artist, play.title, play.playID].map(csvField).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

func csvField(_ value: String) -> String {
    guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
    return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

public func candidateLetter(_ index: Int) -> String {
    String(UnicodeScalar(UInt8(97 + index)))
}

/// A time in the Mac's time zone, such as "Oct 13, 3:12 PM".
public func displayTime(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}
