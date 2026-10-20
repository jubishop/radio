import Foundation

/// Music.app's state during one sync. After a failure, the rest of the sync
/// skips Music.app and leaves its work for the next sync.
struct MusicAppSession {
    var failure: String?
    var succeeded = false
}

/// Keeps Radio's playlists to the most recently played songs, in order of
/// each song's latest play on any station: a few in "Radio" and many more in
/// "Radio Archive". Music.app makes every change to the playlists: it adds
/// and moves songs by placing them at the end, and drops songs that fall past
/// a playlist's limit. The web API only adds songs to the library, so
/// Music.app can find them.
extension Radio {
    public static let playlistName = "Radio"
    public static let archivePlaylistName = "Radio Archive"

    /// How long a song added to the library through the web API may take to
    /// reach Music.app. Until then, songs played after it wait, so the
    /// playlist stays in play order; after it, they go ahead without it.
    static let librarySyncDelay: TimeInterval = 60 * 60

    func name(of kind: Playlist.Kind) -> String {
        switch kind {
        case .recent: Self.playlistName
        case .archive: Self.archivePlaylistName
        }
    }

    /// How many of the most recently played songs a playlist keeps.
    func limit(of kind: Playlist.Kind) -> Int {
        switch kind {
        case .recent: playlistLimit
        case .archive: archiveLimit
        }
    }

    /// Records catalog titles for matches saved before Radio stored them,
    /// since Music.app finds entries by title and artist.
    func fillCatalogDetails(client: AppleMusicClient) async throws {
        let missing = try store.catalogIDsMissingDetails()
        guard !missing.isEmpty else { return }
        for song in try await client.songs(ids: missing) {
            try store.setCatalogDetails(song)
        }
    }

    /// Removes automatic matches that today's matching rules reject, such as
    /// DJ mixes matched before those were recognized, so they're matched
    /// again. A match stays until every playlist holding it has dropped it.
    func replaceRejectedMatches(music: inout MusicAppSession) async throws -> Int {
        guard musicApp != nil else { return 0 }
        var replaced = 0
        for song in try store.songs(status: .matched) where song.matchedBy == "auto" {
            guard let catalogID = song.catalogID, let name = song.catalogName, let artist = song.catalogArtist else { continue }
            let catalog = CatalogSong(id: catalogID, name: name, artistName: artist, albumName: song.catalogAlbum ?? "",
                                      url: song.catalogURL ?? "", isExplicit: false)
            guard chooseMatch(artist: song.artist, title: song.title, candidates: [catalog]) == nil else { continue }
            let entry = MusicAppSong(name: name, artist: artist, album: song.catalogAlbum ?? "")
            var removedEverywhere = true
            for kind in try store.playlistsHolding(catalogID: catalogID) {
                var playlist = try store.playlist(kind)
                if try await !removeEntry(catalogID: catalogID, song: entry, playlist: &playlist, music: &music) {
                    removedEverywhere = false
                }
            }
            if removedEverywhere {
                try store.resetAutoMatches(catalogID: catalogID)
                replaced += 1
            }
        }
        return replaced
    }

    /// Removes the tracks of songs the user sent back to review, unless a
    /// song matched since still uses one. Returns how many tracks left.
    func removeTracksSentBack(music: inout MusicAppSession) async throws -> Int {
        guard musicApp != nil else { return 0 }
        var removed = 0
        for removal in try store.playlistRemovals() {
            guard try !store.isMatched(catalogID: removal.catalogID) else {
                try store.deleteRemoval(catalogID: removal.catalogID)
                continue
            }
            let holding = try store.playlistsHolding(catalogID: removal.catalogID)
            var removedEverywhere = true
            for kind in holding {
                var playlist = try store.playlist(kind)
                if try await !removeEntry(catalogID: removal.catalogID, song: removal.song, playlist: &playlist, music: &music) {
                    removedEverywhere = false
                }
            }
            if removedEverywhere {
                try store.deleteRemoval(catalogID: removal.catalogID)
                if !holding.isEmpty { removed += 1 }
            }
        }
        return removed
    }

