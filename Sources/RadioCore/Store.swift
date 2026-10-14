import Foundation

public struct Station: Equatable, Sendable {
    public var id: Int64
    public var slug: String
    public var source: String
    public var feedID: String
    public var name: String
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
    public var catalogName: String?
    public var catalogArtist: String?
    public var catalogAlbum: String?
    public var matchedBy: String?
    public var candidates: [CatalogSong]
    public var heldAt: Date?
}

/// One of Radio's Apple Music playlists, which every station feeds.
struct Playlist {
    /// Raw values are stored in the database.
    enum Kind: String, CaseIterable {
        /// "Radio": the most recently played songs.
        case recent
        /// "Radio Archive": many more of them.
        case archive
    }

    var kind: Kind
    /// Music.app's persistent ID for the playlist, once Radio knows it.
    var musicID: String?
}

/// A song to put at the end of a playlist: a song new to it, or an entry
/// whose song has played again since it was placed.
struct TrackToPlace {
    var songID: Int64
    var catalogID: String
    /// The station whose play puts a new song in the playlist.
    var stationID: Int64?
    /// Nil for a match saved before Radio stored catalog titles.
    var song: MusicAppSong?
    var latestPlay: String
    var inPlaylist: Bool
    /// When Radio first asked Apple to add the song to the library.
    var libraryRequestedAt: Date?
}

/// A playlist entry for a song no longer among the most recently played.
struct TrackToDrop {
    var catalogID: String
    var song: MusicAppSong?
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

    /// The schema version `migrate` produces.
    private static let schemaVersion: Int64 = 5

    /// Both LaunchAgents open the database at once after a deploy, so the
    /// version is read again inside the write lock and only one migrates.
    private func migrate() throws {
        guard try userVersion() < Self.schemaVersion else { return }
        try db.transaction {
            let version = try userVersion()
            if version < 1 { try createSchemaOne() }
            if version < 2 { try migrateToSchemaTwo() }
            if version < 3 { try migrateToSchemaThree() }
            if version < 4 { try migrateToSchemaFour() }
            if version < 5 { try migrateToSchemaFive() }
        }
    }

    private func userVersion() throws -> Int64 {
        try db.query("PRAGMA user_version").first?.int("user_version") ?? 0
    }

