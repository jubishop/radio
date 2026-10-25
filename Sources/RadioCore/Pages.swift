import Foundation

/// Server-rendered HTML for the dashboard and the review email. Every
/// dynamic value goes through `escape`.
enum Pages {
    static func dashboard(_ status: RadioStatus, signInURL: String) -> String {
        var body = """
            <header>
              <h1>Radio</h1>
              <p class="health">\(appleMusic(status.appleMusic, signInURL: signInURL))
                \(review(count: status.heldCount))
                \(playlists(status))
                <a class="pill chart" href="/charts">Charts</a>
                <a class="pill chart" href="/stats">Stats</a>
                <span class="pill">Last sync \(status.lastSyncAt.map { escape(displayTime($0)) } ?? "never")</span></p>
            """
        if let error = status.lastSyncError {
            body += "<p class=\"problem\">Last sync failed: \(escape(error))</p>"
        }
        if let error = status.musicAppError {
            body += "<p class=\"problem\">Music.app can't update the playlists: \(escape(error))</p>"
        }
        if let since = status.musicBehindSince {
            body += "<p class=\"problem\">Music stopped taking in library changes around \(escape(displayTime(since))), "
                + "probably because an alert is waiting for Music to be opened. Open Music on the Mac mini to see it. "
                + "Until then, new songs can't join the playlists.</p>"
        }
        if let error = status.jevError {
            body += "<p class=\"problem\">Jev can't judge songs held for review: \(escape(error))</p>"
        }
        body += "</header>"
        if status.stations.isEmpty {
            body += "<p class=\"empty\">No stations yet. Run <code>radio station add alt1021rva</code>.</p>"
        }
        for summary in status.stations {
            body += station(summary)
        }
        return page(title: "Radio", body: body, refresh: true)
    }

    private static func appleMusic(_ state: AppleMusicState, signInURL: String) -> String {
        switch state {
        case .notConfigured:
            return "<span class=\"pill bad\">Apple Music not set up · run <code>radio credentials set</code></span>"
        case .needsSignIn:
            return "<span class=\"pill bad\">Apple Music sign-in needed · open <code>\(escape(signInURL))</code> on the Mac mini</span>"
        case .rejected(let since):
            return "<span class=\"pill bad\">Apple Music sign-in expired \(escape(displayTime(since))) · open <code>\(escape(signInURL))</code> on the Mac mini</span>"
        case .connected(let storefront, _):
            return "<span class=\"pill good\">Apple Music connected · \(escape(storefront.uppercased()))</span>"
        }
    }

    private static func playlists(_ status: RadioStatus) -> String {
        let songs = "\(status.playlistCount) song\(status.playlistCount == 1 ? "" : "s")"
        return "<a class=\"pill playlist\" href=\"\(path(of: .recent))\">\(songs) in \(escape(Radio.playlistName))</a>\n"
            + "<a class=\"pill playlist\" href=\"\(path(of: .newest))\">\(status.newCount) in \(escape(Radio.newPlaylistName))</a>\n"
            + "<a class=\"pill playlist\" href=\"\(path(of: .unheard))\">\(status.unplayedCount) in \(escape(Radio.unplayedPlaylistName))</a>\n"
            + "<a class=\"pill playlist\" href=\"\(path(of: .archive))\">\(status.archiveCount) in \(escape(Radio.archivePlaylistName))</a>"
    }

    /// Where the dashboard lists a playlist's songs.
    static func path(of kind: Playlist.Kind) -> String {
        switch kind {
        case .recent: "/playlists/radio"
        case .newest: "/playlists/new"
        case .unheard: "/playlists/unplayed"
        case .archive: "/playlists/archive"
        }
    }

