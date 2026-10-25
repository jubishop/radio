import Foundation
import Synchronization

public enum MusicAppAction: Equatable, Sendable {
    /// Puts the song at the end of the playlist: removes any entries it has
    /// there, then adds its library track. Makes the playlist if it's missing.
    case place
    /// Removes the song's entries from the playlist, keeping it in the library.
    case remove
    /// Sets the comment of the song's track, the one in the playlist or else
    /// the one placing would add. Keeps a comment that doesn't start with
    /// `mark`, which someone else wrote.
    case comment(String, mark: String)
    /// Gives the playlist its name and description, without a song.
    case rename
}

/// A playlist as Music.app finds it: by persistent ID once Radio knows it,
/// otherwise by name.
public struct MusicAppPlaylist: Sendable {
    public var id: String?
    public var name: String
    /// Given to the playlist when Music.app makes it.
    public var description: String

    public init(id: String?, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// A song as Music.app finds it: by title and artist, since Music.app
/// scripting has no catalog IDs, preferring a library track from the album.
public struct MusicAppSong: Sendable {
    public var name: String
    public var artist: String
    public var album: String

    public init(name: String, artist: String, album: String) {
        self.name = name
        self.artist = artist
        self.album = album
    }

    /// Music.app tells songs apart by title and artist, ignoring case, so
    /// songs with the same key share one entry in a playlist.
    static func key(name: String, artist: String) -> String {
        name.lowercased() + "\u{1F}" + artist.lowercased()
    }
}

/// How often the user played and skipped a library track in Music, as its
/// Plays and Skips columns count them.
public struct TrackListens: Equatable, Sendable {
    public var name: String
    public var artist: String
    public var plays: Int
    public var skips: Int

    public init(name: String, artist: String, plays: Int, skips: Int) {
        self.name = name
        self.artist = artist
        self.plays = plays
        self.skips = skips
    }
}

/// What Music.app did. Playlist IDs are Music.app's persistent IDs.
public enum MusicAppResult: Equatable, Sendable {
    case placed(playlistID: String)
    /// Also returned when placing removed the entry but couldn't add it back.
    case removed(playlistID: String)
    /// The track has the comment, or keeps one someone else wrote.
    case commented(playlistID: String)
    /// The playlist has its name and description.
    case renamed(playlistID: String)
    /// The playlist has no entry with that title and artist.
    case trackNotFound(playlistID: String)
    /// The library has no track for the song, perhaps because a song added
    /// to the library through the web API hasn't reached this Mac yet.
    /// Nothing was changed.
    case notInLibrary(playlistID: String)
    case playlistNotFound
    case ambiguousPlaylist
}

/// Edits playlists through Music.app, the only thing that changes them.
/// Music.app uploads its whole copy of a playlist it changed, which would
/// wipe out songs the web API added that hadn't reached this Mac yet. See
/// docs/design.md.
public protocol MusicApp: Sendable {
    func perform(_ action: MusicAppAction, playlist: MusicAppPlaylist, song: MusicAppSong) async throws -> MusicAppResult
    /// Every library track's plays and skips.
    func listens() async throws -> [TrackListens]
    /// Whether Music.app has changed the library from an out-of-date copy
    /// of it since `date`. Music.app stops taking in the library's changes
    /// while an alert waits for it to be opened, so it can't find songs the
    /// web API adds. See docs/design.md.
    func fellBehind(since date: Date) async throws -> Bool
}

/// Runs AppleScript in Music.app through `osascript`. Values travel as
/// arguments, never as script source.
public struct ScriptedMusicApp: MusicApp {
    let timeout: TimeInterval
    let osascript: String
    let log: String

    /// Tests pass stand-ins for `osascript` and `log`.
    public init(timeout: TimeInterval = 120, osascript: String = "/usr/bin/osascript", log: String = "/usr/bin/log") {
        self.timeout = timeout
        self.osascript = osascript
        self.log = log
    }

    public func perform(_ action: MusicAppAction, playlist: MusicAppPlaylist, song: MusicAppSong) async throws -> MusicAppResult {
        let (name, comment, mark) = switch action {
        case .place: ("place", "", "")
        case .remove: ("remove", "", "")
        case .comment(let text, let mark): ("comment", text, mark)
        case .rename: ("rename", "", "")
        }
        let output = try await runOSAScript(Self.script, arguments: [
            name, playlist.id ?? "", playlist.name, playlist.description, song.name, song.artist, song.album, comment, mark,
        ])
        let parts = output.split(separator: " ", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "placed": return .placed(playlistID: id)
        case "removed": return .removed(playlistID: id)
        case "commented": return .commented(playlistID: id)
        case "renamed": return .renamed(playlistID: id)
        case "no-track": return .trackNotFound(playlistID: id)
        case "not-in-library": return .notInLibrary(playlistID: id)
        case "no-playlist": return .playlistNotFound
        case "ambiguous-playlist": return .ambiguousPlaylist
        default: throw RadioError("Unexpected reply from Music: \(output)")
        }
    }

    public func listens() async throws -> [TrackListens] {
        Self.listens(fromOutput: try await runOSAScript(Self.listensScript, arguments: []))
    }

    /// Looks in the unified log for the library agent's note that Music.app
    /// changed the library from an older revision than the library's. It
    /// logged one with every edit Radio made while an alert held Music.app
    /// back, from 11:28 PM on 2026-10-24 to 9:13 AM the next day, and none
    /// in the day before.
    public func fellBehind(since date: Date) async throws -> Bool {
        let output = try await run(log, [
            "show", "--start", Self.logTime(date), "--style", "compact",
            "--predicate", "process == \"AMPLibraryAgent\" AND eventMessage CONTAINS \"\(Self.behindNote)\"",
        ], name: "log") { RadioError("Couldn't read Music's log: \($0)") }
        return output.contains(Self.behindNote)
    }

    static let behindNote = "sent change using non-current revision"

    /// A time as `log show` reads it, in UTC, which no change of clocks
    /// makes ambiguous.
    static func logTime(_ date: Date) -> String {
        date.formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
            timeZone: .gmt, calendar: Calendar(identifier: .gregorian)
        )) + "+0000"
    }

