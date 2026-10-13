---
status: current
---

# Operations

This page covers how to install Radio on the Mac mini, connect it to Apple
Music, follow stations, and review songs. The reasons behind each choice are
in [Radio design](design.md).

## Install or update

```sh
bin/deploy
radio station add alt1021rva   # first install only
```

`bin/deploy` builds Radio, installs `~/.local/bin/radio`, and loads two
LaunchAgents:

| Agent | Runs | Log |
| --- | --- | --- |
| `com.jubishop.radio.run` | `radio run` every 15 minutes: poll, sync, alerts | `~/Library/Logs/Radio/com.jubishop.radio.run.log` |
| `com.jubishop.radio.serve` | `radio serve`, kept running: the dashboard on port 8102 | `~/Library/Logs/Radio/com.jubishop.radio.serve.log` |

Data lives in `~/Library/Application Support/Radio`: `radio.sqlite`,
`credentials.json`, and the MusicKit key. Every file there is owner-only.

## Connect Apple Music

This is needed once, and again when Apple expires the sign-in, roughly every
six months.

1. In the Apple Developer account for team `34TKMKM889`, go to Certificates,
   Identifiers & Profiles. Under Identifiers, register a **Media ID**, such as
   `media.com.artisanalsoftware.radio`.
2. Under Keys, create a key with **Media Services (MusicKit)** enabled and
   configured for that Media ID. Download `AuthKey_<KEYID>.p8`, which Apple
   offers only once, and note the Key ID.
3. Save the key:
   `radio credentials set --key-id <KEYID> --team-id 34TKMKM889 --key-file ~/Downloads/AuthKey_<KEYID>.p8`.
   Radio copies the key into its data directory, so the download can be
   deleted afterward.
4. On the Mac mini, open <http://localhost:8102/auth> and sign in with the
   Apple ID that owns the library. Sign-in works only from the Mac mini.

The next scheduled run matches songs and creates two playlists, which every
station feeds. Run `radio sync` to do it immediately.

- **Radio** holds the 100 songs played most recently on any station, so
  shuffling it plays what the stations played lately. When a new song joins,
  the least recently played one leaves the playlist but stays in your
  library.
- **Radio Archive** holds every song the stations have played.

Both playlists end with the most recently played song. Sort one by
**Playlist Order, descending** to see it newest first.

Radio moves re-played songs to the end and drops old ones through Music.app,
so Music.app on the Mac mini must stay signed in with **Sync Library** on.
Approve "radio wants access to control Music" the first time Radio uses it.
The prompt stays up for only two minutes, during a scheduled run that has a
song to move or drop. To bring it up while you're at the Mac mini, run
`launchctl kickstart gui/$(id -u)/com.jubishop.radio.run`. Once you've
answered, change the choice in System Settings > Privacy & Security >
Automation. `bin/deploy` signs the binary with your Apple Development
identity, so the approval lasts across updates. Until Music.app works, the
dashboard shows why, new songs keep being added, and moves and drops wait,
so "Radio" can pass 100 songs.

When the sign-in expires, Radio sends one Pushover alert and the dashboard
shows "sign-in expired". Repeat step 4.

## Daily use

- **Dashboard:** <http://jubi.local:8102> from any device on the home network.
  It shows recent plays, songs just added, feed and sync health, and the
  review queue. It refreshes every minute.
- **Review:** <http://jubi.local:8102/review>, or in Terminal use
  `radio unmatched`, then `radio match 12a`, `radio match 12 <apple-music-link>`,
  or `radio ignore 12`. A weekly Pushover nudge links to the review page when
  new songs are waiting.
- **Status and data:** `radio status`, and `radio export > plays.csv` for
  every logged play.
- **More stations:** `radio station add <audacy-slug>`, where the slug is the
  path in the station's audacy.com URL. Its songs join the "Radio" playlist.

## Upgrade from per-station playlists

Earlier releases gave each station its own playlist, such as "Alt 102.1". The
first sync after upgrading creates "Radio" with the 100 most recently played
matched songs, in order of latest play. The old playlists stop changing;
delete them in Music when you no longer want them. A later upgrade adds
"Radio Archive" the same way, with every matched song. If the library
already has another playlist named "Radio" or "Radio Archive", rename that
one, or the dashboard reports that Music.app can't tell which playlist is
Radio's.

## Alerts

Radio reads `PUSHOVER_USER_KEY` and `PUSHOVER_API_KEY` from `~/.env`. It sends:

- one alert when a station's feed has failed for two hours, because the feed
  keeps only about four hours of plays;
- one alert when Apple Music has rejected the sign-in for an hour. Brief 401s
  happen, especially in the first minutes after a new MusicKit key is created;
- a weekly nudge when songs were held back for review that week.

## Stop or remove

```sh
launchctl bootout gui/$(id -u)/com.jubishop.radio.run
launchctl bootout gui/$(id -u)/com.jubishop.radio.serve
rm ~/Library/LaunchAgents/com.jubishop.radio.*.plist ~/.local/bin/radio
```

Removing the agents keeps the data directory. The playlists stay in Apple
Music.