    /// A playlist's songs, most recently played first, with the stations
    /// that played each one and how often, and the user's plays and skips.
    /// "Radio (New)" adds each song's release date, and it and
    /// "Radio (Unplayed)" mark the song the next new one will push out.
    static func playlist(_ kind: Playlist.Kind, name: String, entries: [PlaylistEntry]) -> String {
        let count = "\(entries.count) song\(entries.count == 1 ? "" : "s")"
        let rule = switch kind {
        case .newest: " A newer release pushes out the oldest, or among songs released the same day, the one played longest ago."
        case .unheard: " A new song pushes out the one you've played and skipped most in Music, or among ties, the one played longest ago."
        case .recent, .archive: ""
        }
        var body = """
            <header><p><a href="/">← Radio</a></p><h1>\(escape(name))</h1>
            <p class="meta">\(count), most recently played first.\(rule) Each song's comment in Music gives its latest play and each station's plays.</p></header>
            <section>
            """
        if entries.isEmpty {
            body += "<p class=\"empty\">No songs yet.</p>"
        } else {
            body += "<ol>"
            for entry in entries {
                let time = entry.latestPlay.map { "<time>\(escape(shortTime($0)))</time> " } ?? ""
                let stations = entry.stations.map(tag).joined(separator: " ")
                let released = entry.releaseDate.map { " <span class=\"released\">released \(escape($0))</span>" }
                    ?? (kind == .newest ? " <span class=\"released\">released date unknown</span>" : "")
                let drop = entry.dropsNext ? " <span class=\"badge drop\">drops next</span>" : ""
                body += "<li>\(time)\(link(entry.url, "\(entry.artist) – \(entry.title)")) \(stations)\(released)"
                    + "\(listens(entry.listens))\(drop)</li>"
            }
            body += "</ol>"
        }
        return page(title: "\(name) · Radio", body: body + "</section>", refresh: false)
    }

    /// Such as "3 plays · 1 skip", leaving out a count of zero.
    private static func listens(_ listens: Listens) -> String {
        var parts: [String] = []
        if listens.plays > 0 { parts.append("\(listens.plays) play\(listens.plays == 1 ? "" : "s")") }
        if listens.skips > 0 { parts.append("\(listens.skips) skip\(listens.skips == 1 ? "" : "s")") }
        return parts.isEmpty ? "" : " <span class=\"listens\">\(parts.joined(separator: " · "))</span>"
    }

