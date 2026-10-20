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
- **Radio Archive** holds the 10,000 songs played most recently, and drops
  the oldest the same way.

Both playlists end with the most recently played song. Sort one by
**Playlist Order, descending** to see it newest first.

Music.app makes every change to the playlists, so Music.app on the Mac mini
must stay signed in with **Sync Library** on. Radio asks Apple to add a new
song to your library, and Music.app puts it in the playlists once it reaches
the Mac, usually on the next run, about 15 minutes later.
Approve "radio wants access to control Music" the first time Radio uses it.
The prompt stays up for only two minutes, during a scheduled run that has a
song to place or drop. To bring it up while you're at the Mac mini, run
`launchctl kickstart gui/$(id -u)/com.jubishop.radio.run`. Once you've
answered, change the choice in System Settings > Privacy & Security >
Automation. `bin/deploy` signs the binary with your Apple Development
identity, so the approval lasts across updates. Until Music.app works, the
dashboard shows why and the playlists don't change.

When the sign-in expires, Radio sends one Pushover alert and the dashboard
shows "sign-in expired". Repeat step 4.

## Daily use

- **Dashboard:** <http://jubi.local:8102> from any device on the home network.
  It shows recent plays, songs just added, feed and sync health, and the
  review queue. It refreshes every minute. Radio serves plain HTTP, so an
  `https://` address fails at once; use `http://`. Away from home, a device
  on the Mac's tailnet can open it at the Mac's full Tailscale name, such as
  `http://mac-mini.tail1234.ts.net:8102`, or its Tailscale IP address.
- **Review:** <http://jubi.local:8102/review> lists songs needing review
  first, with Jev's suggestion when it has one, then every song Jev or you
  matched or you ignored, newest first, each with an undo. In Terminal, use
  `radio unmatched`, then `radio match 12a`, `radio match 12 <apple-music-link>`,
  or `radio ignore 12`; `radio reviewed` lists decisions and `radio undo 12`
  sends one back. Once a day, while any song is waiting, Radio sends a
  Pushover message and an email that lists those songs, and both link to the
  review page.
- **Playlists:** <http://jubi.local:8102/playlists/radio> and
  <http://jubi.local:8102/playlists/archive> list each playlist's songs with
  the stations that played them. In Music, each song's comment gives its
  latest play and how often each station played it, such as
  `📻 2026-10-20 13:38 · Hits 106.1 ×12, MOViN 92.5 ×3`.
  Playlists can't show comments as a column, but the Songs view can: show its
  Comments column with View > Show View Options, and sort by it to list
  Radio's songs in play order.
- **Status and data:** `radio status`, and `radio export > plays.csv` for
  every logged play.
- **More stations:** add each with its network's command. Its songs join
  the "Radio" and "Radio Archive" playlists.
  - Audacy: `radio station add <slug>`, where the slug is the path in the
    station's audacy.com URL, such as `alt1021rva`.
  - iHeartRadio: `radio station add <site> --source iheart`, where the site is
    the name before `.iheart.com` in the station's own site, such as
    `hits1061seattle`.
  - Hubbard Radio: `radio station add <domain> --source hubbard`, where the
    domain is the station's own site, such as `movin925.com`.

## Upgrade from per-station playlists

Earlier releases gave each station its own playlist, such as "Alt 102.1". The
first sync after upgrading creates "Radio" with the 100 most recently played
matched songs, in order of latest play. The old playlists stop changing;
delete them in Music when you no longer want them. A later upgrade adds
"Radio Archive" the same way. If the library
already has another playlist named "Radio" or "Radio Archive", rename that
one, or the dashboard reports that Music.app can't tell which playlist is
Radio's.

## Jev

Radio reads `JEV_API_KEY` from `~/.env` and asks TypeSafe's Jev about songs
held back for review; without the key, it doesn't. Keys come from the
TypeSafe developer console. When Jev fails, the dashboard and `radio status`
show the error, and held songs wait for the next sync.

## Alerts

Radio reads `PUSHOVER_USER_KEY` and `PUSHOVER_API_KEY` for Pushover, and
`RESEND_API_KEY` and `EMAIL_TO` for email, from `~/.env`. It sends Pushover
alerts:

- one when a station's feed has failed for two hours, because the feed keeps
  only about four hours of plays;
- one when Apple Music has rejected the sign-in for an hour. Apple's 401 and
  403 responses both count as a rejection. Brief 401s happen, especially in
  the first minutes after a new MusicKit key is created.

Once a day, if any song is waiting for review, Radio also sends a review
reminder, at about the time of day Radio first ran: a Pushover message with
the count, and an email from `radio@jubishop.com` that lists each song with
its plays, stations, and Jev's suggestion. Both link to the review page. If
Resend refuses the email, that run fails in the run log, and the next run
retries the email without repeating the push. Without one service's keys, the
other still goes out.

Alerts and reminders link to `RADIO_DASHBOARD_URL`, which `bin/deploy` reads
from `.env` in the checkout it runs from. Git ignores that file, so the
address stays out of this public repository. Set it to the Mac's full
Tailscale name, such as
`RADIO_DASHBOARD_URL=http://mac-mini.tail1234.ts.net:8102`, so the links open
on any device on the tailnet, then run `bin/deploy`. Without it, they link to
`http://jubi.local:8102`, which opens only on the home network. The sign-in
alert still links to `http://localhost:8102/auth`, since sign-in works only on
the Mac itself.

## Stop or remove

```sh
launchctl bootout gui/$(id -u)/com.jubishop.radio.run
launchctl bootout gui/$(id -u)/com.jubishop.radio.serve
rm ~/Library/LaunchAgents/com.jubishop.radio.*.plist ~/.local/bin/radio
```

Removing the agents keeps the data directory. The playlists stay in Apple
Music.
