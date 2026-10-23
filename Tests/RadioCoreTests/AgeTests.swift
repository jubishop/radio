import Foundation
import RadioCore
import Testing

/// The user asked on 2026-10-22 for release dates on the dashboard, how old
/// each station's songs are, new releases and who played them first, song
/// ages by hour and decade, deep cuts, and the songs stations share.
@Suite struct AgeTests {
    func request(_ path: String) -> WebRequest {
        WebRequest(method: "GET", path: path, query: [:], headers: [:], body: Data(), isLoopback: false)
    }

    func page(_ harness: Harness, _ path: String) async -> String {
        String(decoding: await Dashboard(radio: harness.radio).handle(request(path)).body, as: UTF8.self)
    }

    /// The UTC calendar date `days` before the harness clock, as Apple
    /// writes release dates.
    func released(_ harness: Harness, daysAgo days: Double) -> String {
        (harness.clock.now - days * 86_400).formatted(.iso8601.year().month().day())
    }

    func released(_ harness: Harness, yearsAgo years: Double) -> String {
        released(harness, daysAgo: years * 365.25)
    }

    /// The part of a page from a section's heading to the end of its section.
    func section(_ page: String, _ heading: String) throws -> String {
        let start = try #require(page.components(separatedBy: "<h2>\(heading)</h2>").dropFirst().first)
        return start.components(separatedBy: "</section>")[0]
    }

    /// Two stations, each song released a round number of years before it
    /// plays: Alt 102.1 plays a 40-year-old song, a 20-year-old one twice,
    /// and a 0.1-year-old one, and Rock 99 the 20- and 40-year-old ones.
    func harnessWithAges() async throws -> Harness {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        harness.music.addToCatalog("Band", "Old", released: released(harness, yearsAgo: 40))
        harness.music.addToCatalog("Band", "Mid", released: released(harness, yearsAgo: 20))
        harness.music.addToCatalog("Band", "Fresh", released: released(harness, yearsAgo: 0.1))
        harness.play("Band", "Old", minutesAgo: 50)
        harness.play("Band", "Mid", minutesAgo: 40)
        harness.play("Band", "Mid", minutesAgo: 30)
        harness.play("Band", "Fresh", minutesAgo: 20)
        harness.play("Band", "Mid", on: "101-2000", minutesAgo: 15)
        harness.play("Band", "Old", on: "101-2000", minutesAgo: 10)
        _ = try await harness.radio.run()
        return harness
    }

    @Test func songListsShowEachSongsReleaseYear() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("The Killers", "Mr. Brightside", released: "2003-09-29")
        // Only live recordings, so the song waits for review.
        harness.music.addToCatalog("Weezer", "Buddy Holly (Live)", released: "1994")
        harness.music.addToCatalog("Weezer", "Buddy Holly (Live)", album: "Blue Album (Deluxe)", released: "1994-05-10")
        harness.play("The Killers", "Mr. Brightside", minutesAgo: 10)
        harness.play("Weezer", "Buddy Holly")
        _ = try await harness.radio.run()

        let dashboard = await page(harness, "/")
        let playlist = await page(harness, "/playlists/radio")
        let charts = await page(harness, "/charts")
        let review = await page(harness, "/review")

