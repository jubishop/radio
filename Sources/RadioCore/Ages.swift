import Foundation

/// How old songs were when the stations played them, counting plays of songs
/// with an Apple Music release date. The user asked for song ages on
/// 2026-10-22.
struct SongAges {
    var plays: Int
    var averageYears: Double
    /// The release year of the middle play, in release order.
    var medianYear: Int
    /// Shares of `plays`, from 0 to 1.
    var underAYear: Double
    var tenYearsOrMore: Double
    /// Plays by release decade, in the order of `Decades.labels`.
    var decades: [Int]
    /// The 24 hours of the day in the Mac's time zone, from midnight.
    var hours: [HourAges]
    var oldest: ChartSong?
}

/// The plays in one hour of the day and their songs' total age.
struct HourAges {
    var plays = 0
    var years = 0.0

    var averageYears: Double? { plays > 0 ? years / Double(plays) : nil }
}

/// The five release decades the charts show: everything before the
/// fourth-latest decade, then each decade up to the current one, such as
/// "Before 1990" to "2020s" in 2026.
struct Decades {
    let first: Int

    init(now: Date) {
        first = Calendar.utc.component(.year, from: now) / 10 * 10 - 30
    }

    var labels: [String] {
        ["Before \(first)"] + (0..<4).map { "\(first + $0 * 10)s" }
    }

    func index(ofYear year: Int) -> Int {
        year < first ? 0 : min(4, (year - first) / 10 + 1)
    }
}

/// A song released recently that the stations played.
struct NewRelease {
    var song: ChartSong
    var released: Date
    /// The first play among the stations Radio was logging on the release
    /// day, when one of them played it.
    var first: StationPlays?
}

/// How many recent releases a station played, and how many it played first.
struct NewReleaseCounts {
    var stationID: Int64
    var name: String
    var played = 0
    var first = 0
}

extension Calendar {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
}

/// The day a release date names, at midnight UTC. Apple sometimes gives only
/// a year, which counts as its middle, or a year and month, which counts as
/// the month's middle.
func releaseDay(_ text: String) -> Date? {
    let parts = text.split(separator: "-").map { Int($0) }
    guard let year = parts.first ?? nil, parts.allSatisfy({ $0 != nil }) else { return nil }
    let components = switch parts.count {
    case 1: DateComponents(year: year, month: 7, day: 1)
    case 2: DateComponents(year: year, month: parts[1], day: 15)
    default: DateComponents(year: year, month: parts[1], day: parts[2])
    }
    return Calendar.utc.date(from: components)
}

extension Store {
    static let year: TimeInterval = 365.25 * 24 * 60 * 60
    /// "New releases" lists songs released this recently.
    static let newReleaseWindow: TimeInterval = 60 * 24 * 60 * 60
    static let deepCutCount = 10

    /// The song ages of each station's plays since `since`, by station, and
    /// of every station's together under the key nil. A station without a
    /// dated play has none.
    func songAges(since: Date, now: Date) throws -> [Int64?: SongAges] {
        let rows = try db.query(
            """
            WITH \(Self.charted)
            SELECT song_key, station_id, played_at, released FROM charted
            WHERE played_at >= ? AND released IS NOT NULL
            """,
            [.text(iso(since))]
        )
        var plays: [Int64?: [(year: Int, age: Double, hour: Int, released: String, key: String)]] = [:]
        for row in rows {
            guard let released = row.string("released"), let day = releaseDay(released),
                  let playedAt = parseISODate(row.string("played_at")!) else { continue }
            let play = (year: Calendar.utc.component(.year, from: day), age: max(0, playedAt.timeIntervalSince(day)) / Self.year,
                        hour: Calendar.current.component(.hour, from: playedAt), released: released, key: row.string("song_key")!)
            plays[row.int("station_id")!, default: []].append(play)
            plays[nil, default: []].append(play)
        }
        let decades = Decades(now: now)
        var ages: [Int64?: SongAges] = [:]
        for (station, list) in plays {
            var byDecade = Array(repeating: 0, count: 5)
            var hours = Array(repeating: HourAges(), count: 24)
            for play in list {
                byDecade[decades.index(ofYear: play.year)] += 1
                hours[play.hour].plays += 1
                hours[play.hour].years += play.age
            }
            let count = Double(list.count)
            let oldest = list.min { ($0.released, $0.key) < ($1.released, $1.key) }!
            ages[station] = SongAges(
                plays: list.count,
                averageYears: list.map(\.age).reduce(0, +) / count,
                medianYear: list.map(\.year).sorted()[(list.count - 1) / 2],
                underAYear: Double(list.count { $0.age < 1 }) / count,
                tenYearsOrMore: Double(list.count { $0.age >= 10 }) / count,
                decades: byDecade,
                hours: hours,
                oldest: try chartSongs(keys: [oldest.key], since: since).first
            )
        }
        return ages
    }

