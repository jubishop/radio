import Foundation

/// How often the user played and skipped a song in Music, in all time:
/// the Plays and Skips of every library track with the song's title and
/// artist, such as its clean and explicit copies.
struct Listens: Equatable {
    var plays: Int
    var skips: Int

    /// What decides which song leaves "Radio" first. The user chose to count
    /// skips as plays on 2026-10-20.
    var total: Int { plays + skips }
}

/// A song in "Radio" or one a station played that could enter it.
struct RadioContender {
    var catalogID: String
    /// The song's latest play on any station, as stored, which sorts in
    /// time order.
    var latestPlay: String
    var listens: Int

    /// True when this song leaves a full "Radio" before `other`: the one
    /// the user played and skipped most, then the one the stations played
    /// least recently.
    func dropsBefore(_ other: RadioContender) -> Bool {
        if listens != other.listens { return listens > other.listens }
        if latestPlay != other.latestPlay { return latestPlay < other.latestPlay }
        return catalogID < other.catalogID
    }
}

/// Chooses the songs in "Radio". Since 2026-10-20, a song entering a full
/// "Radio" pushes out the song the user played and skipped most in Music,
/// the least recently played among ties, and a song the user played more
/// than every song there stays out. That applies to new songs, songs
/// already in the library, and songs a station plays again after they
/// left. Radio remembers its choices, so a song that left or stayed out
/// comes back into contention only when a station plays it again. "Radio
/// Archive" still keeps the most recently played songs.
extension Radio {
    /// Records the user's plays and skips of each matched song from
    /// Music.app. After a failure, they stay as last read, and the rest of
    /// the sync skips Music.app.
    func readListens(music: inout MusicAppSession) async throws {
        guard let musicApp, music.failure == nil else { return }
        let tracks: [TrackListens]
        do {
            tracks = try await musicApp.listens()
        } catch {
            music.failure = String(describing: error)
            return
        }
        music.succeeded = true
        var byTitle: [String: Listens] = [:]
        for track in tracks {
            let key = Self.listensKey(track.name, track.artist)
            let sum = byTitle[key] ?? Listens(plays: 0, skips: 0)
            byTitle[key] = Listens(plays: sum.plays + track.plays, skips: sum.skips + track.skips)
        }
        var listens: [String: Listens] = [:]
        for song in try store.catalogTitles() {
            listens[song.catalogID] = byTitle[Self.listensKey(song.name, song.artist)]
        }
        try store.recordListens(listens)
    }

    /// Music.app compares titles and artists ignoring case.
    private static func listensKey(_ name: String, _ artist: String) -> String {
        name.lowercased() + "\u{1F}" + artist.lowercased()
    }

    /// Lets each song a station played since Radio last chose contend for
    /// "Radio", in play order. The first time, it chooses the songs "Radio"
    /// held before, the most recently played, so upgrading changes nothing.
    func chooseRadioSongs() throws {
        if try !store.hasRadioChoices() { try store.seedRadioChoices(limit: playlistLimit) }
        try store.unchooseUnmatchedSongs()
        let (current, newcomers) = try store.radioContenders()
        var chosen = current
        var left: [RadioContender] = []
        func makeRoom() {
            while chosen.count > playlistLimit {
                let worst = chosen.indices.max { chosen[$1].dropsBefore(chosen[$0]) }!
                left.append(chosen.remove(at: worst))
            }
        }
        makeRoom()
        for newcomer in newcomers {
            chosen.append(newcomer)
            makeRoom()
        }
        let currentIDs = Set(current.map(\.catalogID))
        for song in chosen where !currentIDs.contains(song.catalogID) {
            try store.recordRadioChoice(catalogID: song.catalogID, chosen: true, playedAt: song.latestPlay)
        }
        for song in left {
            try store.recordRadioChoice(catalogID: song.catalogID, chosen: false, playedAt: song.latestPlay)
        }
    }

    /// The song the next new one would push out of "Radio", once it's full.
    func nextToDropFromRadio() throws -> String? {
        let chosen = try store.radioContenders().chosen
        guard chosen.count >= playlistLimit else { return nil }
        return chosen.max { $1.dropsBefore($0) }?.catalogID
    }
}

