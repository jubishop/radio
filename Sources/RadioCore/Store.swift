import Foundation

public struct Station: Equatable, Sendable {
    public var id: Int64
    public var slug: String
    public var source: String
    public var feedID: String
    public var name: String
    public var playlistID: String?
    public var lastPollOKAt: Date?
    public var pollFailingSince: Date?
    public var lastPollError: String?
    public var feedAlertSentAt: Date?
}

public enum SongStatus: String, Sendable {
    case pending, matched, unmatched, ignored
}

public struct Song: Equatable, Sendable {
    public var id: Int64
    public var artist: String
    public var title: String
    public var status: SongStatus
    public var catalogID: String?
    public var catalogURL: String?
    public var candidates: [CatalogSong]
    public var heldAt: Date?
}

/// A play as the dashboard shows it, with where its song stands.
public struct PlayEntry: Equatable, Sendable {
    public enum State: String, Sendable { case added, waiting, held, ignored }
    public var playedAt: Date
    public var artist: String
    public var title: String
    public var state: State
    public var url: String?
}

public struct AddedTrack: Equatable, Sendable {
    public var addedAt: Date
    public var artist: String
    public var title: String
    public var url: String?
}

/// A song held back for review.
public struct HeldSong: Equatable, Sendable {
    public var id: Int64
    public var artist: String
    public var title: String
    public var playCount: Int
    public var lastPlayedAt: Date
    public var stations: [String]
    public var candidates: [CatalogSong]
}

/// Radio's SQLite schema and queries.
final class Store {
    let db: Database

    init(url: URL) throws {
        db = try Database(path: url.path)
        try migrate()
    }

    private func migrate() throws {
        let version = try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
        guard version < 1 else { return }
        try db.transaction {
            try db.execute("""
                CREATE TABLE stations (
                    id INTEGER PRIMARY KEY,
                    slug TEXT NOT NULL UNIQUE,
                    source TEXT NOT NULL,
                    feed_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    playlist_id TEXT,
                    added_at TEXT NOT NULL,
                    last_poll_ok_at TEXT,
                    poll_failing_since TEXT,
                    last_poll_error TEXT,
                    feed_alert_sent_at TEXT
                )
                """)
            try db.execute("""
                CREATE TABLE songs (
                    id INTEGER PRIMARY KEY,
                    key TEXT NOT NULL UNIQUE,
                    artist TEXT NOT NULL,
                    title TEXT NOT NULL,
                    status TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'matched', 'unmatched', 'ignored')),
                    catalog_id TEXT,
                    catalog_url TEXT,
                    matched_by TEXT,
                    candidates TEXT,
                    first_heard_at TEXT NOT NULL,
                    held_at TEXT,
                    resolved_at TEXT
                )
                """)
            try db.execute("""
                CREATE TABLE plays (
                    station_id INTEGER NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
                    play_id TEXT NOT NULL,
                    played_at TEXT NOT NULL,
                    artist TEXT NOT NULL,
                    title TEXT NOT NULL,
                    song_id INTEGER NOT NULL REFERENCES songs(id),
                    PRIMARY KEY (station_id, play_id)
                )
                """)
            try db.execute("CREATE INDEX plays_by_time ON plays (station_id, played_at)")
            try db.execute("CREATE INDEX plays_by_song ON plays (song_id)")
            try db.execute("""
                CREATE TABLE playlist_tracks (
                    station_id INTEGER NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
                    catalog_id TEXT NOT NULL,
                    song_id INTEGER NOT NULL REFERENCES songs(id),
                    added_at TEXT NOT NULL,
                    PRIMARY KEY (station_id, catalog_id)
                )
                """)
            try db.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try db.execute("PRAGMA user_version = 1")
        }
    }

    // MARK: Stations

