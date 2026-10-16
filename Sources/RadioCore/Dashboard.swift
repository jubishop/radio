import Foundation

/// Routes web requests to the dashboard, playlist, review, and sign-in pages.
public struct Dashboard: Sendable {
    let radio: Radio

    public init(radio: Radio) {
        self.radio = radio
    }

    public func handle(_ request: WebRequest) async -> WebResponse {
        guard request.isAddressedToThisMac else {
            return .text("Open Radio by this Mac's .local name, localhost, or IP address.", status: 403)
        }
        // Otherwise a page on another site could make changes through the
        // browser of anyone on the home network.
        if request.method != "GET", request.isFromAnotherSite {
            return .text("Radio accepts changes only from its own pages.", status: 403)
        }
        let parts = request.path.split(separator: "/").map(String.init)
        do {
            switch (request.method, parts.count) {
            case ("GET", 0):
                return .html(Pages.dashboard(try await radio.status(), signInURL: radio.signInURL))
            case ("GET", 2) where parts[0] == "playlists":
                guard let kind = Playlist.Kind.allCases.first(where: { Pages.path(of: $0) == request.path }) else {
                    return .html(Pages.notFound(), status: 404)
                }
                return .html(Pages.playlist(name: await radio.name(of: kind), entries: try await radio.playlistEntries(kind)))
            case ("GET", 1) where parts[0] == "review":
                return .html(Pages.review(try await radio.heldSongs(), reviewed: try await radio.reviewedSongs(),
                                          message: request.query["message"]))
            case ("POST", 3) where parts[0] == "review":
                return await review(songID: Int64(parts[1]), action: parts[2], form: request.form)
            case ("GET", 1) where parts[0] == "auth":
                guard request.isLoopback else { return .html(Pages.signInElsewhere(radio.signInURL), status: 403) }
                return .html(Pages.signIn(developerToken: try await radio.developerToken()))
            case ("POST", 2) where parts == ["auth", "token"]:
                guard request.isLoopback else { return .text("Sign in from the Mac running Radio.", status: 403) }
                return await saveToken(request.body)
            default:
                return .html(Pages.notFound(), status: 404)
            }
        } catch {
            return .html(Pages.error(String(describing: error)), status: 500)
        }
    }

    private func review(songID: Int64?, action: String, form: [String: String]) async -> WebResponse {
        guard let songID else { return .html(Pages.notFound(), status: 404) }
        let message: String
        do {
            switch action {
            case "match":
                let choice: ReviewChoice
                if let link = form["link"], !link.trimmingCharacters(in: .whitespaces).isEmpty {
                    choice = .link(link)
                } else if let candidate = form["candidate"], let index = Int(candidate) {
                    choice = .candidate(index)
                } else {
                    throw RadioError("Pick a candidate or paste an Apple Music link")
                }
                let song = try await radio.match(songID: songID, choice: choice)
                message = "Matched to \(song.artistName) – \(song.name). It joins the playlists on the next sync."
            case "ignore":
                try await radio.ignore(songID: songID)
                message = "Ignored. It won't be added or asked about again."
            case "undo":
                try await radio.undo(songID: songID)
                message = "Sent back for review. If it was matched, it leaves the playlists on the next sync."
            default:
                return .html(Pages.notFound(), status: 404)
            }
        } catch {
            message = "Couldn't save that: \(error)"
        }
        var components = URLComponents()
        components.path = "/review"
        components.queryItems = [URLQueryItem(name: "message", value: message)]
        return .redirect(components.string ?? "/review")
    }

    private func saveToken(_ body: Data) async -> WebResponse {
        struct Body: Decodable { let token: String }
        guard let token = try? JSONDecoder().decode(Body.self, from: body).token, !token.isEmpty else {
            return .text("Missing token", status: 400)
        }
        do {
            try await radio.saveUserToken(token)
            return .text("Signed in", status: 200)
        } catch {
            return .text("Apple Music didn't accept that sign-in: \(error)", status: 400)
        }
    }
}
