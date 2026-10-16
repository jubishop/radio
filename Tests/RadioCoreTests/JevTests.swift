import Foundation
import RadioCore
import Testing

/// Jev judges each held-back song's candidates: it adds the song when it's
/// sure, suggests a candidate when it's fairly sure, and otherwise leaves the
/// song for review.
@Suite struct JevTests {
    /// Seen 2026-10-15: the feed misspelled Missy Elliott.
    @Test func aHeldSongJevIsSureOfIsAdded() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On")
        harness.jev.score("Get Ur Freak On", 0.93)
        harness.play("Missy Elliot", "GET UR FREAK ON")

        let report = try await harness.radio.run().sync

        #expect(report.jevMatched == 1)
        #expect(try await harness.radio.heldSongs().isEmpty)
        #expect(harness.music.playlists()["Radio"] == ["Get Ur Freak On"])
        let reviewed = try #require(try await harness.radio.reviewedSongs().first)
        #expect(reviewed.title == "GET UR FREAK ON")
        #expect(reviewed.decision == .jev(score: 0.93, model: "jev-1.14.0"))
        #expect(reviewed.catalog?.name == "Get Ur Freak On")
    }

    @Test func aLikelyPickIsSuggestedAndAnUnlikelyOneIsNot() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Lake of Fire (Live Acoustic)", album: "MTV Unplugged In New York")
        harness.music.addToCatalog("Incubus", "Wish You Were Here")
        harness.jev.score("Lake of Fire (Live Acoustic)", 0.6)
        harness.jev.score("Wish You Were Here", 0.59)
        harness.play("Nirvana", "Lake Of Fire", minutesAgo: 5)
        harness.play("Incubus", "I Wish You Were Here")

        _ = try await harness.radio.run()

        let held = try await harness.radio.heldSongs()
        #expect(held.first { $0.artist == "Nirvana" }?.suggestion == JevSuggestion(candidate: 0, score: 0.6))
        #expect(held.first { $0.artist == "Incubus" }?.suggestion == nil)
        #expect(harness.music.playlists().isEmpty)
    }

    @Test func eachHeldSongIsJudgedOnce() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Come As You Are (Live)")
        harness.play("Nirvana", "Come As You Are")
        _ = try await harness.radio.run()

        harness.clock.advance(hours: 1)
        harness.play("Nirvana", "Come As You Are")
        _ = try await harness.radio.run()

        #expect(harness.http.requests("POST https://api.typesafe.ai/").count == 1)
    }

    @Test func aJevFailureLeavesTheSongForReviewAndIsRetried() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On")
        harness.jev.score("Get Ur Freak On", 0.93)
        harness.jev.setFailing(true)
        harness.play("Missy Elliot", "GET UR FREAK ON")

        let failed = try await harness.radio.run().sync

        #expect(failed.error == nil)
        #expect(try await harness.radio.heldSongs().count == 1)
        #expect(try await harness.radio.status().jevError?.contains("500") == true)

        harness.jev.setFailing(false)
        _ = try await harness.radio.sync()

        #expect(try await harness.radio.heldSongs().isEmpty)
        #expect(try await harness.radio.status().jevError == nil)
    }

    /// Radio follows the newest model, so the user agreed on 2026-10-15 that
    /// songs still waiting for review get one question from each new model.
    @Test func aNewModelJudgesSongsStillWaitingForReviewAgain() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Lake of Fire (Live Acoustic)")
        harness.music.addToCatalog("Nirvana", "Come As You Are (Live)")
        harness.jev.score("Lake of Fire (Live Acoustic)", 0.4)
        harness.play("Nirvana", "Lake Of Fire", minutesAgo: 5)
        harness.play("Nirvana", "Come As You Are")
        _ = try await harness.radio.run()
        let sentBack = try #require(try await harness.radio.heldSongs().first { $0.title == "Come As You Are" })
        _ = try await harness.radio.match(songID: sentBack.id, choice: .candidate(0))
        try await harness.radio.undo(songID: sentBack.id)

        harness.jev.setModel("jev-1.15.0")
        harness.jev.score("Lake of Fire (Live Acoustic)", 0.95)
        harness.music.addToCatalog("Incubus", "Wish You Were Here")
        harness.clock.advance(hours: 1)
        harness.play("Incubus", "I Wish You Were Here")
        _ = try await harness.radio.run()
        _ = try await harness.radio.run()

        #expect(FakeJev.askedTitles(harness.http) == ["Lake Of Fire", "Come As You Are", "I Wish You Were Here", "Lake Of Fire"])
        let lake = try #require(try await harness.radio.reviewedSongs().first { $0.title == "Lake Of Fire" })
        #expect(lake.decision == .jev(score: 0.95, model: "jev-1.15.0"))
    }

    /// The user asked on 2026-10-15 for songs held before candidates had
    /// ISRCs and lengths to be searched and judged again, once.
    @Test func upgradingSearchesAgainForSongsHeldBeforeCandidatesHadISRCs() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        var unplugged = harness.music.addToCatalog("Nirvana", "Lake of Fire (Live Acoustic)")
        var live = harness.music.addToCatalog("Nirvana", "Come As You Are (Live)")
        harness.play("Nirvana", "Lake Of Fire", minutesAgo: 5)
        harness.play("Nirvana", "Come As You Are")
        _ = try await harness.radio.run()
        let sentBack = try #require(try await harness.radio.heldSongs().first { $0.title == "Come As You Are" })
        _ = try await harness.radio.match(songID: sentBack.id, choice: .candidate(0))
        try await harness.radio.undo(songID: sentBack.id)
        // As an earlier release saved them, without ISRCs or lengths.
        unplugged.isrc = nil; unplugged.durationMillis = nil
        live.isrc = nil; live.durationMillis = nil
        let oldLake = String(decoding: try JSONEncoder().encode([unplugged]), as: UTF8.self)
        let oldLive = String(decoding: try JSONEncoder().encode([live]), as: UTF8.self)
        executeSQL([
            "UPDATE songs SET candidates = '\(oldLake)', jev_score = 0.37 WHERE title = 'Lake Of Fire'",
            "UPDATE songs SET candidates = '\(oldLive)' WHERE title = 'Come As You Are'",
            "PRAGMA user_version = 8",
        ], in: harness.home)
        harness.jev.score("Lake of Fire (Live Acoustic)", 0.79)
        let clock = harness.clock
        let upgraded = try Radio(
            home: harness.home, http: harness.http, sources: [AudacySource(http: harness.http)],
            notifier: PushoverNotifier(http: harness.http, userKey: nil, apiKey: nil), musicApp: harness.musicApp,
            jevAPIKey: "jev-key", now: { clock.now }
        )

        _ = try await upgraded.sync()

        let held = try await upgraded.heldSongs()
        #expect(held.first { $0.title == "Lake Of Fire" }?.suggestion == JevSuggestion(candidate: 0, score: 0.79))
        #expect(held.first { $0.title == "Lake Of Fire" }?.candidates.first?.isrc != nil)
        #expect(held.first { $0.title == "Come As You Are" }?.candidates.first?.isrc == nil)
        #expect(FakeJev.askedTitles(harness.http) == ["Lake Of Fire", "Come As You Are", "Lake Of Fire"])
    }

    @Test func withoutAKeyJevIsNotAsked() async throws {
        let harness = try Harness(jevAPIKey: nil)
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On")
        harness.jev.score("Get Ur Freak On", 0.93)
        harness.play("Missy Elliot", "GET UR FREAK ON")

        _ = try await harness.radio.run()

        #expect(harness.http.requests("POST https://api.typesafe.ai/").isEmpty)
        #expect(try await harness.radio.heldSongs().count == 1)
    }

    /// Apple gives a clean edit its own ISRC, so it's matched to its explicit
    /// original by title, artist, and length.
    @Test func aCleanEditIsOneOptionWithItsExplicitOriginal() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On (Amended LP Version)", seconds: 237)
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On", explicit: true, seconds: 236)
        harness.jev.score("Get Ur Freak On (Amended LP Version)", 0.96)
        harness.play("Missy Elliot", "GET UR FREAK ON")

        _ = try await harness.radio.run()

        #expect(try options(in: harness).count == 1)
        #expect(harness.music.playlists()["Radio"] == ["Get Ur Freak On"])
    }

    /// Seen 2026-10-15: Usher went to a trimmed copy on a compilation instead
    /// of the EP. Copies sharing an ISRC are one option, and the first in
    /// Apple's search order, usually the original release, is added.
    @Test func copiesOfOneRecordingAreOneOptionAndTheFirstIsAdded() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        let original = harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On", album: "Miss E... So Addictive",
                                                  isrc: "USEW20100037", seconds: 236)
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On (Party Hits)", album: "Party Hits",
                                   isrc: "USEW20100037", seconds: 230)
        harness.jev.score("Get Ur Freak On", 0.91)
        harness.play("Missy Elliot", "GET UR FREAK ON")

        _ = try await harness.radio.run()

        #expect(try options(in: harness).count == 1)
        #expect(try await harness.radio.reviewedSongs().first?.catalog?.id == original.id)
    }

    @Test func otherVersionsOfASongAreSeparateOptions() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Come As You Are (Live)", seconds: 220)
        harness.music.addToCatalog("Nirvana", "Come As You Are (Remix)", seconds: 221)
        harness.play("Nirvana", "Come As You Are")

        _ = try await harness.radio.run()

        #expect(try options(in: harness).count == 2)
    }

    @Test func aCopyOfAnotherLengthIsASeparateOption() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On", seconds: 236)
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On", seconds: 270)
        harness.play("Missy Elliot", "GET UR FREAK ON")

        _ = try await harness.radio.run()

        #expect(try options(in: harness).count == 2)
    }

    @Test func jevChoosesAmongTheRecordingsWithTheNewestModel() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        for index in 0..<12 {
            harness.music.addToCatalog("Nirvana", "Come As You Are (Live \(index))")
        }
        harness.play("Nirvana", "Come As You Are")

        _ = try await harness.radio.run()

        let request = try #require(harness.http.requests("POST https://api.typesafe.ai/v1/systemone").first)
        #expect(request.headers["Authorization"] == "Bearer jev-key")
        let body = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        #expect(body["model"] as? String == "jev-preview")
        let state = body["state"] as? [String: Any]
        #expect(state?["station"] as? String == "Alt 102.1")
        #expect(state?["played"] as? [String: String] == ["artist": "Nirvana", "title": "Come As You Are"])
        let options = try options(in: harness)
        #expect(options.count == 10)
        #expect(options["a"] == ["artist": "Nirvana", "title": "Come As You Are (Live 0)", "album": "Album"])
        #expect(try await harness.radio.heldSongs().first?.candidates.count == 10)
    }

    /// The recordings offered in Jev's first question, by letter, without
    /// "none".
    private func options(in harness: Harness) throws -> [String: [String: String]] {
        let request = try #require(harness.http.requests("POST https://api.typesafe.ai/v1/systemone").first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any])
        let question = try #require((body["questions"] as? [String: [String: Any]])?["pick"])
        #expect(question["type"] as? String == "choice")
        let criteria = try #require(question["criteria"] as? [String: Any])
        #expect(criteria["none"] is String)
        return criteria.compactMapValues { $0 as? [String: String] }
    }
}
