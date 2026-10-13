import Foundation

public enum MusicAppAction: String, Sendable {
    /// Moves the song's entry to the end of the playlist.
    case move
    /// Removes the song's entries from the playlist, keeping it in the library.
    case remove
}

/// What Music.app did. Playlist IDs are Music.app's persistent IDs, which
/// differ from the web API's library playlist IDs.
public enum MusicAppResult: Equatable, Sendable {
    case moved(playlistID: String)
    /// Also returned when a move removed the entry but couldn't add it back.
    case removed(playlistID: String)
    /// The playlist has no entry with that title and artist, perhaps because
    /// a song added through the web API hasn't synced to this Mac yet.
    case trackNotFound(playlistID: String)
    /// The entry exists but its song isn't in the library, so it can't be
    /// re-added. Nothing was changed.
    case notInLibrary(playlistID: String)
    case playlistNotFound
    case ambiguousPlaylist
}

/// Edits playlists through Music.app, which can remove entries; the web API
/// can only add them. See docs/design.md.
public protocol MusicApp: Sendable {
    func perform(_ action: MusicAppAction, playlistID: String?, playlistName: String,
                 songName: String, songArtist: String) async throws -> MusicAppResult
}

/// Runs AppleScript in Music.app through `osascript`. Values travel as
/// arguments, never as script source.
public struct ScriptedMusicApp: MusicApp {
    let timeout: TimeInterval

    public init(timeout: TimeInterval = 120) {
        self.timeout = timeout
    }

    public func perform(_ action: MusicAppAction, playlistID: String?, playlistName: String,
                        songName: String, songArtist: String) async throws -> MusicAppResult {
        let output = try await runOSAScript(arguments: [action.rawValue, playlistID ?? "", playlistName, songName, songArtist])
        let parts = output.split(separator: " ", maxSplits: 1).map(String.init)
        let id = parts.count > 1 ? parts[1] : ""
        switch parts.first {
        case "moved": return .moved(playlistID: id)
        case "removed": return .removed(playlistID: id)
        case "no-track": return .trackNotFound(playlistID: id)
        case "not-in-library": return .notInLibrary(playlistID: id)
        case "no-playlist": return .playlistNotFound
        case "ambiguous-playlist": return .ambiguousPlaylist
        default: throw RadioError("Unexpected reply from Music: \(output)")
        }
    }

    private func runOSAScript(arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", Self.script] + arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        let timeout = self.timeout
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { process in
                let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationReason == .uncaughtSignal {
                    continuation.resume(throwing: RadioError("Music didn't respond within \(Int(timeout)) seconds"))
                } else if process.terminationStatus != 0 {
                    continuation.resume(throwing: Self.error(from: stderr))
                } else {
                    continuation.resume(returning: stdout.trimmingCharacters(in: .whitespacesAndNewlines))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
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

    /// Finds the playlist by persistent ID, or by name before Radio knows its
    /// ID. Entries are found by title and artist, since Music.app scripting
    /// has no catalog IDs. A move deletes every entry for the song (by its
    /// library database ID) and adds the library track back, which appends it;
    /// script positions follow the playlist's view sort, so they can't be used.
    static let script = """
        on run argv
            set {action, playlistID, playlistName, songName, songArtist} to argv
            tell application "Music"
                if playlistID is not "" then
                    set found to (every user playlist whose persistent ID is playlistID)
                else
                    set found to (every user playlist whose name is playlistName and smart is false)
                end if
                if (count of found) is 0 then return "no-playlist"
                if (count of found) > 1 then return "ambiguous-playlist"
                set target to item 1 of found
                set targetID to persistent ID of target
                set entries to (every track of target whose name is songName and artist is songArtist)
                if (count of entries) is 0 then return "no-track " & targetID
                set songID to database ID of item 1 of entries
                if action is "move" then
                    set libraryTracks to (every track of library playlist 1 whose database ID is songID)
                    if (count of libraryTracks) is 0 then return "not-in-library " & targetID
                    set libraryTrack to item 1 of libraryTracks
                end if
                delete (every track of target whose database ID is songID)
                if action is "remove" then return "removed " & targetID
                try
                    duplicate libraryTrack to target
                on error
                    return "removed " & targetID
                end try
                return "moved " & targetID
            end tell
        end run
        """
}