    /// Reads the listens script's output: tracks separated by character 30
    /// and fields by character 31, which no title or artist contains.
    public static func listens(fromOutput output: String) -> [TrackListens] {
        output.split(separator: "\u{1E}").compactMap { record in
            let fields = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let plays = Int(fields[2]), let skips = Int(fields[3]) else { return nil }
            return TrackListens(name: fields[0], artist: fields[1], plays: plays, skips: skips)
        }
    }

    private func runOSAScript(_ script: String, arguments: [String]) async throws -> String {
        try await run(osascript, ["-e", script] + arguments, name: "Music", failure: Self.error(from:))
    }

    /// Runs a command and returns its output, or throws `failure` of its
    /// errors when it fails.
    private func run(_ executable: String, _ arguments: [String], name: String,
                     failure: @escaping @Sendable (String) -> RadioError) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let timeout = self.timeout
        // Both pipes are read as the command writes them. When osascript's
        // were read only after it exited, a reply longer than a pipe holds,
        // such as every track's plays and skips, stalled it until the timeout.
        let replies = Mutex((output: Data(), errors: Data()))
        let reading = DispatchGroup()
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                reading.wait()
                let (stdout, stderr) = replies.withLock {
                    (String(decoding: $0.output, as: UTF8.self), String(decoding: $0.errors, as: UTF8.self))
                }
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: RadioError("\(name) didn't respond within \(Int(timeout)) seconds"))
                } else if process.terminationStatus != 0 {
                    continuation.resume(throwing: failure(stderr))
                } else {
                    continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            reading.enter()
            reading.enter()
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().async {
                let data = output.fileHandleForReading.readDataToEndOfFile()
                replies.withLock { $0.output = data }
                reading.leave()
            }
            DispatchQueue.global().async {
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                replies.withLock { $0.errors = data }
                reading.leave()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }

    private static func error(from stderr: String) -> RadioError {
        if stderr.contains("-1743") {
            return RadioError("Radio isn't allowed to control Music. Allow it in System Settings > Privacy & Security > Automation.")
        }
        return RadioError("Music couldn't update the playlist: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    /// Finds the playlist by persistent ID, then by name, and makes it when
    /// placing a song and there's none. Renaming sets the name of the
    /// playlist found and changes no entries. Entries and library tracks are
    /// found by title and artist. Placing deletes every entry for the song's
    /// library track (by its database ID) and adds the track back, which
    /// appends it; script positions follow the playlist's view sort, so they
    /// can't be used. A comment belongs to the library track, so it shows in
    /// every playlist, and changing it doesn't edit the playlist.
    static let script = """
        on run argv
            set {action, playlistID, playlistName, playlistDescription, songName, songArtist, songAlbum, songComment, commentMark} to argv
            tell application "Music"
                set found to {}
                if playlistID is not "" then set found to (every user playlist whose persistent ID is playlistID)
                if (count of found) is 0 then set found to (every user playlist whose name is playlistName and smart is false)
                if (count of found) > 1 then return "ambiguous-playlist"
                if (count of found) is 1 then
                    set target to item 1 of found
                else if action is not "place" then
                    return "no-playlist"
                else
                    set target to make new user playlist with properties {name:playlistName}
                    try
                        set description of target to playlistDescription
                    end try
                end if
                set targetID to persistent ID of target
                if action is "rename" then
                    set name of target to playlistName
                    try
                        set description of target to playlistDescription
                    end try
                    return "renamed " & targetID
                end if
                set entries to (every track of target whose name is songName and artist is songArtist)
                if action is "remove" then
                    if (count of entries) is 0 then return "no-track " & targetID
                    set songID to database ID of item 1 of entries
                    delete (every track of target whose database ID is songID)
                    return "removed " & targetID
                end if
                if (count of entries) > 0 then
                    set entryID to database ID of item 1 of entries
                    set libraryTracks to (every track of library playlist 1 whose database ID is entryID)
                else
                    set libraryTracks to (every track of library playlist 1 whose name is songName and artist is songArtist and album is songAlbum)
                    if (count of libraryTracks) is 0 then
                        set libraryTracks to (every track of library playlist 1 whose name is songName and artist is songArtist)
                    end if
                end if
                if (count of libraryTracks) is 0 then return "not-in-library " & targetID
                set libraryTrack to item 1 of libraryTracks
                if action is "comment" then
                    set existingComment to comment of libraryTrack
                    if existingComment is "" or existingComment starts with commentMark then
                        set comment of libraryTrack to songComment
                    end if
                    return "commented " & targetID
                end if
                set songID to database ID of libraryTrack
                delete (every track of target whose database ID is songID)
                try
                    duplicate libraryTrack to target
                on error
                    return "removed " & targetID
                end try
                return "placed " & targetID
            end tell
        end run
        """

    /// Asks for each property of every library track at once, about a
    /// second for 4,278 tracks on 2026-10-20, then joins them track by
    /// track.
    static let listensScript = """
        on run
            tell application "Music"
                set trackNames to name of every track of library playlist 1
                set trackArtists to artist of every track of library playlist 1
                set trackPlays to played count of every track of library playlist 1
                set trackSkips to skipped count of every track of library playlist 1
            end tell
            if (count of trackArtists) is not (count of trackNames) or (count of trackPlays) is not (count of trackNames) ¬
                or (count of trackSkips) is not (count of trackNames) then error "The library changed while Radio read it."
            set fieldMark to character id 31
            set trackLines to {}
            repeat with i from 1 to count of trackNames
                set end of trackLines to (item i of trackNames) & fieldMark & (item i of trackArtists) & fieldMark ¬
                    & ((item i of trackPlays) as text) & fieldMark & ((item i of trackSkips) as text)
            end repeat
            set AppleScript's text item delimiters to character id 30
            return trackLines as text
        end run
        """
}
