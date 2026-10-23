import Foundation

/// The song-age parts of the stats page, which the user asked for on
/// 2026-10-22: each station's song ages, decades, ages by hour, new
/// releases, deep cuts, and shared songs. Each chart's values also appear in
/// a table, and each mark shows its value on hover or focus. The colors were
/// checked with the data-visualization palette validator on 2026-10-22; see
/// docs/design.md.
extension Pages {
    /// An hour with fewer plays than this shows no age, since a few songs
    /// would swing it.
    static let minimumHourPlays = 10

    /// Such as " <span class="year">2003</span>", or nothing without a date.
    static func year(_ releaseDate: String?) -> String {
        yearTag(releaseDate).map { " " + $0 } ?? ""
    }

    static func yearTag(_ releaseDate: String?) -> String? {
        releaseDate.map { "<span class=\"year\">\(escape(String($0.prefix(4))))</span>" }
    }

    /// Such as "25%".
    static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded()))%"
    }

    /// A station card's song ages.
    static func songAges(_ ages: SongAges?) -> String {
        guard let ages else { return "<p class=\"empty\">No release dates this week.</p>" }
        var html = "<h3>Song ages</h3><dl class=\"figures\">"
            + "<div><dt>Average age</dt><dd>\(decimal(ages.averageYears, digits: 1)) years</dd></div>"
            + "<div><dt>Median year</dt><dd>\(ages.medianYear)</dd></div>"
            + "<div><dt>Under a year old</dt><dd>\(percent(ages.underAYear))</dd></div>"
            + "<div><dt>10+ years old</dt><dd>\(percent(ages.tenYearsOrMore))</dd></div></dl>"
        if let oldest = ages.oldest {
            let year = oldest.releaseDate.map { " · \(escape(String($0.prefix(4))))" } ?? ""
            html += "<p>Oldest song: \(link(oldest.url, "\(oldest.artist) – \(oldest.title)"))\(year)</p>"
        }
        return html
    }

    /// The stations with dated songs this week, then every station together.
    private static func ageRows(_ stats: Stats) -> [(name: String, key: String, ages: SongAges)] {
        stats.stations.compactMap { station in
            station.ages.map { (station.name, color(ofStation: station.stationID), $0) }
        } + (stats.ages.map { [("All stations", "", $0)] } ?? [])
    }

    /// A 100% bar for each station of its plays by release decade, in one
    /// blue ramp, darker for older decades in light mode and lighter in
    /// dark mode, with a label inside each segment wide enough for one.
    static func decades(_ stats: Stats) -> String {
        var html = "<section><h2>Decades</h2>"
            + "<p class=\"meta\">Each station's plays this week by the decade its songs came out.</p>"
        let rows = ageRows(stats)
        guard !rows.isEmpty else { return html + "<p class=\"empty\">No release dates this week.</p></section>" }
        html += "<ul class=\"legend\">" + stats.decades.enumerated().map {
            "<li><span class=\"swatch d\($0.offset)\"></span>\(escape($0.element))</li>"
        }.joined() + "</ul><div class=\"bars\">"
        for row in rows {
            let decades = row.ages.decades.enumerated().filter { $0.element > 0 }
            let total = Double(row.ages.plays)
            let segments = decades.map { index, plays in
                let share = Double(plays) / total
                let tip = "\(percent(share)) · \(stats.decades[index]) · \(count(plays, "play"))"
                return "<span class=\"seg d\(index)\" style=\"flex-grow: \(plays)\" tabindex=\"0\" data-tip=\"\(escape(tip))\">"
                    + "\(share >= 0.12 ? percent(share) : "")</span>"
            }.joined()
            let summary = row.name + ": " + decades.map { "\(stats.decades[$0.offset]) \(percent(Double($0.element) / total))" }
                .joined(separator: ", ")
            html += "<div class=\"bar-row\"><span class=\"key \(row.key)\">\(escape(row.name))</span>"
                + "<div class=\"bar\" role=\"img\" aria-label=\"\(escape(summary))\">\(segments)</div></div>"
        }
        html += "</div><details><summary>Table</summary><div class=\"scroll\"><table><thead><tr><th>Station</th>"
            + stats.decades.map { "<th>\(escape($0))</th>" }.joined() + "</tr></thead><tbody>"
        for row in rows {
            html += "<tr><th>\(escape(row.name))</th>" + row.ages.decades.map {
                "<td>\($0) (\(percent(Double($0) / Double(row.ages.plays))))</td>"
            }.joined() + "</tr>"
        }
        return html + "</tbody></table></div></details></section>"
    }

    /// Such as "12 AM" or "3 PM".
    private static func hourName(_ hour: Int) -> String {
        "\(hour % 12 == 0 ? 12 : hour % 12) \(hour < 12 ? "AM" : "PM")"
    }

    /// Such as "12a" or "3p", for the heatmap's columns.
    private static func shortHourName(_ hour: Int) -> String {
        "\(hour % 12 == 0 ? 12 : hour % 12)\(hour < 12 ? "a" : "p")"
    }

    /// The heat class for how much older (o) or newer (n) an hour ran than
    /// the station's average, in steps at 0.5, 1.5, 3, and 5 years; within
    /// half a year it's the neutral midpoint.
    private static func step(_ years: Double) -> String {
        let size = abs(years)
        guard size >= 0.5 else { return "m" }
        return (years > 0 ? "o" : "n") + (size < 1.5 ? "1" : size < 3 ? "2" : size < 5 ? "3" : "4")
    }

    /// A heatmap of each station's hours, in a diverging scale around its
    /// weekly average: blue for newer songs, orange for older, and gray
    /// within half a year. Hours are in the Mac's time zone.
    static func hours(_ stats: Stats) -> String {
        let zone = TimeZone.current.localizedName(for: .generic, locale: Locale(identifier: "en_US")) ?? TimeZone.current.identifier
        var html = "<section><h2>Song age by hour</h2><p class=\"meta\">How much older or newer each station's songs ran in "
            + "each hour of the day this week than its average, in \(escape(zone)). An hour needs \(minimumHourPlays) plays.</p>"
        let rows = ageRows(stats).filter { !$0.key.isEmpty }
        guard !rows.isEmpty else { return html + "<p class=\"empty\">No release dates this week.</p></section>" }
        html += "<div class=\"scale\"><span class=\"meta\">Newer</span>"
            + ["n4", "n3", "n2", "n1", "m", "o1", "o2", "o3", "o4"].map { "<span class=\"cell \($0)\"></span>" }.joined()
            + "<span class=\"meta\">Older</span><span class=\"cell none\"></span><span class=\"meta\">Too few plays</span></div>"
        html += "<div class=\"scroll\"><div class=\"heat\"><span></span>" + (0..<24).map { hour in
            "<span class=\"hour\">\(hour % 3 == 0 ? shortHourName(hour) : "")</span>"
        }.joined()
        for row in rows {
            html += "<span class=\"key \(row.key)\">\(escape(row.name))</span>"
            for (hour, ages) in row.ages.hours.enumerated() {
                guard ages.plays >= minimumHourPlays, let average = ages.averageYears else {
                    let tip = ages.plays == 0 ? "No plays · \(hourName(hour))" : "Too few plays · \(hourName(hour)) · \(count(ages.plays, "play"))"
                    html += "<span class=\"cell none\" tabindex=\"0\" data-tip=\"\(tip)\"></span>"
                    continue
                }
                let difference = average - row.ages.averageYears
                let gap = decimal(abs(difference), digits: 1)
                let relative = gap == decimal(0, digits: 1) ? "about average" : "\(gap) \(difference > 0 ? "older" : "newer") than average"
                let tip = "\(decimal(average, digits: 1)) years, \(relative) · \(hourName(hour)) · \(count(ages.plays, "play"))"
                html += "<span class=\"cell \(step(difference))\" tabindex=\"0\" data-tip=\"\(tip)\"></span>"
            }
        }
        html += "</div></div><details><summary>Table</summary><p class=\"meta\">Average song age in years.</p>"
            + "<div class=\"scroll\"><table><thead><tr><th>Hour</th>" + rows.map { "<th>\(escape($0.name))</th>" }.joined()
            + "</tr></thead><tbody>"
        for hour in 0..<24 {
            html += "<tr><th>\(hourName(hour))</th>" + rows.map { row in
                let ages = row.ages.hours[hour]
                return "<td>\(ages.plays >= minimumHourPlays ? ages.averageYears.map { decimal($0, digits: 1) } ?? "" : "")</td>"
            }.joined() + "</tr>"
        }
        return html + "</tbody></table></div></details></section>"
    }

    /// Such as "2 days after release" or "the day it came out".
    private static func lag(from released: Date, to played: Date) -> String {
        let days = Int((played.timeIntervalSince(released) / 86_400).rounded(.down))
        if days == 0 { return "the day it came out" }
        return days > 0 ? "\(count(days, "day")) after release" : "\(count(-days, "day")) before release"
    }

    static func newReleases(_ stats: Stats) -> String {
        var html = "<section><h2>New releases</h2><p class=\"meta\">Songs released in the last 60 days that the stations played, "
            + "newest first. A first play counts only the stations Radio was logging on the release day.</p>"
        guard !stats.newReleases.isEmpty else { return html + "<p class=\"empty\">No new releases yet.</p></section>" }
        let day = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day()
        html += "<ol>"
        for release in stats.newReleases {
            let song = release.song
            let first = release.first.map {
                " <span class=\"meta\">· first on</span> \(tag(stationID: $0.stationID, name: $0.name)) "
                    + "<span class=\"meta\">\(lag(from: release.released, to: $0.latestPlay))</span>"
            } ?? ""
            html += "<li><time>\(escape(release.released.formatted(day)))</time> \(link(song.url, "\(song.artist) – \(song.title)")) "
                + "<span class=\"meta\">\(count(song.plays, "play"))</span> \(song.stations.map(tag).joined(separator: " "))\(first)</li>"
        }
        html += "</ol><div class=\"scroll\"><table class=\"counts\"><thead><tr><th>Station</th><th>New releases</th><th>Played first</th></tr>"
            + "</thead><tbody>"
        for station in stats.newReleaseCounts {
            html += "<tr><th>\(escape(station.name))</th><td>\(station.played)</td><td>\(station.first)</td></tr>"
        }
        return html + "</tbody></table></div></section>"
    }

    static func deepCuts(_ stats: Stats) -> String {
        "<section><h2>Deep cuts</h2><p class=\"meta\">The oldest songs the stations played this week.</p>"
            + ranked(stats.deepCuts, empty: "No release dates this week.") { song in
                "\(yearTag(song.releaseDate) ?? "") \(link(song.url, "\(song.artist) – \(song.title)")) "
                    + "<span class=\"meta\">\(count(song.plays, "play"))</span> " + song.stations.map(tag).joined(separator: " ")
            } + "</section>"
    }

    /// A table of the songs each pair of stations shared, shaded in one
    /// blue by how many, with each station's own count on the diagonal.
    static func sharedSongs(_ stats: Stats) -> String {
        let stations = stats.stations.filter { $0.plays > 0 }
        var html = "<section><h2>Shared songs</h2><p class=\"meta\">How many songs each pair of stations both played this week; "
            + "darker cells share more. The diagonal is each station's own count.</p>"
        let most = stations.flatMap { a in stations.filter { $0.stationID != a.stationID }.map { stats.shared[a.stationID]?[$0.stationID] ?? 0 } }
            .max() ?? 0
        html += "<div class=\"scroll\"><table class=\"shared-songs\"><thead><tr><th></th>"
            + stations.map { "<th>\(escape($0.name))</th>" }.joined() + "</tr></thead><tbody>"
        for a in stations {
            html += "<tr><th>\(escape(a.name))</th>" + stations.map { b in
                let songs = stats.shared[a.stationID]?[b.stationID] ?? 0
                if a.stationID == b.stationID { return "<td class=\"self\">\(songs)</td>" }
                let share = songs == 0 ? 0 : 8 + Int((52 * Double(songs) / Double(max(most, 1))).rounded())
                return "<td class=\"shared\" style=\"--share: \(share)%\">\(songs)</td>"
            }.joined() + "</tr>"
        }
        return html + "</tbody></table></div></section>"
    }

    /// The charts' styles: the decade ramp and its label inks, the heat
    /// scale's midpoint and arms, and the shared songs' blue.
    static let chartStyles = """
        :root { --d0: #104281; --d1: #1c5cab; --d2: #2a78d6; --d3: #5598e7; --d4: #86b6ef;
          --i0: #fff; --i1: #fff; --i2: #fff; --i3: #fff; --i4: #0b0b0b;
          --mid: #f0efec; --n1: #c0d2e9; --n2: #90b5e4; --n3: #6097de; --n4: #2a78d6;
          --o1: #f3cfc0; --o2: #f3af95; --o3: #f18d68; --o4: #eb6834; --seq: #2a78d6; }
        @media (prefers-color-scheme: dark) { :root { --d0: #9ec5f4; --d1: #6da7ec; --d2: #3987e5; --d3: #256abf; --d4: #184f95;
          --i0: #0b0b0b; --i1: #0b0b0b; --i2: #fff; --i3: #fff; --i4: #fff;
          --mid: #383835; --n1: #3c4c5e; --n2: #3e6089; --n3: #3d73b6; --n4: #3987e5;
          --o1: #5f4336; --o2: #874c35; --o3: #af5330; --o4: #d95926; --seq: #3987e5; } }
        .d0 { --fill: var(--d0); --ink: var(--i0); } .d1 { --fill: var(--d1); --ink: var(--i1); } .d2 { --fill: var(--d2); --ink: var(--i2); }
        .d3 { --fill: var(--d3); --ink: var(--i3); } .d4 { --fill: var(--d4); --ink: var(--i4); }
        .m { --fill: var(--mid); } .n1 { --fill: var(--n1); } .n2 { --fill: var(--n2); } .n3 { --fill: var(--n3); } .n4 { --fill: var(--n4); }
        .o1 { --fill: var(--o1); } .o2 { --fill: var(--o2); } .o3 { --fill: var(--o3); } .o4 { --fill: var(--o4); }
        .year { color: var(--muted); font-size: 13px; font-variant-numeric: tabular-nums; }
        .key { font-size: 14px; white-space: nowrap; }
        .key::before { content: ""; display: inline-block; width: 8px; height: 8px; margin-right: 6px; border-radius: 50%;
          background: var(--station, var(--muted)); vertical-align: middle; }
        .legend { display: flex; flex-wrap: wrap; gap: 4px 16px; margin: 8px 0 12px; padding: 0; list-style: none; }
        .legend li { display: flex; align-items: center; gap: 6px; padding: 0; border: 0; font-size: 13px; color: var(--muted); }
        .swatch { width: 12px; height: 12px; border-radius: 3px; background: var(--fill); }
        .bars { display: grid; gap: 10px; }
        .bar-row { display: grid; grid-template-columns: 9em 1fr; align-items: center; gap: 12px; }
        @media (max-width: 720px) { .bar-row { grid-template-columns: 1fr; gap: 4px; } }
        .bar { display: flex; gap: 2px; height: 20px; }
        .seg { display: flex; align-items: center; justify-content: center; flex-basis: 0; min-width: 3px; background: var(--fill);
          color: var(--ink); font-size: 11px; font-variant-numeric: tabular-nums; }
        .seg:last-child { border-radius: 0 4px 4px 0; }
        .scale { display: flex; flex-wrap: wrap; align-items: center; gap: 2px; margin: 8px 0 12px; }
        .scale .meta { margin: 0 6px; font-size: 13px; } .scale .cell { width: 18px; height: 14px; }
        .heat { display: grid; grid-template-columns: 9em repeat(24, minmax(14px, 1fr)); gap: 2px; align-items: center; min-width: 560px; }
        .heat .hour { font-size: 11px; color: var(--muted); white-space: nowrap; }
        .heat .key { padding-right: 8px; overflow: hidden; text-overflow: ellipsis; }
        .cell { height: 22px; border-radius: 2px; background: var(--fill); }
        .cell.none { background: none; box-shadow: inset 0 0 0 1px var(--line); }
        .seg:hover, .seg:focus-visible, .cell[tabindex]:hover, .cell[tabindex]:focus-visible {
          filter: brightness(1.12); outline: 2px solid var(--text); outline-offset: 1px; }
        [data-tip] { position: relative; }
        [data-tip]:hover::after, [data-tip]:focus-visible::after { content: attr(data-tip); position: absolute; bottom: calc(100% + 6px);
          left: 50%; transform: translateX(-50%); z-index: 3; padding: 4px 8px; border-radius: 6px; background: var(--text);
          color: var(--card); font-size: 12px; line-height: 1.3; white-space: nowrap; pointer-events: none; }
        .scroll { overflow-x: auto; }
        table { border-collapse: collapse; margin-top: 8px; font-size: 14px; font-variant-numeric: tabular-nums; }
        th, td { padding: 4px 10px; border-top: 1px solid var(--line); text-align: right; white-space: nowrap; }
        th:first-child { text-align: left; } thead th { font-size: 12px; font-weight: 600; color: var(--muted); }
        td.shared { background: color-mix(in oklab, var(--seq) var(--share), var(--card)); } td.self { color: var(--muted); }
        """
}
