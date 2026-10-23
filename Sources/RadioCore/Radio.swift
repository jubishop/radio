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
    /// Songs not placed yet: ones whose library track hasn't reached
    /// Music.app, and those played after one, which wait to keep play order.
    public var waiting = 0
}

public struct SyncReport: Sendable {
    public var skippedReason: String?
    public var matched = 0
    /// Held songs Jev was sure of, added without review.
    public var jevMatched = 0
    public var held = 0
    /// Changes by playlist name.
    public var playlists: [String: PlaylistChanges] = [:]
    /// Songs whose earlier automatic match the current rules reject, removed
    /// from the playlists to be matched again.
    public var replaced = 0
    /// Tracks removed from the playlists because the user sent their song
    /// back to review.
    public var removed = 0
    /// Songs Music.app was asked to comment with their latest play and
    /// stations. A comment someone else wrote stays.
    public var commented = 0
    /// Why Jev couldn't judge held songs; they wait for the next sync.
    public var jevError: String?
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
    /// Songs in "Radio", "Radio (New)", "Radio (Unplayed)", and
    /// "Radio Archive".
    public var playlistCount: Int
    public var newCount: Int
    public var unplayedCount: Int
    public var archiveCount: Int
    public var appleMusic: AppleMusicState
    public var lastSyncAt: Date?
    public var lastSyncError: String?
    /// Why Music.app couldn't update a playlist, until it can.
    public var musicAppError: String?
    /// Why Jev couldn't judge held songs, until it can.
    public var jevError: String?
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
    let mailer: ResendMailer?
    let musicApp: MusicApp?
    let jev: Jev?
    let now: @Sendable () -> Date
    /// "Radio" keeps this many of the most recently played songs,
    /// "Radio (New)" this many of the newest releases, and
    /// "Radio (Unplayed)" this many chosen by the user's plays and skips.
    public nonisolated let playlistLimit: Int
    /// "Radio Archive" keeps this many.
    public nonisolated let archiveLimit: Int
    /// Where alerts and reminders link. `bin/deploy` sets it from the
    /// checkout's `.env`; without one, it's `http://jubi.local:8102`.
    public nonisolated let dashboardURL: String
    public nonisolated let signInURL: String

    /// Alert when a feed has failed for this long. Audacy's feed keeps about
    /// four hours of plays.
    static let feedAlertDelay: TimeInterval = 2 * 60 * 60
    /// Alert when Apple Music has rejected the sign-in for this long. A new
    /// MusicKit key answers 401 intermittently for minutes while it rolls out.
    static let authAlertDelay: TimeInterval = 60 * 60
    static let nudgeInterval: TimeInterval = 24 * 60 * 60
    /// Apple Music candidates kept for each held song, for Jev and review.
    static let storedCandidates = 10
    /// Jev adds a held song when it scores a candidate at least this high,
    /// and suggests one scored at least `jevSuggestScore`. The user chose
    /// both on 2026-10-15; see docs/design.md.
    static let jevAddScore = 0.9
    static let jevSuggestScore = 0.6