    /// Syncs "Radio" before the archive, so trouble in the much larger
    /// archive can't hold it up. Without Music.app, nothing changes. Returns
    /// the changes by playlist name.
    func syncPlaylists(client: AppleMusicClient, music: inout MusicAppSession) async throws -> [String: PlaylistChanges] {
        guard musicApp != nil else { return [:] }
        var changes: [String: PlaylistChanges] = [:]
        for kind in Playlist.Kind.allCases {
            changes[name(of: kind)] = try await syncPlaylist(kind, client: client, music: &music)
        }
        return changes
    }

    /// Drops songs that more recent ones have pushed out, then places new
    /// and re-played songs at the end in play order, so the playlist ends
    /// with the most recent play. A song whose library track hasn't reached
    /// Music.app holds back the songs played after it, for up to the sync
    /// delay.
    private func syncPlaylist(_ kind: Playlist.Kind, client: AppleMusicClient,
                              music: inout MusicAppSession) async throws -> PlaylistChanges {
        var playlist = try store.playlist(kind)
        var changes = PlaylistChanges()
        for track in try store.tracksToDrop(from: kind, limit: limit(of: kind)) {
            guard let song = track.song else { continue }
            guard try await removeEntry(catalogID: track.catalogID, song: song, playlist: &playlist, music: &music) else { break }
            // Without an ID, the playlist is gone, and its entries with it.
            guard playlist.musicID != nil else { break }
            changes.dropped += 1
        }

        let tracks = try store.tracksToPlace(in: kind, limit: limit(of: kind))
        try await requestLibraryAdds(tracks, client: client)
        for (index, track) in tracks.enumerated() {
            guard let song = track.song else { continue }
            guard let result = try await perform(.place, song: song, playlist: &playlist, music: &music) else { break }
            switch result {
            case .placed:
                try store.recordPlaced(track, in: kind, at: now())
                if track.inPlaylist { changes.moved += 1 } else { changes.added += 1 }
            case .removed:
                // Music.app removed the entry but couldn't add it back; the
                // next sync adds the song again.
                try store.removePlaylistTrack(from: kind, catalogID: track.catalogID)
            case .notInLibrary:
                let requestedAt = track.libraryRequestedAt ?? now()
                if now().timeIntervalSince(requestedAt) < Self.librarySyncDelay {
                    changes.waiting += tracks.count - index
                    return changes
                }
                changes.waiting += 1
                // An entry whose track will apparently never reach the
                // library stays where it is.
                if track.inPlaylist { try store.setPosition(in: kind, catalogID: track.catalogID, playedAt: track.latestPlay) }
            case .trackNotFound, .commented, .playlistNotFound, .ambiguousPlaylist:
                return changes
            }
        }
        return changes
    }

    /// Starts every comment Radio writes, so it replaces only its own.
    static let commentMark = "📻"

