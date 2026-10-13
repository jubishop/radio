import Foundation

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String = "GET", url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public var isSuccess: Bool { (200..<300).contains(status) }
}

/// Sends HTTP requests. Radio's network boundary, so tests can substitute it.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: 30)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.setValue("Radio/1.0 (+https://github.com/jubishop/radio)", forHTTPHeaderField: "User-Agent")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(status: status, body: data)
    }
}

struct HTTPStatusError: Error, CustomStringConvertible {
    let url: URL
    let status: Int
    let body: String

    var description: String {
        "HTTP \(status) from \(url.host() ?? url.absoluteString): \(body.prefix(200))"
    }
}

extension HTTPResponse {
    func requireSuccess(for url: URL) throws -> Data {
        guard isSuccess else {
            throw HTTPStatusError(url: url, status: status, body: String(decoding: body, as: UTF8.self))
        }
        return body
    }
}
