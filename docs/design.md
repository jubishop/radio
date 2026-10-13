---
status: current
---

# Radio design

Radio logs each song its stations play, starting with Alt 102.1 (WRXL,
Richmond), and keeps the 100 most recently played in one Apple Music playlist
named "Radio". This page records the accepted decisions, the
constraints they rest on, and the questions still open. Feed details are in
[Audacy now-playing feed](audacy-now-playing-feed.md).

## Constraints

- **Runs on the user's Mac mini.** The user set this requirement on
  2026-10-13. On that date, the machine's `pmset` sleep setting was `0` (it
  never sleeps) and it had been up for 13 days.
- **The feed keeps only the last 50 plays,** about four hours, and older plays
  can't be fetched. If the logger stops for longer than that, those plays are
  lost.
- **Apple publishes no playlist size limit.** Apple's
  [Music guide](https://support.apple.com/guide/music/access-to-your-music-library-musa3dd5209/mac)
  caps the cloud library at 100,000 songs, not counting iTunes Store
  purchases. It doesn't say whether a playlist has a limit or what happens
  past one (checked 2026-10-13). In a 2022
  [Apple Community thread](https://discussions.apple.com/thread/253717041),
  a user reported that a playlist stopped at 50,000 songs: songs added past
  that appeared at first, then disappeared without an error. Apple hasn't
  confirmed this. Radio's playlist holds at most 100 songs, far below either
  figure, but the songs it drops stay in the library. The library therefore
  still grows with every new song a station plays. On 2026-10-13, Radio's
  first five hours on one station logged 66 plays of 64 songs.

## Decisions

### Read the Audacy JSON feed, not the audio stream

Accepted 2026-10-13. The user's plan said to use a JSON now-playing feed if one
existed, and one does. It already has the artist, title, start time, and a
play ID, so the logger doesn't need the stream URL, ICY metadata, HLS ID3
tags, or AVFoundation.

The user's plan ruled out a cloud scheduled task because hourly runs would
miss songs. With a four-hour feed window, an hourly run would catch every
play, so that reason no longer applies. The logger stays on the Mac mini
because the user requires it.

### Keep the playlist up to date

Accepted 2026-10-13. The logger runs indefinitely, and a scheduled sync adds
newly heard songs to the playlist. This replaces the plan's one-time playlist
built after one or two weeks. The user accepted the recommendation, whose
reason was that a poll every 15 minutes costs almost nothing. The tradeoff is
that playlist creation must be automated, so pasting the list into a web
service by hand isn't enough.

### Add every unique song the first time it plays

Accepted 2026-10-13. Every song a station plays goes into the playlist,
added the first time it's heard. Its order was first-heard order until a
[later decision](#move-a-re-played-song-to-the-end-of-the-playlist) the same
day ordered it by most recent play. The playlist only grew until
[another decision](#keep-only-the-100-most-recently-played-songs) that day
capped it at 100 songs. The user accepted the recommendation, whose reasons were that it
matches the goal of logging every song and that the public Apple Music API
seems to support only adding tracks to library playlists. Apple said in its
developer forums that it couldn't offer removal, and developers report that
DELETE and PUT now return 403. No official Apple documentation was found that
supports removing tracks (searched 2026-10-13). The tradeoff is that one-off
songs from specialty shows, such as the Sunday "Underexposed" local-music
show, are included.

### Move a re-played song to the end of the playlist

Accepted 2026-10-13. This replaces the first-heard order in the decision
above. When a song already in the playlist plays again on any station, Radio
moves its entry to the end. The playlist is therefore ordered by most recent
play,
and sorting it in reverse (newest first) shows re-played songs at the top. The
user asked for re-played songs to return to the top and chose the recommended
approach.

No Apple interface Radio can use reorders a playlist:

- The web API only adds tracks.
- The macOS 27 SDK marks every MusicKit library write (`createPlaylist`,
  `add`, `edit`) as `@available(macOS, unavailable)`, checked 2026-10-13.
- Music.app's scripting `move` command applies only to playlists.

Radio therefore moves the song through Music.app on the Mac mini: it copies
the entry to the end of the same playlist, then deletes the original. New
songs are still added through the web API. Costs:

- Music.app on the Mac mini must stay signed in with Sync Library on.
- The user approves "radio wants to control Music" once.
- `bin/deploy` signs the binary with the user's Apple Development identity,
  so that approval survives updates.
- If Music.app can't move a song, it stays where it is. The move stays
  pending and is retried on each later sync until Music.app succeeds. A song
  that Music.app reports as not in the library isn't retried.

The rejected alternatives were rebuilding the playlist newest-first on every
sync, which rewrites the whole playlist and risks iCloud sync conflicts, and
keeping first-heard order.

### Sync through the Apple Music REST API from a headless CLI

Accepted 2026-10-13. A command that launchd runs uses the Apple Music REST API
to search the catalog, create the library playlist, and add tracks. On each
run it signs its own developer token with a MusicKit `.p8` key from the user's
paid Apple Developer team, `34TKMKM889`. The membership was confirmed from
App Store provisioning profiles on this Mac. A local browser page uses
MusicKit JS for a one-time sign-in that gets the Music User Token. The user
accepted the recommendation, whose reason was that a plain CLI is the
simplest thing for launchd to run headless.

The rejected alternative was a signed macOS app using the MusicKit framework,
which has no user token to renew but needs an Xcode project, code signing,
and a running app. The tradeoffs of the CLI:

- The Music User Token reportedly expires after about six months, and then
  the user must sign in again. The sync must fail clearly and notify the user
  when that happens.
- The user must create the MusicKit key in their developer account.
- TuneMyMusic and Soundiiz are ruled out, because keeping the playlist up to
  date needs automated syncs.

### Write it as a Swift package with no dependencies

Accepted 2026-10-13. The tool is a Swift package that builds one executable.
It uses URLSession for HTTP and JSON, CryptoKit P256 to sign the ES256
developer token, and Swift Testing for tests. The user accepted the
recommendation, whose reasons were that Swift 6.4 is already installed, the
user works in Swift, the platform frameworks cover everything with no
third-party packages, and launchd can run a single compiled binary.

Python and Ruby were rejected. Both would need either a dependency or a
hand-written DER-to-raw signature conversion for the JWT, and launchd would
have to depend on a user-managed interpreter.

### Store plays and sync state in SQLite outside the repository

Accepted 2026-10-13. The tool keeps its state in
`~/Library/Application Support/Radio/radio.sqlite` and reads it through
macOS's built-in SQLite3 C library. The database records each play, keyed by
the feed's play ID, along with each song's Apple Music match and whether it
has been added to the playlist. A `radio export` command writes the CSV the
user's plan described. The user accepted the recommendation, whose reasons
were that sync state needs safe updates and has no dependency cost, and that
data outside the checkout survives clones and deleted worktrees. This replaces
the plan's CSV-only log, so the data can't be opened directly in a
spreadsheet without running the export.

### Keep Apple credentials in owner-only files

Accepted 2026-10-13. The MusicKit key (`AuthKey_<KEYID>.p8`) and a
`credentials.json` file with the key ID, team ID, and Music User Token live in
`~/Library/Application Support/Radio`, with mode `0600`. The tool refuses to
use a credential file that other users can read. The user accepted the
recommendation, whose reasons were that it works headless under launchd with
no prompts and matches the user's plaintext `~/.env` setup for other API keys.
The tradeoff is that the secrets aren't encrypted at rest.

The macOS Keychain was rejected because access depends on the binary's code
signature, and an approval dialog would block headless runs. 1Password was
rejected because the user's Git workflow notes say to avoid 1Password prompts
in automated work.

### Send Pushover alerts for failures only

Accepted 2026-10-13. The user authorized Radio to send Pushover alerts in two
cases: when Apple Music rejects the Music User Token, and when the feed has
failed for more than two hours. The second case matters because plays older
than the feed's window of about four hours are lost. A problem sends at most
one alert until it recovers. On 2026-10-13 the sign-in alert gained a one-hour
delay, so it fires only when rejection persists. The reason: a newly created
MusicKit key answered 401 intermittently for several minutes while Apple
rolled it out, and one 401 had sent a false alert. Radio reads `PUSHOVER_USER_KEY` and
`PUSHOVER_API_KEY` from `~/.env` at run time, so `~/.env` remains their only
copy. Both names were present there, in an owner-only file, on 2026-10-13.
The user accepted the recommendation, whose reason was that a lapsed token or
a dead feed is otherwise invisible until the playlist stops growing. Radio
sends no alerts for new songs.

### Support many stations

Accepted 2026-10-13. Radio polls Alt 102.1 (WRXL, Richmond) now, and the user
asked for the design to allow more stations later. At first each station had
its own playlist, named after the station, until a
[later decision](#funnel-every-station-into-one-playlist-named-radio) the same
day put every station's songs in one playlist.

- Stations are stored data, not code. `radio station add <audacy-slug>` reads
  the station's Audacy page for its feed ID (`window.STATION_ROC_ID`) and its
  name. Each run polls every station.
- Plays and feed-failure alerts are tracked per station. Apple Music matches
  are cached across stations, so a song that two stations play is searched
  only once.
- The Audacy feed reader sits behind a small source interface, so a station
  from another network can get its own reader later. Only the Audacy reader is
  built now.

### Funnel every station into one playlist named "Radio"

Accepted 2026-10-13. This replaces the per-station playlists in the decision
above. The user asked to rename the playlist to something like "Radio" so
that every station feeds a single playlist. Radio creates the playlist on its
first sync and then tracks it by its library playlist ID. The playlist holds
each song once, however many stations play it, ordered by the song's most
recent play on any station.

### Keep only the 100 most recently played songs

Accepted 2026-10-13. This replaces the ever-growing playlist in the decisions
above. The user asked to limit the playlist to 100 songs and drop the oldest
when a new one arrives, so that shuffling it plays songs the stations played
recently. The oldest song is the one least recently played on any station,
so a re-played song stays. Radio drops songs through Music.app, the same way
it moves them, and a dropped song returns when a station plays it again.
Dropped songs stay in the library.

### Prefer explicit versions

Accepted 2026-10-13. When Apple Music has both explicit and clean versions of
a song, Radio adds the explicit one, and uses the clean one only when no
explicit version exists. The user accepted the recommendation, whose reason
was that the album version is usually the explicit one, even though the
station plays clean edits.

### Match strictly and hold back uncertain songs for review

Accepted 2026-10-13. Radio adds a song automatically only when its normalized
artist and title both match an Apple Music catalog song. Normalization ignores
a leading "The", treats "&" and "and" alike, and handles featured artists and
"A / B" credits. Live, Acoustic, Remix, and Karaoke versions are avoided unless
the station played one. Any other song is held back for review on the
[review page](#review-held-back-songs-on-a-home-network-web-page). The page
lists each held-back song with its station, play count, last play time, and
Apple Music's top three candidates with links. From the page you can pick a
candidate, paste any Apple Music song link, or ignore the song for good. A
choice is remembered for that song across every station.

The user chose strict matching because the API can't remove a wrong track,
so a bad match would stay in the playlist until it's deleted by hand in Music.

### Review held-back songs on a home-network web page

Accepted 2026-10-13. An always-running LaunchAgent serves the review page at
`http://jubi.local:8102`, and any device on the home network can open it. The
page has no login or secret token, because the user said the information
isn't sensitive, so anyone on the home network can match or ignore songs. The
user chose a web page over the recommended terminal-only review. Later the
same day, the user asked to keep terminal commands as well: `radio unmatched`,
`radio match`, and `radio ignore` do the same work as the page.

The macOS application firewall was off on 2026-10-13, and port 8102 was free.

### Make the page a home-network activity dashboard

Accepted 2026-10-13. The user asked for a live site showing what has been
happening, and chose the recommended home-network dashboard over a public
site. The page at `http://jubi.local:8102` shows, for each station, the
current and recent plays and the songs its plays just added to the playlist.
It also
shows the review queue and health: last poll, last sync, and Apple Music
sign-in status. The page refreshes itself. Public hosting was deferred
because it would add a service to deploy, secure, and keep in sync.

### Send a weekly Pushover nudge about held-back songs

Accepted 2026-10-13. Once a week, Radio sends a Pushover message if songs were
held back since the last nudge. It says how many and links to
`http://jubi.local:8102`, and it sends nothing otherwise. This is in addition
to the failure alerts. The link opens only on the home network, which the user
accepted. The user accepted the recommendation, whose reason was that nobody
would otherwise remember to check.

### Run application checks locally, not in CI

Accepted 2026-10-13. GitHub Actions keeps running only the document and
foundation checks (`bin/check`) on Ubuntu. The Swift build and tests need
macOS frameworks, so `bin/check --full` runs locally on the Mac before each
merge, which the [check policy](foundation/engineering-policy.md#checks)
allows when there's no enforced CI gate. The user chose this over the
recommended macOS CI job, which would have cost 10× Actions minutes on this
private repository. The tradeoff is that nothing enforces the application
checks.

## Proposed implementation defaults

These are conventional choices proposed on 2026-10-13. The user hasn't
explicitly approved them.

- **Package layout:** a `RadioCore` library with the logic, a thin `radio`
  executable, and Swift Testing tests. Fakes sit at the HTTP boundary, and
  tests use a real SQLite database in a temporary directory.
- **Commands:**
  - `radio station add <audacy-slug>` and `radio station list`
  - `radio poll` and `radio sync`
  - `radio run`, which polls, syncs, and handles alerts and the weekly nudge
  - `radio serve`
  - `radio unmatched`, `radio match`, and `radio ignore`
  - `radio credentials`
  - `radio export`
  - `radio status`
- **Schedule:** the `run` LaunchAgent fires every 15 minutes, which leaves
  most of the feed's four-hour window as slack. The `serve` LaunchAgent stays
  running. Both use `launchctl bootstrap` in the `gui/<uid>` domain, and
  `bin/deploy` builds a release binary into `~/.local/bin/radio` and loads
  both agents. Logs go to `~/Library/Logs/Radio`.
- **Data directory:** `RADIO_HOME` overrides
  `~/Library/Application Support/Radio`, so development checkouts never touch
  the live database.
- **Song identity:** a song is its normalized primary artist plus its title
  without parenthetical suffixes. The playlist holds an Apple Music catalog
  ID at most once.
- **Upgrading to one playlist:** the web API can't rename a playlist or
  remove its entries, so the upgrade doesn't reuse a station's playlist. The
  first sync after it creates "Radio" with the 100 most recently played
  matched songs, in order of latest play. Each station's old playlist, such
  as "Alt 102.1", stops changing and stays in Music until it's deleted by
  hand.
- **Dropping songs:** each sync first drops, through Music.app, every entry
  outside the 100 most recently played songs, and then adds and moves. When
  Music.app can't drop them, new songs are still added, and the playlist
  passes 100 until Music.app works. An entry to drop that Music.app can't
  find is retried for an hour, like a move, and then forgotten.
- **Station credit:** a song added to the playlist is credited to the
  station whose play placed it, which is its latest play at that time. The
  dashboard lists each station's credited songs as "just added".
- **Moves in practice:** adds and moves run in play order within each sync.
  Music.app finds a playlist by name until it learns the playlist's
  persistent ID, and finds an entry by its catalog title and artist. It
  deletes every entry for that library track and adds the track back.
  An entry Music.app can't find is retried for an hour, since a song added
  through the web API takes time to sync to the Mac. After that, Radio treats
  the entry as removed by hand and adds the song again on its next play.
- **Rule changes apply to old matches:** each sync rechecks automatic matches
  against the current rules. Any the rules now reject are removed through
  Music.app and matched again. On 2026-10-13 the first release was found to
  have accepted four DJ-mix versions ("(Mixed)" titles from "(DJ Mix)"
  albums). The updated matcher rejects these. Music.app replaced them in
  "Alt 102.1" on 2026-10-13, once its access was approved.
- **Apple sign-in:** the dashboard's `/auth` page runs MusicKit JS and
  accepts only loopback requests, so it's opened at `http://localhost:8102/auth`
  on the Mac mini. That page receives a developer token, which shouldn't
  travel over the home network.
- **One sync at a time:** a sync takes an exclusive lock on `sync.lock` in the
  data directory, and a sync that finds it held skips with "Another sync is
  running." The lock was added on 2026-10-13, after overlapping syncs had
  duplicated playlists, and the API can't delete a playlist.
- **Alternate versions:** a catalog candidate is rejected when its title or
  album marks an alternate version, unless the played title does too, and a
  song with no accepted candidate is held for review. Title marks are live,
  acoustic, remix, mix, mixed, karaoke, instrumental, demo, unplugged, sped
  up, slowed, and a cappella, in parentheses, brackets, or after a dash.
  Album marks add "DJ Mix", "Mixed by", "Continuous Mix", tribute, and
  live-album phrases such as "(Live)".

## Open questions

None remain from the design interview.
