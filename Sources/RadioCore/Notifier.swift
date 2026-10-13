import Foundation

/// Sends short alerts to the user's devices through Pushover.
public struct PushoverNotifier: Sendable {
    let http: HTTPClient
    let userKey: String?
    let apiKey: String?

    public init(http: HTTPClient, userKey: String?, apiKey: String?) {
        self.http = http
        self.userKey = userKey
        self.apiKey = apiKey
    }

    /// Reads `PUSHOVER_USER_KEY` and `PUSHOVER_API_KEY` from an env file.
    public init(http: HTTPClient, envFile: URL) {
        let values = readEnvFile(at: envFile)
        self.init(http: http, userKey: values["PUSHOVER_USER_KEY"], apiKey: values["PUSHOVER_API_KEY"])
    }

    var isConfigured: Bool { userKey?.isEmpty == false && apiKey?.isEmpty == false }

    /// Returns false, without sending, when Pushover keys are missing.
    @discardableResult
    func send(title: String, message: String, link: String? = nil) async throws -> Bool {
        guard let userKey, let apiKey, isConfigured else { return false }
        var fields = ["token": apiKey, "user": userKey, "title": title, "message": message]
        if let link {
            fields["url"] = link
            fields["url_title"] = "Open Radio"
        }
        var components = URLComponents()
        components.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        let body = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        let url = URL(string: "https://api.pushover.net/1/messages.json")!
        let response = try await http.send(HTTPRequest(
            method: "POST", url: url,
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: Data(body.utf8)
        ))
        _ = try response.requireSuccess(for: url)
        return true
    }
}
