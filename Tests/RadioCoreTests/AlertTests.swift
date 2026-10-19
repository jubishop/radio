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

    @Test func theDailyReminderCoversEverySongWaitingForReview() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.run()

        harness.clock.advance(hours: 12)
        harness.play("Unknown Band", "First")
        harness.play("Unknown Band", "Second", minutesAgo: 1)
        _ = try await harness.radio.run()
        #expect(harness.pushes.isEmpty)
        #expect(harness.emails.isEmpty)

        harness.clock.advance(hours: 12)
        _ = try await harness.radio.run()
        #expect(harness.pushes == ["Radio: songs to review"])
        let message = String(decoding: try #require(harness.http.requests("POST https://api.pushover.net/").last?.body), as: UTF8.self)
        #expect(message.contains("2%20songs%20need"))
        #expect(harness.emails.map { $0["subject"] as? String } == ["Radio: 2 songs to review"])

        // Songs left waiting come up again the next day.
        harness.clock.advance(days: 1)
        _ = try await harness.radio.run()
        #expect(harness.pushes.count == 2)
        #expect(harness.emails.count == 2)

        for song in try await harness.radio.heldSongs() {
            try await harness.radio.ignore(songID: song.id)
        }
        harness.clock.advance(days: 1)
        _ = try await harness.radio.run()
        #expect(harness.pushes.count == 2)
        #expect(harness.emails.count == 2)
    }

    /// A late run, or a day without runs, doesn't make later reminders late.
    @Test func theDailyReminderKeepsItsTimeOfDay() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("Unknown Band", "First")
        _ = try await harness.radio.run()

        harness.clock.advance(hours: 24.25)
        _ = try await harness.radio.run()
        #expect(harness.pushes.count == 1)
        harness.clock.advance(hours: 23.75)
        _ = try await harness.radio.run()
        #expect(harness.pushes.count == 2)

        harness.clock.advance(days: 2.5)
        _ = try await harness.radio.run()
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        #expect(harness.pushes.count == 3)
        harness.clock.advance(hours: 11.75)
        _ = try await harness.radio.run()
        #expect(harness.pushes.count == 4)
    }

    @Test func theReviewEmailListsEachSongAndLinksToTheReviewPage() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Lake of Fire (Live Acoustic)", album: "MTV Unplugged In New York")
        harness.jev.score("Lake of Fire (Live Acoustic)", 0.6)
        harness.play("Nirvana", "Lake Of Fire", minutesAgo: 5)
        harness.play("Simon & <Unknown>", "Nobody Knows")
        _ = try await harness.radio.run()
        harness.clock.advance(days: 1)
        _ = try await harness.radio.run()

        let email = try #require(harness.emails.first)
        #expect(email["from"] as? String == "Radio <radio@jubishop.com>")
        #expect(email["to"] as? [String] == ["me@example.com"])
        #expect(harness.http.requests("POST https://api.resend.com/emails").first?.headers["Authorization"] == "Bearer resend-key")
        let text = try #require(email["text"] as? String)
        #expect(text.contains("http://jubi.local:8102/review"))
        #expect(text.contains("Nirvana – Lake Of Fire\n  1 play on Alt 102.1 · last "))
        #expect(text.contains("Jev suggests Nirvana – Lake of Fire (Live Acoustic), from MTV Unplugged In New York"))
        #expect(text.contains("Simon & <Unknown> – Nobody Knows"))
        let html = try #require(email["html"] as? String)
        #expect(html.contains("href=\"http://jubi.local:8102/review\""))
        #expect(html.contains("Simon &amp; &lt;Unknown&gt; – Nobody Knows"))
        #expect(!html.contains("<Unknown>"))
    }

    @Test func aFailedEmailIsRetriedWithoutRepeatingThePush() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("Unknown Band", "First")
        _ = try await harness.radio.run()

        harness.http.on("POST https://api.resend.com/") { _ in json(["message": "unavailable"], status: 500) }
        harness.clock.advance(days: 1)
        await #expect(throws: (any Error).self) { try await harness.radio.run() }

        harness.http.on("POST https://api.resend.com/") { _ in json(["id": "email-2"]) }
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        _ = try await harness.radio.run()
        #expect(harness.pushes.count == 1)
        #expect(harness.emails.count == 2)
    }

    /// Without one service's keys, the other still reminds once a day.
    @Test(arguments: [true, false]) func eitherReminderWorksAlone(pushover: Bool) async throws {
        let harness = try Harness(pushover: pushover, email: !pushover)
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("Unknown Band", "First")
        _ = try await harness.radio.run()

        harness.clock.advance(days: 1)
        _ = try await harness.radio.run()
        harness.clock.advance(hours: 0.25)
        _ = try await harness.radio.run()
        harness.clock.advance(days: 1)
        _ = try await harness.radio.run()

        #expect(harness.http.requests("POST https://api.pushover.net/").count == (pushover ? 2 : 0))
        #expect(harness.emails.count == (pushover ? 0 : 2))
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
