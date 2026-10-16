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

    @Test func theExplicitVersionIsPreferredAmongSurePicks() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On (Amended LP Version)")
        harness.music.addToCatalog("Missy Elliott", "Get Ur Freak On", explicit: true)
        harness.jev.score("Get Ur Freak On (Amended LP Version)", 0.96)
        harness.jev.score("Get Ur Freak On", 0.91)
        harness.play("Missy Elliot", "GET UR FREAK ON")

        _ = try await harness.radio.run()

        #expect(harness.music.playlists()["Radio"] == ["Get Ur Freak On"])
    }

    @Test func jevIsAskedAboutEveryCandidateWithTheNewestModel() async throws {
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
        let questions = body["questions"] as? [String: [String: Any]] ?? [:]
        #expect(questions.count == 10)
        let first = (questions["c0"]?["instructions"] as? [String: Any])?["candidate"] as? [String: String]
        #expect(first == ["artist": "Nirvana", "title": "Come As You Are (Live 0)", "album": "Album"])
        #expect(try await harness.radio.heldSongs().first?.candidates.count == 10)
    }
}
