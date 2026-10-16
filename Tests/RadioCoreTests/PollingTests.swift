import Foundation
import RadioCore
import Testing

@Suite struct PollingTests {
    @Test func addingAStationReadsItsFeedIDAndNameFromItsPage() async throws {
        let harness = try Harness()
        let station = try await harness.radio.addStation(slug: "alt1021rva")
        #expect(station.feedID == "101-1041")
        #expect(station.name == "Alt 102.1")
        #expect(station.source == "audacy")
    }

    @Test func addingAnIHeartStationReadsItsStreamIDFromItsSiteAndItsNameFromTheAPI() async throws {
        let harness = try Harness()
        let station = try await harness.radio.addStation(slug: "hits1061seattle", source: "iheart")
        #expect(station.feedID == "4257")
        #expect(station.name == "Hits 106.1")
        #expect(station.source == "iheart")
    }

    @Test func anIHeartSlugMustBeASiteName() async throws {
        let harness = try Harness()
        await #expect(throws: (any Error).self) { try await harness.radio.addStation(slug: "hits1061seattle.iheart.com/", source: "iheart") }
        await #expect(throws: (any Error).self) { try await harness.radio.addStation(slug: "nosuchstation", source: "iheart") }
        #expect(harness.http.requests("GET https://hits1061seattle.iheart.com").isEmpty)
    }

