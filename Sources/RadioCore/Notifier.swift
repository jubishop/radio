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

/// Sends email to the user through Resend.
public struct ResendMailer: Sendable {
    let http: HTTPClient
    let apiKey: String?
    let recipient: String?
    let sender: String

    public init(http: HTTPClient, apiKey: String?, recipient: String?, sender: String = "Radio <radio@jubishop.com>") {
        self.http = http
        self.apiKey = apiKey
        self.recipient = recipient
        self.sender = sender
    }

    /// Reads `RESEND_API_KEY` and `EMAIL_TO` from an env file.
    public init(http: HTTPClient, envFile: URL) {
        let values = readEnvFile(at: envFile)
        self.init(http: http, apiKey: values["RESEND_API_KEY"], recipient: values["EMAIL_TO"])
    }

    var isConfigured: Bool { apiKey?.isEmpty == false && recipient?.isEmpty == false }

    /// Returns false, without sending, when the Resend key or recipient is
    /// missing.
    @discardableResult
    func send(subject: String, text: String, html: String) async throws -> Bool {
        guard let apiKey, let recipient, isConfigured else { return false }
        let body: [String: Any] = ["from": sender, "to": [recipient], "subject": subject, "text": text, "html": html]
        let url = URL(string: "https://api.resend.com/emails")!
        let response = try await http.send(HTTPRequest(
            method: "POST", url: url,
            headers: ["Authorization": "Bearer \(apiKey)", "Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body)
        ))
        _ = try response.requireSuccess(for: url)
        return true
    }
}
