import Foundation
import RadioCore
import SQLite3
import Testing

@Suite struct MusicAppTests {
    func harnessWithSongs(_ titles: [String], released: [String: String] = [:], playlistLimit: Int = 100,
                          archiveLimit: Int = 10_000) async throws -> Harness {
        let harness = try Harness(playlistLimit: playlistLimit, archiveLimit: archiveLimit)
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        for (index, title) in titles.enumerated() {
            harness.music.addToCatalog("Band", title, released: released[title])
            harness.play("Band", title, minutesAgo: Double(titles.count - index))
        }
        _ = try await harness.radio.run()
        return harness
    }

    @Test func aReplayedSongMovesToTheEnd() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"])
        harness.clock.advance(hours: 1)
        harness.play("Band", "B")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["A", "C", "B"])
    }

    @Test func replaysMoveInTheOrderTheyWerePlayed() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C", "D"])
        harness.clock.advance(hours: 1)
        harness.play("Band", "C", minutesAgo: 5)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["B", "D", "C", "A"])
    }

    @Test func aSongReplayedOnAnotherStationMovesToTheEnd() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"])
        _ = try await harness.radio.addStation(slug: "rock")
        harness.clock.advance(hours: 1)
        harness.play("Band", "A", on: "101-2000")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["B", "C", "A"])
    }

    @Test func aNewSongPushesTheLeastRecentlyPlayedOneOutOfAFullPlaylist() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"], playlistLimit: 3)
        harness.music.addToCatalog("Band", "D")
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        let (_, sync) = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["B", "C", "D"])
        #expect(sync.playlists["Radio"]?.added == 1)
        #expect(sync.playlists["Radio"]?.dropped == 1)
        #expect(try await harness.radio.status().playlistCount == 3)
    }

    /// The user asked on 2026-10-20 for a new song to push the song they've
    /// played and skipped most out of a playlist, then for that playlist to
    /// be "Radio (Unplayed)", beside a "Radio" that drops the least recently
    /// played, like the archive.
    @Test func aNewSongPushesOutTheSongYouPlayedAndSkippedMostFromRadioUnplayed() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"], playlistLimit: 3)
        harness.music.setListens("A", plays: 2)
        harness.music.setListens("B", plays: 1, skips: 2)
        harness.music.addToCatalog("Band", "D")
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        let (_, sync) = try await harness.radio.run()
        #expect(harness.music.playlists() == [
            "Radio": ["B", "C", "D"], "Radio (New)": ["B", "C", "D"],
            "Radio (Unplayed)": ["A", "C", "D"], "Radio Archive": ["A", "B", "C", "D"],
        ])
        #expect(sync.playlists["Radio (Unplayed)"]?.dropped == 1)
        #expect(sync.playlists["Radio"]?.dropped == 1)
    }

    @Test func amongSongsYouPlayedEquallyTheLeastRecentlyPlayedOneDrops() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"], playlistLimit: 3)
        harness.music.setListens("A", plays: 1)
        harness.music.setListens("C", skips: 1)
        harness.music.addToCatalog("Band", "D")
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio (Unplayed)"] == ["B", "C", "D"])
    }

    /// A song stays out of a full "Radio (Unplayed)" when you've played it more
    /// than every song there, so it can't bounce in and out on each sync. It
    /// gets in once a song there passes it.
    @Test func aReplayedSongYouPlayedMostStaysOutOfRadioUnplayed() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C", "D"], playlistLimit: 3)
        harness.music.setListens("A", plays: 5)
        harness.clock.advance(hours: 1)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == [
            "Radio": ["C", "D", "A"], "Radio (New)": ["C", "D", "A"],
            "Radio (Unplayed)": ["B", "C", "D"], "Radio Archive": ["B", "C", "D", "A"],
        ])

        let calls = harness.musicApp.calls
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.musicApp.calls == calls)

        harness.music.setListens("C", plays: 6)
        harness.clock.advance(hours: 1)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio (Unplayed)"] == ["B", "D", "A"])
    }

    @Test func aSongAlreadyInYourLibraryThatYouPlayedMostStaysOutOfRadioUnplayed() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"], playlistLimit: 3)
        harness.music.addToCatalog("Band", "D")
        harness.music.addToLibrary("D")
        harness.music.setListens("D", plays: 40)
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == [
            "Radio": ["B", "C", "D"], "Radio (New)": ["B", "C", "D"],
            "Radio (Unplayed)": ["A", "B", "C"], "Radio Archive": ["A", "B", "C", "D"],
        ])
    }

    /// Playing the songs in "Radio (Unplayed)" doesn't bring back one it dropped;
    /// only a station playing that song again does.
    @Test func aDroppedSongReturnsOnlyWhenAStationPlaysItAgain() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C", "D"], playlistLimit: 3)
        for title in ["B", "C", "D"] { harness.music.setListens(title, plays: 3) }
        harness.clock.advance(hours: 1)
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio (Unplayed)"] == ["B", "C", "D"])
    }

    /// The first choices for "Radio (Unplayed)" are the songs "Radio" held, the
    /// most recently played; your plays decide only what later songs push
    /// out.
    @Test func radioUnplayedStartsWithTheMostRecentlyPlayedSongs() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C", "D"], playlistLimit: 3)
        executeSQL(["DELETE FROM unheard_choices"], in: harness.home)
        harness.music.setListens("B", plays: 9)
        harness.clock.advance(hours: 1)
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio (Unplayed)"] == ["B", "C", "D"])
    }

    /// When the user split the playlists on 2026-10-20, the playlist that
    /// had been "Radio" kept its name and went back to the most recently
    /// played songs, and "Radio (Unplayed)" started with the songs Radio had
    /// chosen for it.
    @Test func upgradingKeepsRadioAndStartsRadioUnplayedWithItsChoices() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C", "D"], playlistLimit: 3)
        // Schema 10 had no "Radio (Unplayed)", then named "Radio (New)", or
        // today's "Radio (New)". Its choices, A, C, and D, were for "Radio".
        harness.music.deletePlaylist("Radio (Unplayed)")
        harness.music.deletePlaylist("Radio (New)")
        executeSQL(undoSchemaTwelve + [
            "DELETE FROM playlist_tracks WHERE playlist = 'unheard'", "DELETE FROM playlists WHERE kind = 'unheard'",
            "ALTER TABLE unheard_choices RENAME TO radio_choices",
            "UPDATE radio_choices SET chosen = catalog_id IN (SELECT catalog_id FROM songs WHERE title IN ('A', 'C', 'D'))",
            "PRAGMA user_version = 10",
        ], in: harness.home)
        let clock = harness.clock
        let upgraded = try Radio(
            home: harness.home, http: harness.http, sources: [AudacySource(http: harness.http)],
            notifier: PushoverNotifier(http: harness.http, userKey: nil, apiKey: nil), musicApp: harness.musicApp,
            playlistLimit: 3, now: { clock.now }
        )
        harness.clock.advance(hours: 0.25)

        _ = try await upgraded.run()

        #expect(harness.music.playlists() == [
            "Radio": ["B", "C", "D"], "Radio (New)": ["B", "C", "D"],
            "Radio (Unplayed)": ["A", "C", "D"], "Radio Archive": ["A", "B", "C", "D"],
        ])
    }

    /// The user asked on 2026-10-22 for a "Radio (New)" in which a new song
    /// pushes out the oldest release, and renamed the playlist that had the
    /// name "Radio (Unplayed)".
    @Test func aNewerReleasePushesTheOldestOneOutOfRadioNew() async throws {
        let harness = try await harnessWithSongs(
            ["A", "B", "C"], released: ["A": "2026-01-09", "B": "1991-09-10", "C": "2025-06-01"], playlistLimit: 3
        )
        harness.music.addToCatalog("Band", "D", released: "2024-02-02")
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        let (_, sync) = try await harness.radio.run()
        #expect(harness.music.playlists() == [
            "Radio": ["B", "C", "D"], "Radio (New)": ["A", "C", "D"], "Radio (Unplayed)": ["B", "C", "D"],
            "Radio Archive": ["A", "B", "C", "D"],
        ])
        #expect(sync.playlists["Radio (New)"]?.dropped == 1)
        #expect(try await harness.radio.status().newCount == 3)
    }

    /// A release older than every song in a full "Radio (New)" stays out.
    /// A year without a day counts from the start of that year.
    @Test func anOlderReleaseStaysOutOfAFullRadioNew() async throws {
        let harness = try await harnessWithSongs(
            ["A", "B", "C"], released: ["A": "2026-03-01", "B": "1979-06-01", "C": "2026-02-20"], playlistLimit: 3
        )
        harness.music.addToCatalog("Band", "D", released: "1979")
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        let (_, sync) = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio (New)"] == ["A", "B", "C"])
        #expect(sync.playlists["Radio (New)"]?.added == 0)
    }

    /// A song Apple gives no release date leaves first, then, among songs
    /// released the same day, the one the stations played longest ago.
    @Test func amongSongsReleasedTheSameDayTheLeastRecentlyPlayedOneDrops() async throws {
        let harness = try await harnessWithSongs(
            ["B", "C", "A"], released: ["B": "2026-10-02", "C": "2026-10-02"], playlistLimit: 3
        )
        harness.music.addToCatalog("Band", "D", released: "2026-10-02")
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio (New)"] == ["B", "C", "D"])

        harness.music.addToCatalog("Band", "E", released: "2026-10-02")
        harness.clock.advance(hours: 1)
        harness.play("Band", "E")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio (New)"] == ["C", "D", "E"])
    }

    /// The first sync fills "Radio (New)" with the newest releases the
    /// stations have played, in play order.
    @Test func radioNewStartsWithTheNewestReleasesTheStationsPlayed() async throws {
        let harness = try await harnessWithSongs(
            ["A", "B", "C", "D", "E"],
            released: ["A": "2026-05-01", "B": "2001-01-01", "C": "2025-08-15", "D": "1999-12-31", "E": "2024-04-04"],
            playlistLimit: 3
        )
        #expect(harness.music.playlists()["Radio (New)"] == ["A", "C", "E"])
        #expect(harness.music.playlists()["Radio"] == ["C", "D", "E"])
    }

    /// Upgrading renames the playlist that was "Radio (New)" in place, so it
    /// keeps its songs and its place in Music, before making the new
    /// "Radio (New)", which finds the release dates of songs matched before.
    @Test func upgradingRenamesRadioNewToRadioUnplayedAndMakesANewRadioNew() async throws {
        let harness = try await harnessWithSongs(
            ["A", "B", "C", "D"],
            released: ["A": "2026-01-01", "B": "1999-01-01", "C": "2025-01-01", "D": "2001-01-01"], playlistLimit: 3
        )
        // Schema 11's "Radio (New)" is today's "Radio (Unplayed)".
        harness.music.deletePlaylist("Radio (New)")
        harness.music.renamePlaylist("Radio (Unplayed)", to: "Radio (New)")
        executeSQL(undoSchemaTwelve + ["PRAGMA user_version = 11"], in: harness.home)
        let clock = harness.clock
        let upgraded = try Radio(
            home: harness.home, http: harness.http, sources: [AudacySource(http: harness.http)],
            notifier: PushoverNotifier(http: harness.http, userKey: nil, apiKey: nil), musicApp: harness.musicApp,
            playlistLimit: 3, now: { clock.now }
        )
        harness.clock.advance(hours: 0.25)

        _ = try await upgraded.run()

        #expect(harness.music.playlistNames() == ["Radio", "Radio (Unplayed)", "Radio Archive", "Radio (New)"])
        #expect(harness.music.playlists() == [
            "Radio": ["B", "C", "D"], "Radio (New)": ["A", "C", "D"], "Radio (Unplayed)": ["B", "C", "D"],
            "Radio Archive": ["A", "B", "C", "D"],
        ])
    }

    /// Every library track's plays and skips came to about 160 KB, more
    /// than a pipe holds, and osascript stalled until the timeout on
    /// 2026-10-20.
    @Test func aReplyLongerThanAPipeHoldsIsReadInFull() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("osascript-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let osascript = directory.appendingPathComponent("osascript")
        try """
            #!/bin/sh
            i=0
            while [ $i -lt 5000 ]; do printf 'Song %d\\037Band\\0373\\0371\\036' $i; i=$((i + 1)); done
            """.write(to: osascript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: osascript.path)

        let listens = try await ScriptedMusicApp(timeout: 10, osascript: osascript.path).listens()

        #expect(listens.count == 5000)
        #expect(listens.last == TrackListens(name: "Song 4999", artist: "Band", plays: 3, skips: 1))
    }

    @Test func musicsPlaysAndSkipsAreReadFromTheScriptsOutput() {
        let record = String(UnicodeScalar(30)), field = String(UnicodeScalar(31))
        let output = ["Babydoll", "Dominic Fike", "12", "3"].joined(separator: field) + record
            + ["Tab\there", "Band", "0", "0"].joined(separator: field)
        #expect(ScriptedMusicApp.listens(fromOutput: output) == [
            TrackListens(name: "Babydoll", artist: "Dominic Fike", plays: 12, skips: 3),
            TrackListens(name: "Tab\there", artist: "Band", plays: 0, skips: 0),
        ])
        #expect(ScriptedMusicApp.listens(fromOutput: "").isEmpty)
    }

    /// Music.app uploads its whole copy of a playlist it changed, so a song
    /// added on Apple's side that Music.app hadn't downloaded yet was lost
    /// (2026-10-13: "Radio" held 35 of 100 songs).
    @Test func songsAddedWhileMusicIsBehindAreKept() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"], playlistLimit: 3)
        harness.music.setSyncDelayed(true)
        harness.music.addToCatalog("Band", "D")
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        _ = try await harness.radio.run()
        harness.music.syncMusicApp()
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        harness.music.syncMusicApp()

        #expect(harness.music.playlists() == [
            "Radio": ["B", "C", "D"], "Radio (New)": ["B", "C", "D"],
            "Radio (Unplayed)": ["B", "C", "D"], "Radio Archive": ["A", "B", "C", "D"],
        ])
        #expect(try await harness.radio.status().playlistCount == 3)
    }

    /// Two stations' spellings can match two releases with the same title
    /// and artist, which Music.app finds as one track.
    @Test func aMatchWithTheTitleAndArtistOfAnEarlierOneSharesItsEntry() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Band", "Song (feat. Guest)")
        harness.play("Band", "Song")
        _ = try await harness.radio.run()
        harness.music.addToCatalog("Band", "Song (Feat. Guest)", album: "Hits", explicit: true)
        harness.clock.advance(hours: 0.25)
        harness.play("Band", "Song Feat. Guest")

        let (_, sync) = try await harness.radio.run()

        #expect(sync.matched == 1)
        #expect(harness.music.playlists()["Radio Archive"] == ["Song (feat. Guest)"])
        let status = try await harness.radio.status()
        let counts = [status.playlistCount, status.newCount, status.unplayedCount, status.archiveCount]
        #expect(counts == [1, 1, 1, 1])
    }

    /// On 2026-10-25, four such pairs left "Radio Archive" with 836 songs
    /// while Radio counted 840.
    @Test func upgradingMergesMatchesMusicCannotTellApart() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Band", "Song (feat. Guest)", released: "2001-01-01")
        harness.play("Band", "Song")
        _ = try await harness.radio.run()
        let hits = harness.music.addToCatalog("Band", "Song (Feat. Guest)", album: "Hits", released: "2020-01-01")
        harness.clock.advance(hours: 0.25)
        let later = harness.clock.now.formatted(.iso8601)
        // Schema 12 matched the second spelling to the second release, and
        // Music.app placed it as the first release's entry.
        executeSQL([
            """
            INSERT INTO songs (id, key, artist, title, status, catalog_id, catalog_url, catalog_name, catalog_artist,
                catalog_album, matched_by, first_heard_at, resolved_at)
            VALUES (2, 'band|song feat guest', 'Band', 'Song Feat. Guest', 'matched', '\(hits.id)', '\(hits.url)',
                'Song (Feat. Guest)', 'Band', 'Hits', 'auto', '\(later)', '\(later)')
            """,
            "INSERT INTO plays VALUES (1, 'later', '\(later)', 'Band', 'Song Feat. Guest', 2)",
            "INSERT INTO playlist_tracks SELECT kind, '\(hits.id)', 2, 1, '\(later)', '\(later)' FROM playlists",
            "INSERT INTO release_dates VALUES ('\(hits.id)', '2020-01-01')",
            "PRAGMA user_version = 12",
        ], in: harness.home)
        let clock = harness.clock
        let upgraded = try Radio(
            home: harness.home, http: harness.http, sources: [AudacySource(http: harness.http)],
            notifier: PushoverNotifier(http: harness.http, userKey: nil, apiKey: nil), musicApp: harness.musicApp,
            now: { clock.now }
        )
        let editsBefore = harness.musicApp.calls

        _ = try await upgraded.run()

        let status = try await upgraded.status()
        let counts = [status.playlistCount, status.newCount, status.unplayedCount, status.archiveCount]
        #expect(counts == [1, 1, 1, 1])
        #expect(harness.music.playlists()["Radio Archive"] == ["Song (feat. Guest)"])
        let page = String(decoding: await Dashboard(radio: upgraded).handle(
            WebRequest(method: "GET", path: "/playlists/new", query: [:], headers: [:], body: Data(), isLoopback: false)
        ).body, as: UTF8.self)
        #expect(page.contains("released 2001-01-01"))
        #expect(!page.contains("2020-01-01"))
        #expect(page.contains("Alt 102.1 ×2"))
        // Only the comment, which now counts both plays, changes.
        #expect(harness.musicApp.calls == editsBefore + 1)
    }

    @Test func theArchiveKeepsEverySongAndMovesReplays() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"], playlistLimit: 3)
        harness.music.addToCatalog("Band", "D")
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == [
            "Radio": ["B", "C", "D"], "Radio (New)": ["B", "C", "D"],
            "Radio (Unplayed)": ["B", "C", "D"], "Radio Archive": ["A", "B", "C", "D"],
        ])

        // A returns to Radio and moves to the end of the archive.
        harness.clock.advance(hours: 1)
        harness.play("Band", "A")
        let (_, sync) = try await harness.radio.run()
        #expect(harness.music.playlists() == [
            "Radio": ["C", "D", "A"], "Radio (New)": ["C", "D", "A"],
            "Radio (Unplayed)": ["C", "D", "A"], "Radio Archive": ["B", "C", "D", "A"],
        ])
        #expect(sync.playlists["Radio Archive"]?.moved == 1)
        let status = try await harness.radio.status()
        #expect((status.playlistCount, status.archiveCount) == (3, 4))
    }

    @Test func theArchiveDropsTheLeastRecentlyPlayedSongsPastItsLimit() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C", "D"], playlistLimit: 2, archiveLimit: 3)
        #expect(harness.music.playlists() == [
            "Radio": ["C", "D"], "Radio (New)": ["C", "D"],
            "Radio (Unplayed)": ["C", "D"], "Radio Archive": ["B", "C", "D"],
        ])

        harness.music.addToCatalog("Band", "E")
        harness.clock.advance(hours: 1)
        harness.play("Band", "E")
        let (_, sync) = try await harness.radio.run()
        #expect(harness.music.playlists() == [
            "Radio": ["D", "E"], "Radio (New)": ["D", "E"],
            "Radio (Unplayed)": ["D", "E"], "Radio Archive": ["C", "D", "E"],
        ])
        #expect(sync.playlists["Radio Archive"]?.dropped == 1)
    }

    @Test func aReplayKeepsASongInAFullPlaylist() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"], playlistLimit: 3)
        harness.music.addToCatalog("Band", "D")
        harness.clock.advance(hours: 1)
        harness.play("Band", "A", minutesAgo: 5)
        harness.play("Band", "D")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["C", "A", "D"])
    }

    @Test func aBacklogAddsOnlyTheMostRecentlyPlayedSongs() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C", "D", "E"], playlistLimit: 3)
        #expect(harness.music.playlists() == [
            "Radio": ["C", "D", "E"], "Radio (New)": ["C", "D", "E"],
            "Radio (Unplayed)": ["C", "D", "E"], "Radio Archive": ["A", "B", "C", "D", "E"],
        ])
    }

    @Test func thePlaylistsCatchUpOnceMusicWorksAgain() async throws {
        let harness = try await harnessWithSongs(["A", "B"], playlistLimit: 2)
        harness.music.addToCatalog("Band", "C")
        harness.musicApp.fail(with: "Radio isn't allowed to control Music")
        harness.clock.advance(hours: 1)
        harness.play("Band", "C")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["A", "B"])

        harness.musicApp.fail(with: nil)
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["B", "C"])
    }

    @Test func aSongToDropThatWasRemovedByHandIsForgotten() async throws {
        let harness = try await harnessWithSongs(["A", "B"], playlistLimit: 2)
        harness.music.addToCatalog("Band", "C")
        harness.music.removeByHand("A", from: "Radio")
        harness.clock.advance(hours: 2)
        harness.play("Band", "C")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["B", "C"])
        #expect(try await harness.radio.status().playlistCount == 2)
    }

    @Test func songsAreNotMovedUnlessTheyPlayAgainAfterBeingAdded() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Band", "A")
        harness.music.addToCatalog("Band", "B")
        harness.play("Band", "A", minutesAgo: 9)
        harness.play("Band", "B", minutesAgo: 6)
        harness.play("Band", "A", minutesAgo: 3)
        _ = try await harness.radio.run()
        let calls = harness.musicApp.calls
        harness.clock.advance(hours: 1)
        _ = try await harness.radio.run()

        // Each song is added at its latest play, so nothing needs moving.
        #expect(harness.music.playlists()["Radio"] == ["B", "A"])
        #expect(harness.musicApp.calls == calls)
    }

    @Test func aMoveMusicCannotMakeIsReportedAndRetried() async throws {
        let harness = try await harnessWithSongs(["A", "B"])
        harness.musicApp.fail(with: "Radio isn't allowed to control Music")
        harness.clock.advance(hours: 1)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["A", "B"])
        #expect(try await harness.radio.status().musicAppError == "Radio isn't allowed to control Music")

        harness.musicApp.fail(with: nil)
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["B", "A"])
        #expect(try await harness.radio.status().musicAppError == nil)
    }

    @Test func aPlaylistRenamedInMusicIsStillFound() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"])
        harness.clock.advance(hours: 1)
        harness.play("Band", "A")
        _ = try await harness.radio.run()

        harness.music.renamePlaylist("Radio", to: "Radio Songs")
        harness.clock.advance(hours: 1)
        harness.play("Band", "B")
        _ = try await harness.radio.run()

        #expect(harness.music.playlists()["Radio Songs"] == ["C", "A", "B"])
    }

    @Test func aNewSongWaitsUntilItsLibraryTrackReachesMusic() async throws {
        let harness = try await harnessWithSongs(["A", "B"])
        let song = harness.music.addToCatalog("Band", "C")
        harness.music.setReachesMusicApp("C", false)
        harness.clock.advance(hours: 0.25)
        harness.play("Band", "C")
        let (_, waiting) = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["A", "B"])
        #expect(waiting.playlists["Radio"]?.waiting == 1)

        harness.music.setReachesMusicApp("C", true)
        harness.clock.advance(hours: 0.25)
        let (_, placed) = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["A", "B", "C"])
        #expect(placed.playlists["Radio"]?.added == 1)
        // Apple was asked once to add the song to the library.
        #expect(harness.http.requests("POST https://api.music.apple.com/v1/me/library?")
            .filter { $0.url.query?.contains(song.id) == true }.count == 1)
    }

    @Test func songsPlayedAfterAWaitingSongWaitToKeepPlayOrder() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"])
        harness.music.addToCatalog("Band", "D")
        harness.music.setReachesMusicApp("D", false)
        harness.clock.advance(hours: 0.25)
        harness.play("Band", "D", minutesAgo: 5)
        harness.play("Band", "A")
        let (_, waiting) = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["A", "B", "C"])
        #expect(waiting.playlists["Radio"]?.waiting == 2)

        harness.music.setReachesMusicApp("D", true)
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["B", "C", "D", "A"])
    }

    @Test func aSongThatNeverReachesMusicStopsHoldingOthersBackAfterAnHour() async throws {
        let harness = try await harnessWithSongs(["A", "B"])
        harness.music.addToCatalog("Band", "C")
        harness.music.setReachesMusicApp("C", false)
        harness.clock.advance(hours: 0.25)
        harness.play("Band", "C", minutesAgo: 5)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        harness.clock.advance(hours: 1)
        let (_, sync) = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["B", "A"])
        let changes = try #require(sync.playlists["Radio"])
        #expect((changes.added, changes.moved, changes.waiting) == (0, 1, 1))
    }

    @Test func aSongRemovedByHandReturnsWhenItPlaysAgain() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"])
        harness.music.removeByHand("A", from: "Radio")
        harness.clock.advance(hours: 2)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["B", "C", "A"])
    }

    @Test func anotherPlaylistWithTheSameNameIsReportedRatherThanGuessed() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Band", "A")
        _ = harness.music.seedPlaylist(name: "Radio", songIDs: [])
        _ = harness.music.seedPlaylist(name: "Radio", songIDs: [])
        harness.play("Band", "A")
        _ = try await harness.radio.run()

        #expect(harness.music.playlistNames() == ["Radio", "Radio"])
        #expect(try await harness.radio.status().musicAppError?.contains("more than one playlist named \"Radio\"") == true)
    }

    // MARK: Comments

    /// A time as Radio's comments give it: to the minute, in the Mac's time
    /// zone, so the Comments column sorts in time order.
    func minute(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// The user asked on 2026-10-20 for each station's play count, shown
    /// only when it played the song more than once.
    @Test func eachSongsCommentGivesItsLatestPlayAndHowOftenEachStationPlayedIt() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        harness.music.addToCatalog("Band", "A")
        harness.music.addToCatalog("Band", "B")
        harness.play("Band", "A", minutesAgo: 40)
        harness.play("Band", "A", minutesAgo: 30)
        harness.play("Band", "A", on: "101-2000", minutesAgo: 20)
        harness.play("Band", "B", minutesAgo: 10)
        _ = try await harness.radio.run()

        let now = harness.clock.now
        #expect(harness.music.comment(of: "A") == "📻 \(minute(now - 20 * 60)) · Rock 99, Alt 102.1 ×2")
        #expect(harness.music.comment(of: "B") == "📻 \(minute(now - 10 * 60)) · Alt 102.1")
    }

    @Test func aReplayUpdatesTheComment() async throws {
        let harness = try await harnessWithSongs(["A", "B"])
        _ = try await harness.radio.addStation(slug: "rock")
        harness.clock.advance(hours: 1)
        harness.play("Band", "A", on: "101-2000")
        let (_, sync) = try await harness.radio.run()

        #expect(harness.music.comment(of: "A") == "📻 \(minute(harness.clock.now)) · Rock 99, Alt 102.1")
        #expect(sync.commented == 1)
    }

    @Test func aCommentSomeoneElseWroteIsKept() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Band", "A")
        harness.music.addToCatalog("Band", "B")
        harness.music.writeCommentByHand("Saw them live", on: "A")
        harness.play("Band", "A", minutesAgo: 2)
        harness.play("Band", "B", minutesAgo: 1)
        _ = try await harness.radio.run()
        harness.music.writeCommentByHand("Great bridge", on: "B")
        harness.clock.advance(hours: 1)
        harness.play("Band", "A")
        harness.play("Band", "B")
        _ = try await harness.radio.run()

        #expect(harness.music.comment(of: "A") == "Saw them live")
        #expect(harness.music.comment(of: "B") == "Great bridge")
    }

    @Test func commentsMusicCouldNotWriteAreWrittenOnceItWorksAgain() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Band", "A")
        harness.play("Band", "A")
        harness.musicApp.fail(with: "Radio isn't allowed to control Music")
        _ = try await harness.radio.run()
        #expect(harness.music.comment(of: "A") == nil)

        harness.musicApp.fail(with: nil)
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.music.comment(of: "A") == "📻 \(minute(harness.clock.now - 15 * 60)) · Alt 102.1")
    }

    /// Databases from earlier releases (schema 1, and schema 2 on the Mac
    /// mini since 2026-10-13) gave each station its own playlist. The first
    /// release also accepted DJ mixes that the matcher now rejects.
    @Test func upgradingStartsOneRadioPlaylistWithEverySongAndReplacesDJMixes() async throws {
        let harness = try Harness()
        try await harness.signIn()
        let dog = harness.music.addToCatalog("Florence + the Machine", "Dog Days Are Over (Mixed)", album: "Festival Mix 2022 (DJ Mix)")
        let savior = harness.music.addToCatalog("Rise Against", "Savior")
        let numb = harness.music.addToCatalog("LINKIN PARK", "Numb")
        harness.music.addToCatalog("Florence + the Machine", "Dog Days Are Over", album: "Lungs")
        let playlistID = harness.music.seedPlaylist(name: "Alt 102.1", songIDs: [dog.id, savior.id, numb.id])
        let now = harness.clock.now
        func at(_ minutes: Double) -> String { now.addingTimeInterval(-minutes * 60).formatted(.iso8601) }
        let home = RadioHome(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-tests-\(UUID().uuidString)"))
        try writeSchemaOneDatabase(at: home, statements: [
            "INSERT INTO stations VALUES (1, 'alt1021rva', 'audacy', '101-1041', 'Alt 102.1', '\(playlistID)', '\(at(60))', '\(at(1))', NULL, NULL, NULL)",
            "INSERT INTO songs VALUES (1, 'florence and the machine|dog days are over', 'Florence + The Machine', 'Dog Days Are Over', 'matched', '\(dog.id)', '\(dog.url)', 'auto', '[]', '\(at(30))', NULL, '\(at(29))')",
            "INSERT INTO songs VALUES (2, 'rise against|savior', 'Rise Against', 'Savior', 'matched', '\(savior.id)', '\(savior.url)', 'auto', '[]', '\(at(20))', NULL, '\(at(19))')",
            "INSERT INTO songs VALUES (3, 'linkin park|numb', 'Linkin Park', 'Numb', 'matched', '\(numb.id)', '\(numb.url)', 'auto', '[]', '\(at(10))', NULL, '\(at(9))')",
            "INSERT INTO plays VALUES (1, '1', '\(at(30))', 'Florence + The Machine', 'Dog Days Are Over', 1)",
            "INSERT INTO plays VALUES (1, '2', '\(at(20))', 'Rise Against', 'Savior', 2)",
            "INSERT INTO plays VALUES (1, '3', '\(at(10))', 'Linkin Park', 'Numb', 3)",
            "INSERT INTO plays VALUES (1, '4', '\(at(5))', 'Rise Against', 'Savior', 2)",
            "INSERT INTO playlist_tracks VALUES (1, '\(dog.id)', 1, '\(at(29))')",
            "INSERT INTO playlist_tracks VALUES (1, '\(savior.id)', 2, '\(at(19))')",
            "INSERT INTO playlist_tracks VALUES (1, '\(numb.id)', 3, '\(at(9))')",
        ])
        for file in try FileManager.default.contentsOfDirectory(atPath: harness.home.directory.path)
        where file.hasSuffix(".json") || file.hasSuffix(".p8") {
            try FileManager.default.copyItem(at: harness.home.directory.appendingPathComponent(file),
                                             to: home.directory.appendingPathComponent(file))
        }
        let clock = harness.clock
        let upgraded = try Radio(
            home: home, http: harness.http, sources: [AudacySource(http: harness.http)],
            notifier: PushoverNotifier(http: harness.http, userKey: nil, apiKey: nil),
            musicApp: harness.musicApp, now: { clock.now }
        )

        _ = try await upgraded.sync()

        // The station's old playlist is left as it was. The new one holds the
        // album version instead of the DJ mix, in order of latest play.
        #expect(harness.music.playlists() == [
            "Alt 102.1": ["Dog Days Are Over (Mixed)", "Savior", "Numb"],
            "Radio": ["Dog Days Are Over", "Numb", "Savior"],
            "Radio (New)": ["Dog Days Are Over", "Numb", "Savior"],
            "Radio (Unplayed)": ["Dog Days Are Over", "Numb", "Savior"],
            "Radio Archive": ["Dog Days Are Over", "Numb", "Savior"],
        ])
        #expect(try await upgraded.status().playlistCount == 3)
    }

    /// The Mac mini's database since 2026-10-13 (schema 3) already has a
    /// "Radio" playlist, which the archive must not replace or duplicate.
    @Test func upgradingKeepsTheRadioPlaylistAndStartsTheArchive() async throws {
        let harness = try Harness()
        try await harness.signIn()
        let savior = harness.music.addToCatalog("Rise Against", "Savior")
        let numb = harness.music.addToCatalog("LINKIN PARK", "Numb")
        let playlistID = harness.music.seedPlaylist(name: "Radio", songIDs: [savior.id, numb.id])
        let now = harness.clock.now
        func at(_ minutes: Double) -> String { now.addingTimeInterval(-minutes * 60).formatted(.iso8601) }
        let home = RadioHome(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-tests-\(UUID().uuidString)"))
        try writeSchemaThreeDatabase(at: home, statements: [
            "INSERT INTO stations VALUES (1, 'alt1021rva', 'audacy', '101-1041', 'Alt 102.1', '\(at(60))', '\(at(1))', NULL, NULL, NULL)",
            "INSERT INTO songs VALUES (1, 'rise against|savior', 'Rise Against', 'Savior', 'matched', '\(savior.id)', '\(savior.url)', 'auto', '[]', '\(at(20))', NULL, '\(at(19))', 'Savior', 'Rise Against', 'Album')",
            "INSERT INTO songs VALUES (2, 'linkin park|numb', 'Linkin Park', 'Numb', 'matched', '\(numb.id)', '\(numb.url)', 'auto', '[]', '\(at(10))', NULL, '\(at(9))', 'Numb', 'LINKIN PARK', 'Album')",
            "INSERT INTO plays VALUES (1, '1', '\(at(20))', 'Rise Against', 'Savior', 1)",
            "INSERT INTO plays VALUES (1, '2', '\(at(10))', 'Linkin Park', 'Numb', 2)",
            "INSERT INTO playlist_tracks VALUES ('\(savior.id)', 1, 1, '\(at(19))', '\(at(20))')",
            "INSERT INTO playlist_tracks VALUES ('\(numb.id)', 2, 1, '\(at(9))', '\(at(10))')",
            "INSERT INTO meta VALUES ('playlist.id', '\(playlistID)')",
        ])
        for file in try FileManager.default.contentsOfDirectory(atPath: harness.home.directory.path)
        where file.hasSuffix(".json") || file.hasSuffix(".p8") {
            try FileManager.default.copyItem(at: harness.home.directory.appendingPathComponent(file),
                                             to: home.directory.appendingPathComponent(file))
        }
        let clock = harness.clock
        let upgraded = try Radio(
            home: home, http: harness.http, sources: [AudacySource(http: harness.http)],
            notifier: PushoverNotifier(http: harness.http, userKey: nil, apiKey: nil),
            musicApp: harness.musicApp, now: { clock.now }
        )

        _ = try await upgraded.sync()

        #expect(harness.music.playlistNames() == ["Radio", "Radio (New)", "Radio (Unplayed)", "Radio Archive"])
        #expect(harness.music.playlists() == [
            "Radio": ["Savior", "Numb"], "Radio (New)": ["Savior", "Numb"],
            "Radio (Unplayed)": ["Savior", "Numb"], "Radio Archive": ["Savior", "Numb"],
        ])
        #expect(try await upgraded.status().stations.first?.recentlyAdded.map(\.title) == ["Numb", "Savior"])
    }

    /// The Mac mini's database on 2026-10-13 (schema 4) listed songs that
    /// Music.app had wiped out of both playlists. Placing every entry again
    /// restores them, in play order.
    @Test func upgradingRestoresSongsMusicWipedOut() async throws {
        let harness = try Harness()
        try await harness.signIn()
        let songs = ["A", "B", "C", "D"].map { harness.music.addToCatalog("Band", $0) }
        let (a, b, d) = (songs[0].id, songs[1].id, songs[3].id)
        let radioID = harness.music.seedPlaylist(name: "Radio", songIDs: [b, a, d])
        let archiveID = harness.music.seedPlaylist(name: "Radio Archive", songIDs: [a, d])
        let now = harness.clock.now
        func at(_ minutes: Double) -> String { now.addingTimeInterval(-minutes * 60).formatted(.iso8601) }
        let home = RadioHome(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-tests-\(UUID().uuidString)"))
        var statements = [
            "INSERT INTO stations VALUES (1, 'alt1021rva', 'audacy', '101-1041', 'Alt 102.1', '\(at(90))', '\(at(1))', NULL, NULL, NULL)",
            "INSERT INTO playlists VALUES ('recent', '\(radioID)', 'M-\(radioID)')",
            "INSERT INTO playlists VALUES ('archive', '\(archiveID)', 'M-\(archiveID)')",
        ]
        for (index, song) in songs.enumerated() {
            let played = at(Double(40 - index * 10))
            statements += [
                "INSERT INTO songs VALUES (\(index + 1), 'band|\(song.name.lowercased())', 'Band', '\(song.name)', 'matched', '\(song.id)', '\(song.url)', 'auto', '[]', '\(played)', NULL, '\(played)', '\(song.name)', 'Band', 'Album')",
                "INSERT INTO plays VALUES (1, '\(index + 1)', '\(played)', 'Band', '\(song.name)', \(index + 1))",
                "INSERT INTO playlist_tracks VALUES ('recent', '\(song.id)', \(index + 1), 1, '\(played)', '\(played)')",
                "INSERT INTO playlist_tracks VALUES ('archive', '\(song.id)', \(index + 1), 1, '\(played)', '\(played)')",
            ]
        }
        try writeSchemaFourDatabase(at: home, statements: statements)
        for file in try FileManager.default.contentsOfDirectory(atPath: harness.home.directory.path)
        where file.hasSuffix(".json") || file.hasSuffix(".p8") {
            try FileManager.default.copyItem(at: harness.home.directory.appendingPathComponent(file),
                                             to: home.directory.appendingPathComponent(file))
        }
        let clock = harness.clock
        let upgraded = try Radio(
            home: home, http: harness.http, sources: [AudacySource(http: harness.http)],
            notifier: PushoverNotifier(http: harness.http, userKey: nil, apiKey: nil),
            musicApp: harness.musicApp, now: { clock.now }
        )

        _ = try await upgraded.sync()

        #expect(harness.music.playlistNames() == ["Radio", "Radio Archive", "Radio (New)", "Radio (Unplayed)"])
        #expect(harness.music.playlists() == [
            "Radio": ["A", "B", "C", "D"], "Radio (New)": ["A", "B", "C", "D"],
            "Radio (Unplayed)": ["A", "B", "C", "D"], "Radio Archive": ["A", "B", "C", "D"],
        ])
        let status = try await upgraded.status()
        #expect((status.playlistCount, status.archiveCount) == (4, 4))
    }

    /// The Mac mini's database on 2026-10-13 (schema 5) had songs in both
    /// playlists and no comments. They get comments without moving.
    @Test func upgradingCommentsTheSongsAlreadyInThePlaylists() async throws {
        let harness = try Harness()
        try await harness.signIn()
        let songs = ["A", "B"].map { harness.music.addToCatalog("Band", $0) }
        let ids = songs.map(\.id)
        let radioID = harness.music.seedPlaylist(name: "Radio", songIDs: ids)
        let archiveID = harness.music.seedPlaylist(name: "Radio Archive", songIDs: ids)
        let now = harness.clock.now
        func at(_ minutes: Double) -> String { now.addingTimeInterval(-minutes * 60).formatted(.iso8601) }
        let home = RadioHome(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("radio-tests-\(UUID().uuidString)"))
        var statements = [
            "INSERT INTO stations VALUES (1, 'alt1021rva', 'audacy', '101-1041', 'Alt 102.1', '\(at(90))', '\(at(1))', NULL, NULL, NULL)",
            "INSERT INTO playlists VALUES ('recent', NULL, 'M-\(radioID)')",
            "INSERT INTO playlists VALUES ('archive', NULL, 'M-\(archiveID)')",
        ]
        for (index, song) in songs.enumerated() {
            let played = at(Double(20 - index * 10))
            statements += [
                "INSERT INTO songs VALUES (\(index + 1), 'band|\(song.name.lowercased())', 'Band', '\(song.name)', 'matched', '\(song.id)', '\(song.url)', 'auto', '[]', '\(played)', NULL, '\(played)', '\(song.name)', 'Band', 'Album')",
                "INSERT INTO plays VALUES (1, '\(index + 1)', '\(played)', 'Band', '\(song.name)', \(index + 1))",
                "INSERT INTO playlist_tracks VALUES ('recent', '\(song.id)', \(index + 1), 1, '\(played)', '\(played)')",
                "INSERT INTO playlist_tracks VALUES ('archive', '\(song.id)', \(index + 1), 1, '\(played)', '\(played)')",
            ]
        }
        // Schema 5 (commit 3820d9c) is schema 4 without the web API's
        // playlist IDs, plus library requests.
        statements += [
            "ALTER TABLE playlists DROP COLUMN library_id",
            "CREATE TABLE library_requests (catalog_id TEXT PRIMARY KEY, requested_at TEXT NOT NULL)",
            "PRAGMA user_version = 5",
        ]
        try writeSchemaFourDatabase(at: home, statements: statements)
        for file in try FileManager.default.contentsOfDirectory(atPath: harness.home.directory.path)
        where file.hasSuffix(".json") || file.hasSuffix(".p8") {
            try FileManager.default.copyItem(at: harness.home.directory.appendingPathComponent(file),
                                             to: home.directory.appendingPathComponent(file))
        }
        let clock = harness.clock
        let upgraded = try Radio(
            home: home, http: harness.http, sources: [AudacySource(http: harness.http)],
            notifier: PushoverNotifier(http: harness.http, userKey: nil, apiKey: nil),
            musicApp: harness.musicApp, now: { clock.now }
        )

        let sync = try await upgraded.sync()

        #expect(harness.music.comment(of: "A") == "📻 \(minute(now - 20 * 60)) · Alt 102.1")
        #expect(harness.music.comment(of: "B") == "📻 \(minute(now - 10 * 60)) · Alt 102.1")
        #expect(harness.music.playlists() == [
            "Radio": ["A", "B"], "Radio (New)": ["A", "B"], "Radio (Unplayed)": ["A", "B"], "Radio Archive": ["A", "B"],
        ])
        let changes = try #require(sync.playlists["Radio"])
        #expect((changes.added, changes.moved, changes.dropped) == (0, 0, 0))
        #expect(sync.commented == 2)
    }

    /// The tables exactly as the first release (commit 4580917) created them.
    func writeSchemaOneDatabase(at home: RadioHome, statements: [String]) throws {
        try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(home.directory.appendingPathComponent("radio.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = [
            """
            CREATE TABLE stations (id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE, source TEXT NOT NULL,
                feed_id TEXT NOT NULL, name TEXT NOT NULL, playlist_id TEXT, added_at TEXT NOT NULL,
                last_poll_ok_at TEXT, poll_failing_since TEXT, last_poll_error TEXT, feed_alert_sent_at TEXT)
            """,
            """
            CREATE TABLE songs (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, artist TEXT NOT NULL,
                title TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'matched', 'unmatched', 'ignored')),
                catalog_id TEXT, catalog_url TEXT, matched_by TEXT, candidates TEXT,
                first_heard_at TEXT NOT NULL, held_at TEXT, resolved_at TEXT)
            """,
            """
            CREATE TABLE plays (station_id INTEGER NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
                play_id TEXT NOT NULL, played_at TEXT NOT NULL, artist TEXT NOT NULL, title TEXT NOT NULL,
                song_id INTEGER NOT NULL REFERENCES songs(id), PRIMARY KEY (station_id, play_id))
            """,
            "CREATE INDEX plays_by_time ON plays (station_id, played_at)",
            "CREATE INDEX plays_by_song ON plays (song_id)",
            """
            CREATE TABLE playlist_tracks (station_id INTEGER NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
                catalog_id TEXT NOT NULL, song_id INTEGER NOT NULL REFERENCES songs(id), added_at TEXT NOT NULL,
                PRIMARY KEY (station_id, catalog_id))
            """,
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "PRAGMA user_version = 1",
        ]
        for statement in schema + statements {
            #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
        }
    }

    /// The tables exactly as schema 4 (commit f153939) left them.
    func writeSchemaFourDatabase(at home: RadioHome, statements: [String]) throws {
        try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(home.directory.appendingPathComponent("radio.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = [
            """
            CREATE TABLE stations (id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE, source TEXT NOT NULL,
                feed_id TEXT NOT NULL, name TEXT NOT NULL, added_at TEXT NOT NULL, last_poll_ok_at TEXT,
                poll_failing_since TEXT, last_poll_error TEXT, feed_alert_sent_at TEXT)
            """,
            """
            CREATE TABLE songs (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, artist TEXT NOT NULL,
                title TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'matched', 'unmatched', 'ignored')),
                catalog_id TEXT, catalog_url TEXT, matched_by TEXT, candidates TEXT,
                first_heard_at TEXT NOT NULL, held_at TEXT, resolved_at TEXT,
                catalog_name TEXT, catalog_artist TEXT, catalog_album TEXT)
            """,
            """
            CREATE TABLE plays (station_id INTEGER NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
                play_id TEXT NOT NULL, played_at TEXT NOT NULL, artist TEXT NOT NULL, title TEXT NOT NULL,
                song_id INTEGER NOT NULL REFERENCES songs(id), PRIMARY KEY (station_id, play_id))
            """,
            "CREATE INDEX plays_by_time ON plays (station_id, played_at)",
            "CREATE INDEX plays_by_song ON plays (song_id)",
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            "CREATE TABLE playlists (kind TEXT PRIMARY KEY, library_id TEXT, music_id TEXT)",
            """
            CREATE TABLE playlist_tracks (playlist TEXT NOT NULL REFERENCES playlists(kind),
                catalog_id TEXT NOT NULL, song_id INTEGER NOT NULL REFERENCES songs(id),
                station_id INTEGER REFERENCES stations(id) ON DELETE SET NULL, added_at TEXT NOT NULL,
                position_played_at TEXT, PRIMARY KEY (playlist, catalog_id))
            """,
            "CREATE INDEX playlist_tracks_by_station ON playlist_tracks (playlist, station_id, added_at)",
            "PRAGMA user_version = 4",
        ]
        for statement in schema + statements {
            #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
        }
    }

    /// The tables exactly as schema 3 (commit b8de147) left them.
    func writeSchemaThreeDatabase(at home: RadioHome, statements: [String]) throws {
        try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(home.directory.appendingPathComponent("radio.sqlite").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = [
            """
            CREATE TABLE stations (id INTEGER PRIMARY KEY, slug TEXT NOT NULL UNIQUE, source TEXT NOT NULL,
                feed_id TEXT NOT NULL, name TEXT NOT NULL, added_at TEXT NOT NULL, last_poll_ok_at TEXT,
                poll_failing_since TEXT, last_poll_error TEXT, feed_alert_sent_at TEXT)
            """,
            """
            CREATE TABLE songs (id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, artist TEXT NOT NULL,
                title TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending', 'matched', 'unmatched', 'ignored')),
                catalog_id TEXT, catalog_url TEXT, matched_by TEXT, candidates TEXT,
                first_heard_at TEXT NOT NULL, held_at TEXT, resolved_at TEXT,
                catalog_name TEXT, catalog_artist TEXT, catalog_album TEXT)
            """,
            """
            CREATE TABLE plays (station_id INTEGER NOT NULL REFERENCES stations(id) ON DELETE CASCADE,
                play_id TEXT NOT NULL, played_at TEXT NOT NULL, artist TEXT NOT NULL, title TEXT NOT NULL,
                song_id INTEGER NOT NULL REFERENCES songs(id), PRIMARY KEY (station_id, play_id))
            """,
            "CREATE INDEX plays_by_time ON plays (station_id, played_at)",
            "CREATE INDEX plays_by_song ON plays (song_id)",
            "CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
            """
            CREATE TABLE playlist_tracks (catalog_id TEXT PRIMARY KEY, song_id INTEGER NOT NULL REFERENCES songs(id),
                station_id INTEGER REFERENCES stations(id) ON DELETE SET NULL, added_at TEXT NOT NULL,
                position_played_at TEXT)
            """,
            "CREATE INDEX playlist_tracks_by_station ON playlist_tracks (station_id, added_at)",
            "PRAGMA user_version = 3",
        ]
        for statement in schema + statements {
            #expect(sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK, "\(statement)")
        }
    }
}
