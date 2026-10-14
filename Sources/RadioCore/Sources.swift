import Foundation

/// A station as its source describes it.
public struct StationInfo: Equatable, Sendable {
    public var slug: String
    public var source: String
    public var feedID: String
    public var name: String
}

/// One play reported by a station's feed.
public struct FeedPlay: Equatable, Sendable {
    public var playID: String
    public var playedAt: Date
    public var artist: String
    public var title: String
}

/// Finds stations and reads their recent plays. Each radio network gets its
/// own implementation.
public protocol PlaySource: Sendable {
    var name: String { get }
    func lookUp(slug: String) async throws -> StationInfo
    func recentPlays(feedID: String) async throws -> [FeedPlay]
}

struct SourceError: Error, CustomStringConvertible {
    let description: String
}

/// Reads Audacy station pages and their public now-playing feed. See
/// docs/audacy-now-playing-feed.md.
public struct AudacySource: PlaySource {
    public let name = "audacy"
    let http: HTTPClient

    /// The feed returns nothing for any count above 50.
    static let maximumCount = 50

    public init(http: HTTPClient) {
        self.http = http
    }

    public func lookUp(slug: String) async throws -> StationInfo {
        let url = URL(string: "https://www.audacy.com/\(slug)")!
        let html = String(decoding: try await http.send(HTTPRequest(url: url)).requireSuccess(for: url), as: UTF8.self)
        guard let feedID = firstMatch(#"STATION_ROC_ID\s*=\s*['"]([^'"]+)['"]"#, in: html) else {
            throw SourceError(description: "No Audacy station ID on \(url). Check the slug.")
        }
        let name = firstMatch(#"<title>[^<]*\|\s*([^<|]+?)\s*</title>"#, in: html)
            ?? firstMatch(#"<meta property="og:title" content="([^"]+)""#, in: html)
            ?? slug
        return StationInfo(slug: slug, source: self.name, feedID: feedID, name: decodeEntities(name))
    }

    public func recentPlays(feedID: String) async throws -> [FeedPlay] {
        let url = URL(string: "https://api.audacy.com/experience/v2/stations/\(feedID)/nowplaying?count=\(Self.maximumCount)")!
        let data = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"])).requireSuccess(for: url)
        let feed = try JSONDecoder().decode(Feed.self, from: data)
        return (feed.performances ?? []).compactMap { performance in
            guard let date = parseISODate(performance.time) else { return nil }
            return FeedPlay(
                playID: String(performance.id),
                playedAt: date,
                artist: performance.artist?.trimmingCharacters(in: .whitespaces) ?? "",
                title: performance.title?.trimmingCharacters(in: .whitespaces) ?? ""
            )
        }
    }

    private struct Feed: Decodable {
        let performances: [Performance]?
    }

    private struct Performance: Decodable {
        let id: Int64
        let time: String
        let artist: String?
        let title: String?
    }
}

/// Reads iHeartRadio station sites and their public track history. See
/// docs/iheart-track-history.md.
public struct IHeartSource: PlaySource {
    public let name = "iheart"
    let http: HTTPClient

    /// The feed returns up to 200 plays. 100 cover about eight hours, so a
    /// long outage loses fewer of them.
    static let count = 100

    public init(http: HTTPClient) {
        self.http = http
    }

    /// The slug is the station site's name, such as `hits1061seattle` for
    /// hits1061seattle.iheart.com.
    public func lookUp(slug: String) async throws -> StationInfo {
        guard slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }), !slug.isEmpty else {
            throw SourceError(description: "\(slug) isn't an iHeartRadio site name, such as hits1061seattle.")
        }
        let site = URL(string: "https://\(slug).iheart.com/")!
        let html = String(decoding: try await http.send(HTTPRequest(url: site)).requireSuccess(for: site), as: UTF8.self)
        guard let streamID = firstMatch(#""stream":\{"id":(\d+)"#, in: html) else {
            throw SourceError(description: "No iHeartRadio stream ID on \(site). Check the slug.")
        }
        let url = URL(string: "https://us.api.iheart.com/api/v2/content/liveStations/\(streamID)")!
        let data = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"])).requireSuccess(for: url)
        let name = try JSONDecoder().decode(LiveStations.self, from: data).hits.first?.name
        return StationInfo(slug: slug, source: self.name, feedID: streamID, name: name ?? slug)
    }

    public func recentPlays(feedID: String) async throws -> [FeedPlay] {
        let url = URL(string: "https://us.api.iheart.com/api/v3/live-meta/stream/\(feedID)/trackHistory?limit=\(Self.count)")!
        let data = try await http.send(HTTPRequest(url: url, headers: ["Accept": "application/json"])).requireSuccess(for: url)
        // The feed has no play ID, and a station plays one song at a time, so
        // the start time identifies a play.
        return try JSONDecoder().decode(TrackHistory.self, from: data).data.map { track in
            FeedPlay(
                playID: String(track.startTime),
                playedAt: Date(timeIntervalSince1970: TimeInterval(track.startTime)),
                artist: track.artist?.trimmingCharacters(in: .whitespaces) ?? "",
                title: track.title?.trimmingCharacters(in: .whitespaces) ?? ""
            )
        }
    }

    private struct LiveStations: Decodable {
        let hits: [Station]

        struct Station: Decodable {
            let name: String?
        }
    }

    private struct TrackHistory: Decodable {
        let data: [Track]
    }

    private struct Track: Decodable {
        let startTime: Int64
        let artist: String?
        let title: String?
    }
}

func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
}

func decodeEntities(_ text: String) -> String {
    text.replacingOccurrences(of: "&amp;", with: "&")
        .replacingOccurrences(of: "&#x27;", with: "'")
        .replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&quot;", with: "\"")
}
