import Foundation
import RadioCore
import Testing

@Suite struct AlertTests {
    @Test func aFeedFailingForTwoHoursSendsOneAlert() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.audacy.setFailing("101-1041", true)

        _ = try await harness.radio.run()
        harness.clock.advance(hours: 1.5)
        _ = try await harness.radio.run()
        #expect(harness.pushes.isEmpty)

        harness.clock.advance(hours: 0.5)
        _ = try await harness.radio.run()
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.pushes == ["Radio: Alt 102.1 feed is down"])
    }

    @Test func aRecoveredFeedCanAlertAgainLater() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.audacy.setFailing("101-1041", true)
        _ = try await harness.radio.run()
        harness.clock.advance(hours: 2)
        _ = try await harness.radio.run()

        harness.audacy.setFailing("101-1041", false)
        _ = try await harness.radio.run()
        harness.audacy.setFailing("101-1041", true)
        _ = try await harness.radio.run()
        harness.clock.advance(hours: 2)
        _ = try await harness.radio.run()

        #expect(harness.pushes.count == 2)
    }

    @Test func aRejectedSignInAlertsOnceAndShowsOnTheDashboard() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Muse", "Uprising")
        harness.play("Muse", "Uprising")
        _ = try await harness.radio.poll()
        harness.music.setUserTokenStatus(403)

        _ = try await harness.radio.run()
        harness.clock.advance(hours: 1)
        _ = try await harness.radio.run()

        #expect(harness.pushes == ["Radio: Apple Music sign-in needed"])
        guard case .rejected = try await harness.radio.appleMusicState() else {
            Issue.record("expected a rejected sign-in")
            return
        }

        harness.music.setUserTokenStatus(200)
        try await harness.radio.saveUserToken("fresh-token")
        _ = try await harness.radio.run()
        #expect(harness.music.playlists()["Radio"] == ["Uprising"])
        #expect(try await harness.radio.appleMusicState() == .connected(storefront: "us", signedInAt: harness.clock.now))
    }

    /// A new MusicKit key answers 401 intermittently for several minutes while
    /// Apple rolls it out (seen 2026-10-13), so a brief rejection isn't news.
    @Test func aBriefRejectionDoesNotAlert() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Muse", "Uprising")
        harness.play("Muse", "Uprising")
        harness.music.setUserTokenStatus(401)

        _ = try await harness.radio.run()
        harness.clock.advance(hours: 0.5)
        _ = try await harness.radio.run()
        harness.music.setUserTokenStatus(200)
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()

        #expect(harness.pushes.isEmpty)
        #expect(harness.music.playlists()["Radio"] == ["Uprising"])
    }

    @Test func theWeeklyNudgeCountsNewlyHeldSongs() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.run()

        harness.clock.advance(days: 3)
        harness.play("Unknown Band", "First")
        harness.play("Unknown Band", "Second", minutesAgo: 1)
        _ = try await harness.radio.run()
        #expect(harness.pushes.isEmpty)

        harness.clock.advance(days: 4)
        _ = try await harness.radio.run()
        #expect(harness.pushes == ["Radio: songs to review"])
        let message = String(decoding: try #require(harness.http.requests("POST https://api.pushover.net/").last?.body), as: UTF8.self)
        #expect(message.contains("2%20new%20songs%20need"))

        harness.clock.advance(days: 7)
        _ = try await harness.radio.run()
        #expect(harness.pushes.count == 1)
    }

    @Test func noAlertsAreSentWithoutPushoverKeys() async throws {
        let harness = try Harness(pushover: false)
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.audacy.setFailing("101-1041", true)
        _ = try await harness.radio.run()
        harness.clock.advance(hours: 3)
        _ = try await harness.radio.run()
        #expect(harness.http.requests("POST https://api.pushover.net/").isEmpty)
    }
}
