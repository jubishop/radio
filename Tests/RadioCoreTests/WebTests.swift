import CryptoKit
import Foundation
import RadioCore
import Testing

@Suite struct WebTests {
    func request(_ method: String, _ path: String, form: String = "", headers: [String: String] = [:], loopback: Bool = false) -> WebRequest {
        let parts = path.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for item in URLComponents(string: "?" + parts[1])?.queryItems ?? [] { query[item.name] = item.value }
        }
        return WebRequest(method: method, path: String(parts[0]), query: query, headers: headers, body: Data(form.utf8), isLoopback: loopback)
    }

    func text(_ response: WebResponse) -> String { String(decoding: response.body, as: UTF8.self) }

    @Test func theDashboardShowsEachStationsRecentPlaysAndHealth() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Rise Against", "Savior")
        harness.play("Rise Against", "Savior", minutesAgo: 4)
        harness.play("Tom & Jerry <Band>", "Unmatched Song")
        _ = try await harness.radio.run()

        let page = text(await Dashboard(radio: harness.radio).handle(request("GET", "/")))

        #expect(page.contains("<h2>Alt 102.1</h2>"))
        #expect(page.contains("Latest: <strong>Tom &amp; Jerry &lt;Band&gt; – Unmatched Song</strong>"))
        #expect(page.contains(#"<span class="pill good">Apple Music connected · US</span>"#))
        #expect(page.contains(#"<a class="pill bad" href="/review">1 song to review</a>"#))
        #expect(page.contains(#"<span class="badge playlist">in Radio</span>"#))
        #expect(page.contains("<h3>Just added to Radio</h3>"))
        #expect(page.contains(#"<a class="pill playlist" href="/playlists/radio">1 song in Radio</a>"#))
        #expect(page.contains(#"<a class="pill playlist" href="/playlists/new">1 in Radio (New)</a>"#))
        #expect(page.contains(#"<a class="pill playlist" href="/playlists/archive">1 in Radio Archive</a>"#))
        #expect(page.contains(#"<a class="pill chart" href="/charts">Charts</a>"#))
        #expect(page.contains(#"<a class="pill chart" href="/stats">Stats</a>"#))
    }

    /// The review page also lists past decisions to undo, so the user asked
    /// on 2026-10-15 for the dashboard to link to it with nothing waiting,
    /// and for green to mean all is well.
    @Test func nothingToReviewLinksToTheReviewPageInGreen() async throws {
        let dashboard = Dashboard(radio: try Harness().radio)

        let home = text(await dashboard.handle(request("GET", "/")))
        let review = text(await dashboard.handle(request("GET", "/review")))

        #expect(home.contains(#"<a class="pill good" href="/review">No songs to review</a>"#))
        #expect(review.contains(#"<p class="empty good">Nothing to review.</p>"#))
    }

    /// The user asked on 2026-10-15 for more color than black, white, red,
    /// and green. Each station keeps one color, from its ID, on every page.
    @Test func eachStationKeepsItsColorAcrossPages() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        harness.music.addToCatalog("Rise Against", "Savior")
        harness.play("Rise Against", "Savior", on: "101-2000")
        _ = try await harness.radio.run()
        let dashboard = Dashboard(radio: harness.radio)

        let home = text(await dashboard.handle(request("GET", "/")))
        let radio = text(await dashboard.handle(request("GET", "/playlists/radio")))

        #expect(home.contains(#"<section class="station s0"><h2>Alt 102.1</h2>"#))
        #expect(home.contains(#"<section class="station s1"><h2>Rock 99</h2>"#))
        #expect(radio.contains(#"<span class="tag s1">Rock 99</span>"#))
    }

    @Test func eachPlaylistsPageListsItsSongsWithTheStationsThatPlayedThem() async throws {
        let harness = try Harness(playlistLimit: 1)
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        let savior = harness.music.addToCatalog("Rise Against", "Savior")
        harness.music.addToCatalog("Tom & Jerry", "<Hit>")
        harness.play("Rise Against", "Savior", minutesAgo: 40)
        harness.play("Rise Against", "Savior", minutesAgo: 30)
        harness.play("Rise Against", "Savior", on: "101-2000", minutesAgo: 20)
        harness.play("Tom & Jerry", "<Hit>", minutesAgo: 10)
        _ = try await harness.radio.run()
        let dashboard = Dashboard(radio: harness.radio)

        let radio = text(await dashboard.handle(request("GET", "/playlists/radio")))
        let archive = text(await dashboard.handle(request("GET", "/playlists/archive")))
        let missing = await dashboard.handle(request("GET", "/playlists/other"))

        #expect(radio.contains("<h1>Radio</h1>"))
        #expect(radio.contains("Tom &amp; Jerry – &lt;Hit&gt;"))
        #expect(!radio.contains("Savior"))
        #expect(archive.contains("<h1>Radio Archive</h1>"))
        // Most recently played first, with every station that played each
        // song, most recent first.
        let hit = try #require(archive.range(of: "Tom &amp; Jerry – &lt;Hit&gt;"))
        let saviorLink = try #require(archive.range(of: #"<a href="\#(savior.url)" target="_blank" rel="noopener">Rise Against – Savior</a>"#))
        #expect(hit.lowerBound < saviorLink.lowerBound)
        #expect(archive.contains(#"<span class="tag s1">Rock 99</span> <span class="tag s0">Alt 102.1 ×2</span>"#))
        #expect(missing.status == 404)
    }

    /// The user asked on 2026-10-20 to keep every song's plays on every
    /// station viewable, and for a top 100 with the station that played each
    /// song last.
    @Test func theChartsPageRanksThisWeeksSongsAndEverySongSinceLoggingBegan() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        let savior = harness.music.addToCatalog("Rise Against", "Savior")
        let hitSong = harness.music.addToCatalog("Tom & Jerry", "<Hit>")
        harness.music.addToCatalog("Old Band", "Old Song")
        let firstPlay = harness.clock.now.addingTimeInterval(-40 * 60)
        for minutesAgo in [40.0, 30, 20, 10] {
            harness.play("Old Band", "Old Song", minutesAgo: minutesAgo)
        }
        _ = try await harness.radio.run()
        harness.clock.advance(days: 8)
        harness.play("Rise Against", "Savior", minutesAgo: 50)
        harness.play("Rise Against", "Savior", minutesAgo: 40)
        harness.play("Tom & Jerry", "<Hit>", minutesAgo: 30)
        harness.play("Rise Against", "Savior", on: "101-2000", minutesAgo: 20)
        _ = try await harness.radio.run()

        let page = text(await Dashboard(radio: harness.radio).handle(request("GET", "/charts")))

        #expect(page.contains("<h1>Charts</h1>"))
        #expect(page.contains(#"<a href="/stats">Stats</a>"#))
        let since = firstPlay.formatted(.dateTime.month(.abbreviated).day())
        let sections = page.components(separatedBy: "<h2>Most played since \(since)</h2>")
        try #require(sections.count == 2)
        let (week, allTime) = (sections[0], sections[1])
        #expect(week.contains("<h2>Top 100 this week</h2>"))
        // Most played first, each with the station that played it last.
        let saviorLink = #"<a href="\#(savior.url)" target="_blank" rel="noopener">Rise Against – Savior</a>"#
        #expect(week.contains(#"<span class="rank">1</span> \#(saviorLink) <span class="meta">3 plays · last</span> <span class="tag s1">Rock 99</span>"#))
        let hitLink = #"<a href="\#(hitSong.url)" target="_blank" rel="noopener">Tom &amp; Jerry – &lt;Hit&gt;</a>"#
        #expect(week.contains(#"<span class="rank">2</span> \#(hitLink) <span class="meta">1 play · last</span> <span class="tag s0">Alt 102.1</span>"#))
        // Plays older than a week count only since logging began.
        #expect(!week.contains("Old Song"))
        let order = ["Old Band – Old Song", "Rise Against – Savior", "Tom &amp; Jerry – &lt;Hit&gt;"]
        let positions = order.map { allTime.range(of: $0)?.lowerBound }
        #expect(!positions.contains(nil))
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
        #expect(allTime.contains(#"Old Band – Old Song</a> <span class="meta">4 plays</span> <span class="tag s0">Alt 102.1 ×4</span></li>"#))
        #expect(allTime.contains(#"\#(saviorLink) <span class="meta">3 plays</span> <span class="tag s0">Alt 102.1 ×2</span> <span class="tag s1">Rock 99</span></li>"#))
    }

    /// Every song matched to one Apple Music song counts as that song, as on
    /// the playlist pages, and songs the user ignored stay off the charts.
    @Test func theChartsCountEachAppleMusicSongOnceAndLeaveOutIgnoredSongs() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        let song = harness.music.addToCatalog("Nirvana", "Come As You Are")
        harness.play("Nirvana", "Come As You Are", minutesAgo: 3)
        // Radio keeps a title's featured credit in its song keys, so it logs
        // this as another song.
        harness.play("Nirvana", "Come As You Are Ft. Dave Grohl", minutesAgo: 2)
        harness.play("Unknown Band", "Demo", minutesAgo: 1)
        _ = try await harness.radio.run()
        let held = try await harness.radio.heldSongs()
        let credited = try #require(held.first { $0.title == "Come As You Are Ft. Dave Grohl" })
        let unknown = try #require(held.first { $0.artist == "Unknown Band" })
        _ = try await harness.radio.match(songID: credited.id, choice: .link(song.url))
        try await harness.radio.ignore(songID: unknown.id)
        let dashboard = Dashboard(radio: harness.radio)

        let charts = text(await dashboard.handle(request("GET", "/charts")))
        let stats = text(await dashboard.handle(request("GET", "/stats")))

        #expect(charts.contains(#"Nirvana – Come As You Are</a> <span class="meta">2 plays · last</span>"#))
        #expect(charts.contains(#"Nirvana – Come As You Are</a> <span class="meta">2 plays</span> <span class="tag s0">Alt 102.1 ×2</span>"#))
        #expect(!charts.contains("Unknown Band"))
        #expect(!stats.contains("Unknown Band"))
    }

    /// The user asked on 2026-10-20 for more to look at than the charts.
    @Test func theStatsPageSummarizesEachStationsWeek() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        harness.music.addToCatalog("Rise Against", "Savior")
        harness.music.addToCatalog("Tom & Jerry", "<Hit>")
        harness.play("Rise Against", "Savior", minutesAgo: 4000)
        harness.play("Rise Against", "Savior", minutesAgo: 600)
        harness.play("Rise Against", "Savior", minutesAgo: 300)
        harness.play("Tom & Jerry", "<Hit>", minutesAgo: 200)
        harness.play("Rise Against", "Savior", on: "101-2000", minutesAgo: 100)
        _ = try await harness.radio.run()

        let page = text(await Dashboard(radio: harness.radio).handle(request("GET", "/stats")))

        #expect(page.contains("<h1>Stats</h1>"))
        #expect(page.contains(#"<a href="/charts">Charts</a>"#))
        // Alt 102.1 logged 4 plays over about 2.8 days, of 2 songs, one of
        // them played nowhere else; Savior came back every 1,850 minutes.
        let alt = try #require(page.components(separatedBy: #"<section class="station s0">"#).dropFirst().first)
        #expect(alt.contains("<h2>Alt 102.1</h2>"))
        #expect(alt.contains("<dt>Plays a day</dt><dd>1.4</dd>"))
        #expect(alt.contains("<dt>Songs</dt><dd>2</dd>"))
        #expect(alt.contains("<dt>Plays per song</dt><dd>2.0</dd>"))
        #expect(alt.contains("<dt>Only here</dt><dd>1</dd>"))
        #expect(alt.contains("Rise Against – Savior</a> · 3 plays, about every 30.8 hours"))
        let rock = try #require(page.components(separatedBy: #"<section class="station s1">"#).dropFirst().first)
        #expect(rock.contains("<dt>Only here</dt><dd>0</dd>"))
        #expect(rock.contains("Rise Against – Savior</a> · 1 play</p>"))
        let rising = try #require(page.components(separatedBy: "<h2>Rising</h2>").dropFirst().first)
        #expect(rising.contains(#"Rise Against – Savior</a> <span class="meta">3 in the last 2 days, up from 1</span>"#))
        #expect(rising.contains(#"Tom &amp; Jerry – &lt;Hit&gt;</a> <span class="meta">1 in the last 2 days, up from 0</span>"#))
        // Most gained first.
        let gained = try #require(rising.range(of: "Savior"))
        #expect(gained.lowerBound < (rising.range(of: "Hit")?.lowerBound ?? rising.startIndex))
        let widest = try #require(page.components(separatedBy: "<h2>On the most stations</h2>").dropFirst().first)
        #expect(widest.contains(#"Rise Against – Savior</a> <span class="meta">2 stations</span> <span class="tag s0">Alt 102.1 ×3</span> <span class="tag s1">Rock 99</span>"#))
        #expect(!widest.components(separatedBy: "</section>")[0].contains("Hit"))
        let artists = try #require(page.components(separatedBy: "<h2>Top artists this week</h2>").dropFirst().first)
        #expect(artists.contains(#"<span class="rank">1</span> Rise Against <span class="meta">4 plays · 1 song</span>"#))
        #expect(artists.contains(#"<span class="rank">2</span> Tom &amp; Jerry <span class="meta">1 play · 1 song</span>"#))
    }

    @Test func theChartsAndStatsPagesWaitForPlays() async throws {
        let dashboard = Dashboard(radio: try Harness().radio)

        let charts = await dashboard.handle(request("GET", "/charts"))
        let stats = await dashboard.handle(request("GET", "/stats"))

        #expect(charts.status == 200)
        #expect(text(charts).contains("<h2>Most played</h2>"))
        #expect(text(charts).contains(#"<p class="empty">No plays this week yet.</p>"#))
        #expect(stats.status == 200)
        #expect(text(stats).contains(#"<p class="empty">No plays this week yet.</p>"#))
    }

    /// The user asked on 2026-10-20 to see their plays and skips, and the
    /// song the next new one will push out of "Radio (New)".
    @Test func thePlaylistPagesShowYourPlaysAndSkipsAndWhatDropsNext() async throws {
        let harness = try Harness(playlistLimit: 2)
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        for title in ["A", "B"] { harness.music.addToCatalog("Band", title) }
        harness.play("Band", "A", minutesAgo: 20)
        harness.play("Band", "B", minutesAgo: 10)
        _ = try await harness.radio.run()
        harness.music.setListens("A", plays: 3, skips: 1)
        harness.music.setListens("B", plays: 1)
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        let dashboard = Dashboard(radio: harness.radio)

        let radio = text(await dashboard.handle(request("GET", "/playlists/radio")))
        let new = text(await dashboard.handle(request("GET", "/playlists/new")))
        let archive = text(await dashboard.handle(request("GET", "/playlists/archive")))

        #expect(new.contains("<h1>Radio (New)</h1>"))
        let songs = new.components(separatedBy: "<li>").dropFirst()
        let a = try #require(songs.first { $0.contains("Band – A") })
        let b = try #require(songs.first { $0.contains("Band – B") })
        #expect(a.contains("3 plays · 1 skip"))
        #expect(a.contains(#"<span class="badge drop">drops next</span>"#))
        #expect(b.contains("1 play"))
        #expect(!b.contains("drops next"))
        for page in [radio, archive] {
            #expect(page.contains("3 plays · 1 skip"))
            #expect(!page.contains("drops next"))
        }
    }

    @Test func theReviewPageMatchesAndIgnoresSongs() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Come As You Are (Live)")
        harness.play("Nirvana", "Come As You Are")
        harness.play("Unknown Band", "Demo", minutesAgo: 2)
        _ = try await harness.radio.run()
        let dashboard = Dashboard(radio: harness.radio)
        let held = try await harness.radio.heldSongs()
        let nirvana = try #require(held.first { $0.artist == "Nirvana" })
        let unknown = try #require(held.first { $0.artist == "Unknown Band" })

        let page = text(await dashboard.handle(request("GET", "/review")))
        #expect(page.contains("Nirvana – Come As You Are"))
        #expect(page.contains("Use a"))

        let matched = await dashboard.handle(request("POST", "/review/\(nirvana.id)/match", form: "candidate=0"))
        let ignored = await dashboard.handle(request("POST", "/review/\(unknown.id)/ignore"))
        #expect(matched.status == 303)
        #expect(matched.headers["Location"]?.hasPrefix("/review?message=Matched") == true)
        #expect(ignored.status == 303)
        #expect(try await harness.radio.heldSongs().isEmpty)

        _ = try await harness.radio.sync()
        #expect(harness.music.playlists()["Radio"] == ["Come As You Are (Live)"])
    }

    /// The user asked on 2026-10-15 for songs needing review first, with
    /// Jev's suggestion, then every pick by Jev or the user, newest first,
    /// each with an undo.
    @Test func theReviewPageListsSongsToReviewThenEveryDecisionNewestFirst() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On")
        harness.music.addToCatalog("Nirvana", "Lake of Fire (Live Acoustic)")
        harness.music.addToCatalog("Pearl Jam", "Last Kiss (Live)")
        harness.jev.score("Get Ur Freak On", 0.93)
        harness.jev.score("Lake of Fire (Live Acoustic)", 0.74)
        harness.play("Missy Elliot", "GET UR FREAK ON", minutesAgo: 4)
        harness.play("Nirvana", "Lake Of Fire", minutesAgo: 3)
        harness.play("Pearl Jam", "Last Kiss", minutesAgo: 2)
        harness.play("Unknown Band", "Demo", minutesAgo: 1)
        harness.play("Another Band", "Tape")
        _ = try await harness.radio.run()
        let held = try await harness.radio.heldSongs()
        let pearlJam = try #require(held.first { $0.artist == "Pearl Jam" })
        let unknown = try #require(held.first { $0.artist == "Unknown Band" })
        harness.clock.advance(hours: 1)
        _ = try await harness.radio.match(songID: pearlJam.id, choice: .candidate(0))
        harness.clock.advance(hours: 1)
        try await harness.radio.ignore(songID: unknown.id)
        let dashboard = Dashboard(radio: harness.radio)

        let page = text(await dashboard.handle(request("GET", "/review")))

        let order = ["Needs your review", "Another Band – Tape", "Nirvana – Lake Of Fire", "Jev suggests",
                     "Reviewed", "Unknown Band – Demo", "Ignored by you", "Pearl Jam – Last Kiss", "Matched by you",
                     "Missy Elliot – GET UR FREAK ON", "Matched by Jev"]
        let positions = order.map { page.range(of: $0)?.lowerBound }
        #expect(!positions.contains(nil), "\(zip(order, positions).filter { $0.1 == nil }.map(\.0))")
        #expect(positions.compactMap { $0 } == positions.compactMap { $0 }.sorted())
        let missy = try #require(try await harness.radio.reviewedSongs().first { $0.artist == "Missy Elliot" })
        #expect(page.contains("action=\"/review/\(missy.id)/undo\""))

        let undone = await dashboard.handle(request("POST", "/review/\(missy.id)/undo"))

        #expect(undone.status == 303)
        #expect(undone.headers["Location"]?.hasPrefix("/review?message=") == true)
        #expect(try await harness.radio.heldSongs().contains { $0.id == missy.id })
    }

    @Test func signInIsOnlyServedToThisMac() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let dashboard = Dashboard(radio: harness.radio)

        let remote = await dashboard.handle(request("GET", "/auth"))
        let local = await dashboard.handle(request("GET", "/auth", loopback: true))
        let remoteToken = await dashboard.handle(WebRequest(
            method: "POST", path: "/auth/token", query: [:], headers: [:],
            body: Data(#"{"token":"stolen"}"#.utf8), isLoopback: false
        ))

        #expect(remote.status == 403)
        #expect(!text(remote).contains("developerToken"))
        #expect(local.status == 200)
        #expect(text(local).contains("musickit.js"))
        #expect(remoteToken.status == 403)
        #expect(try await harness.radio.appleMusicState() == .needsSignIn)
    }

    @Test func onlyThisMacsOwnNamesAreServed() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let dashboard = Dashboard(radio: harness.radio)
        func status(_ path: String, host: String) async -> Int {
            await dashboard.handle(request("GET", path, headers: ["host": host], loopback: true)).status
        }

        // Tailscale assigns and resolves `.ts.net` names, so no other site
        // can claim one for this Mac either.
        for host in [
            "jubi.local:8102", "Jubi.Local", "localhost:8102", "127.0.0.1:8102", "192.168.1.20:8102", "[::1]:8102",
            "mac-mini.tail1234.ts.net:8102", "Mac-Mini.Tail1234.TS.NET",
        ] {
            #expect(await status("/", host: host) == 200, "\(host)")
        }
        #expect(await status("/auth", host: "localhost:8102") == 200)
        // A site can point its own domain at this Mac (DNS rebinding), making
        // the dashboard and the sign-in page's developer token its own.
        for host in [
            "rebind.attacker.example:8102", "jubi.local.attacker.example", "localhost.attacker.example",
            "mac-mini.tail1234.ts.net.attacker.example", "attacker-ts.net",
        ] {
            #expect(await status("/", host: host) == 403, "\(host)")
            #expect(await status("/auth", host: host) == 403, "\(host)")
        }
    }

    @Test func aTokenPostedFromThisMacSignsIn() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let response = await Dashboard(radio: harness.radio).handle(WebRequest(
            method: "POST", path: "/auth/token", query: [:], headers: [:],
            body: Data(#"{"token":"user-token"}"#.utf8), isLoopback: true
        ))
        #expect(response.status == 200)
        #expect(try await harness.radio.appleMusicState() == .connected(storefront: "us", signedInAt: harness.clock.now))
    }

    @Test func aTokenPostedFromAnotherSiteIsRefused() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        // A page from another site, open in a browser on this Mac.
        let response = await Dashboard(radio: harness.radio).handle(WebRequest(
            method: "POST", path: "/auth/token", query: [:],
            headers: ["host": "localhost:8102", "origin": "http://attacker.example"],
            body: Data(#"{"token":"user-token"}"#.utf8), isLoopback: true
        ))
        #expect(response.status == 403)
        #expect(try await harness.radio.appleMusicState() == .needsSignIn)
    }

    @Test func theServerAnswersOverHTTP() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        let dashboard = Dashboard(radio: harness.radio)
        let server = try WebServer(port: 0) { await dashboard.handle($0) }
        let port = try await server.start()
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/nope")!)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Alt 102.1"))
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func theServerRefusesChangesSentFromAnotherSite() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("Unknown Band", "Demo")
        _ = try await harness.radio.run()
        let song = try #require(try await harness.radio.heldSongs().first)
        let dashboard = Dashboard(radio: harness.radio)
        let server = try WebServer(port: 0) { await dashboard.handle($0) }
        let port = try await server.start()
        defer { server.stop() }

        // Browsers send Origin with every POST, naming the page's site.
        func ignore(from origin: String) async throws -> Int? {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/review/\(song.id)/ignore")!)
            request.httpMethod = "POST"
            request.setValue(origin, forHTTPHeaderField: "Origin")
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode
        }

        #expect(try await ignore(from: "http://attacker.example") == 403)
        #expect(try await ignore(from: "null") == 403)
        #expect(try await harness.radio.heldSongs().count == 1)
        // The review page's own form; the redirect back to it loads.
        #expect(try await ignore(from: "http://127.0.0.1:\(port)") == 200)
        #expect(try await harness.radio.heldSongs().isEmpty)
    }

    @Test func anHTTPSRequestFailsAtOnceInsteadOfHanging() async throws {
        let harness = try Harness()
        let dashboard = Dashboard(radio: harness.radio)
        let server = try WebServer(port: 0) { await dashboard.handle($0) }
        let port = try await server.start()
        defer { server.stop() }

        let request = URLRequest(url: URL(string: "https://127.0.0.1:\(port)/")!, timeoutInterval: 5)
        let start = ContinuousClock.now
        await #expect(throws: (any Error).self) { try await URLSession.shared.data(for: request) }
        #expect(ContinuousClock.now - start < .seconds(2))
    }

    // A listener that also takes IPv6 never sees IPv4 connections that
    // arrive over Tailscale, so the server listens on IPv4 alone.
    @Test func theServerListensOnIPv4Only() async throws {
        let harness = try Harness()
        let dashboard = Dashboard(radio: harness.radio)
        let server = try WebServer(port: 0) { await dashboard.handle($0) }
        let port = try await server.start()
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let request = URLRequest(url: URL(string: "http://[::1]:\(port)/")!, timeoutInterval: 5)
        await #expect(throws: (any Error).self) { try await URLSession.shared.data(for: request) }
    }

    @Test func theServerTreatsLocalConnectionsAsThisMac() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let dashboard = Dashboard(radio: harness.radio)
        let server = try WebServer(port: 0) { await dashboard.handle($0) }
        let port = try await server.start()
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}