    public init(
        home: RadioHome,
        http: HTTPClient,
        sources: [PlaySource],
        notifier: PushoverNotifier,
        mailer: ResendMailer? = nil,
        musicApp: MusicApp? = nil,
        jevAPIKey: String? = nil,
        playlistLimit: Int = 100,
        archiveLimit: Int = 10_000,
        dashboardURL: String? = nil,
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
        self.mailer = mailer
        self.musicApp = musicApp
        self.jev = jevAPIKey.flatMap { $0.isEmpty ? nil : Jev(http: http, apiKey: $0) }
        self.playlistLimit = playlistLimit
        self.archiveLimit = archiveLimit
        self.dashboardURL = dashboardURL.flatMap { $0.isEmpty ? nil : $0 } ?? "http://jubi.local:8102"
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

    /// Matches new songs, adds them to the playlists, moves re-played songs
    /// to the end, and drops old ones. See PlaylistSync.swift.
    public func sync() async throws -> SyncReport {
        var report = SyncReport()
        guard let client = try client(requireUser: true) else {
            report.skippedReason = "Apple Music isn't set up. Run `radio credentials set` and sign in at \(signInURL)."
            return report
        }
        // Another process (launchd's run or a manual sync) may be syncing; two
        // syncs could each make the playlists.
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
            report.removed = try await removeTracksSentBack(music: &music)
            // A song held back before a matching fix may now match one of its
            // candidates.
            for song in try store.songs(status: .unmatched) where song.undoneAt == nil {
                if let match = chooseMatch(artist: song.artist, title: song.title, candidates: song.candidates) {
                    try store.markMatched(songID: song.id, catalog: match, by: "auto", at: now())
                    report.matched += 1
                }
            }
            for song in try store.songs(status: .pending) {
                let results = try await client.searchSongs(SongIdentity.searchTerm(artist: song.artist, title: song.title))
                if let match = chooseMatch(artist: song.artist, title: song.title, candidates: results) {
                    try store.markMatched(songID: song.id, catalog: match, by: "auto", at: now())
                    report.matched += 1
                } else {
                    try store.markHeld(songID: song.id, candidates: Array(results.prefix(Self.storedCandidates)), at: now())
                    report.held += 1
                }
            }
            try await judgeHeldSongs(&report)
            report.playlists = try await syncPlaylists(client: client, music: &music)
            report.commented = try await syncComments(music: &music)
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

    /// Asks Jev about each held song it hasn't judged, offering one copy of
    /// each recording among its candidates. When Jev is sure of a recording,
    /// Radio adds its explicit copy, or else its first in Apple's search
    /// order, usually the original release; otherwise it records that copy
    /// as Jev's pick for review. When an answer names a newer model, held
    /// songs judged by an older one are asked about once more; Radio follows
    /// the newest model, and learns of one only from an answer. After a
    /// failure, the rest wait for the next sync.
    private func judgeHeldSongs(_ report: inout SyncReport) async throws {
        guard let jev else { return }
        var asked = Set<Int64>()
        while let item = try store.songsToJudge(model: store.meta("jev.model")).first(where: { !asked.contains($0.song.id) }) {
            let song = item.song
            asked.insert(song.id)
            let recordings = groupCopies(song.candidates)
            let verdict: JevVerdict
            do {
                verdict = try await jev.judge(station: item.station, artist: song.artist, title: song.title,
                                              recordings: recordings.map { song.candidates[$0[0]] })
            } catch {
                report.jevError = String(describing: error)
                try store.setMeta("jev.last_error", report.jevError)
                return
            }
            try store.setMeta("jev.last_error", nil)
            try store.setMeta("jev.model", verdict.model)
            let scores = verdict.scores
            let best = scores.indices.max { scores[$0] < scores[$1] }!
            let copies = recordings[best]
            let pick = copies.first { song.candidates[$0].isExplicit } ?? copies[0]
            try store.recordJevVerdict(songID: song.id, model: verdict.model, score: scores[best], pick: pick, at: now())
            if scores[best] >= Self.jevAddScore {
                try store.markMatched(songID: song.id, catalog: song.candidates[pick], by: "jev", at: now())
                report.jevMatched += 1
            }
        }
    }

    // MARK: Scheduled runs

    /// Polls, syncs, and sends any alerts. launchd runs this every 15 minutes.
    public func run() async throws -> (polls: [PollResult], sync: SyncReport) {
        let polls = try await poll()
        let sync = try await sync()
        try await sendFeedAlerts()
        try await sendAuthAlert()
        try await sendReviewReminder()
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

    /// Once a day, while songs wait for review, sends a push and an email
    /// that lists them. Each day starts a whole number of days after the
    /// first check, so a late run doesn't make the next reminder late, and a
    /// reminder more than half a day late skips the next one. Each counts as
    /// sent once its service accepts it, so a failed email is retried without
    /// repeating the push; a service without keys is skipped.
    private func sendReviewReminder() async throws {
        guard let lastCheck = try store.metaDate("nudge.last_check_at") else {
            try store.setMetaDate("nudge.last_check_at", now())
            return
        }
        let elapsed = now().timeIntervalSince(lastCheck)
        guard elapsed >= Self.nudgeInterval else { return }
        let due = lastCheck + Self.nudgeInterval
        let songs = try store.heldSongs()
        if !songs.isEmpty {
            let one = songs.count == 1
            let summary = "\(one ? "1 song needs" : "\(songs.count) songs need") review before \(one ? "it" : "they") can join the playlists."
            let reviewURL = "\(dashboardURL)/review"
            if try !sentSince(due, "nudge.push_sent_at"),
               try await notifier.send(title: "Radio: songs to review", message: summary, link: reviewURL) {
                try store.setMetaDate("nudge.push_sent_at", now())
            }
            if let mailer, try !sentSince(due, "nudge.email_sent_at") {
                let email = Pages.reviewEmail(songs, summary: summary, reviewURL: reviewURL)
                if try await mailer.send(subject: "Radio: \(one ? "1 song" : "\(songs.count) songs") to review",
                                         text: email.text, html: email.html) {
                    try store.setMetaDate("nudge.email_sent_at", now())
                }
            }
        }
        let days = (elapsed / Self.nudgeInterval).rounded()
        try store.setMetaDate("nudge.last_check_at", lastCheck + days * Self.nudgeInterval)
    }

    private func sentSince(_ date: Date, _ key: String) throws -> Bool {
        try store.metaDate(key).map { $0 >= date } ?? false
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

    /// Songs Jev or the user matched, and songs the user ignored, most
    /// recently decided first.
    public func reviewedSongs() throws -> [ReviewedSong] {
        try store.reviewedSongs()
    }

    /// Sends a matched or ignored song back to review, where it stays until
    /// the user decides. A matched song's track leaves the playlists on the
    /// next sync.
    public func undo(songID: Int64) throws {
        guard let song = try store.song(id: songID), song.status == .matched || song.status == .ignored else {
            throw RadioError("Song \(songID) isn't matched or ignored")
        }
        try store.sendBackToReview(songID: songID, at: now())
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
            newCount: try store.playlistCount(.newest),
            unplayedCount: try store.playlistCount(.unheard),
            archiveCount: try store.playlistCount(.archive),
            appleMusic: try appleMusicState(),
            lastSyncAt: try store.metaDate("sync.last_at"),
            lastSyncError: try store.meta("sync.last_error"),
            musicAppError: try store.meta("music.last_error"),
            jevError: try store.meta("jev.last_error"),
            heldCount: try store.heldCount()
        )
    }

    /// A playlist's songs, most recently played first, marking the one the
    /// next new song will push out of "Radio (New)" or "Radio (Unplayed)".
    func playlistEntries(_ kind: Playlist.Kind) throws -> [PlaylistEntry] {
        var entries = try store.playlistEntries(kind).reversed()
            .sorted { ($0.latestPlay ?? .distantPast) > ($1.latestPlay ?? .distantPast) }
        let next = switch kind {
        case .newest: try store.nextToDropFromNewest(limit: playlistLimit)
        case .unheard: try nextToDropFromUnheard()
        case .recent, .archive: String?.none
        }
        if let next {
            for index in entries.indices where entries[index].catalogID == next {
                entries[index].dropsNext = true
            }
        }
        return entries
    }

    func charts() throws -> Charts {
        try store.charts(now: now())
    }

    func stats() throws -> Stats {
        try store.stats(now: now())
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