    /// Such as "📻 2026-10-13 15:14 · Alt 102.1 ×3, 107.7 The End": the
    /// song's latest play in the Mac's time zone, which sorts the Comments
    /// column in time order, then the stations that played it, most recently
    /// first, each with how often it did when more than once.
    static func comment(for entry: PlaylistEntry) -> String? {
        guard let latest = entry.latestPlay else { return nil }
        let time = latest.formatted(Date.VerbatimFormatStyle(
            format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits)",
            timeZone: .current, calendar: Calendar(identifier: .gregorian)
        ))
        return "\(commentMark) \(time) · " + entry.stations.map { $0.plays > 1 ? "\($0.name) ×\($0.plays)" : $0.name }
            .joined(separator: ", ")
    }

    /// Gives each song in the playlists a Music.app comment with its latest
    /// play and each station's plays, when its plays have changed it, since Music.app's
    /// playlists can't show Radio's details any other way. Returns how many
    /// songs Music.app was asked to comment.
    func syncComments(music: inout MusicAppSession) async throws -> Int {
        guard musicApp != nil else { return 0 }
        var commented = 0
        var seen = Set<String>()
        for kind in Playlist.Kind.allCases {
            var playlist = try store.playlist(kind)
            entries: for entry in try store.playlistEntries(kind) where seen.insert(entry.catalogID).inserted {
                guard let song = entry.song, let text = Self.comment(for: entry), text != entry.comment else { continue }
                let action = MusicAppAction.comment(text, mark: Self.commentMark)
                guard let result = try await perform(action, song: song, playlist: &playlist, music: &music) else { break }
                switch result {
                case .commented:
                    try store.recordComment(text, catalogID: entry.catalogID)
                    commented += 1
                case .notInLibrary, .trackNotFound, .placed, .removed:
                    continue
                case .playlistNotFound, .ambiguousPlaylist:
                    break entries
                }
            }
        }
        return commented
    }

    /// Asks Apple to add songs to the library, where Music.app can find
    /// them, unless that was asked within the sync delay. Adding a song
    /// that's already there changes nothing.
    private func requestLibraryAdds(_ tracks: [TrackToPlace], client: AppleMusicClient) async throws {
        var seen = Set<String>()
        let ids = tracks.filter { track in
            track.libraryRequestedAt.map { now().timeIntervalSince($0) >= Self.librarySyncDelay } ?? true
        }.map(\.catalogID).filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { return }
        try await client.addToLibrary(songIDs: ids)
        try store.recordLibraryRequests(ids, at: now())
    }

    /// Removes a song's entry through Music.app. Returns true once the entry
    /// is gone, including one removed by hand, and false when Music.app
    /// failed or the entry can't be removed.
    private func removeEntry(catalogID: String, song: MusicAppSong, playlist: inout Playlist,
                             music: inout MusicAppSession) async throws -> Bool {
        guard let result = try await perform(.remove, song: song, playlist: &playlist, music: &music) else { return false }
        switch result {
        case .removed, .placed, .trackNotFound, .playlistNotFound:
            try store.removePlaylistTrack(from: playlist.kind, catalogID: catalogID)
            return true
        case .notInLibrary, .commented, .ambiguousPlaylist:
            return false
        }
    }

    /// Runs one Music.app action on a playlist, remembering the playlist's
    /// Music.app ID. Returns nil when Music.app failed, now or earlier in
    /// this sync, or when Radio's playlist turned out to be gone, which
    /// leaves the playlist for the next sync to fill in order.
    private func perform(_ action: MusicAppAction, song: MusicAppSong, playlist: inout Playlist,
                         music: inout MusicAppSession) async throws -> MusicAppResult? {
        guard let musicApp, music.failure == nil else { return nil }
        let limit = limit(of: playlist.kind).formatted()
        let target = MusicAppPlaylist(
            id: playlist.musicID, name: name(of: playlist.kind),
            description: "The \(limit) songs played most recently on the stations Radio follows, most recent last."
        )
        let result: MusicAppResult
        do {
            result = try await musicApp.perform(action, playlist: target, song: song)
        } catch {
            music.failure = String(describing: error)
            return nil
        }
        switch result {
        case .placed(let id), .removed(let id), .commented(let id), .trackNotFound(let id), .notInLibrary(let id):
            music.succeeded = true
            guard playlist.musicID != id else { break }
            let replaced = playlist.musicID != nil
            // Music.app found another playlist by that name, or made one,
            // so the playlist Radio knew is gone, with its entries.
            if replaced { try store.forgetEntries(of: playlist.kind) }
            try store.setMusicPlaylistID(id, for: playlist.kind)
            playlist.musicID = id
            if replaced { return nil }
        case .playlistNotFound:
            // Deleted in Music; placing the next song makes a new one.
            music.succeeded = true
            try store.forgetEntries(of: playlist.kind)
            try store.setMusicPlaylistID(nil, for: playlist.kind)
            playlist.musicID = nil
        case .ambiguousPlaylist:
            music.failure = "Music has more than one playlist named \"\(target.name)\". "
                + "Rename the others so Radio can tell which one is its playlist."
        }
        return result
    }

    /// Shows a Music.app failure on the dashboard until Music.app works again.
    func finish(_ music: MusicAppSession) throws {
        if let failure = music.failure {
            try store.setMeta("music.last_error", failure)
        } else if music.succeeded {
            try store.setMeta("music.last_error", nil)
        }
    }
}
