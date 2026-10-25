import Foundation
import RadioCore

let usage = """
    Usage: radio <command>

    Stations
      station add <slug> [--source audacy|iheart|hubbard] [--name NAME]
                              Follow a station. The slug is its audacy.com path,
                              e.g. alt1021rva; with --source iheart its
                              iheart.com site name, e.g. hits1061seattle; or
                              with --source hubbard its site's domain, e.g.
                              movin925.com
      station list            List followed stations

    Scheduled work
      run                     Poll, sync, and send alerts and the daily review
                              reminder (launchd runs this)
      poll                    Log new plays from every station
      sync                    Match new songs and update the playlists
      serve [--port 8102]     Serve the dashboard (launchd keeps this running)

    Review
      unmatched               List songs held back for review, with Jev's
                              suggestion
      match <id><letter>      Use a listed candidate, e.g. `radio match 12a`
      match <id> <link>       Use any Apple Music song link
      ignore <id>             Never add this song
      reviewed                List songs Jev or you matched, and songs you
                              ignored, newest first
      undo <id>               Send one of those back for review

    Setup and data
      credentials set --key-id ID --team-id ID --key-file AuthKey.p8
      credentials show        Show Apple Music setup, without secrets
      status                  Show station and sync health
      export [--station SLUG] Write every logged play as CSV

    RADIO_HOME overrides ~/Library/Application Support/Radio. RADIO_ENV_FILE,
    ~/.env by default, holds PUSHOVER_USER_KEY, PUSHOVER_API_KEY,
    RESEND_API_KEY, EMAIL_TO, and JEV_API_KEY. RADIO_DASHBOARD_URL, by default
    http://jubi.local:8102, is where alerts link.
    """

struct UsageError: Error, CustomStringConvertible {
    let description: String
}

func option(_ name: String, in arguments: [String]) throws -> String? {
    guard let index = arguments.firstIndex(of: name) else { return nil }
    guard index + 1 < arguments.count else { throw UsageError(description: "\(name) needs a value") }
    return arguments[index + 1]
}

func log(_ message: String) {
    print("[\(Date().formatted(.iso8601))] \(message)")
}

func makeRadio() throws -> Radio {
    let http = URLSessionHTTPClient()
    let environment = ProcessInfo.processInfo.environment
    let envFile = environment["RADIO_ENV_FILE"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".env")
    return try Radio(
        home: .standard(),
        http: http,
        sources: [AudacySource(http: http), IHeartSource(http: http), HubbardSource(http: http)],
        notifier: PushoverNotifier(http: http, envFile: envFile),
        mailer: ResendMailer(http: http, envFile: envFile),
        musicApp: ScriptedMusicApp(),
        jevAPIKey: readEnvFile(at: envFile)["JEV_API_KEY"],
        dashboardURL: environment["RADIO_DASHBOARD_URL"]
    )
}

func printPolls(_ results: [PollResult]) {
    for result in results {
        if let error = result.error {
            log("\(result.station): feed failed: \(error)")
        } else {
            log("\(result.station): \(result.newPlays) new play\(result.newPlays == 1 ? "" : "s")")
        }
    }
}