        #expect(dashboard.contains(#"The Killers – Mr. Brightside <span class="year">2003</span>"#))
        #expect(dashboard.contains(#"Mr. Brightside</a> <span class="year">2003</span></li>"#))
        #expect(playlist.contains(#"<span class="released">released 2003-09-29</span>"#))
        #expect(charts.contains(#"Mr. Brightside</a> <span class="year">2003</span>"#))
        #expect(review.contains(#"<span class="meta">Album · 1994</span>"#))
        #expect(review.contains(#"<span class="meta">Blue Album (Deluxe) · 1994</span>"#))
    }

    @Test func eachStationsCardShowsHowOldItsSongsAre() async throws {
        let harness = try await harnessWithAges()

        let stats = await page(harness, "/stats")

        let alt = try #require(stats.components(separatedBy: #"<section class="station s0">"#).dropFirst().first)
        #expect(alt.contains("<dt>Average age</dt><dd>20.0 years</dd>"))
        #expect(alt.contains("<dt>Median year</dt><dd>2006</dd>"))
        #expect(alt.contains("<dt>Under a year old</dt><dd>25%</dd>"))
        #expect(alt.contains("<dt>10+ years old</dt><dd>75%</dd>"))
        #expect(alt.contains("<p>Oldest song: <a "))
        #expect(alt.contains("Band – Old</a> · 1986</p>"))
        let rock = try #require(stats.components(separatedBy: #"<section class="station s1">"#).dropFirst().first)
        #expect(rock.contains("<dt>Average age</dt><dd>30.0 years</dd>"))
        #expect(rock.contains("<dt>Under a year old</dt><dd>0%</dd>"))
        #expect(rock.contains("<dt>10+ years old</dt><dd>100%</dd>"))
    }

    @Test func theDecadesChartSplitsEachStationsPlaysByReleaseDecade() async throws {
        let harness = try await harnessWithAges()

        let decades = try section(await page(harness, "/stats"), "Decades")

        #expect(decades.contains("<th>Before 1990</th><th>1990s</th><th>2000s</th><th>2010s</th><th>2020s</th>"))
        #expect(decades.contains("<tr><th>Alt 102.1</th><td>1 (25%)</td><td>0 (0%)</td><td>2 (50%)</td><td>0 (0%)</td><td>1 (25%)</td></tr>"))
        #expect(decades.contains("<tr><th>Rock 99</th><td>1 (50%)</td><td>0 (0%)</td><td>1 (50%)</td><td>0 (0%)</td><td>0 (0%)</td></tr>"))
        #expect(decades.contains("<tr><th>All stations</th><td>2 (33%)</td><td>0 (0%)</td><td>3 (50%)</td><td>0 (0%)</td><td>1 (17%)</td></tr>"))
        // A segment for each decade with plays, labeled when it's wide enough.
        #expect(decades.contains(#"data-tip="50% · 2000s · 2 plays">50%</span>"#))
        #expect(!decades.contains("1990s · 0 plays"))
    }

    @Test func theHourChartShowsWhenAStationRunsOlderOrNewer() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Band", "Old", released: released(harness, yearsAgo: 40))
        harness.music.addToCatalog("Band", "Fresh", released: released(harness, yearsAgo: 0.1))
        harness.music.addToCatalog("Band", "Once", released: released(harness, yearsAgo: 10))
        for minute in 185..<195 { harness.play("Band", "Old", minutesAgo: Double(minute)) }
        for minute in 785..<795 { harness.play("Band", "Fresh", minutesAgo: Double(minute)) }
        harness.play("Band", "Once", minutesAgo: 400)
        _ = try await harness.radio.run()
        func hour(_ minutesAgo: Double) -> Int {
            Calendar.current.component(.hour, from: harness.clock.now - minutesAgo * 60)
        }
        func label(_ hour: Int) -> String {
            hour == 0 ? "12 AM" : hour < 12 ? "\(hour) AM" : hour == 12 ? "12 PM" : "\(hour - 12) PM"
        }

        let hours = try section(await page(harness, "/stats"), "Song age by hour")

        // The station averages 19.6 years; an hour needs 10 plays.
        #expect(hours.contains(#"class="cell o4" tabindex="0" data-tip="40.0 years, 20.4 older than average · \#(label(hour(185))) · 10 plays""#))
        #expect(hours.contains(#"class="cell n4" tabindex="0" data-tip="0.1 years, 19.5 newer than average · \#(label(hour(785))) · 10 plays""#))
        #expect(hours.contains("<tr><th>\(label(hour(185)))</th><td>40.0</td></tr>"))
        #expect(hours.contains("<tr><th>\(label(hour(400)))</th><td></td></tr>"))
        #expect(hours.contains(#"class="cell none" tabindex="0" data-tip="Too few plays · \#(label(hour(400))) · 1 play""#))
    }

    @Test func newReleasesShowWhichStationPlayedThemFirst() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        harness.music.addToCatalog("Band", "Old", released: "1990-01-01")
        let fresh = released(harness, daysAgo: 10)
        let newer = released(harness, daysAgo: 5)
        harness.music.addToCatalog("Band", "Fresh", released: fresh)
        harness.music.addToCatalog("Band", "Newer", released: newer)
        harness.music.addToCatalog("Band", "Too Old", released: released(harness, daysAgo: 61))
        // Radio logged Alt 102.1 before either release, and Rock 99 only
        // after both.
        harness.play("Band", "Old", minutesAgo: 20 * 1440)
        harness.play("Band", "Fresh", minutesAgo: 8 * 1440)
        harness.play("Band", "Old", on: "101-2000", minutesAgo: 3 * 1440)
        harness.play("Band", "Fresh", on: "101-2000", minutesAgo: 1440)
        harness.play("Band", "Newer", on: "101-2000", minutesAgo: 60)
        harness.play("Band", "Too Old", minutesAgo: 30)
        _ = try await harness.radio.run()
        func day(_ date: String) -> String {
            try! Date(date, strategy: .iso8601.year().month().day())
                .formatted(Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day())
        }

        let releases = try section(await page(harness, "/stats"), "New releases")

        let newerRow = try #require(releases.range(of: "Band – Newer"))
        let freshRow = try #require(releases.range(of: "Band – Fresh"))
        #expect(newerRow.lowerBound < freshRow.lowerBound)
        #expect(!releases.contains("Too Old"))
        #expect(releases.contains("<li><time>\(day(fresh))</time> <a "))
        #expect(releases.contains(#"Band – Fresh</a> <span class="meta">2 plays</span> "#
            + #"<span class="tag s1">Rock 99</span> <span class="tag s0">Alt 102.1</span> "#
            + #"<span class="meta">· first on</span> <span class="tag s0">Alt 102.1</span> <span class="meta">2 days after release</span></li>"#))
        #expect(releases.contains("<li><time>\(day(newer))</time> <a "))
        #expect(releases.contains(#"Band – Newer</a> <span class="meta">1 play</span> <span class="tag s1">Rock 99</span></li>"#))
        #expect(releases.contains("<tr><th>Alt 102.1</th><td>1</td><td>1</td></tr>"))
        #expect(releases.contains("<tr><th>Rock 99</th><td>2</td><td>0</td></tr>"))
    }

    @Test func deepCutsListTheOldestSongsAndSharedSongsCountPairs() async throws {
        let harness = try await harnessWithAges()

        let stats = await page(harness, "/stats")

        let cuts = try section(stats, "Deep cuts")
        let old = try #require(cuts.components(separatedBy: #"<span class="rank">1</span> "#).dropFirst().first)
        #expect(old.hasPrefix(#"<span class="year">1986</span> <a "#))
        #expect(old.contains(#"Band – Old</a> <span class="meta">2 plays</span>"#))
        let mid = try #require(cuts.components(separatedBy: #"<span class="rank">2</span> "#).dropFirst().first)
        #expect(mid.hasPrefix(#"<span class="year">2006</span> <a "#))
        let shared = try section(stats, "Shared songs")
        #expect(shared.contains("<tr><th>Alt 102.1</th><td class=\"self\">3</td><td class=\"shared\" style=\"--share: 60%\">2</td></tr>"))
        #expect(shared.contains("<tr><th>Rock 99</th><td class=\"shared\" style=\"--share: 60%\">2</td><td class=\"self\">2</td></tr>"))
    }
}