    func insertStation(_ info: StationInfo, at date: Date) throws -> Station {
        try db.execute(
            "INSERT INTO stations (slug, source, feed_id, name, added_at) VALUES (?, ?, ?, ?, ?)",
            [.text(info.slug), .text(info.source), .text(info.feedID), .text(info.name), .text(iso(date))]
        )
        return try station(slug: info.slug)!
    }

    func stations() throws -> [Station] {
        try db.query("SELECT * FROM stations ORDER BY id").map(station(from:))
    }

    func station(slug: String) throws -> Station? {
        try db.query("SELECT * FROM stations WHERE slug = ?", [.text(slug)]).first.map(station(from:))
    }

    func recordPollSuccess(stationID: Int64, at date: Date) throws {
        try db.execute(
            """
            UPDATE stations SET last_poll_ok_at = ?, poll_failing_since = NULL,
                last_poll_error = NULL, feed_alert_sent_at = NULL WHERE id = ?
            """,
            [.text(iso(date)), .integer(stationID)]
        )
    }

    func recordPollFailure(stationID: Int64, error: String, at date: Date) throws {
        try db.execute(
            """
            UPDATE stations SET poll_failing_since = COALESCE(poll_failing_since, ?),
                last_poll_error = ? WHERE id = ?
            """,
            [.text(iso(date)), .text(error), .integer(stationID)]
        )
    }

    func markFeedAlertSent(stationID: Int64, at date: Date) throws {
        try db.execute("UPDATE stations SET feed_alert_sent_at = ? WHERE id = ?", [.text(iso(date)), .integer(stationID)])
    }

    func setPlaylist(stationID: Int64, playlistID: String?) throws {
        try db.execute(
            "UPDATE stations SET playlist_id = ? WHERE id = ?",
            [playlistID.map(SQLValue.text) ?? .null, .integer(stationID)]
        )
        if playlistID == nil {
            try db.execute("DELETE FROM playlist_tracks WHERE station_id = ?", [.integer(stationID)])
        }
    }

    private func station(from row: Row) -> Station {
        Station(
            id: row.int("id")!,
            slug: row.string("slug")!,
            source: row.string("source")!,
            feedID: row.string("feed_id")!,
            name: row.string("name")!,
            playlistID: row.string("playlist_id"),
            lastPollOKAt: row.string("last_poll_ok_at").flatMap(parseISODate),
            pollFailingSince: row.string("poll_failing_since").flatMap(parseISODate),
            lastPollError: row.string("last_poll_error"),
            feedAlertSentAt: row.string("feed_alert_sent_at").flatMap(parseISODate)
        )
    }

    // MARK: Plays

    /// Records a play and its song. Returns false for a play already logged.
    func recordPlay(_ play: FeedPlay, stationID: Int64) throws -> Bool {
        try db.transaction {
            let existing = try db.query(
                "SELECT 1 FROM plays WHERE station_id = ? AND play_id = ?",
                [.integer(stationID), .text(play.playID)]
            )
            guard existing.isEmpty else { return false }
            let key = SongIdentity.key(artist: play.artist, title: play.title)
            try db.execute(
                "INSERT OR IGNORE INTO songs (key, artist, title, first_heard_at) VALUES (?, ?, ?, ?)",
                [.text(key), .text(play.artist), .text(play.title), .text(iso(play.playedAt))]
            )
            let songID = try db.query("SELECT id FROM songs WHERE key = ?", [.text(key)]).first!.int("id")!
            try db.execute(
                "INSERT INTO plays (station_id, play_id, played_at, artist, title, song_id) VALUES (?, ?, ?, ?, ?, ?)",
                [.integer(stationID), .text(play.playID), .text(iso(play.playedAt)), .text(play.artist), .text(play.title), .integer(songID)]
            )
            return true
        }
    }

