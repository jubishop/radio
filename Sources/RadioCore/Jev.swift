import Foundation

/// How likely Jev thinks each recording offered is to be the one the station
/// played, in the order offered, and the model that answered.
struct JevVerdict {
    var model: String
    var scores: [Double]
}

/// Asks TypeSafe's Jev one Choice question: which of the recordings offered,
/// or none of them, is the one a station played. The wording is what the
/// 2026-10-15 evaluation measured; see docs/jev-matching-evaluation.md.
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

    /// `recordings` offers one copy of each recording.
    func judge(station: String, artist: String, title: String, recordings: [CatalogSong]) async throws -> JevVerdict {
        var criteria: [String: Any] = ["none": "None of the songs above is that recording. Each one is: " + Self.notIt]
        for (index, recording) in recordings.enumerated() {
            criteria[candidateLetter(index)] = ["artist": recording.artistName, "title": recording.name, "album": recording.albumName]
        }
        let body: [String: Any] = [
            "model": Self.model,
            "state": ["station": station, "played": ["artist": artist, "title": title]],
            "questions": ["pick": [
                "type": "choice",
                "instructions": [
                    "question": "Which Apple Music song is the recording the station played, as `played` reports it?",
                    "feed_text": Self.feedText,
                ],
                "criteria": criteria,
            ]],
        ]
        let request = HTTPRequest(
            method: "POST", url: Self.url,
            headers: ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body)
        )
        let data = try await http.send(request).requireSuccess(for: Self.url)
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let probabilities = response.answers["pick"]?.probabilities else {
            throw RadioError("Jev didn't answer which recording it was")
        }
        return JevVerdict(model: response.model, scores: recordings.indices.map { probabilities[candidateLetter($0)] ?? 0 })
    }

    private struct Response: Decodable {
        let model: String
        let answers: [String: Answer]

        struct Answer: Decodable {
            let probabilities: [String: Double]?
        }
    }
}