func printSync(_ report: SyncReport) {
    if let reason = report.skippedReason {
        log("Sync skipped: \(reason)")
        return
    }
    let changes = report.playlists.sorted { $0.key < $1.key }.compactMap { name, changes -> String? in
        let parts = [("added", changes.added), ("moved to the end", changes.moved), ("dropped", changes.dropped),
                     ("waiting for the library", changes.waiting)]
            .filter { $0.1 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? nil : "\(name): " + parts.joined(separator: ", ")
    }
    var summary = "\(report.matched) matched, \(report.held) held for review"
    if report.jevMatched > 0 { summary += ", \(report.jevMatched) matched by Jev" }
    var details = changes
    if report.replaced > 0 { details.append("replaced \(report.replaced) rejected matches") }
    if report.removed > 0 { details.append("removed \(report.removed) sent back for review") }
    if report.commented > 0 { details.append("commented \(report.commented) song\(report.commented == 1 ? "" : "s")") }
    log("Sync: " + ([summary] + details).joined(separator: "; "))
    if let error = report.jevError { log("Jev failed: \(error)") }
    if let error = report.error { log("Sync failed: \(error)") }
}

func parseMatch(_ arguments: [String]) throws -> (Int64, ReviewChoice) {
    guard let first = arguments.first else { throw UsageError(description: "Usage: radio match <id><letter> | <id> <link>") }
    if arguments.count >= 2, let id = Int64(first) {
        return (id, .link(arguments[1]))
    }
    guard let letter = first.last, letter.isLetter, let id = Int64(first.dropLast()),
          let ascii = letter.lowercased().unicodeScalars.first?.value, (97...122).contains(ascii)
    else { throw UsageError(description: "Usage: radio match <id><letter> | <id> <link>") }
    return (id, .candidate(Int(ascii) - 97))
}

func main(_ arguments: [String]) async throws -> Int32 {
    guard let command = arguments.first else {
        print(usage)
        return 64
    }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "help", "--help", "-h":
        print(usage)
    case "station":
        let radio = try makeRadio()
        switch rest.first {
        case "add":
            guard rest.count >= 2 else { throw UsageError(description: "Usage: radio station add <slug> [--source audacy|iheart|hubbard] [--name NAME]") }
            let station = try await radio.addStation(
                slug: rest[1], source: try option("--source", in: rest) ?? "audacy", name: try option("--name", in: rest)
            )
            print("Added \(station.name) (\(station.slug), feed \(station.feedID)). Its songs go into the \"\(Radio.playlistName)\", \"\(Radio.newPlaylistName)\", \"\(Radio.unplayedPlaylistName)\", and \"\(Radio.archivePlaylistName)\" playlists.")
        case "list":
            for station in try await radio.stations() {
                print("\(station.slug)\t\(station.name)\t\(station.source):\(station.feedID)")
            }
        default:
            throw UsageError(description: "Usage: radio station add|list")
        }
    case "poll":
        printPolls(try await makeRadio().poll())
    case "sync":
        let report = try await makeRadio().sync()
        printSync(report)
        return report.error == nil ? 0 : 1
    case "run":
        let (polls, sync) = try await makeRadio().run()
        printPolls(polls)
        printSync(sync)
        return polls.allSatisfy { $0.error == nil } && sync.error == nil ? 0 : 1
    case "serve":
        let radio = try makeRadio()
        let port = UInt16(try option("--port", in: rest) ?? "8102") ?? 8102
        let dashboard = Dashboard(radio: radio)
        let server = try WebServer(port: port) { await dashboard.handle($0) }
        let actual = try await server.start()
        log("Serving the dashboard on port \(actual); alerts link to \(radio.dashboardURL)")
        while true { try await Task.sleep(for: .seconds(3600)) }
    case "unmatched":
        let songs = try await makeRadio().heldSongs()
        if songs.isEmpty { print("Nothing to review.") }
        for song in songs {
            print("\(song.id)  \(song.artist) – \(song.title)  (\(song.playCount) play\(song.playCount == 1 ? "" : "s") on \(song.stations.joined(separator: ", ")), last \(displayTime(song.lastPlayedAt)))")
            for (index, candidate) in song.candidates.enumerated() {
                let explicit = candidate.isExplicit ? " [explicit]" : ""
                let suggested = song.suggestion.flatMap { $0.candidate == index ? "  ← Jev suggests (\($0.score.formatted(.number.precision(.fractionLength(2)))))" : nil } ?? ""
                print("    \(song.id)\(candidateLetter(index))  \(candidate.artistName) – \(candidate.name) (\(candidate.albumName))\(explicit)  \(candidate.url)\(suggested)")
            }
            if song.candidates.isEmpty { print("    (no candidates)") }
        }
    case "match":
        let (id, choice) = try parseMatch(rest)
        let song = try await makeRadio().match(songID: id, choice: choice)
        print("Matched to \(song.artistName) – \(song.name). It joins the playlists on the next sync.")
    case "ignore":
        guard let id = rest.first.flatMap({ Int64($0) }) else { throw UsageError(description: "Usage: radio ignore <id>") }
        try await makeRadio().ignore(songID: id)
        print("Ignored song \(id).")
    case "reviewed":
        let songs = try await makeRadio().reviewedSongs()
        if songs.isEmpty { print("Nothing reviewed yet.") }
        for song in songs {
            let decision = switch song.decision {
            case .jev(let score, let model): "matched by Jev, \(score.formatted(.number.precision(.fractionLength(2)))) from \(model)"
            case .manual: "matched by you"
            case .ignored: "ignored by you"
            }
            let pick = song.catalog.map { " → \($0.artistName) – \($0.name)" } ?? ""
            print("\(song.id)  \(song.artist) – \(song.title)\(pick)  (\(decision), \(displayTime(song.decidedAt)))")
        }
    case "undo":
        guard let id = rest.first.flatMap({ Int64($0) }) else { throw UsageError(description: "Usage: radio undo <id>") }
        try await makeRadio().undo(songID: id)
        print("Sent song \(id) back for review. If it was matched, it leaves the playlists on the next sync.")
    case "credentials":
        let radio = try makeRadio()
        switch rest.first {
        case "set":
            guard let keyID = try option("--key-id", in: rest), let teamID = try option("--team-id", in: rest),
                  let keyFile = try option("--key-file", in: rest)
            else { throw UsageError(description: "Usage: radio credentials set --key-id ID --team-id ID --key-file AuthKey.p8") }
            let pem = try String(contentsOfFile: (keyFile as NSString).expandingTildeInPath, encoding: .utf8)
            try await radio.setCredentials(keyID: keyID, teamID: teamID, keyPEM: pem)
            print("Saved MusicKit key \(keyID) for team \(teamID). Next, open \(radio.signInURL) on this Mac to sign in to Apple Music.")
        case "show":
            guard let saved = try await radio.savedCredentials() else {
                print("Apple Music isn't configured. Run `radio credentials set`.")
                break
            }
            print("Key ID: \(saved.keyID)\nTeam ID: \(saved.teamID)")
            print("Signed in: \(saved.musicUserToken == nil ? "no" : "yes, \(saved.userTokenSavedAt.map(displayTime) ?? "date unknown")")")
            print("Storefront: \(saved.storefront ?? "unknown")")
        default:
            throw UsageError(description: "Usage: radio credentials set|show")
        }
    case "status":
        let radio = try makeRadio()
        let status = try await radio.status(recentPlays: 1, recentlyAdded: 0)
        switch status.appleMusic {
        case .notConfigured: print("Apple Music: not set up (run `radio credentials set`)")
        case .needsSignIn: print("Apple Music: sign-in needed (open \(radio.signInURL) on this Mac)")
        case .rejected(let since): print("Apple Music: sign-in rejected since \(displayTime(since)) (open \(radio.signInURL) on this Mac)")
        case .connected(let storefront, let signedInAt):
            print("Apple Music: connected (\(storefront)), signed in \(signedInAt.map(displayTime) ?? "at an unknown time")")
        }
        print("Last sync: \(status.lastSyncAt.map(displayTime) ?? "never")\(status.lastSyncError.map { " (failed: \($0))" } ?? "")")
        print("Songs to review: \(status.heldCount)")
        if let error = status.musicAppError { print("Music.app: \(error)") }
        if let since = status.musicBehindSince {
            print("Music.app: behind its library since \(displayTime(since)); open Music to see the alert holding it back")
        }
        if let error = status.jevError { print("Jev: \(error)") }
        print("Playlist \"\(Radio.playlistName)\": \(status.playlistCount) of \(radio.playlistLimit) songs")
        print("Playlist \"\(Radio.newPlaylistName)\": \(status.newCount) of \(radio.playlistLimit) songs")
        print("Playlist \"\(Radio.unplayedPlaylistName)\": \(status.unplayedCount) of \(radio.playlistLimit) songs")
        print("Playlist \"\(Radio.archivePlaylistName)\": \(status.archiveCount) of \(radio.archiveLimit) songs")
        for summary in status.stations {
            let station = summary.station
            let feed = station.pollFailingSince.map { "failing since \(displayTime($0)): \(station.lastPollError ?? "")" }
                ?? station.lastPollOKAt.map { "read \(displayTime($0))" } ?? "not read yet"
            print("\(station.name): feed \(feed); \(summary.playCount) plays")
        }
    case "export":
        print(try await makeRadio().exportCSV(stationSlug: try option("--station", in: rest)), terminator: "")
    default:
        throw UsageError(description: "Unknown command \(command). Run `radio help`.")
    }
    return 0
}

// launchd sends output to log files; flush each line as it's written.
setvbuf(stdout, nil, _IOLBF, 0)

do {
    exit(try await main(Array(CommandLine.arguments.dropFirst())))
} catch let error as UsageError {
    FileHandle.standardError.write(Data("\(error.description)\n".utf8))
    exit(64)
} catch {
    FileHandle.standardError.write(Data("radio: \(error)\n".utf8))
    exit(1)
}
