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
/// own implementation; Audacy is the only one so far.
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
