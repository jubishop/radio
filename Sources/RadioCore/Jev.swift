import Foundation

/// The scores Jev gave a held song's candidates, and the model that answered.
struct JevVerdict {
    var model: String
    var scores: [Double]
}

/// Asks TypeSafe's Jev, with one yes/no question per candidate, how likely
/// each Apple Music candidate is to be the recording a station played. The
/// wording is what the 2026-10-15 evaluation measured; see
/// docs/jev-matching-evaluation.md.
struct Jev {
    /// TypeSafe's newest release, preview or official. The user chose to
    /// follow it rather than pin a version.
    static let model = "jev-preview"
    static let url = URL(string: "https://api.typesafe.ai/v1/systemone")!

    private static let feedText = "A station's feed may write the artist and title in all caps, misspell or abbreviate them, "
        + "cut them off, or credit artists in a different order or format than Apple Music does."
    private static let notIt = "A different song; the song by a different artist, such as a cover, tribute, or karaoke version; "
        + "or a live, remix, acoustic, or other alternate version that the station didn't play."

    let http: HTTPClient
    let apiKey: String

    func judge(station: String, artist: String, title: String, candidates: [CatalogSong]) async throws -> JevVerdict {
        var questions: [String: Any] = [:]
        for (index, candidate) in candidates.enumerated() {
            questions["c\(index)"] = [
                "type": "noul",
                "instructions": [
                    "question": "Is `candidate` the recording the station played, as `played` reports it?",
                    "candidate": ["artist": candidate.artistName, "title": candidate.name, "album": candidate.albumName],
                    "feed_text": Self.feedText,
                ],
                "criteria": ["true": "The same song by the same artist, in the version the station played.", "false": Self.notIt],
            ]
        }
        let body: [String: Any] = [
            "model": Self.model,
            "state": ["station": station, "played": ["artist": artist, "title": title]],
            "questions": questions,
        ]
        let request = HTTPRequest(
            method: "POST", url: Self.url,
            headers: ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let data = try await http.send(request).requireSuccess(for: Self.url)
        let response = try JSONDecoder().decode(Response.self, from: data)
        let scores = try candidates.indices.map { index in
            guard let score = response.answers["c\(index)"]?.noul else {
                throw RadioError("Jev didn't answer about candidate \(candidateLetter(index))")
            }
            return score
        }
        return JevVerdict(model: response.model, scores: scores)
    }

    private struct Response: Decodable {
        let model: String
        let answers: [String: Answer]

        struct Answer: Decodable {
            let noul: Double?
        }
    }
}