    private func createSchemaOne() throws {
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

    /// Adds what moving and replacing playlist entries needs: catalog titles
    /// to find entries in Music.app, Music.app's playlist IDs, and the play
    /// each entry's position reflects. Existing entries were placed at their
    /// song's first play.
    private func migrateToSchemaTwo() throws {
        try db.execute("ALTER TABLE songs ADD COLUMN catalog_name TEXT")
        try db.execute("ALTER TABLE songs ADD COLUMN catalog_artist TEXT")
        try db.execute("ALTER TABLE songs ADD COLUMN catalog_album TEXT")
        try db.execute("ALTER TABLE stations ADD COLUMN music_playlist_id TEXT")
        try db.execute("ALTER TABLE playlist_tracks ADD COLUMN position_played_at TEXT")
        try db.execute("""
            UPDATE playlist_tracks SET position_played_at = (
                SELECT MIN(p.played_at) FROM plays p
                WHERE p.station_id = playlist_tracks.station_id AND p.song_id = playlist_tracks.song_id)
            """)
        try db.execute("PRAGMA user_version = 2")
    }

    /// Replaces each station's playlist with one playlist for every station.
    /// The API can't move entries between playlists, so the new playlist
    /// starts empty for the next sync to fill, and the old ones stay in Music.
    /// Each entry remembers the station that added it, for the dashboard.
    private func migrateToSchemaThree() throws {
        try db.execute("DROP TABLE playlist_tracks")
        try db.execute("""
            CREATE TABLE playlist_tracks (
                catalog_id TEXT PRIMARY KEY,
                song_id INTEGER NOT NULL REFERENCES songs(id),
                station_id INTEGER REFERENCES stations(id) ON DELETE SET NULL,
                added_at TEXT NOT NULL,
                position_played_at TEXT
            )
            """)
        try db.execute("CREATE INDEX playlist_tracks_by_station ON playlist_tracks (station_id, added_at)")
        try db.execute("ALTER TABLE stations DROP COLUMN playlist_id")
        try db.execute("ALTER TABLE stations DROP COLUMN music_playlist_id")
        try db.execute("PRAGMA user_version = 3")
    }

    /// Adds "Radio Archive", a second, larger playlist. Each playlist's IDs move
    /// from meta to a row of `playlists`, and each entry records which
    /// playlist it's in. The archive starts empty for the next sync to fill.
    private func migrateToSchemaFour() throws {
        try db.execute("CREATE TABLE playlists (kind TEXT PRIMARY KEY, library_id TEXT, music_id TEXT)")
        try db.execute("""
            INSERT INTO playlists (kind, library_id, music_id) VALUES ('recent',
                (SELECT value FROM meta WHERE key = 'playlist.id'),
                (SELECT value FROM meta WHERE key = 'playlist.music_id'))
            """)
        try db.execute("INSERT INTO playlists (kind) VALUES ('archive')")
        try db.execute("DELETE FROM meta WHERE key IN ('playlist.id', 'playlist.music_id')")
        try db.execute("""
            CREATE TABLE playlist_tracks_4 (
                playlist TEXT NOT NULL REFERENCES playlists(kind),
                catalog_id TEXT NOT NULL,
                song_id INTEGER NOT NULL REFERENCES songs(id),
                station_id INTEGER REFERENCES stations(id) ON DELETE SET NULL,
                added_at TEXT NOT NULL,
                position_played_at TEXT,
                PRIMARY KEY (playlist, catalog_id)
            )
            """)
        try db.execute("""
            INSERT INTO playlist_tracks_4 (playlist, catalog_id, song_id, station_id, added_at, position_played_at)
            SELECT 'recent', catalog_id, song_id, station_id, added_at, position_played_at FROM playlist_tracks
            ORDER BY rowid
            """)
        try db.execute("DROP TABLE playlist_tracks")
        try db.execute("ALTER TABLE playlist_tracks_4 RENAME TO playlist_tracks")
        try db.execute("CREATE INDEX playlist_tracks_by_station ON playlist_tracks (playlist, station_id, added_at)")
        try db.execute("PRAGMA user_version = 4")
    }

    /// Music.app becomes the only thing that changes the playlists, and the
    /// web API only adds songs to the library, so the API's playlist IDs go.
    /// Music.app had wiped out songs the API added (see docs/design.md), so
    /// every entry is placed again, in play order, which restores them.
    private func migrateToSchemaFive() throws {
        try db.execute("ALTER TABLE playlists DROP COLUMN library_id")
        try db.execute("CREATE TABLE library_requests (catalog_id TEXT PRIMARY KEY, requested_at TEXT NOT NULL)")
        try db.execute("UPDATE playlist_tracks SET position_played_at = NULL")
        try db.execute("PRAGMA user_version = 5")
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

    func station(id: Int64) throws -> Station? {
        try db.query("SELECT * FROM stations WHERE id = ?", [.integer(id)]).first.map(station(from:))
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

    private func station(from row: Row) -> Station {
        Station(
            id: row.int("id")!,
            slug: row.string("slug")!,
            source: row.string("source")!,
            feedID: row.string("feed_id")!,
            name: row.string("name")!,
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
                        WHERE t.playlist = 'recent' AND t.song_id = p.song_id) AS added
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
            UPDATE songs SET status = 'matched', catalog_id = ?, catalog_url = ?, catalog_name = ?,
                catalog_artist = ?, catalog_album = ?, matched_by = ?, resolved_at = ?
            WHERE id = ?
            """,
            [.text(catalog.id), .text(catalog.url), .text(catalog.name), .text(catalog.artistName),
             .text(catalog.albumName), .text(method), .text(iso(date)), .integer(songID)]
        )
    }

    func setCatalogDetails(_ catalog: CatalogSong) throws {
        try db.execute(
            "UPDATE songs SET catalog_name = ?, catalog_artist = ?, catalog_album = ? WHERE catalog_id = ?",
            [.text(catalog.name), .text(catalog.artistName), .text(catalog.albumName), .text(catalog.id)]
        )
    }

    /// Catalog IDs of matched songs saved before schema 2 recorded titles.
    func catalogIDsMissingDetails() throws -> [String] {
        try db.query("SELECT DISTINCT catalog_id FROM songs WHERE status = 'matched' AND catalog_name IS NULL")
            .compactMap { $0.string("catalog_id") }
    }

    /// Puts every automatic match to a catalog song back to be matched again,
    /// once its playlist entries are removed.
    func resetAutoMatches(catalogID: String) throws {
        try db.execute(
            """
            UPDATE songs SET status = 'pending', catalog_id = NULL, catalog_url = NULL, catalog_name = NULL,
                catalog_artist = NULL, catalog_album = NULL, matched_by = NULL, candidates = NULL,
                held_at = NULL, resolved_at = NULL
            WHERE catalog_id = ? AND matched_by = 'auto'
            """,
            [.text(catalogID)]
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
            catalogName: row.string("catalog_name"),
            catalogArtist: row.string("catalog_artist"),
            catalogAlbum: row.string("catalog_album"),
            matchedBy: row.string("matched_by"),
            candidates: candidates,
            heldAt: row.string("held_at").flatMap(parseISODate)
        )
    }

    // MARK: Playlists

    func playlist(_ kind: Playlist.Kind) throws -> Playlist {
        let row = try db.query("SELECT music_id FROM playlists WHERE kind = ?", [.text(kind.rawValue)]).first
        return Playlist(kind: kind, musicID: row?.string("music_id"))
    }

    func setMusicPlaylistID(_ id: String?, for kind: Playlist.Kind) throws {
        try db.execute("UPDATE playlists SET music_id = ? WHERE kind = ?", [id.map(SQLValue.text) ?? .null, .text(kind.rawValue)])
    }

    /// Forgets a playlist's entries, when the playlist was deleted in Music,
    /// so its songs are placed again.
    func forgetEntries(of kind: Playlist.Kind) throws {
        try db.execute("DELETE FROM playlist_tracks WHERE playlist = ?", [.text(kind.rawValue)])
    }

    /// The matched songs played most recently on any station, up to the bound
    /// limit. SQLite takes the bare columns
    /// from the row that has the MAX, so each song's station is the one that
    /// played it last.
    private static let recentSongs = """
        recent AS (
            SELECT s.id AS song_id, s.catalog_id, p.station_id, MAX(p.played_at) AS latest_played
            FROM plays p JOIN songs s ON s.id = p.song_id
            WHERE s.status = 'matched'
            GROUP BY s.catalog_id ORDER BY latest_played DESC, s.catalog_id DESC LIMIT ?
        )
        """

    /// Songs to place at the end of a playlist, in the order of their latest
    /// plays: those among the `limit` most recently played that aren't in it
    /// yet, and entries whose song has played again, on any station, since
    /// the entry was placed.
    func tracksToPlace(in kind: Playlist.Kind, limit: Int) throws -> [TrackToPlace] {
        try db.query(
            """
            WITH \(Self.recentSongs),
            placing AS (
                SELECT r.song_id, r.catalog_id, r.station_id, r.latest_played, 0 AS in_playlist FROM recent r
                WHERE NOT EXISTS (SELECT 1 FROM playlist_tracks t WHERE t.playlist = ? AND t.catalog_id = r.catalog_id)
                UNION ALL
                SELECT t.song_id, t.catalog_id, t.station_id, MAX(p.played_at), 1
                FROM playlist_tracks t
                JOIN songs s ON s.catalog_id = t.catalog_id AND s.status = 'matched'
                JOIN plays p ON p.song_id = s.id
                WHERE t.playlist = ?
                GROUP BY t.catalog_id
                HAVING MAX(p.played_at) > COALESCE(t.position_played_at, '')
            )
            SELECT x.song_id, x.catalog_id, x.station_id, x.latest_played, x.in_playlist,
                s.catalog_name, s.catalog_artist, s.catalog_album, l.requested_at
            FROM placing x JOIN songs s ON s.id = x.song_id
            LEFT JOIN library_requests l ON l.catalog_id = x.catalog_id
            ORDER BY x.latest_played, x.in_playlist, x.song_id
            """,
            [.integer(Int64(limit)), .text(kind.rawValue), .text(kind.rawValue)]
        ).map {
            TrackToPlace(songID: $0.int("song_id")!, catalogID: $0.string("catalog_id")!, stationID: $0.int("station_id"),
                         song: Self.musicAppSong($0), latestPlay: $0.string("latest_played")!,
                         inPlaylist: $0.int("in_playlist") == 1,
                         libraryRequestedAt: $0.string("requested_at").flatMap(parseISODate))
        }
    }

    /// A playlist's entries for songs outside the `limit` most recently
    /// played, least recently placed first.
    func tracksToDrop(from kind: Playlist.Kind, limit: Int) throws -> [TrackToDrop] {
        try db.query(
            """
            WITH \(Self.recentSongs)
            SELECT t.catalog_id, s.catalog_name, s.catalog_artist, s.catalog_album
            FROM playlist_tracks t JOIN songs s ON s.id = t.song_id
            WHERE t.playlist = ? AND t.catalog_id NOT IN (SELECT catalog_id FROM recent)
            ORDER BY t.position_played_at, t.rowid
            """,
            [.integer(Int64(limit)), .text(kind.rawValue)]
        ).map {
            TrackToDrop(catalogID: $0.string("catalog_id")!, song: Self.musicAppSong($0))
        }
    }

    private static func musicAppSong(_ row: Row) -> MusicAppSong? {
        guard let name = row.string("catalog_name"), let artist = row.string("catalog_artist") else { return nil }
        return MusicAppSong(name: name, artist: artist, album: row.string("catalog_album") ?? "")
    }

    /// Records a song placed at the end of a playlist, at its latest play.
    func recordPlaced(_ track: TrackToPlace, in kind: Playlist.Kind, at date: Date) throws {
        try db.execute(
            """
            INSERT INTO playlist_tracks (playlist, catalog_id, song_id, station_id, added_at, position_played_at)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT (playlist, catalog_id) DO UPDATE SET position_played_at = excluded.position_played_at
            """,
            [.text(kind.rawValue), .text(track.catalogID), .integer(track.songID), track.stationID.map(SQLValue.integer) ?? .null,
             .text(iso(date)), .text(track.latestPlay)]
        )
    }

    func setPosition(in kind: Playlist.Kind, catalogID: String, playedAt: String) throws {
        try db.execute(
            "UPDATE playlist_tracks SET position_played_at = ? WHERE playlist = ? AND catalog_id = ?",
            [.text(playedAt), .text(kind.rawValue), .text(catalogID)]
        )
    }

    /// Keeps the first time Radio asked for each song.
    func recordLibraryRequests(_ catalogIDs: [String], at date: Date) throws {
        try db.transaction {
            for id in catalogIDs {
                try db.execute(
                    "INSERT INTO library_requests (catalog_id, requested_at) VALUES (?, ?) ON CONFLICT (catalog_id) DO NOTHING",
                    [.text(id), .text(iso(date))]
                )
            }
        }
    }

    /// The playlists holding a catalog song.
    func playlistsHolding(catalogID: String) throws -> [Playlist.Kind] {
        try db.query("SELECT playlist FROM playlist_tracks WHERE catalog_id = ?", [.text(catalogID)])
            .compactMap { $0.string("playlist").flatMap(Playlist.Kind.init(rawValue:)) }
    }

    func removePlaylistTrack(from kind: Playlist.Kind, catalogID: String) throws {
        try db.execute("DELETE FROM playlist_tracks WHERE playlist = ? AND catalog_id = ?",
                       [.text(kind.rawValue), .text(catalogID)])
    }

    func playlistCount(_ kind: Playlist.Kind) throws -> Int {
        Int(try db.query("SELECT COUNT(*) AS n FROM playlist_tracks WHERE playlist = ?", [.text(kind.rawValue)]).first!.int("n")!)
    }

    /// Songs a station's plays added to "Radio", newest first.
    func recentlyAdded(stationID: Int64, limit: Int) throws -> [AddedTrack] {
        try db.query(
            """
            SELECT t.added_at, s.artist, s.title, s.catalog_url
            FROM playlist_tracks t JOIN songs s ON s.id = t.song_id
            WHERE t.playlist = 'recent' AND t.station_id = ? ORDER BY t.added_at DESC, t.rowid DESC LIMIT ?
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
