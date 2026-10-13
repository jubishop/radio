import Foundation

/// Music.app's state during one sync. After a failure, the rest of the sync
/// skips Music.app and leaves its work for the next sync.
struct MusicAppSession {
    var failure: String?
    var succeeded = false
}

/// Keeps Radio's playlists to the most recently played songs, in order of
/// each song's latest play on any station: a few in "Radio" and many more in
/// "Radio Archive". New songs are added through the web API. Re-played songs
/// are moved to the end, and songs that fall past a playlist's limit are
/// dropped, through Music.app, the only interface that can remove an entry.
extension Radio {
    public static let playlistName = "Radio"
    public static let archivePlaylistName = "Radio Archive"

    /// How long a song added through the web API may take to appear in
    /// Music.app. After this, an entry Music.app can't find is treated as
    /// removed by hand and is added again through the API.
    static let musicAppSyncDelay: TimeInterval = 60 * 60

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
            var removedEverywhere = true
            for entry in try store.entries(catalogID: catalogID) {
                var playlist = try store.playlist(entry.kind)
                if try await !removeEntry(catalogID: catalogID, name: name, artist: artist, addedAt: entry.addedAt,
                                          playlist: &playlist, music: &music) {
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

    /// Syncs "Radio" before the archive, so trouble in the much larger
    /// archive can't hold it up. Returns the changes by playlist name.
    func syncPlaylists(client: AppleMusicClient, music: inout MusicAppSession) async throws -> [String: PlaylistChanges] {
        var changes: [String: PlaylistChanges] = [:]
        for kind in Playlist.Kind.allCases {
            changes[name(of: kind)] = try await syncPlaylist(kind, client: client, music: &music)
        }
        return changes
    }

    /// Drops songs that more recent ones have pushed out, then adds new songs
    /// and moves re-played ones, interleaved in play order so the playlist
    /// ends with the most recent play. When Music.app can't drop songs, new
    /// ones are still added, and the playlist exceeds its limit until it can.
    private func syncPlaylist(_ kind: Playlist.Kind, client: AppleMusicClient,
                              music: inout MusicAppSession) async throws -> PlaylistChanges {
        var playlist = try store.playlist(kind)
        var changes = PlaylistChanges()
        if musicApp != nil {
            for track in try store.tracksToDrop(from: kind, limit: limit(of: kind)) {
                guard let name = track.catalogName, let artist = track.catalogArtist else { continue }
                if try await removeEntry(catalogID: track.catalogID, name: name, artist: artist, addedAt: track.addedAt,
                                         playlist: &playlist, music: &music) {
                    changes.dropped += 1
                }
            }
        }
        let adds = try store.songsToAdd(to: kind, limit: limit(of: kind))
        let moves = musicApp == nil ? [] : try store.tracksToMove(in: kind)
        var steps: [(latestPlay: String, add: TrackToAdd?, move: TrackToMove?)] =
            adds.map { ($0.latestPlay, $0, nil) } + moves.map { ($0.latestPlay, nil, $0) }
        steps.sort { ($0.latestPlay, $0.add == nil ? 1 : 0) < ($1.latestPlay, $1.add == nil ? 1 : 0) }

        var batch: [TrackToAdd] = []
        for (index, step) in steps.enumerated() {
            if let move = step.move, try await self.move(move, in: &playlist, client: client, music: &music) {
                changes.moved += 1
            }
            guard let track = step.add else { continue }
            batch.append(track)
            let nextIsAdd = index + 1 < steps.count && steps[index + 1].add != nil
            guard !nextIsAdd || batch.count == AppleMusicClient.batchSize else { continue }
            guard try await add(batch, to: &playlist, client: client) else { return changes }
            changes.added += batch.count
            batch = []
        }
        return changes
    }

    /// Returns false when the playlist was deleted in Music; it's recreated
    /// with its songs on the next sync.
    private func add(_ tracks: [TrackToAdd], to playlist: inout Playlist, client: AppleMusicClient) async throws -> Bool {
        if let playlistID = playlist.id {
            do {
                try await client.addSongs(tracks.map(\.catalogID), toPlaylist: playlistID)
            } catch let error as HTTPStatusError where error.status == 404 {
                try store.setPlaylistID(nil, for: playlist.kind)
                return false
            }
        } else {
            let limit = limit(of: playlist.kind).formatted()
            let created = try await client.createPlaylist(
                name: name(of: playlist.kind),
                description: "The \(limit) songs played most recently on the stations Radio follows, most recent last.",
                songIDs: tracks.map(\.catalogID)
            )
            try store.setPlaylistID(created, for: playlist.kind)
            playlist.id = created
        }
        try store.recordAdded(tracks, to: playlist.kind, at: now())
        return true
    }

    /// Returns true when the entry now sits at the end of the playlist.
    private func move(_ track: TrackToMove, in playlist: inout Playlist, client: AppleMusicClient,
                      music: inout MusicAppSession) async throws -> Bool {
        guard let name = track.catalogName, let artist = track.catalogArtist, let playlistID = playlist.id,
              let result = await perform(.move, name: name, artist: artist, playlist: &playlist, music: &music)
        else { return false }
        switch result {
        case .moved:
            break
        case .removed:
            // Music.app removed the entry but couldn't add it back.
            try await client.addSongs([track.catalogID], toPlaylist: playlistID)
        case .trackNotFound:
            // Either the add hasn't reached this Mac yet, or the entry was
            // removed by hand; after the sync delay, add the song again.
            guard now().timeIntervalSince(track.addedAt) > Self.musicAppSyncDelay else { return false }
            try await client.addSongs([track.catalogID], toPlaylist: playlistID)
        case .notInLibrary:
            // Nothing was changed and retrying won't help; leave it in place.
            try store.setPosition(in: playlist.kind, catalogID: track.catalogID, playedAt: track.latestPlay)
            return false
        case .playlistNotFound, .ambiguousPlaylist:
            return false
        }
        try store.setPosition(in: playlist.kind, catalogID: track.catalogID, playedAt: track.latestPlay)
        return true
    }

    /// Removes a song's entry through Music.app. Returns true once the entry
    /// is gone, which includes an entry Music.app hasn't seen for longer than
    /// the sync delay, since it was removed by hand.
    private func removeEntry(catalogID: String, name: String, artist: String, addedAt: Date,
                             playlist: inout Playlist, music: inout MusicAppSession) async throws -> Bool {
        guard let result = await perform(.remove, name: name, artist: artist, playlist: &playlist, music: &music)
        else { return false }
        switch result {
        case .removed, .moved:
            break
        case .trackNotFound where now().timeIntervalSince(addedAt) > Self.musicAppSyncDelay:
            break
        default:
            return false
        }
        try store.removePlaylistTrack(from: playlist.kind, catalogID: catalogID)
        return true
    }

    /// Runs one Music.app action on a playlist, remembering the playlist's
    /// Music.app ID. Returns nil when Music.app failed, now or earlier in
    /// this sync.
    private func perform(_ action: MusicAppAction, name: String, artist: String, playlist: inout Playlist,
                         music: inout MusicAppSession) async -> MusicAppResult? {
        guard let musicApp, music.failure == nil else { return nil }
        let playlistName = self.name(of: playlist.kind)
        let result: MusicAppResult
        do {
            result = try await musicApp.perform(action, playlistID: playlist.musicID, playlistName: playlistName,
                                                 songName: name, songArtist: artist)
        } catch {
            music.failure = String(describing: error)
            return nil
        }
        switch result {
        case .moved(let id), .removed(let id), .trackNotFound(let id), .notInLibrary(let id):
            music.succeeded = true
            if playlist.musicID != id {
                try? store.setMusicPlaylistID(id, for: playlist.kind)
                playlist.musicID = id
            }
        case .playlistNotFound:
            // A remembered ID may be stale; find it by name next time. A new
            // playlist may simply not have reached this Mac yet.
            if playlist.musicID != nil {
                try? store.setMusicPlaylistID(nil, for: playlist.kind)
                playlist.musicID = nil
            }
        case .ambiguousPlaylist:
            music.failure = "Music has more than one playlist named \"\(playlistName)\". "
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
