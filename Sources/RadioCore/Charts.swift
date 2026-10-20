import Foundation

/// A song as the charts count it. Every song matched to one Apple Music song
/// counts as that song, as on the playlist pages.
struct ChartSong {
    var artist: String
    var title: String
    var url: String?
    var plays: Int
    var latestPlay: Date
    /// The station that played it last.
    var latestStationID: Int64
    var latestStation: String
    /// Each station's plays of it, most first, where a page shows them.
    var stations: [StationPlays] = []
}

/// The `/charts` page.
struct Charts {
    /// The oldest logged play, or nil before any.
    var since: Date?
    /// The last week's most played songs, most first.
    var week: [ChartSong]
    /// The most played songs since `since`, most first.
    var allTime: [ChartSong]
}

/// The `/stats` page, counted over the last week.
struct Stats {
    var stations: [StationStats]
    /// Songs played more in the last two days than the two before, most
    /// gained first.
    var rising: [RisingSong]
    /// Songs played by two or more stations, most stations first.
    var widest: [ChartSong]
    var artists: [ArtistPlays]
}

struct StationStats {
    var stationID: Int64
    var name: String
    var plays: Int
    /// Over the part of the week the station was logged, and at least a day.
    var playsPerDay: Double
    var songs: Int
    /// Songs no other station played this week.
    var onlyHere: Int
    var top: ChartSong?
    /// The average time between the top song's plays, when it has two.
    var topInterval: TimeInterval?
}

struct RisingSong {
    /// With `plays` counting the last two days.
    var song: ChartSong
    /// Plays in the two days before.
    var previous: Int
}

struct ArtistPlays {
    var artist: String
    var plays: Int
    var songs: Int
}

extension Store {
    static let chartLength = 100
    static let week: TimeInterval = 7 * 24 * 60 * 60
    static let risingWindow: TimeInterval = 2 * 24 * 60 * 60

    /// Every play except those of ignored songs, keyed by the song it counts
    /// toward, with that song's Apple Music name when it's matched.
    private static let charted = """
        charted AS (
            SELECT p.station_id, st.name AS station, p.played_at,
                COALESCE(CASE WHEN s.status = 'matched' THEN s.catalog_id END, 'song:' || s.id) AS song_key,
                CASE WHEN s.status = 'matched' THEN COALESCE(s.catalog_artist, s.artist) ELSE s.artist END AS artist,
                CASE WHEN s.status = 'matched' THEN COALESCE(s.catalog_name, s.title) ELSE s.title END AS title,
                CASE WHEN s.status = 'matched' THEN s.catalog_url END AS url
            FROM plays p JOIN songs s ON s.id = p.song_id JOIN stations st ON st.id = p.station_id
            WHERE s.status != 'ignored'
        )
        """

    /// Columns a `ChartSong` reads from a group of `charted` rows. SQLite
    /// takes the bare station columns from the row with the latest play.
    private static let chartColumns = """
        song_key, artist, title, url, COUNT(*) AS plays, MAX(played_at) AS latest_played, station_id, station
        """

    func charts(now: Date) throws -> Charts {
        let since = try db.query("SELECT MIN(played_at) AS since FROM plays").first?.string("since").flatMap(parseISODate)
        let week = try db.query(
            """
            WITH \(Self.charted)
            SELECT \(Self.chartColumns) FROM charted WHERE played_at >= ?
            GROUP BY song_key ORDER BY plays DESC, latest_played DESC LIMIT ?
            """,
            [.text(iso(now - Self.week)), .integer(Int64(Self.chartLength))]
        )
        let allTime = try db.query(
            """
            WITH \(Self.charted)
            SELECT \(Self.chartColumns) FROM charted
            GROUP BY song_key ORDER BY plays DESC, latest_played DESC LIMIT ?
            """,
            [.integer(Int64(Self.chartLength))]
        )
        return Charts(since: since, week: week.map(Self.chartSong),
                      allTime: try withStations(allTime.map { ($0.string("song_key")!, Self.chartSong($0)) }, since: nil))
    }

