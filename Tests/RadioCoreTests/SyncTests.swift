import Foundation
import RadioCore
import Testing

@Suite struct SyncTests {
    @Test func syncIsSkippedUntilAppleMusicIsSetUp() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("Muse", "Uprising")
        _ = try await harness.radio.poll()
        let report = try await harness.radio.sync()
        #expect(report.skippedReason != nil)
        #expect(harness.music.playlists().isEmpty)
    }

    @Test func firstSyncCreatesTheRadioAndArchivePlaylistsInOrderOfLatestPlay() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Weezer", "Africa")
        harness.music.addToCatalog("Foo Fighters", "My Hero")
        harness.play("Foo Fighters", "My Hero", minutesAgo: 9)
        harness.play("Weezer", "Africa", minutesAgo: 6)
        harness.play("Foo Fighters", "My Hero", minutesAgo: 3)
        _ = try await harness.radio.poll()

        let report = try await harness.radio.sync()

        #expect(report.playlists["Radio"]?.added == 2)
        #expect(report.playlists["Radio Archive"]?.added == 2)
        #expect(harness.music.playlists() == [
            "Radio": ["Africa", "My Hero"], "Radio (New)": ["Africa", "My Hero"],
            "Radio (Unplayed)": ["Africa", "My Hero"], "Radio Archive": ["Africa", "My Hero"],
        ])
    }

    @Test func laterSyncsAppendOnlyNewSongs() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Weezer", "Africa")
        harness.music.addToCatalog("Bush", "Glycerine")
        harness.play("Weezer", "Africa", minutesAgo: 5)
        _ = try await harness.radio.run()

        harness.clock.advance(hours: 1)
        harness.play("Bush", "Glycerine", minutesAgo: 2)
        harness.play("Weezer", "Africa")
        _ = try await harness.radio.run()

        #expect(harness.music.playlists()["Radio"] == ["Glycerine", "Africa"])
    }

    @Test func everyStationFeedsTheOneRadioPlaylistAndSharedSongsAreSearchedOnce() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        harness.music.addToCatalog("Foo Fighters", "Everlong")
        harness.music.addToCatalog("Muse", "Uprising")
        harness.play("Foo Fighters", "Everlong", on: "101-1041", minutesAgo: 6)
        harness.play("Muse", "Uprising", on: "101-1041", minutesAgo: 4)
        harness.play("Foo Fighters", "Everlong", on: "101-2000", minutesAgo: 2)
        _ = try await harness.radio.run()

        #expect(harness.music.playlistNames() == ["Radio", "Radio (New)", "Radio (Unplayed)", "Radio Archive"])
        #expect(harness.music.playlists()["Radio"] == ["Uprising", "Everlong"])
        #expect(harness.http.requests("GET https://api.music.apple.com/v1/catalog/us/search").count == 2)
        // Each song counts as added by the station whose play placed it.
        let stations = try await harness.radio.status().stations
        #expect(stations.map { $0.recentlyAdded.map(\.title) } == [["Uprising"], ["Everlong"]])
    }

    @Test func uncertainSongsAreHeldBackWithCandidates() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Come As You Are (Live)")
        harness.play("Nirvana", "Come As You Are")
        _ = try await harness.radio.run()

        let held = try await harness.radio.heldSongs()
        #expect(held.map(\.title) == ["Come As You Are"])
        #expect(held.first?.candidates.map(\.name) == ["Come As You Are (Live)"])
        #expect(held.first?.stations == ["Alt 102.1"])
        #expect(harness.music.playlists().isEmpty)
    }

    /// Without this, a song held back before a matching fix would wait for
    /// review even though the fix now accepts one of its candidates.
    @Test func heldSongsTheCurrentRulesAcceptAreAddedWithoutReview() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Come As You Are (Live)")
        harness.play("Nirvana", "Come As You Are")
        _ = try await harness.radio.run()
        // As if an earlier release had held back the studio version.
        let studio = harness.music.addToCatalog("Nirvana", "Come As You Are", album: "Nevermind")
        let candidates = String(decoding: try JSONEncoder().encode([studio]), as: UTF8.self)
        executeSQL(["UPDATE songs SET candidates = '\(candidates)'"], in: harness.home)

        let report = try await harness.radio.sync()

        #expect(report.matched == 1)
        #expect(try await harness.radio.heldSongs().isEmpty)
        #expect(harness.music.playlists()["Radio"] == ["Come As You Are"])
    }

    /// Before feeds were decoded, MOViN 92.5 logged "Macklemore &amp; Ryan
    /// Lewis", which held the song back.
    @Test func upgradingDecodesHTMLEntitiesInLoggedSongs() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "movin925.com", source: "hubbard")
        harness.music.addToCatalog("Macklemore & Ryan Lewis", "Can't Hold Us (feat. Ray Dalton)")
        harness.hubbard.play("Macklemore & Ryan Lewis", "Can't Hold Us", at: harness.clock.now.addingTimeInterval(-600))
        _ = try await harness.radio.poll()
        executeSQL(undoSchemaTwelve + [
            "UPDATE songs SET artist = 'Macklemore &amp; Ryan Lewis', key = 'macklemore and amp ryan lewis|cant hold us'",
            "UPDATE plays SET artist = 'Macklemore &amp; Ryan Lewis'",
            // Schema 6 had none of schema 8's additions.
            "ALTER TABLE songs DROP COLUMN jev_checked_at", "ALTER TABLE songs DROP COLUMN jev_model",
            "ALTER TABLE songs DROP COLUMN jev_score", "ALTER TABLE songs DROP COLUMN jev_pick",
            "ALTER TABLE songs DROP COLUMN undone_at", "DROP TABLE playlist_removals",
            "DROP TABLE listens", "DROP TABLE unheard_choices",
            "DELETE FROM playlist_tracks WHERE playlist = 'unheard'", "DELETE FROM playlists WHERE kind = 'unheard'",
            "PRAGMA user_version = 6",
        ], in: harness.home)
        let clock = harness.clock
        let upgraded = try Radio(
            home: harness.home, http: harness.http, sources: [HubbardSource(http: harness.http)],
            notifier: PushoverNotifier(http: harness.http, userKey: nil, apiKey: nil), musicApp: harness.musicApp,
            now: { clock.now }
        )
        harness.hubbard.play("Macklemore & Ryan Lewis", "Can't Hold Us", at: harness.clock.now)

        _ = try await upgraded.run()

        #expect(try await upgraded.heldSongs().isEmpty)
        #expect(harness.music.playlists()["Radio"] == ["Can't Hold Us (feat. Ray Dalton)"])
        let rows = try await upgraded.exportCSV(stationSlug: nil).split(separator: "\n").dropFirst()
        #expect(rows.count == 2 && rows.allSatisfy { $0.contains(",Macklemore & Ryan Lewis,Can't Hold Us,") })
    }

    @Test func pickingACandidateAddsItOnTheNextSync() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Come As You Are (Live)")
        harness.play("Nirvana", "Come As You Are")
        _ = try await harness.radio.run()
        let held = try #require(try await harness.radio.heldSongs().first)

        _ = try await harness.radio.match(songID: held.id, choice: .candidate(0))
        _ = try await harness.radio.sync()

        #expect(harness.music.playlists()["Radio"] == ["Come As You Are (Live)"])
        #expect(try await harness.radio.heldSongs().isEmpty)
    }

    @Test func pastingASongLinkMatchesThatSong() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        let chosen = harness.music.addToCatalog("Temper City", "Self-Aware")
        harness.play("Temper City", "Self Aware Remix Radio")
        _ = try await harness.radio.run()
        let held = try #require(try await harness.radio.heldSongs().first)

        _ = try await harness.radio.match(songID: held.id, choice: .link(chosen.url))
        _ = try await harness.radio.sync()

        #expect(harness.music.playlists()["Radio"] == ["Self-Aware"])
    }

    @Test func undoingAPickReturnsTheSongToReviewAndTakesItOutOfThePlaylists() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Lake of Fire (Live at Reading)")
        harness.music.addToCatalog("Nirvana", "Lake of Fire (Live Acoustic)", album: "MTV Unplugged In New York")
        harness.jev.score("Lake of Fire (Live at Reading)", 0.95)
        harness.play("Nirvana", "Lake Of Fire")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["Lake of Fire (Live at Reading)"])
        let picked = try #require(try await harness.radio.reviewedSongs().first)

        try await harness.radio.undo(songID: picked.id)

        let held = try #require(try await harness.radio.heldSongs().first)
        #expect(held.id == picked.id && held.suggestion == nil)
        #expect(try await harness.radio.reviewedSongs().isEmpty)
        _ = try await harness.radio.match(songID: held.id, choice: .candidate(1))
        _ = try await harness.radio.sync()
        #expect(harness.music.playlists()["Radio"] == ["Lake of Fire (Live Acoustic)"])
        #expect(harness.http.requests("POST https://api.typesafe.ai/").count == 1)
    }

    @Test func aSongSentBackStaysForReviewUntilPicked() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Come As You Are (Live)")
        harness.play("Nirvana", "Come As You Are")
        // Jev never judges the song, as for one held before Jev.
        harness.jev.setFailing(true)
        _ = try await harness.radio.run()
        harness.jev.setFailing(false)
        let held = try #require(try await harness.radio.heldSongs().first)
        _ = try await harness.radio.match(songID: held.id, choice: .candidate(0))
        _ = try await harness.radio.sync()

        try await harness.radio.undo(songID: held.id)
        // Candidates the matching rules or Jev would accept on their own.
        let studio = harness.music.addToCatalog("Nirvana", "Come As You Are", album: "Nevermind")
        harness.jev.score("Come As You Are", 0.99)
        let candidates = String(decoding: try JSONEncoder().encode([studio]), as: UTF8.self)
        executeSQL(["UPDATE songs SET candidates = '\(candidates)'"], in: harness.home)
        _ = try await harness.radio.sync()

        #expect(try await harness.radio.heldSongs().map(\.id) == [held.id])
        #expect(harness.music.playlists()["Radio"] == [])
        #expect(harness.http.requests("POST https://api.typesafe.ai/").count == 1)
    }

    @Test func undoingAPickSharedWithAnotherSongKeepsItInThePlaylists() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        let studio = harness.music.addToCatalog("Nirvana", "Come As You Are")
        harness.play("Nirvana", "Come As You Are", minutesAgo: 5)
        harness.play("Nirvana", "Come As You Are Radio Edit")
        _ = try await harness.radio.run()
        let held = try #require(try await harness.radio.heldSongs().first)
        _ = try await harness.radio.match(songID: held.id, choice: .link(studio.url))
        _ = try await harness.radio.sync()

        try await harness.radio.undo(songID: held.id)
        let report = try await harness.radio.sync()

        #expect(report.removed == 0)
        #expect(harness.music.playlists()["Radio"] == ["Come As You Are"])
        #expect(try await harness.radio.heldSongs().map(\.id) == [held.id])
    }

    @Test func undoingAnIgnoreReturnsTheSongToReview() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("Unknown Local Band", "Demo Tape")
        _ = try await harness.radio.run()
        let held = try #require(try await harness.radio.heldSongs().first)
        try await harness.radio.ignore(songID: held.id)
        #expect(try await harness.radio.reviewedSongs().map(\.decision) == [.ignored])

        try await harness.radio.undo(songID: held.id)

        #expect(try await harness.radio.heldSongs().map(\.id) == [held.id])
        #expect(try await harness.radio.reviewedSongs().isEmpty)
    }

    @Test func ignoredSongsAreNeverAdded() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("Unknown Local Band", "Demo Tape")
        _ = try await harness.radio.run()
        let held = try #require(try await harness.radio.heldSongs().first)

        try await harness.radio.ignore(songID: held.id)
        harness.clock.advance(hours: 1)
        harness.play("Unknown Local Band", "Demo Tape")
        _ = try await harness.radio.run()

        #expect(try await harness.radio.heldSongs().isEmpty)
        #expect(harness.music.playlists().isEmpty)
    }

    @Test func aPlaylistDeletedInMusicIsRecreatedWithEverySong() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Weezer", "Africa")
        harness.music.addToCatalog("Bush", "Glycerine")
        harness.play("Weezer", "Africa")
        _ = try await harness.radio.run()

        harness.music.deleteAllPlaylists()
        harness.clock.advance(hours: 1)
        harness.play("Bush", "Glycerine")
        _ = try await harness.radio.run()
        _ = try await harness.radio.sync()

        #expect(harness.music.playlists() == [
            "Radio": ["Africa", "Glycerine"], "Radio (New)": ["Africa", "Glycerine"],
            "Radio (Unplayed)": ["Africa", "Glycerine"], "Radio Archive": ["Africa", "Glycerine"],
        ])
    }

    @Test func aLargeBacklogFillsThePlaylistWithTheHundredLatestSongs() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        for index in 0..<120 {
            harness.music.addToCatalog("Band \(index)", "Song \(index)")
        }
        for batch in 0..<3 {
            for index in (batch * 40)..<((batch + 1) * 40) {
                harness.play("Band \(index)", "Song \(index)", minutesAgo: Double(40 - index % 40))
            }
            _ = try await harness.radio.poll()
            harness.clock.advance(hours: 1)
        }

        _ = try await harness.radio.sync()

        let playlist = try #require(harness.music.playlists()["Radio"])
        #expect(playlist == (20..<120).map { "Song \($0)" })
        #expect(harness.music.playlists()["Radio Archive"] == (0..<120).map { "Song \($0)" })
    }
}

