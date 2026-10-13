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

    @Test func firstSyncCreatesAPlaylistNamedAfterTheStationInOrderOfLatestPlay() async throws {
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

        #expect(report.added == ["Alt 102.1": 2])
        #expect(harness.music.playlists() == ["Alt 102.1": ["Africa", "My Hero"]])
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

        #expect(harness.music.playlists() == ["Alt 102.1": ["Glycerine", "Africa"]])
    }

    @Test func eachStationGetsItsOwnPlaylistAndSharedSongsAreSearchedOnce() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        harness.music.addToCatalog("Foo Fighters", "Everlong")
        harness.music.addToCatalog("Muse", "Uprising")
        harness.play("Foo Fighters", "Everlong", on: "101-1041", minutesAgo: 2)
        harness.play("Muse", "Uprising", on: "101-1041")
        harness.play("Foo Fighters", "Everlong", on: "101-2000")
        _ = try await harness.radio.run()

        #expect(harness.music.playlists() == ["Alt 102.1": ["Everlong", "Uprising"], "Rock 99": ["Everlong"]])
        #expect(harness.http.requests("GET https://api.music.apple.com/v1/catalog/us/search").count == 2)
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

        #expect(harness.music.playlists() == ["Alt 102.1": ["Come As You Are (Live)"]])
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

        #expect(harness.music.playlists() == ["Alt 102.1": ["Self-Aware"]])
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

        #expect(harness.music.playlists() == ["Alt 102.1": ["Africa", "Glycerine"]])
    }

    @Test func largeBacklogsAreAddedInBatches() async throws {
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

        let playlist = try #require(harness.music.playlists()["Alt 102.1"])
        #expect(playlist == (0..<120).map { "Song \($0)" })
    }
}

@Suite struct ConcurrentSyncTests {
    /// launchd's scheduled run and a manual `radio sync` can overlap, and the
    /// API can't delete a duplicate playlist or remove a twice-added song.
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
            notifier: PushoverNotifier(http: http, userKey: nil, apiKey: nil), now: { clock.now }
        )

        async let a = first.radio.sync()
        async let b = second.sync()
        let reports = try await [a, b]

        #expect(first.music.playlistNames() == ["Alt 102.1"])
        #expect(first.music.playlists()["Alt 102.1"] == (0..<5).map { "Song \($0)" })
        #expect(reports.filter { $0.skippedReason != nil }.count == 1)
    }
}