    func stats(now: Date) throws -> Stats {
        let weekStart = iso(now - Self.week)
        let figures = try db.query(
            """
            WITH \(Self.charted), week AS (SELECT * FROM charted WHERE played_at >= ?),
            spread AS (SELECT song_key, COUNT(DISTINCT station_id) AS stations FROM week GROUP BY song_key)
            SELECT w.station_id, COUNT(*) AS plays, COUNT(DISTINCT w.song_key) AS songs,
                COUNT(DISTINCT CASE WHEN sp.stations = 1 THEN w.song_key END) AS only_here,
                (SELECT MIN(played_at) FROM plays WHERE station_id = w.station_id) AS first_played
            FROM week w JOIN spread sp ON sp.song_key = w.song_key
            GROUP BY w.station_id
            """,
            [.text(weekStart)]
        )
        let tops = try db.query(
            """
            WITH \(Self.charted),
            per AS (
                SELECT \(Self.chartColumns), MIN(played_at) AS first_in_week FROM charted WHERE played_at >= ?
                GROUP BY station_id, song_key
            )
            SELECT * FROM (
                SELECT *, ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY plays DESC, latest_played DESC) AS place FROM per
            ) WHERE place = 1
            """,
            [.text(weekStart)]
        )
        let stations = try stations().map { station in
            let row = figures.first { $0.int("station_id") == station.id }
            let plays = Int(row?.int("plays") ?? 0)
            let songs = Int(row?.int("songs") ?? 0)
            let logged = max(now - Self.week, row?.string("first_played").flatMap(parseISODate) ?? now)
            var stats = StationStats(
                stationID: station.id, name: station.name, plays: plays,
                playsPerDay: Double(plays) / max(now.timeIntervalSince(logged) / 86_400, 1),
                songs: songs, onlyHere: Int(row?.int("only_here") ?? 0)
            )
            if let top = tops.first(where: { $0.int("station_id") == station.id }) {
                let song = Self.chartSong(top)
                stats.top = song
                if song.plays > 1, let first = top.string("first_in_week").flatMap(parseISODate) {
                    stats.topInterval = song.latestPlay.timeIntervalSince(first) / Double(song.plays - 1)
                }
            }
            return stats
        }
        let risingStart = now - Self.risingWindow
        let rising = try db.query(
            """
            WITH \(Self.charted)
            SELECT \(Self.chartColumns), SUM(played_at >= ?) AS recent FROM charted WHERE played_at >= ?
            GROUP BY song_key HAVING recent > plays - recent
            ORDER BY 2 * recent - plays DESC, recent DESC, latest_played DESC LIMIT 10
            """,
            [.text(iso(risingStart)), .text(iso(risingStart - Self.risingWindow))]
        ).map { row in
            var song = Self.chartSong(row)
            let previous = song.plays - Int(row.int("recent")!)
            song.plays -= previous
            return RisingSong(song: song, previous: previous)
        }
        let widest = try db.query(
            """
            WITH \(Self.charted)
            SELECT \(Self.chartColumns), COUNT(DISTINCT station_id) AS station_count FROM charted WHERE played_at >= ?
            GROUP BY song_key HAVING station_count >= 2
            ORDER BY station_count DESC, plays DESC, latest_played DESC LIMIT 15
            """,
            [.text(weekStart)]
        )
        let artists = try db.query(
            """
            WITH \(Self.charted)
            SELECT artist, COUNT(*) AS plays, COUNT(DISTINCT song_key) AS songs FROM charted WHERE played_at >= ?
            GROUP BY artist COLLATE NOCASE ORDER BY plays DESC, artist LIMIT 10
            """,
            [.text(weekStart)]
        ).map { ArtistPlays(artist: $0.string("artist")!, plays: Int($0.int("plays")!), songs: Int($0.int("songs")!)) }
        return Stats(
            stations: stations, rising: rising,
            widest: try withStations(widest.map { ($0.string("song_key")!, Self.chartSong($0)) }, since: now - Self.week),
            artists: artists
        )
    }

    /// The songs with each station's plays of them since `since`, most
    /// first, or since logging began.
    private func withStations(_ songs: [(key: String, song: ChartSong)], since: Date?) throws -> [ChartSong] {
        guard !songs.isEmpty else { return [] }
        var stations: [String: [StationPlays]] = [:]
        let keys = Set(songs.map(\.key))
        for row in try db.query(
            """
            WITH \(Self.charted)
            SELECT song_key, station_id, station, COUNT(*) AS plays, MAX(played_at) AS latest_played FROM charted
            WHERE played_at >= ? GROUP BY song_key, station_id ORDER BY plays DESC, latest_played DESC
            """,
            [.text(iso(since ?? .distantPast))]
        ) where keys.contains(row.string("song_key")!) {
            stations[row.string("song_key")!, default: []].append(StationPlays(
                stationID: row.int("station_id")!, name: row.string("station")!, plays: Int(row.int("plays")!),
                latestPlay: parseISODate(row.string("latest_played")!)!
            ))
        }
        return songs.map { key, song in
            var song = song
            song.stations = stations[key] ?? []
            return song
        }
    }

    private static func chartSong(_ row: Row) -> ChartSong {
        ChartSong(
            artist: row.string("artist")!, title: row.string("title")!, url: row.string("url"),
            plays: Int(row.int("plays")!), latestPlay: parseISODate(row.string("latest_played")!)!,
            latestStationID: row.int("station_id")!, latestStation: row.string("station")!
        )
    }
}