@Suite struct ConcurrentSyncTests {
    /// launchd's scheduled run and a manual `radio sync` can overlap, and
    /// both could make the playlists.
    @Test func overlappingSyncsCreateOnePlaylistAndAddEachSongOnce() async throws {
        let http = FakeHTTP(latency: .milliseconds(5))
        let first = try Harness(http: http)
        try await first.signIn()
        _ = try await first.radio.addStation(slug: "alt1021rva")
        for index in 0..<5 {
            first.music.addToCatalog("Band \(index)", "Song \(index)")
            first.play("Band \(index)", "Song \(index)", minutesAgo: Double(10 - index))
        }
        _ = try await first.radio.poll()
        let clock = first.clock
        let second = try Radio(
            home: first.home, http: http, sources: [AudacySource(http: http)],
            notifier: PushoverNotifier(http: http, userKey: nil, apiKey: nil), musicApp: first.musicApp, now: { clock.now }
        )

        async let a = first.radio.sync()
        async let b = second.sync()
        let reports = try await [a, b]

        #expect(first.music.playlistNames() == ["Radio", "Radio (New)", "Radio (Unplayed)", "Radio Archive"])
        #expect(first.music.playlists()["Radio"] == (0..<5).map { "Song \($0)" })
        #expect(reports.filter { $0.skippedReason != nil }.count == 1)
    }
}
