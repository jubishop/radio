import CryptoKit
import Foundation
import RadioCore
import Testing

@Suite struct WebTests {
    func request(_ method: String, _ path: String, form: String = "", loopback: Bool = false) -> WebRequest {
        let parts = path.split(separator: "?", maxSplits: 1)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for item in URLComponents(string: "?" + parts[1])?.queryItems ?? [] { query[item.name] = item.value }
        }
        return WebRequest(method: method, path: String(parts[0]), query: query, headers: [:], body: Data(form.utf8), isLoopback: loopback)
    }

    func text(_ response: WebResponse) -> String { String(decoding: response.body, as: UTF8.self) }

    @Test func theDashboardShowsEachStationsRecentPlaysAndHealth() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Rise Against", "Savior")
        harness.play("Rise Against", "Savior", minutesAgo: 4)
        harness.play("Tom & Jerry <Band>", "Unmatched Song")
        _ = try await harness.radio.run()

        let page = text(await Dashboard(radio: harness.radio).handle(request("GET", "/")))

        #expect(page.contains("<h2>Alt 102.1</h2>"))
        #expect(page.contains("Latest: <strong>Tom &amp; Jerry &lt;Band&gt; – Unmatched Song</strong>"))
        #expect(page.contains("Apple Music connected"))
        #expect(page.contains("1 song to review"))
        #expect(page.contains("in playlist"))
        #expect(page.contains("1 song in the Radio playlist"))
    }

    @Test func theReviewPageMatchesAndIgnoresSongs() async throws {
        let harness = try Harness()
        try await harness.signIn()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        harness.music.addToCatalog("Nirvana", "Come As You Are (Live)")
        harness.play("Nirvana", "Come As You Are")
        harness.play("Unknown Band", "Demo", minutesAgo: 2)
        _ = try await harness.radio.run()
        let dashboard = Dashboard(radio: harness.radio)
        let held = try await harness.radio.heldSongs()
        let nirvana = try #require(held.first { $0.artist == "Nirvana" })
        let unknown = try #require(held.first { $0.artist == "Unknown Band" })

        let page = text(await dashboard.handle(request("GET", "/review")))
        #expect(page.contains("Nirvana – Come As You Are"))
        #expect(page.contains("Use a"))

        let matched = await dashboard.handle(request("POST", "/review/\(nirvana.id)/match", form: "candidate=0"))
        let ignored = await dashboard.handle(request("POST", "/review/\(unknown.id)/ignore"))
        #expect(matched.status == 303)
        #expect(matched.headers["Location"]?.hasPrefix("/review?message=Matched") == true)
        #expect(ignored.status == 303)
        #expect(try await harness.radio.heldSongs().isEmpty)

        _ = try await harness.radio.sync()
        #expect(harness.music.playlists() == ["Radio": ["Come As You Are (Live)"]])
    }

    @Test func signInIsOnlyServedToThisMac() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let dashboard = Dashboard(radio: harness.radio)

        let remote = await dashboard.handle(request("GET", "/auth"))
        let local = await dashboard.handle(request("GET", "/auth", loopback: true))
        let remoteToken = await dashboard.handle(WebRequest(
            method: "POST", path: "/auth/token", query: [:], headers: [:],
            body: Data(#"{"token":"stolen"}"#.utf8), isLoopback: false
        ))

        #expect(remote.status == 403)
        #expect(!text(remote).contains("developerToken"))
        #expect(local.status == 200)
        #expect(text(local).contains("musickit.js"))
        #expect(remoteToken.status == 403)
        #expect(try await harness.radio.appleMusicState() == .needsSignIn)
    }

    @Test func aTokenPostedFromThisMacSignsIn() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let response = await Dashboard(radio: harness.radio).handle(WebRequest(
            method: "POST", path: "/auth/token", query: [:], headers: [:],
            body: Data(#"{"token":"user-token"}"#.utf8), isLoopback: true
        ))
        #expect(response.status == 200)
        #expect(try await harness.radio.appleMusicState() == .connected(storefront: "us", signedInAt: harness.clock.now))
    }

    @Test func theServerAnswersOverHTTP() async throws {
        let harness = try Harness()
        _ = try await harness.radio.addStation(slug: "alt1021rva")
        let dashboard = Dashboard(radio: harness.radio)
        let server = try WebServer(port: 0) { await dashboard.handle($0) }
        let port = try await server.start()
        defer { server.stop() }

        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/")!)
        let (_, missing) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/nope")!)

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self).contains("Alt 102.1"))
        #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test func theServerTreatsLocalConnectionsAsThisMac() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let dashboard = Dashboard(radio: harness.radio)
        let server = try WebServer(port: 0) { await dashboard.handle($0) }
        let port = try await server.start()
        defer { server.stop() }

        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/auth")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
    }
}

@Suite struct CredentialTests {
    @Test func developerTokensAreValidES256JWTs() async throws {
        let harness = try Harness()
        let key = P256.Signing.PrivateKey()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: key.pemRepresentation)

        let token = try await harness.radio.developerToken(lifetime: 3600)
        let parts = token.split(separator: ".").map(String.init)
        #expect(parts.count == 3)

        func decode(_ part: String) throws -> Data {
            var base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            return try #require(Data(base64Encoded: base64))
        }
        let header = try JSONSerialization.jsonObject(with: decode(parts[0])) as? [String: Any]
        let claims = try JSONSerialization.jsonObject(with: decode(parts[1])) as? [String: Any]
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: decode(parts[2]))
        let now = Int(harness.clock.now.timeIntervalSince1970)

        #expect(header?["alg"] as? String == "ES256")
        #expect(header?["kid"] as? String == "KEY123")
        #expect(claims?["iss"] as? String == "TEAM456")
        #expect(claims?["iat"] as? Int == now)
        #expect(claims?["exp"] as? Int == now + 3600)
        #expect(key.publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func credentialsReadableByOthersAreRefused() async throws {
        let harness = try Harness()
        try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: P256.Signing.PrivateKey().pemRepresentation)
        let file = harness.home.directory.appendingPathComponent("credentials.json")
        #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        await #expect(throws: CredentialsError.self) { try await harness.radio.savedCredentials() }
    }

    @Test func anInvalidKeyIsRejectedBeforeSaving() async throws {
        let harness = try Harness()
        await #expect(throws: (any Error).self) {
            try await harness.radio.setCredentials(keyID: "KEY123", teamID: "TEAM456", keyPEM: "not a key")
        }
        #expect(try await harness.radio.savedCredentials() == nil)
    }

    @Test func envFilesAreReadWithoutRunningThem() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("radio-env-\(UUID().uuidString)")
        try """
            # comment
            export PUSHOVER_USER_KEY="user value"
            PUSHOVER_API_KEY='app'
            OTHER=$(rm -rf /)
            """.write(to: file, atomically: true, encoding: .utf8)
        let values = readEnvFile(at: file)
        #expect(values["PUSHOVER_USER_KEY"] == "user value")
        #expect(values["PUSHOVER_API_KEY"] == "app")
        #expect(values["OTHER"] == "$(rm -rf /)")
    }
}
