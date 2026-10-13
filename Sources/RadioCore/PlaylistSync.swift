import Foundation

/// Music.app's state during one sync. After a failure, the rest of the sync
/// skips Music.app and leaves its work for the next sync.
struct MusicAppSession {
    var failure: String?
    var succeeded = false
}

/// Keeps each station's playlist in order of most recent play: new songs are
/// added through the web API, and re-played songs are moved to the end
/// through Music.app, which is the only interface that can remove an entry.
extension Radio {
    /// How long a song added through the web API may take to appear in
    /// Music.app. After this, an entry Music.app can't find is treated as
    /// removed by hand and is added again through the API.
    static let musicAppSyncDelay: TimeInterval = 60 * 60

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
                guard var station = try store.station(id: entry.stationID),
                      let result = await perform(.remove, name: name, artist: artist, station: &station, music: &music)
                else {
                    removedEverywhere = false
                    continue
                }
                switch result {
                case .removed, .moved:
                    try store.removePlaylistTrack(stationID: station.id, catalogID: catalogID)
                case .trackNotFound where now().timeIntervalSince(entry.addedAt) > Self.musicAppSyncDelay:
                    try store.removePlaylistTrack(stationID: station.id, catalogID: catalogID)
                default:
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

    /// Adds new songs and moves re-played ones, interleaved in play order so
    /// the playlist ends with the most recent play.
    func syncPlaylist(for station: Station, client: AppleMusicClient,
                      music: inout MusicAppSession) async throws -> (added: Int, moved: Int) {
        var station = station
        let adds = try store.songsToAdd(stationID: station.id)
        let moves = musicApp == nil ? [] : try store.tracksToMove(stationID: station.id)
        var steps: [(latestPlay: String, add: TrackToAdd?, move: TrackToMove?)] =
            adds.map { ($0.latestPlay, $0, nil) } + moves.map { ($0.latestPlay, nil, $0) }
        steps.sort { ($0.latestPlay, $0.add == nil ? 1 : 0) < ($1.latestPlay, $1.add == nil ? 1 : 0) }

        var added = 0
        var moved = 0
        var batch: [TrackToAdd] = []
        for (index, step) in steps.enumerated() {
            if let move = step.move, try await self.move(move, in: &station, client: client, music: &music) {
                moved += 1
            }
            guard let track = step.add else { continue }
            batch.append(track)
            let nextIsAdd = index + 1 < steps.count && steps[index + 1].add != nil
            guard !nextIsAdd || batch.count == AppleMusicClient.batchSize else { continue }
            guard try await add(batch, to: &station, client: client) else { return (added, moved) }
            added += batch.count
            batch = []
        }
        return (added, moved)
    }

    /// Returns false when the playlist was deleted in Music; it's recreated
    /// with every song on the next sync.
    private func add(_ tracks: [TrackToAdd], to station: inout Station, client: AppleMusicClient) async throws -> Bool {
        if let playlistID = station.playlistID {
            do {
                try await client.addSongs(tracks.map(\.catalogID), toPlaylist: playlistID)
            } catch let error as HTTPStatusError where error.status == 404 {
                try store.setPlaylist(stationID: station.id, playlistID: nil)
                try store.setMusicPlaylist(stationID: station.id, musicPlaylistID: nil)
                return false
            }
        } else {
            let created = try await client.createPlaylist(
                name: station.name,
                description: "Every song \(station.name) has played, most recent last. Collected by Radio.",
                songIDs: tracks.map(\.catalogID)
            )
            try store.setPlaylist(stationID: station.id, playlistID: created)
            station.playlistID = created
        }
        try store.recordAdded(stationID: station.id, tracks: tracks, at: now())
        return true
    }

    /// Returns true when the entry now sits at the end of the playlist.
    private func move(_ track: TrackToMove, in station: inout Station, client: AppleMusicClient,
                      music: inout MusicAppSession) async throws -> Bool {
        guard let name = track.catalogName, let artist = track.catalogArtist, let playlistID = station.playlistID,
              let result = await perform(.move, name: name, artist: artist, station: &station, music: &music)
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
            try store.setPosition(stationID: station.id, catalogID: track.catalogID, playedAt: track.latestPlay)
            return false
        case .playlistNotFound, .ambiguousPlaylist:
            return false
        }
        try store.setPosition(stationID: station.id, catalogID: track.catalogID, playedAt: track.latestPlay)
        return true
    }

    /// Runs one Music.app action for a station's playlist, remembering the
    /// playlist's Music.app ID. Returns nil when Music.app failed, now or
    /// earlier in this sync.
    private func perform(_ action: MusicAppAction, name: String, artist: String, station: inout Station,
                         music: inout MusicAppSession) async -> MusicAppResult? {
        guard let musicApp, music.failure == nil else { return nil }
        let result: MusicAppResult
        do {
            result = try await musicApp.perform(action, playlistID: station.musicPlaylistID, playlistName: station.name,
                                                 songName: name, songArtist: artist)
        } catch {
            music.failure = String(describing: error)
            return nil
        }
        switch result {
        case .moved(let id), .removed(let id), .trackNotFound(let id), .notInLibrary(let id):
            music.succeeded = true
            if station.musicPlaylistID != id {
                try? store.setMusicPlaylist(stationID: station.id, musicPlaylistID: id)
                station.musicPlaylistID = id
            }
        case .playlistNotFound:
            // A remembered ID may be stale; find it by name next time. A new
            // playlist may simply not have reached this Mac yet.
            if station.musicPlaylistID != nil {
                try? store.setMusicPlaylist(stationID: station.id, musicPlaylistID: nil)
                station.musicPlaylistID = nil
            }
        case .ambiguousPlaylist:
            music.failure = "Music has more than one playlist named \"\(station.name)\". "
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
