import Foundation
import Network
import Synchronization

public struct WebRequest: Sendable {
    public var method: String
    public var path: String
    public var query: [String: String]
    public var headers: [String: String]
    public var body: Data
    /// True when the request came from this Mac.
    public var isLoopback: Bool

    public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data, isLoopback: Bool) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
        self.isLoopback = isLoopback
    }

    /// Fields of an `application/x-www-form-urlencoded` body.
    public var form: [String: String] {
        parseQuery(String(decoding: body, as: UTF8.self))
    }
}

public struct WebResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data
    public var headers: [String: String] = [:]

    public static func html(_ html: String, status: Int = 200) -> WebResponse {
        WebResponse(status: status, contentType: "text/html; charset=utf-8", body: Data(html.utf8))
    }

    public static func text(_ text: String, status: Int) -> WebResponse {
        WebResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(text.utf8))
    }

    public static func redirect(_ location: String) -> WebResponse {
        WebResponse(status: 303, contentType: "text/plain", body: Data(), headers: ["Location": location])
    }
}

/// A minimal HTTP/1.1 server: one request per connection, then close.
public final class WebServer: Sendable {
    public typealias Handler = @Sendable (WebRequest) async -> WebResponse

    private let listener: NWListener
    private let handler: Handler
    private let queue = DispatchQueue(label: "radio.web")
    static let maximumRequestSize = 1 << 20

    /// Port 0 picks a free port; `start()` returns the one chosen.
    public init(port: UInt16, handler: @escaping Handler) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
        self.handler = handler
    }

    public func start() async throws -> UInt16 {
        let resumed = Mutex(false)
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                let result: Result<UInt16, Error>?
                switch state {
                case .ready: result = .success(listener.port?.rawValue ?? 0)
                case .failed(let error): result = .failure(error)
                case .cancelled: result = .failure(RadioError("Web server was cancelled"))
                default: result = nil
                }
                guard let result, resumed.withLock({ done in defer { done = true }; return !done }) else { return }
                continuation.resume(with: result)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.serve(connection)
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = parseRequest(buffer, isLoopback: isLoopback(connection.currentPath?.remoteEndpoint)) {
                let handler = self.handler
                Task {
                    let response = await handler(request)
                    connection.send(content: encode(response), completion: .contentProcessed { _ in connection.cancel() })
                }
            } else if error != nil || isComplete || buffer.count > Self.maximumRequestSize {
                connection.send(content: encode(.text("Bad request", status: 400)), completion: .contentProcessed { _ in connection.cancel() })
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }
}

private func isLoopback(_ endpoint: NWEndpoint?) -> Bool {
    guard case .hostPort(let host, _) = endpoint else { return false }
    switch host {
    case .ipv4(let address): return address.isLoopback
    case .ipv6(let address): return address.isLoopback || address.asIPv4?.isLoopback == true
    case .name(let name, _): return name == "localhost"
    @unknown default: return false
    }
}

/// Parses a complete request, or returns nil if more bytes are needed.
func parseRequest(_ data: Data, isLoopback: Bool) -> WebRequest? {
    guard let headerEnd = data.firstRange(of: Data("\r\n\r\n".utf8)) else { return nil }
    let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ")
    guard requestLine.count >= 2 else { return nil }
    var headers: [String: String] = [:]
    for line in lines {
        guard let colon = line.firstIndex(of: ":") else { continue }
        headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }
    let bodyStart = headerEnd.upperBound
    let length = Int(headers["content-length"] ?? "0") ?? 0
    guard data.count - bodyStart >= length else { return nil }
    let target = String(requestLine[1])
    let path = target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
    let query = target.contains("?") ? parseQuery(String(target.split(separator: "?", maxSplits: 1)[1])) : [:]
    return WebRequest(
        method: String(requestLine[0]),
        path: path.removingPercentEncoding ?? path,
        query: query,
        headers: headers,
        body: Data(data[bodyStart..<(bodyStart + length)]),
        isLoopback: isLoopback
    )
}

func parseQuery(_ text: String) -> [String: String] {
    var values: [String: String] = [:]
    for pair in text.split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1).map {
            $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
        }
        guard let key = parts.first else { continue }
        values[key] = parts.count > 1 ? parts[1] : ""
    }
    return values
}

private func encode(_ response: WebResponse) -> Data {
    let reason = HTTPURLResponse.localizedString(forStatusCode: response.status).capitalized
    var head = "HTTP/1.1 \(response.status) \(reason)\r\n"
    var headers = response.headers
    headers["Content-Type"] = response.contentType
    headers["Content-Length"] = String(response.body.count)
    headers["Connection"] = "close"
    headers["Cache-Control"] = "no-store"
    for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
        head += "\(name): \(value)\r\n"
    }
    return Data((head + "\r\n").utf8) + response.body
}