    /// The last week's 100 most played songs, each with the station that
    /// played it last, then the 100 most played since logging began, each
    /// with every station's plays. The user asked for both on 2026-10-20.
    static func charts(_ charts: Charts) -> String {
        var body = """
            <header><p><a href="/">← Radio</a> · <a href="/stats">Stats</a></p><h1>Charts</h1>
            <p class="meta">Plays on every station, counting each Apple Music song once however a station credits it.</p></header>
            <section><h2>Top \(Store.chartLength) this week</h2>
            <p class="meta">The songs played most in the last 7 days, with the station that played each one last.</p>
            """
        body += ranked(charts.week, empty: "No plays this week yet.") { song in
            "\(link(song.url, "\(song.artist) – \(song.title)"))\(year(song.releaseDate)) <span class=\"meta\">\(count(song.plays, "play")) · last</span> "
                + "\(tag(stationID: song.latestStationID, name: song.latestStation)) <time>\(escape(shortTime(song.latestPlay)))</time>"
        }
        let since = charts.since.map { " since \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
        body += "</section><section><h2>Most played\(escape(since))</h2>"
            + "<p class=\"meta\">Every station's plays of each song since Radio began logging them.</p>"
        body += ranked(charts.allTime, empty: "No plays yet.") { song in
            "\(link(song.url, "\(song.artist) – \(song.title)"))\(year(song.releaseDate)) <span class=\"meta\">\(count(song.plays, "play"))</span> "
                + song.stations.map(tag).joined(separator: " ")
        }
        return page(title: "Charts · Radio", body: body + "</section>", refresh: false)
    }

    /// Each station's last week, the song-age charts (see StatsCharts.swift),
    /// then the songs rising, the songs on the most stations, the songs
    /// stations share, and the top artists. The user asked on 2026-10-20 for
    /// more to look at than the charts.
    static func stats(_ stats: Stats) -> String {
        var body = """
            <header><p><a href="/">← Radio</a> · <a href="/charts">Charts</a></p><h1>Stats</h1>
            <p class="meta">The last 7 days on every station.</p></header>
            """
        guard stats.stations.contains(where: { $0.plays > 0 }) else {
            return page(title: "Stats · Radio", body: body + "<p class=\"empty\">No plays this week yet.</p>", refresh: false)
        }
        body += "<h2 class=\"group\">Stations</h2><div class=\"cards\">"
        for station in stats.stations {
            body += stationStats(station)
        }
        body += "</div>" + decades(stats) + hours(stats) + newReleases(stats) + deepCuts(stats) + "<section><h2>Rising</h2>"
            + "<p class=\"meta\">Songs played more in the last 2 days than in the 2 days before, most gained first.</p>"
        body += ranked(stats.rising, empty: "Nothing is rising.") { rising in
            "\(link(rising.song.url, "\(rising.song.artist) – \(rising.song.title)"))\(year(rising.song.releaseDate)) "
                + "<span class=\"meta\">\(rising.song.plays) in the last 2 days, up from \(rising.previous)</span>"
        }
        body += "</section><section><h2>On the most stations</h2><p class=\"meta\">Songs more than one station played this week.</p>"
        body += ranked(stats.widest, empty: "No song was played on two stations this week.") { song in
            "\(link(song.url, "\(song.artist) – \(song.title)"))\(year(song.releaseDate)) "
                + "<span class=\"meta\">\(count(song.stations.count, "station"))</span> " + song.stations.map(tag).joined(separator: " ")
        }
        body += "</section>" + sharedSongs(stats) + "<section><h2>Top artists this week</h2>"
        body += ranked(stats.artists, empty: "No plays this week yet.") { artist in
            "\(escape(artist.artist)) <span class=\"meta\">\(count(artist.plays, "play")) · \(count(artist.songs, "song"))</span>"
        }
        return page(title: "Stats · Radio", body: body + "</section>", refresh: false)
    }

    private static func stationStats(_ stats: StationStats) -> String {
        let perSong = stats.songs > 0 ? Double(stats.plays) / Double(stats.songs) : 0
        var html = """
            <section class="station \(color(ofStation: stats.stationID))"><h2>\(escape(stats.name))</h2>
            <dl class="figures"><div><dt>Plays a day</dt><dd>\(decimal(stats.playsPerDay, digits: stats.playsPerDay < 10 ? 1 : 0))</dd></div>\
            <div><dt>Songs</dt><dd>\(stats.songs)</dd></div>\
            <div><dt>Plays per song</dt><dd>\(decimal(perSong, digits: 1))</dd></div>\
            <div><dt>Only here</dt><dd>\(stats.onlyHere)</dd></div></dl>
            """
        if let top = stats.top {
            let every = stats.topInterval.map { ", about every \(interval($0))" } ?? ""
            html += "<p>Top song: \(link(top.url, "\(top.artist) – \(top.title)"))\(year(top.releaseDate)) · \(count(top.plays, "play"))\(every)</p>"
        } else {
            html += "<p class=\"empty\">No plays this week.</p>"
        }
        return html + songAges(stats.ages) + "</section>"
    }

    /// A numbered list, or `empty` when there's nothing to list.
    static func ranked<Item>(_ items: [Item], empty: String, _ row: (Item) -> String) -> String {
        guard !items.isEmpty else { return "<p class=\"empty\">\(escape(empty))</p>" }
        return "<ol>" + items.enumerated().map { "<li><span class=\"rank\">\($0.offset + 1)</span> \(row($0.element))</li>" }.joined()
            + "</ol>"
    }

    /// Such as "1 play" or "3 plays".
    static func count(_ value: Int, _ noun: String) -> String {
        "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    static func decimal(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(digits)))
    }

    /// Such as "45 minutes" or "3.7 hours".
    private static func interval(_ seconds: TimeInterval) -> String {
        seconds < 3600 ? count(Int((seconds / 60).rounded()), "minute") : "\(decimal(seconds / 3600, digits: 1)) hours"
    }

    /// Links to the review page even with nothing waiting, since it also
    /// lists past decisions to undo.
    /// A station's name and how often it played the song, in its color.
    static func tag(_ station: StationPlays) -> String {
        tag(stationID: station.stationID, name: station.name, plays: station.plays)
    }

    static func tag(stationID: Int64, name: String, plays: Int = 1) -> String {
        let plays = plays > 1 ? " ×\(plays)" : ""
        return "<span class=\"tag \(color(ofStation: stationID))\">\(escape(name))\(plays)</span>"
    }

    /// One of eight colors, chosen by the station's ID so each station keeps
    /// its color on every page.
    static func color(ofStation id: Int64) -> String {
        "s\((id - 1) % 8)"
    }

    /// Green when nothing waits for the user and red when songs do.
    private static func review(count: Int) -> String {
        count == 0
            ? "<a class=\"pill good\" href=\"/review\">No songs to review</a>"
            : "<a class=\"pill bad\" href=\"/review\">\(count) song\(count == 1 ? "" : "s") to review</a>"
    }

    private static func station(_ summary: StationSummary) -> String {
        let station = summary.station
        var feed = "Feed OK"
        if let failing = station.pollFailingSince {
            feed = "<span class=\"bad\">Feed failing since \(escape(displayTime(failing)))</span>: \(escape(station.lastPollError ?? ""))"
        } else if let ok = station.lastPollOKAt {
            feed = "Feed read \(escape(displayTime(ok)))"
        } else {
            feed = "Feed not read yet"
        }
        var html = """
            <section class="station \(color(ofStation: station.id))"><h2>\(escape(station.name))</h2>
              <p class="meta">\(feed) · \(summary.playCount) plays logged</p>
            """
        if let latest = summary.recentPlays.first {
            html += "<p class=\"latest\">Latest: <strong>\(escape(latest.artist)) – \(escape(latest.title))</strong> at \(escape(displayTime(latest.playedAt)))</p>"
        }
        html += "<div class=\"columns\"><div><h3>Recent plays</h3><ol>"
        for play in summary.recentPlays {
            html += "<li><time>\(escape(shortTime(play.playedAt)))</time> \(escape(play.artist)) – \(escape(play.title))\(year(play.releaseDate)) "
                + "\(badge(play.state))</li>"
        }
        html += "</ol></div><div><h3>Just added to \(escape(Radio.playlistName))</h3>"
        if summary.recentlyAdded.isEmpty {
            html += "<p class=\"empty\">Nothing yet.</p>"
        } else {
            html += "<ol>"
            for track in summary.recentlyAdded {
                html += "<li><time>\(escape(shortTime(track.addedAt)))</time> \(link(track.url, "\(track.artist) – \(track.title)"))"
                    + "\(year(track.releaseDate))</li>"
            }
            html += "</ol>"
        }
        return html + "</div></div></section>"
    }

    private static func badge(_ state: PlayEntry.State) -> String {
        switch state {
        case .added: "<span class=\"badge playlist\">in \(escape(Radio.playlistName))</span>"
        case .waiting: "<span class=\"badge waiting\">waiting to sync</span>"
        case .held: "<a class=\"badge bad\" href=\"/review\">needs review</a>"
        case .ignored: "<span class=\"badge\">ignored</span>"
        }
    }

    /// Songs that need the user come first, with Jev's suggestion, then
    /// every decision Jev or the user made, newest first, each with an undo.
    /// The user asked for this order on 2026-10-15.
    static func review(_ songs: [HeldSong], reviewed: [ReviewedSong], message: String?) -> String {
        var body = "<header><p><a href=\"/\">← Radio</a></p><h1>Review</h1>"
        body += "<p class=\"meta\">First come songs that didn't match Apple Music closely enough to add on their own. "
            + "Below them is every pick Jev or you made, newest first. Undo sends a song back up here, "
            + "and a matched song leaves the playlists on the next sync.</p></header>"
        if let message {
            body += "<p class=\"notice\">\(escape(message))</p>"
        }
        body += "<h2 class=\"group\">Needs your review</h2>"
        if songs.isEmpty {
            body += "<p class=\"empty good\">Nothing to review.</p>"
        }
        for song in songs {
            body += heldSong(song)
        }
        body += "<h2 class=\"group\">Reviewed</h2>"
        if reviewed.isEmpty {
            body += "<p class=\"empty\">Nothing yet.</p>"
        } else {
            body += "<section><ol class=\"reviewed\">" + reviewed.map(reviewedSong).joined() + "</ol></section>"
        }
        return page(title: "Review · Radio", body: body, refresh: false)
    }

    /// The daily reminder's email, as plain text and HTML: every song
    /// waiting for review, with Jev's suggestion, and a link to the review
    /// page.
    static func reviewEmail(_ songs: [HeldSong], summary: String, reviewURL: String) -> (text: String, html: String) {
        let them = songs.count == 1 ? "it" : "them"
        var text = "\(summary)\n\nReview \(them) at \(reviewURL).\n"
        var items = ""
        for song in songs {
            let plays = "\(song.playCount) play\(song.playCount == 1 ? "" : "s")"
            let details = "\(plays) on \(song.stations.joined(separator: ", ")) · last \(displayTime(song.lastPlayedAt))"
            text += "\n• \(song.artist) – \(song.title)\n  \(details)\n"
            items += "<li style=\"margin:0 0 12px\"><strong>\(escape(song.artist)) – \(escape(song.title))</strong>"
                + "<br><span style=\"color:#656d76\">\(escape(details))</span>"
            if let suggestion = song.suggestion {
                let pick = song.candidates[suggestion.candidate]
                text += "  Jev suggests \(pick.artistName) – \(pick.name), from \(pick.albumName)\n"
                items += "<br>Jev suggests \(link(pick.url, "\(pick.artistName) – \(pick.name)")), from \(escape(pick.albumName))"
            }
            items += "</li>"
        }
        let html = """
            <!doctype html>
            <html lang="en">
            <body style="margin:0;padding:16px;font:15px/1.45 -apple-system,system-ui,sans-serif">
            <p>\(escape(summary))</p>
            <p><a href="\(escape(reviewURL))" style="display:inline-block;padding:8px 16px;border-radius:8px;background:#4f46e5;color:#fff;text-decoration:none">Review \(them)</a></p>
            <ul style="padding-left:20px">\(items)</ul>
            </body>
            </html>
            """
        return (text, html)
    }

    /// A held song with its first three candidates and Jev's pick; the rest
    /// fold away.
    private static func heldSong(_ song: HeldSong) -> String {
        let plays = "\(song.playCount) play\(song.playCount == 1 ? "" : "s")"
        var html = """
            <section class="held">
              <h2>\(escape(song.artist)) – \(escape(song.title))</h2>
              <p class="meta">\(plays) on \(escape(song.stations.joined(separator: ", "))) · last \(escape(displayTime(song.lastPlayedAt))) · <code>radio match \(song.id)</code></p>
            """
        if let suggestion = song.suggestion {
            let candidate = song.candidates[suggestion.candidate]
            html += "<p class=\"suggestion\">Jev suggests <strong>\(candidateLetter(suggestion.candidate))</strong>, "
                + "\(escape(candidate.artistName)) – \(escape(candidate.name)) (\(score(suggestion.score)))</p>"
        }
        if song.candidates.isEmpty {
            html += "<p class=\"empty\">No Apple Music candidates.</p>"
        } else {
            let shown = song.candidates.indices.filter { $0 < 3 || $0 == song.suggestion?.candidate }
            let more = song.candidates.indices.filter { !shown.contains($0) }
            html += "<ol class=\"candidates\">" + shown.map { candidate(song, $0) }.joined() + "</ol>"
            if !more.isEmpty {
                html += "<details><summary>\(more.count) more</summary><ol class=\"candidates\">"
                    + more.map { candidate(song, $0) }.joined() + "</ol></details>"
            }
        }
        return html + """
            <form method="post" action="/review/\(song.id)/match" class="row">
              <input name="link" type="url" placeholder="Paste an Apple Music song link" required>
              <button>Use link</button>
            </form>
            <form method="post" action="/review/\(song.id)/ignore" class="row">
              <button class="quiet">Ignore this song</button>
            </form>
            </section>
            """
    }

    /// With a suggestion, only Jev's pick keeps the prominent button.
    private static func candidate(_ song: HeldSong, _ index: Int) -> String {
        let candidate = song.candidates[index]
        let explicit = candidate.isExplicit ? " <span class=\"badge\">explicit</span>" : ""
        let isPick = song.suggestion?.candidate == index
        let quiet = song.suggestion != nil && !isPick ? " class=\"quiet\"" : ""
        return """
            <li><form method="post" action="/review/\(song.id)/match">
              <input type="hidden" name="candidate" value="\(index)">
              <button\(quiet)>Use \(candidateLetter(index))</button>
              \(link(candidate.url, "\(candidate.artistName) – \(candidate.name)"))\(explicit)\(isPick ? " <span class=\"badge jev\">Jev's pick</span>" : "")
              <span class="meta">\(escape(candidate.albumName))\(candidate.releaseDate.map { " · " + escape(String($0.prefix(4))) } ?? "")</span>
            </form></li>
            """
    }

    private static func reviewedSong(_ song: ReviewedSong) -> String {
        let label = switch song.decision {
        case .jev(let value, let model): "<span class=\"by jev\">Matched by Jev</span> · \(score(value)) · \(escape(model))"
        case .manual: "<span class=\"by you\">Matched by you</span>"
        case .ignored: "<span class=\"by\">Ignored by you</span>"
        }
        let pick = song.catalog.map { " → " + link($0.url, "\($0.artistName) – \($0.name)") } ?? ""
        return """
            <li><form method="post" action="/review/\(song.id)/undo">
              <div><strong>\(escape(song.artist)) – \(escape(song.title))</strong>\(pick)
                <br><span class="meta">\(label) · \(escape(displayTime(song.decidedAt)))</span></div>
              <button class="quiet">Undo</button>
            </form></li>
            """
    }

    /// A Jev score, such as "0.93".
    private static func score(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(2)))
    }

    static func signIn(developerToken: String) -> String {
        let token = String(decoding: (try? JSONEncoder().encode(developerToken)) ?? Data("\"\"".utf8), as: UTF8.self)
        let body = """
            <header><p><a href="/">← Radio</a></p><h1>Sign in to Apple Music</h1>
            <p class="meta">Radio needs permission to add songs to your library. Apple asks again about every six months.</p></header>
            <p><button id="signin" disabled>Loading MusicKit…</button></p>
            <p id="result" class="notice" hidden></p>
            <script src="https://js-cdn.music.apple.com/musickit/v3/musickit.js" data-web-components async></script>
            <script>
            const button = document.getElementById('signin');
            const result = document.getElementById('result');
            function show(text) { result.textContent = text; result.hidden = false; }
            document.addEventListener('musickitloaded', async () => {
              try {
                await MusicKit.configure({ developerToken: \(token), app: { name: 'Radio', build: '1.0' } });
                button.textContent = 'Sign in to Apple Music';
                button.disabled = false;
              } catch (error) {
                show('MusicKit could not start: ' + error);
              }
            });
            button.addEventListener('click', async () => {
              button.disabled = true;
              try {
                const userToken = await MusicKit.getInstance().authorize();
                const response = await fetch('/auth/token', {
                  method: 'POST',
                  headers: { 'Content-Type': 'application/json' },
                  body: JSON.stringify({ token: userToken }),
                });
                show(response.ok ? 'Signed in. Radio will update its playlists on its next sync.' : await response.text());
              } catch (error) {
                show('Sign-in failed: ' + error);
              }
              button.disabled = false;
            });
            </script>
            """
        return page(title: "Sign in · Radio", body: body, refresh: false)
    }

    static func signInElsewhere(_ signInURL: String) -> String {
        page(title: "Sign in · Radio", body: """
            <h1>Sign in on the Mac mini</h1>
            <p>Apple Music sign-in only works on the Mac running Radio. Open <code>\(escape(signInURL))</code> there.</p>
            """, refresh: false)
    }

    static func notFound() -> String {
        page(title: "Not found · Radio", body: "<h1>Not found</h1><p><a href=\"/\">Back to Radio</a></p>", refresh: false)
    }

    static func error(_ message: String) -> String {
        page(title: "Error · Radio", body: "<h1>Something went wrong</h1><p class=\"problem\">\(escape(message))</p>", refresh: false)
    }

    static func link(_ url: String?, _ text: String) -> String {
        guard let url, url.hasPrefix("https://") else { return escape(text) }
        return "<a href=\"\(escape(url))\" target=\"_blank\" rel=\"noopener\">\(escape(text))</a>"
    }

    private static func shortTime(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(.dateTime.hour().minute())
            : date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    private static func page(title: String, body: String, refresh: Bool) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>📻</text></svg>">
        \(refresh ? "<meta http-equiv=\"refresh\" content=\"60\">" : "")
        <title>\(escape(title))</title>
        <style>
        :root { color-scheme: light dark; --text: #1f2328; --muted: #656d76; --line: #e1e4ea; --bg: #f4f5f9; --card: #fff;
          --good: #1a7f37; --bad: #d1242f; --link: #0969da; --action: #4f46e5; --jev: #8250df; --playlist: #0e7c86; --waiting: #9a6700;
          --s0: #2563eb; --s1: #c026d3; --s2: #d97706; --s3: #7c3aed; --s4: #0891b2; --s5: #db2777; --s6: #a16207; --s7: #64748b; }
        @media (prefers-color-scheme: dark) { :root { --text: #e6edf3; --muted: #9198a1; --line: #2d333b; --bg: #0d1117; --card: #161b22;
          --good: #3fb950; --bad: #ff6b6b; --link: #58a6ff; --action: #6366f1; --jev: #bc8cff; --playlist: #39c5cf; --waiting: #e3b341;
          --s0: #60a5fa; --s1: #e879f9; --s2: #fbbf24; --s3: #a78bfa; --s4: #22d3ee; --s5: #f472b6; --s6: #d4a24c; --s7: #94a3b8; } }
        * { box-sizing: border-box; }
        html { background: radial-gradient(900px 320px at 0% 0%, color-mix(in srgb, var(--jev) 12%, transparent), transparent),
          radial-gradient(900px 320px at 100% 0%, color-mix(in srgb, var(--playlist) 12%, transparent), transparent) var(--bg); }
        body { margin: 0 auto; max-width: 1100px; padding: 16px; font: 15px/1.45 -apple-system, system-ui, sans-serif; color: var(--text); }
        h1 { margin: 0 0 4px; font-size: 30px; width: fit-content; color: transparent; -webkit-background-clip: text; background-clip: text;
          background-image: linear-gradient(90deg, var(--jev), var(--link) 55%, var(--playlist)); }
        h2 { margin: 0 0 4px; font-size: 20px; }
        h3 { margin: 12px 0 6px; font-size: 13px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); }
        a { color: var(--link); text-decoration: none; } a:hover { text-decoration: underline; }
        section { background: var(--card); border: 1px solid var(--line); border-radius: 12px; padding: 16px; margin: 16px 0; }
        .meta, .empty, time { color: var(--muted); }
        .pill, .badge, .tag, .by { --c: var(--muted); color: var(--c); }
        .pill, .badge, .tag { background: color-mix(in srgb, var(--c) 13%, transparent); border-radius: 12px; }
        .pill { padding: 3px 10px; font-size: 14px; overflow-wrap: anywhere; }
        .badge, .tag { padding: 1px 7px; font-size: 12px; white-space: nowrap; }
        a.pill:hover, a.badge:hover { text-decoration: none; background: color-mix(in srgb, var(--c) 24%, transparent); }
        .health { display: flex; flex-wrap: wrap; gap: 6px; margin: 10px 0 0; }
        .s0 { --station: var(--s0); } .s1 { --station: var(--s1); } .s2 { --station: var(--s2); } .s3 { --station: var(--s3); }
        .s4 { --station: var(--s4); } .s5 { --station: var(--s5); } .s6 { --station: var(--s6); } .s7 { --station: var(--s7); }
        .tag { --c: var(--station); }
        .good { --c: var(--good); color: var(--c); } .bad { --c: var(--bad); color: var(--c); } .jev { --c: var(--jev); color: var(--c); }
        .you, .chart { --c: var(--link); } .playlist { --c: var(--playlist); } .waiting, .drop { --c: var(--waiting); } .by { font-weight: 600; }
        .listens, .released { color: var(--muted); font-size: 13px; white-space: nowrap; }
        .station { border-top: 4px solid var(--station);
          background: linear-gradient(color-mix(in srgb, var(--station) 8%, var(--card)), var(--card) 120px); }
        .station h2::before { content: ""; display: inline-block; width: 10px; height: 10px; margin-right: 8px; border-radius: 50%;
          background: var(--station); vertical-align: middle; }
        .held { border-left: 4px solid var(--bad); }
        .problem, .notice { padding: 8px 12px; border-radius: 8px; }
        .problem { color: var(--bad); background: color-mix(in srgb, var(--bad) 10%, transparent); }
        .notice { border-left: 3px solid var(--link); border-radius: 0 8px 8px 0; background: color-mix(in srgb, var(--link) 10%, var(--card)); }
        .suggestion { margin: 8px 0; padding: 8px 12px; border-radius: 8px; background: color-mix(in srgb, var(--jev) 10%, transparent); }
        .suggestion strong { color: var(--jev); }
        .columns { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; }
        @media (max-width: 720px) { .columns { grid-template-columns: 1fr; } }
        ol { list-style: none; padding: 0; margin: 0; } li { padding: 4px 0; border-top: 1px solid var(--line); }
        time { display: inline-block; min-width: 5.5em; font-variant-numeric: tabular-nums; }
        .candidates li { padding: 8px 0; } .row { display: flex; gap: 8px; margin-top: 8px; }
        h2.group { margin: 28px 0 0; }
        .rank { display: inline-block; min-width: 2em; margin-right: 4px; text-align: right; color: var(--muted); font-variant-numeric: tabular-nums; }
        .cards { display: grid; grid-template-columns: repeat(auto-fill, minmax(min(100%, 300px), 1fr)); gap: 16px; margin: 16px 0; }
        .cards section { margin: 0; }
        .figures { display: grid; grid-template-columns: 1fr 1fr; gap: 8px 16px; margin: 12px 0; }
        .figures dt { font-size: 13px; color: var(--muted); }
        .figures dd { margin: 0; font-size: 22px; font-weight: 600; font-variant-numeric: tabular-nums; }
        details summary { margin-top: 8px; color: var(--muted); cursor: pointer; }
        .reviewed form { display: flex; align-items: center; gap: 12px; } .reviewed form div { flex: 1; min-width: 0; }
        input { flex: 1; min-width: 0; padding: 6px 8px; font: inherit; border: 1px solid var(--line); border-radius: 8px; background: var(--bg); color: var(--text); }
        button { font: inherit; padding: 5px 12px; border-radius: 8px; border: 1px solid var(--action); background: var(--action); color: #fff; cursor: pointer; }
        button:hover { filter: brightness(1.1); }
        button.quiet { background: none; color: var(--muted); border-color: var(--line); }
        button:disabled { opacity: .5; cursor: default; }
        code { font: 13px ui-monospace, SFMono-Regular, monospace; }
        \(chartStyles)
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