    @Test func iHeartPlaysAreLoggedOnceAcrossOverlappingPolls() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "hits1061seattle", source: "iheart")
        let played = harness.clock.now.addingTimeInterval(-600)
        harness.iheart.play("Olivia Dean", "Man I Need", at: played)

        let first = try await harness.radio.poll()
        harness.iheart.play("Zara Larsson", "Midnight Sun", at: harness.clock.now)
        let second = try await harness.radio.poll()

        #expect(first.map(\.newPlays) == [1])
        #expect(second.map(\.newPlays) == [1])
        let rows = try await harness.radio.exportCSV(stationSlug: "hits1061seattle").split(separator: "\n").dropFirst()
            .map { $0.split(separator: ",").map(String.init) }
        #expect(rows.map { $0[2...3].joined(separator: " – ") } == ["Olivia Dean – Man I Need", "Zara Larsson – Midnight Sun"])
        #expect(rows.first?[1] == played.formatted(.iso8601))
    }

    @Test func pollRequestsAHundredIHeartPlays() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "hits1061seattle", source: "iheart")
        for minute in 0..<150 {
            harness.iheart.play("Artist \(minute)", "Song \(minute)", at: harness.clock.now.addingTimeInterval(Double(minute - 150) * 60))
        }
        let results = try await harness.radio.poll()
        #expect(results.map(\.newPlays) == [100])
    }

    @Test func addingAHubbardStationReadsItsNameFromItsPlayerSettings() async throws {
        let harness = try Harness()
        let station = try await harness.radio.addStation(slug: "movin925.com", source: "hubbard")
        #expect(station.feedID == "live.movin925.com")
        #expect(station.name == "MOViN 92.5")
        #expect(station.source == "hubbard")
    }

    @Test func aHubbardSlugMustBeAStationDomain() async throws {
        let harness = try Harness()
        for slug in ["movin925", "https://movin925.com", "movin925.com/", "movin925..com", "nosuchstation.com"] {
            await #expect(throws: (any Error).self) { try await harness.radio.addStation(slug: slug, source: "hubbard") }
        }
        #expect(harness.http.requests("GET https://live.movin925").isEmpty)
        #expect(try await harness.radio.stations().isEmpty)
    }

    @Test func hubbardSongsAreLoggedOnceAcrossOverlappingPollsAndOtherCuesAreSkipped() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "movin925.com", source: "hubbard")
        let played = harness.clock.now.addingTimeInterval(-600)
        harness.hubbard.play("Tame Impala", "Loser", at: played)
        harness.hubbard.play("Sponsor", "Thirty Second Spot", at: played.addingTimeInterval(220), type: "ad")

        let first = try await harness.radio.poll()
        harness.hubbard.play("Dominic Fike", "Babydoll", at: harness.clock.now)
        let second = try await harness.radio.poll()

        #expect(first.map(\.newPlays) == [1])
        #expect(second.map(\.newPlays) == [1])
        let rows = try await harness.radio.exportCSV(stationSlug: "movin925.com").split(separator: "\n").dropFirst()
            .map { $0.split(separator: ",").map(String.init) }
        #expect(rows.map { $0[2...3].joined(separator: " – ") } == ["Tame Impala – Loser", "Dominic Fike – Babydoll"])
        #expect(rows.first?[1] == played.formatted(.iso8601))
    }

    /// Seen 2026-10-15: MOViN 92.5's feed sent "Macklemore &amp; Ryan Lewis",
    /// which kept the song from matching.
    @Test func htmlEntitiesInFeedsAreDecoded() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "movin925.com", source: "hubbard")
        _ = try await harness.radio.addStation(slug: "hits1061seattle", source: "iheart")
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.hubbard.play("Macklemore &amp; Ryan Lewis", "Can&#039;t Hold Us", at: harness.clock.now)
        harness.iheart.play("Simon &amp; Garfunkel", "Mrs. Robinson &#x2014; Live", at: harness.clock.now)
        harness.play("Hall &amp; Oates", "You Make My Dreams (Come True) &quot;Remastered&quot;")

        _ = try await harness.radio.poll()

        let rows = try await harness.radio.exportCSV(stationSlug: nil).split(separator: "\n").dropFirst()
        #expect(rows.contains { $0.contains(",Macklemore & Ryan Lewis,Can't Hold Us,") })
        #expect(rows.contains { $0.contains(",Simon & Garfunkel,Mrs. Robinson — Live,") })
        #expect(rows.contains { $0.contains(#",Hall & Oates,"You Make My Dreams (Come True) ""Remastered""","#) })
    }

    @Test func pollRequestsAHundredHubbardPlays() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "movin925.com", source: "hubbard")
        for minute in 0..<150 {
            harness.hubbard.play("Artist \(minute)", "Song \(minute)", at: harness.clock.now.addingTimeInterval(Double(minute - 150) * 60))
        }
        let results = try await harness.radio.poll()
        #expect(results.map(\.newPlays) == [100])
    }

    @Test func addingAStationTwiceFails() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        await #expect(throws: RadioError.self) { try await harness.radio.addStation(slug: "alt1021rva") }
    }

    @Test func eachPlayIsLoggedOnceAcrossOverlappingPolls() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("Foo Fighters", "My Hero", minutesAgo: 10)
        harness.play("Weezer", "Africa", minutesAgo: 5)

        let first = try await harness.radio.poll()
        harness.play("Bush", "Glycerine")
        let second = try await harness.radio.poll()

        #expect(first.map(\.newPlays) == [2])
        #expect(second.map(\.newPlays) == [1])
        let csv = try await harness.radio.exportCSV()
        let rows = csv.split(separator: "\n").dropFirst().map { $0.split(separator: ",")[2...3].joined(separator: " – ") }
        #expect(rows == ["Foo Fighters – My Hero", "Weezer – Africa", "Bush – Glycerine"])
    }

    @Test func pollRequestsTheFeedsFiftyPlayMaximum() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        for minute in 0..<60 { harness.play("Artist \(minute)", "Song \(minute)", minutesAgo: Double(60 - minute)) }
        let results = try await harness.radio.poll()
        #expect(results.map(\.newPlays) == [50])
    }

    @Test func blankEntriesAndStationIDsAreNotLogged() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("", "Station ID", minutesAgo: 3)
        harness.play("Alt 102.1", "Richmond's Alternative", minutesAgo: 2)
        harness.play("Muse", "Supermassive Black Hole", minutesAgo: 1)
        let results = try await harness.radio.poll()
        #expect(results.map(\.newPlays) == [1])
    }

    @Test func stationsArePolledSeparately() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        harness.play("Muse", "Uprising", on: "101-1041")
        harness.play("AC/DC", "Thunderstruck", on: "101-2000")
        harness.play("Tool", "Sober", on: "101-2000", minutesAgo: 4)
        let results = try await harness.radio.poll()
        #expect(results.map(\.newPlays) == [1, 2])
        #expect(try await harness.radio.exportCSV(stationSlug: "rock").split(separator: "\n").count == 3)
    }

    @Test func exportQuotesFieldsWithCommasAndQuotes() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.play("Crosby, Stills & Nash", "Say \"Hi\"")
        _ = try await harness.radio.poll()
        let csv = try await harness.radio.exportCSV()
        #expect(csv.contains(#""Crosby, Stills & Nash","Say ""Hi""""#))
    }

    @Test func aFailingFeedIsReportedWithoutStoppingOtherStations() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        _ = try await harness.radio.addStation(slug: "rock")
        harness.audacy.setFailing("101-1041", true)
        harness.play("Tool", "Sober", on: "101-2000")
        let results = try await harness.radio.poll()
        #expect(results[0].error != nil)
        #expect(results[1].newPlays == 1)
        let status = try await harness.radio.status()
        #expect(status.stations[0].station.pollFailingSince == harness.clock.now)
    }
}
