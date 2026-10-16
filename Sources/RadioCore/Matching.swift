import Foundation

/// A song in the Apple Music catalog.
public struct CatalogSong: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var artistName: String
    public var albumName: String
    public var url: String
    public var isExplicit: Bool

    public init(id: String, name: String, artistName: String, albumName: String, url: String, isExplicit: Bool) {
        self.id = id
        self.name = name
        self.artistName = artistName
        self.albumName = albumName
        self.url = url
        self.isExplicit = isExplicit
    }
}

/// How Radio identifies a song across plays, stations, and the catalog.
enum SongIdentity {
    /// One key per song, so differently credited plays of it share a match.
    static func key(artist: String, title: String) -> String {
        "\(primaryArtist(artist))|\(normalize(baseTitle(title)))"
    }

    /// The search text for a played song.
    static func searchTerm(artist: String, title: String) -> String {
        let primary = artistParts(artist).first ?? artist
        return "\(primary) \(baseTitle(title))"
    }

    static func primaryArtist(_ artist: String) -> String {
        normalizeArtist(artistParts(artist).first ?? artist)
    }

    /// Whether two credits name the same act: they match as a whole, or
    /// either one's lead artist is credited anywhere in the other.
    static func sameArtist(_ artist: String, _ other: String) -> Bool {
        let artists = creditedArtists(artist), others = creditedArtists(other)
        return normalizeArtist(artist) == normalizeArtist(other)
            || artists.first.map(others.contains) == true
            || others.first.map(artists.contains) == true
    }

    /// The credit's artists, normalized, lead artist first. This splits more
    /// than `key` does, at "BEYONCE/JAY-Z" and "Usher f/ Pitbull", because
    /// splitting there in `key` would also split names like "HUNTR/X" and
    /// change the keys of logged songs.
    private static func creditedArtists(_ artist: String) -> [String] {
        artist.replacingOccurrences(of: #"\s*(\bf)?/\s*"#, with: "\u{1F}", options: [.regularExpression, .caseInsensitive])
            .split(separator: "\u{1F}")
            .flatMap { artistParts(String($0)) }
            .map(normalizeArtist)
            .filter { !$0.isEmpty }
    }

    /// The title without parenthetical or bracketed notes or a " - " suffix.
    static func baseTitle(_ title: String) -> String {
        var result = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        if let dash = result.range(of: " - ") {
            result = String(result[..<dash.lowerBound])
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    /// The title as matching compares it: the base title without a trailing
    /// featured credit, as in "Rein Me In Ft. Olivia Dean". `key` keeps the
    /// credit, so logged songs keep their keys.
    static func matchingTitle(_ title: String) -> String {
        let base = baseTitle(title)
        let uncredited = base.replacingOccurrences(of: #"\s+(ft|feat|featuring)\b.*$"#, with: "",
                                                   options: [.regularExpression, .caseInsensitive])
        return normalize(uncredited.isEmpty ? base : uncredited)
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "['’`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
        return folded.trimmingCharacters(in: .whitespaces)
    }

    static func normalizeArtist(_ artist: String) -> String {
        let normalized = normalize(artist)
        return normalized.hasPrefix("the ") ? String(normalized.dropFirst(4)) : normalized
    }

    private static func artistParts(_ artist: String) -> [String] {
        artist.replacingOccurrences(
            of: #"\s*(/|,|&|\bfeat\.?|\bft\.?|\bfeaturing\b|\bwith\b|\bx\b|\bvs\.?)\s+"#,
            with: "\u{1F}",
            options: [.regularExpression, .caseInsensitive]
        )
        .split(separator: "\u{1F}")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    }

    /// Words that mark an alternate recording in a title or album.
    private static let versionPattern =
        #"[\(\[\-]\s*[^\)\]]*\b(live|acoustic|remix|mix|mixed|karaoke|instrumental|demo|unplugged|sped up|slowed|a cappella)\b"#
    private static let liveAlbumPattern =
        #"(\(live\)|\blive (at|from|in|on)\b|\bunplugged\b|\bkaraoke\b|\btribute\b|\bdj mix\b|\bmixed by\b|\bcontinuous mix\b)"#

    static func isAlternateVersion(title: String) -> Bool {
        title.range(of: versionPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func isAlternateAlbum(_ album: String) -> Bool {
        album.range(of: liveAlbumPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Picks the catalog song for a played song, or nil when no candidate
/// matches strictly enough to add without review.
public func chooseMatch(artist: String, title: String, candidates: [CatalogSong]) -> CatalogSong? {
    let wantedTitle = SongIdentity.matchingTitle(title)
    let alternateWanted = SongIdentity.isAlternateVersion(title: title)
    let accepted = candidates.filter { candidate in
        guard SongIdentity.sameArtist(artist, candidate.artistName),
              SongIdentity.matchingTitle(candidate.name) == wantedTitle
        else { return false }
        if alternateWanted { return true }
        return !SongIdentity.isAlternateVersion(title: candidate.name) && !SongIdentity.isAlternateAlbum(candidate.albumName)
    }
    return accepted.first(where: \.isExplicit) ?? accepted.first
}