@Suite struct CredentialTests {
    @Test func developerTokensAreValidES256JWTs() async throws {
        let harness = try Harness()
        let key = P256.Signing.PrivateKey()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: key.pemRepresentation)

        let token = try await harness.radio.developerToken(lifetime: 3600)
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        func decode(_ part: String) throws -> Data {
            var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            return try #require(Data(base64Encoded: base64))
        }
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any]
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any]
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        let now = Int(harness.clock.now.timeIntervalSince1970)

        #expect(header?["alg"] as? String == "ES256")
        #expect(header?["kid"] as? String == "KEY123")
        #expect(claims?["iss"] as? String == "TEAM456")
        #expect(claims?["iat"] as? Int == now)
        #expect(claims?["exp"] as? Int == now + 3600)
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func credentialsReadableByOthersAreRefused() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let file = harness.home.directory.appendingPathComponent("credentials.json")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        await #expect(throws: CredentialsError.self) { try await harness.radio.savedCredentials() }
    }

    @Test func anInvalidKeyIsRejectedBeforeSaving() async throws {
        let harness = try Harness()
        await #expect(throws: (any Error).self) {
            try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: "not a key")
        }
        #expect(try await harness.radio.savedCredentials() == nil)
    }

    @Test func envFilesAreReadWithoutRunningThem() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("radio-env-\(UUID().uuidString)")
        try """
            # comment
            export PUSHOVER_USER_KEY="user value"
            PUSHOVER_API_KEY='app'
            OTHER=$(rm -rf /)
            """.write(to: file, atomically: true, encoding: .utf8)
        let values = readEnvFile(at: file)
        #expect(values["PUSHOVER_USER_KEY"] == "user value")
        #expect(values["PUSHOVER_API_KEY"] == "app")
        #expect(values["OTHER"] == "$(rm -rf /)")
    }
}
