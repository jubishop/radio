import Foundation
import RadioCore
import SQLite3
import Testing

@Suite struct MusicAppTests {
    func harnessWithSongs(_ titles: [String], playlistLimit: Int = 100) async throws -> Harness {
        let harness = try Harness(playlistLimit: playlistLimit)
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        for (index, title) in titles.enumerated() {
            harness.music.addToCatalog("Band", title)
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
        #expect(harness.music.playlists() == ["Radio": ["A", "C", "B"]])
    }

    @Test func replaysMoveInTheOrderTheyWerePlayed() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C", "D"])
        harness.clock.advance(hours: 1)
        harness.play("Band", "C", minutesAgo: 5)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["B", "D", "C", "A"]])
    }

    @Test func aSongReplayedOnAnotherStationMovesToTheEnd() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"])
        _ = try await harness.radio.addStation(slug: "rock")
        harness.clock.advance(hours: 1)
        harness.play("Band", "A", on: "101-2000")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["B", "C", "A"]])
    }

    @Test func aNewSongPushesTheLeastRecentlyPlayedOneOutOfAFullPlaylist() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"], playlistLimit: 3)
        harness.music.addToCatalog("Band", "D")
        harness.clock.advance(hours: 1)
        harness.play("Band", "D")
        let (_, sync) = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["B", "C", "D"]])
        #expect(sync.added == 1)
        #expect(sync.dropped == 1)
        #expect(try await harness.radio.status().playlistCount == 3)
    }

    @Test func aReplayKeepsASongInAFullPlaylist() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"], playlistLimit: 3)
        harness.music.addToCatalog("Band", "D")
        harness.clock.advance(hours: 1)
        harness.play("Band", "A", minutesAgo: 5)
        harness.play("Band", "D")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["C", "A", "D"]])
    }

    @Test func aBacklogAddsOnlyTheMostRecentlyPlayedSongs() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C", "D", "E"], playlistLimit: 3)
        #expect(harness.music.playlists() == ["Radio": ["C", "D", "E"]])
        #expect(harness.musicApp.calls == 0)
    }

    @Test func aFullPlaylistShrinksOnceMusicCanRemoveSongs() async throws {
        let harness = try await harnessWithSongs(["A", "B"], playlistLimit: 2)
        harness.music.addToCatalog("Band", "C")
        harness.musicApp.fail(with: "Radio isn't allowed to control Music")
        harness.clock.advance(hours: 1)
        harness.play("Band", "C")
        _ = try await harness.radio.run()
        // New songs still arrive while Music.app can't remove old ones.
        #expect(harness.music.playlists() == ["Radio": ["A", "B", "C"]])

        harness.musicApp.fail(with: nil)
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["B", "C"]])
    }

    @Test func aSongToDropThatWasRemovedByHandIsForgotten() async throws {
        let harness = try await harnessWithSongs(["A", "B"], playlistLimit: 2)
        harness.music.addToCatalog("Band", "C")
        harness.music.removeByHand("A", from: "Radio")
        harness.clock.advance(hours: 2)
        harness.play("Band", "C")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["B", "C"]])
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
        harness.clock.advance(hours: 1)
        _ = try await harness.radio.run()

        // Each song is added at its latest play, so nothing needs moving.
        #expect(harness.music.playlists() == ["Radio": ["B", "A"]])
        #expect(harness.musicApp.calls == 0)
    }

    @Test func aMoveMusicCannotMakeIsReportedAndRetried() async throws {
        let harness = try await harnessWithSongs(["A", "B"])
        harness.musicApp.fail(with: "Radio isn't allowed to control Music")
        harness.clock.advance(hours: 1)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["A", "B"]])
        #expect(try await harness.radio.status().musicAppError == "Radio isn't allowed to control Music")

        harness.musicApp.fail(with: nil)
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["B", "A"]])
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

        #expect(harness.music.playlists() == ["Radio Songs": ["C", "A", "B"]])
    }

    @Test func anEntryMusicCannotSeeYetIsRetriedRatherThanAddedAgain() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"])
        harness.music.setSyncedToMusicApp("A", false)
        harness.clock.advance(hours: 0.25)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["A", "B", "C"]])

        harness.music.setSyncedToMusicApp("A", true)
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["B", "C", "A"]])
    }

    @Test func aSongRemovedByHandReturnsWhenItPlaysAgain() async throws {
        let harness = try await harnessWithSongs(["A", "B", "C"])
        harness.music.removeByHand("A", from: "Radio")
        harness.clock.advance(hours: 2)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["B", "C", "A"]])
    }

    @Test func aPlaylistMusicCannotSeeYetIsRetried() async throws {
        let harness = try await harnessWithSongs(["A"])
        harness.music.renamePlaylist("Radio", to: "Hidden")
        harness.clock.advance(hours: 0.25)
        harness.play("Band", "A")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Hidden": ["A"]])

        harness.music.renamePlaylist("Hidden", to: "Radio")
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.music.playlists() == ["Radio": ["A"]])
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
        ])
        #expect(try await upgraded.status().playlistCount == 3)
        #expect(harness.musicApp.calls == 0)
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
}