    /// The oldest songs played since `since`, oldest first, with each
    /// station's plays.
    func deepCuts(since: Date) throws -> [ChartSong] {
        let rows = try db.query(
            """
            WITH \(Self.charted)
            SELECT \(Self.chartColumns) FROM charted WHERE played_at >= ? AND released IS NOT NULL
            GROUP BY song_key ORDER BY released, plays DESC, latest_played DESC LIMIT ?
            """,
            [.text(iso(since)), .integer(Int64(Self.deepCutCount))]
        )
        return try withStations(rows.map { ($0.string("song_key")!, Self.chartSong($0)) }, since: since)
    }

    /// Songs released in the last 60 days that the stations played, newest
    /// first, with every station's plays of them. A year alone isn't recent
    /// enough to count. Each station's first logged play shows when Radio
    /// began logging it, and a song's first play counts only the stations
    /// logged by its release day, since another could have played it
    /// before Radio was listening.
    func newReleases(now: Date) throws -> (songs: [NewRelease], stations: [NewReleaseCounts]) {
        let earliest = (now - Self.newReleaseWindow).formatted(.iso8601.year().month().day())
        let rows = try db.query(
            """
            WITH \(Self.charted)
            SELECT \(Self.chartColumns) FROM charted WHERE released >= ?
            GROUP BY song_key ORDER BY released DESC, plays DESC, latest_played DESC
            """,
            [.text(earliest)]
        )
        let songs = try withStations(rows.map { ($0.string("song_key")!, Self.chartSong($0)) }, since: nil)
        let loggedSince = Dictionary(uniqueKeysWithValues: try db.query(
            "SELECT station_id, MIN(played_at) AS first_played FROM plays GROUP BY station_id"
        ).map { ($0.int("station_id")!, parseISODate($0.string("first_played")!)!) })
        var firsts: [String: [(stationID: Int64, playedAt: Date)]] = [:]
        for row in try db.query(
            """
            WITH \(Self.charted)
            SELECT song_key, station_id, MIN(played_at) AS first_played FROM charted WHERE released >= ?
            GROUP BY song_key, station_id
            """,
            [.text(earliest)]
        ) {
            firsts[row.string("song_key")!, default: []].append((row.int("station_id")!, parseISODate(row.string("first_played")!)!))
        }
        var counts = Dictionary(uniqueKeysWithValues: try stations().map {
            ($0.id, NewReleaseCounts(stationID: $0.id, name: $0.name))
        })
        var releases: [NewRelease] = []
        for (row, song) in zip(rows, songs) {
            guard let released = song.releaseDate.flatMap(releaseDay) else { continue }
            let plays = firsts[row.string("song_key")!] ?? []
            let first = plays.filter { play in loggedSince[play.stationID].map { $0 <= released } ?? false }
                .min { $0.playedAt < $1.playedAt }
            for play in plays { counts[play.stationID]?.played += 1 }
            if let first { counts[first.stationID]?.first += 1 }
            releases.append(NewRelease(song: song, released: released, first: first.flatMap { first in
                song.stations.first { $0.stationID == first.stationID }.map {
                    StationPlays(stationID: $0.stationID, name: $0.name, plays: 1, latestPlay: first.playedAt)
                }
            }))
        }
        return (releases, counts.values.sorted { $0.stationID < $1.stationID })
    }

    /// The songs with these keys, played since `since`, with each station's
    /// plays.
    private func chartSongs(keys: [String], since: Date) throws -> [ChartSong] {
        let rows = try db.query(
            """
            WITH \(Self.charted)
            SELECT \(Self.chartColumns) FROM charted
            WHERE played_at >= ? AND song_key IN (\(keys.map { _ in "?" }.joined(separator: ", ")))
            GROUP BY song_key
            """,
            [.text(iso(since))] + keys.map(SQLValue.text)
        )
        return rows.map(Self.chartSong)
    }

    /// How many songs each pair of stations both played since `since`, by
    /// station pair, with each station's own count for the pair of it and
    /// itself.
    func sharedSongs(since: Date) throws -> [Int64: [Int64: Int]] {
        var shared: [Int64: [Int64: Int]] = [:]
        for row in try db.query(
            """
            WITH \(Self.charted), heard AS (SELECT DISTINCT station_id, song_key FROM charted WHERE played_at >= ?)
            SELECT a.station_id AS a, b.station_id AS b, COUNT(*) AS songs
            FROM heard a JOIN heard b ON a.song_key = b.song_key GROUP BY a.station_id, b.station_id
            """,
            [.text(iso(since))]
        ) {
            shared[row.int("a")!, default: [:]][row.int("b")!] = Int(row.int("songs")!)
        }
        return shared
    }
}