extension Store {
    /// Each matched song's title and artist as Apple Music has them.
    func catalogTitles() throws -> [(catalogID: String, name: String, artist: String)] {
        try db.query(
            """
            SELECT catalog_id, catalog_name, catalog_artist FROM songs
            WHERE status = 'matched' AND catalog_name IS NOT NULL AND catalog_artist IS NOT NULL
            GROUP BY catalog_id
            """
        ).map { ($0.string("catalog_id")!, $0.string("catalog_name")!, $0.string("catalog_artist")!) }
    }

    /// Replaces every song's plays and skips; a song missing from `listens`
    /// has none.
    func recordListens(_ listens: [String: Listens]) throws {
        try db.transaction {
            try db.execute("DELETE FROM listens")
            for (catalogID, song) in listens {
                try db.execute(
                    "INSERT INTO listens (catalog_id, plays, skips) VALUES (?, ?, ?)",
                    [.text(catalogID), .integer(Int64(song.plays)), .integer(Int64(song.skips))]
                )
            }
        }
    }

    func hasRadioChoices() throws -> Bool {
        try !db.query("SELECT 1 FROM radio_choices LIMIT 1").isEmpty
    }

    /// Chooses the `limit` most recently played songs, as "Radio" held them
    /// before Radio made choices, and passes over the rest at their latest
    /// play.
    func seedRadioChoices(limit: Int) throws {
        try db.execute(
            """
            INSERT INTO radio_choices (catalog_id, chosen, played_at)
            SELECT catalog_id, rank <= ?, latest_played FROM (
                SELECT s.catalog_id, MAX(p.played_at) AS latest_played,
                    ROW_NUMBER() OVER (ORDER BY MAX(p.played_at) DESC, s.catalog_id DESC) AS rank
                FROM plays p JOIN songs s ON s.id = p.song_id
                WHERE s.status = 'matched'
                GROUP BY s.catalog_id
            )
            """,
            [.integer(Int64(limit))]
        )
    }

    /// Songs sent back to review leave "Radio" as of their latest play, so
    /// matching one again doesn't bring it back without a new play.
    func unchooseUnmatchedSongs() throws {
        try db.execute(
            """
            UPDATE radio_choices SET chosen = 0, played_at = COALESCE(
                (SELECT MAX(p.played_at) FROM plays p JOIN songs s ON s.id = p.song_id WHERE s.catalog_id = radio_choices.catalog_id),
                played_at)
            WHERE chosen = 1 AND catalog_id NOT IN (SELECT catalog_id FROM songs WHERE status = 'matched' AND catalog_id IS NOT NULL)
            """
        )
    }

    /// The songs Radio chose for "Radio", and the songs a station played
    /// since Radio last passed them over, in play order.
    func radioContenders() throws -> (chosen: [RadioContender], newcomers: [RadioContender]) {
        var chosen: [RadioContender] = []
        var newcomers: [RadioContender] = []
        for row in try db.query(
            """
            WITH latest AS (
                SELECT s.catalog_id, MAX(p.played_at) AS latest_played
                FROM plays p JOIN songs s ON s.id = p.song_id
                WHERE s.status = 'matched'
                GROUP BY s.catalog_id
            )
            SELECT l.catalog_id, l.latest_played, c.chosen, COALESCE(x.plays + x.skips, 0) AS listens
            FROM latest l
            LEFT JOIN radio_choices c ON c.catalog_id = l.catalog_id
            LEFT JOIN listens x ON x.catalog_id = l.catalog_id
            WHERE c.chosen = 1 OR l.latest_played > COALESCE(c.played_at, '')
            ORDER BY l.latest_played, l.catalog_id
            """
        ) {
            let song = RadioContender(catalogID: row.string("catalog_id")!, latestPlay: row.string("latest_played")!,
                                      listens: Int(row.int("listens")!))
            if row.int("chosen") == 1 { chosen.append(song) } else { newcomers.append(song) }
        }
        return (chosen, newcomers)
    }

    func recordRadioChoice(catalogID: String, chosen: Bool, playedAt: String) throws {
        try db.execute(
            """
            INSERT INTO radio_choices (catalog_id, chosen, played_at) VALUES (?, ?, ?)
            ON CONFLICT (catalog_id) DO UPDATE SET chosen = excluded.chosen, played_at = excluded.played_at
            """,
            [.text(catalogID), .integer(chosen ? 1 : 0), .text(playedAt)]
        )
    }
}