    func recentPlays(stationID: Int64, limit: Int) throws -> [PlayEntry] {
        try db.query(
            """
            SELECT p.played_at, p.artist, p.title, s.status, s.catalog_url,
                EXISTS (SELECT 1 FROM playlist_tracks t
                        WHERE t.station_id = p.station_id AND t.song_id = p.song_id) AS added
            FROM plays p JOIN songs s ON s.id = p.song_id
            WHERE p.station_id = ? ORDER BY p.played_at DESC LIMIT ?
            """,
            [.integer(stationID), .integer(Int64(limit))]
        ).map { row in
            let state: PlayEntry.State =
                row.int("added") == 1 ? .added
                : row.string("status") == SongStatus.unmatched.rawValue ? .held
                : row.string("status") == SongStatus.ignored.rawValue ? .ignored
                : .waiting
            return PlayEntry(
                playedAt: parseISODate(row.string("played_at")!)!,
                artist: row.string("artist")!,
                title: row.string("title")!,
                state: state,
                url: row.string("catalog_url")
            )
        }
    }

    func playCount(stationID: Int64) throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS n FROM plays WHERE station_id = ?", [.integer(stationID)]).first!.int("n")!)
    }

    /// Every play, oldest first, for CSV export.
    func allPlays(stationID: Int64?) throws -> [(station: String, playID: String, playedAt: String, artist: String, title: String)] {
        let filter = stationID == nil ? "" : "WHERE p.station_id = ?"
        return try db.query(
            """
            SELECT st.slug, p.play_id, p.played_at, p.artist, p.title
            FROM plays p JOIN stations st ON st.id = p.station_id \(filter)
            ORDER BY p.played_at, p.station_id
            """,
            stationID.map { [.integer($0)] } ?? []
        ).map { ($0.string("slug")!, $0.string("play_id")!, $0.string("played_at")!, $0.string("artist")!, $0.string("title")!) }
    }

    // MARK: Songs

    func songs(status: SongStatus) throws -> [Song] {
        try db.query("SELECT * FROM songs WHERE status = ? ORDER BY first_heard_at", [.text(status.rawValue)]).map(song(from:))
    }

    func song(id: Int64) throws -> Song? {
        try db.query("SELECT * FROM songs WHERE id = ?", [.integer(id)]).first.map(song(from:))
    }

    func markMatched(songID: Int64, catalog: CatalogSong, by method: String, at date: Date) throws {
        try db.execute(
            """
            UPDATE songs SET status = 'matched', catalog_id = ?, catalog_url = ?, matched_by = ?, resolved_at = ?
            WHERE id = ?
            """,
            [.text(catalog.id), .text(catalog.url), .text(method), .text(iso(date)), .integer(songID)]
        )
    }

    func markHeld(songID: Int64, candidates: [CatalogSong], at date: Date) throws {
        let json = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
        try db.execute(
            "UPDATE songs SET status = 'unmatched', candidates = ?, held_at = ? WHERE id = ?",
            [.text(json), .text(iso(date)), .integer(songID)]
        )
    }

    func markIgnored(songID: Int64, at date: Date) throws {
        try db.execute(
            "UPDATE songs SET status = 'ignored', resolved_at = ? WHERE id = ?",
            [.text(iso(date)), .integer(songID)]
        )
    }

    func heldSongs() throws -> [HeldSong] {
        try db.query(
            """
            SELECT s.*, COUNT(p.play_id) AS play_count, MAX(p.played_at) AS last_played,
                GROUP_CONCAT(DISTINCT st.name) AS station_names
            FROM songs s JOIN plays p ON p.song_id = s.id JOIN stations st ON st.id = p.station_id
            WHERE s.status = 'unmatched'
            GROUP BY s.id ORDER BY play_count DESC, last_played DESC
            """
        ).map { row in
            let song = song(from: row)
            return HeldSong(
                id: song.id,
                artist: song.artist,
                title: song.title,
                playCount: Int(row.int("play_count") ?? 0),
                lastPlayedAt: parseISODate(row.string("last_played")!)!,
                stations: (row.string("station_names") ?? "").split(separator: ",").map(String.init).sorted(),
                candidates: song.candidates
            )
        }
    }

    func heldCount(since date: Date?) throws -> Int {
        let rows = try db.query(
            "SELECT COUNT(*) AS n FROM songs WHERE status = 'unmatched' AND held_at > ?",
            [.text(date.map(iso) ?? "")]
        )
        return Int(rows.first!.int("n")!)
    }

    private func song(from row: Row) -> Song {
        let candidates = row.string("candidates")
            .flatMap { try? JSONDecoder().decode([CatalogSong].self, from: Data($0.utf8)) } ?? []
        return Song(
            id: row.int("id")!,
            artist: row.string("artist")!,
            title: row.string("title")!,
            status: SongStatus(rawValue: row.string("status")!) ?? .pending,
            catalogID: row.string("catalog_id"),
            catalogURL: row.string("catalog_url"),
            candidates: candidates,
            heldAt: row.string("held_at").flatMap(parseISODate)
        )
    }

    // MARK: Playlists

    /// Matched songs a station has played that aren't in its playlist yet,
    /// in the order the station first played them.
    func songsToAdd(stationID: Int64) throws -> [(songID: Int64, catalogID: String)] {
        try db.query(
            """
            SELECT s.id, s.catalog_id, MIN(p.played_at) AS first_played
            FROM plays p JOIN songs s ON s.id = p.song_id
            WHERE p.station_id = ? AND s.status = 'matched'
                AND NOT EXISTS (SELECT 1 FROM playlist_tracks t
                                WHERE t.station_id = p.station_id AND t.catalog_id = s.catalog_id)
            GROUP BY s.catalog_id ORDER BY first_played, s.id
            """,
            [.integer(stationID)]
        ).map { ($0.int("id")!, $0.string("catalog_id")!) }
    }

    func recordAdded(stationID: Int64, tracks: [(songID: Int64, catalogID: String)], at date: Date) throws {
        try db.transaction {
            for track in tracks {
                try db.execute(
                    "INSERT OR IGNORE INTO playlist_tracks (station_id, catalog_id, song_id, added_at) VALUES (?, ?, ?, ?)",
                    [.integer(stationID), .text(track.catalogID), .integer(track.songID), .text(iso(date))]
                )
            }
        }
    }

    func playlistCount(stationID: Int64) throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS n FROM playlist_tracks WHERE station_id = ?", [.integer(stationID)]).first!.int("n")!)
    }

    func recentlyAdded(stationID: Int64, limit: Int) throws -> [AddedTrack] {
        try db.query(
            """
            SELECT t.added_at, s.artist, s.title, s.catalog_url
            FROM playlist_tracks t JOIN songs s ON s.id = t.song_id
            WHERE t.station_id = ? ORDER BY t.added_at DESC, t.rowid DESC LIMIT ?
            """,
            [.integer(stationID), .integer(Int64(limit))]
        ).map {
            AddedTrack(addedAt: parseISODate($0.string("added_at")!)!, artist: $0.string("artist")!,
                       title: $0.string("title")!, url: $0.string("catalog_url"))
        }
    }

    // MARK: Meta

    func meta(_ key: String) throws -> String? {
        try db.query("SELECT value FROM meta WHERE key = ?", [.text(key)]).first?.string("value")
    }

    func setMeta(_ key: String, _ value: String?) throws {
        if let value {
            try db.execute("INSERT INTO meta (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
                           [.text(key), .text(value)])
        } else {
            try db.execute("DELETE FROM meta WHERE key = ?", [.text(key)])
        }
    }

    func metaDate(_ key: String) throws -> Date? {
        try meta(key).flatMap(parseISODate)
    }

    func setMetaDate(_ key: String, _ date: Date?) throws {
        try setMeta(key, date.map(iso))
    }
}

func iso(_ date: Date) -> String {
    date.formatted(.iso8601)
}

func parseISODate(_ text: String) -> Date? {
    try? Date(text, strategy: .iso8601)
}
