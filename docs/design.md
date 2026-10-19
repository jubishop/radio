---
status: current
---

# Radio design

Radio logs each song its stations play, starting with Alt 102.1 (WRXL,
Richmond). It keeps the 100 most recently played in an Apple Music playlist
named "Radio", and the 10,000 most recently played in "Radio Archive". This
page records the
accepted decisions, the constraints they rest on, and the questions still
open. Feed details are in
[Audacy now-playing feed](audacy-now-playing-feed.md),
[iHeartRadio track history](iheart-track-history.md), and
[Hubbard Radio listen-live cues](hubbard-listen-live-cues.md).

## Constraints

- **Runs on the user's Mac mini.** The user set this requirement on
  2026-10-13. On that date, the machine's `pmset` sleep setting was `0` (it
  never sleeps) and it had been up for 13 days.
- **Audacy's feed keeps only the last 50 plays,** about four hours, and
  older plays can't be fetched. If the logger stops for longer than that,
  those plays are lost. iHeartRadio's feed returns up to 200 plays, about 18
  hours, and Hubbard Radio's up to 300, about 21 hours.
- **Apple publishes no playlist size limit.** Apple's
  [Music guide](https://support.apple.com/guide/music/access-to-your-music-library-musa3dd5209/mac)
  caps the cloud library at 100,000 songs, not counting iTunes Store
  purchases. It doesn't say whether a playlist has a limit or what happens
  past one (checked 2026-10-13). In a 2022
  [Apple Community thread](https://discussions.apple.com/thread/253717041),
  a user reported that a playlist stopped at 50,000 songs: songs added past
  that appeared at first, then disappeared without an error. Apple hasn't
  confirmed this. "Radio" holds at most 100 songs and "Radio Archive" at
  most 10,000, but songs they drop stay in the library, so the library grows
  with every new song a station plays. On 2026-10-13, the library held 3,787
  songs, and Radio's first five hours on one station logged 66 plays of 64
  songs.
- **Music.app overwrites a playlist it edits.** After Music.app changes a
  playlist, it uploads its own copy, which replaces Apple's. Songs the web
  API added that hadn't reached the Mac yet are lost, though the API reported
  success. Apple doesn't document this. On 2026-10-13, by 7:30 PM PDT,
  Apple's copy of "Radio" held 35 songs while Radio's database listed 100,
  and "Radio Archive" held 94 of 166. Syncs that edited a playlist through
  Music.app lost nearly every song the API added in that sync, and syncs
  that didn't use Music.app lost none.
- **Music's playlists can't show more columns.** In Music 1.7 on macOS
  27.0.1, a playlist has no column options, and its View menu offers only a
  fixed "Sort By" list without comments. The Songs view has column options,
  including Comments. The user reported this on 2026-10-13. A comment
  belongs to the library track, so it shows wherever the song does, and
  changing it edits no playlist. On 2026-10-13, Music.app's scripting set the
  comment of an Apple Music track in "Radio", and the comment was still there
  three minutes later. None of the library's 3,846 tracks had a comment.

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
songs were still added through the web API until a
[later decision](#change-the-playlists-only-through-musicapp) the same day.
Costs:

- Music.app on the Mac mini must stay signed in with Sync Library on.
- The user approves "radio wants to control Music" once.
- `bin/deploy` signs the binary with the user's Apple Development identity,
  so that approval survives updates.
- If Music.app can't move a song, it stays where it is. The move stays
  pending and is retried on each later sync until Music.app succeeds. A song
  whose track still isn't in the library an hour after Radio asked Apple to
  add it stays where it is.

The rejected alternatives were rebuilding the playlist newest-first on every
sync, which rewrites the whole playlist and risks iCloud sync conflicts, and
keeping first-heard order.

### Sync through the Apple Music REST API from a headless CLI

Accepted 2026-10-13. A command that launchd runs uses the Apple Music REST API
to search the catalog and add songs to the library. Until a
[later decision](#change-the-playlists-only-through-musicapp) the same day, it
also created the playlists and added songs to them. On each
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
  from another network can get its own reader later. An iHeartRadio reader
  came [next](#read-iheartradio-stations-starting-with-hits-1061).

### Read iHeartRadio stations, starting with Hits 106.1

Accepted 2026-10-13. The user asked to add 106.1 in Seattle. That station is
Hits 106.1 (KBKS-FM), which iHeartMedia owns and Audacy doesn't carry, so
Radio gained a second reader, for iHeartRadio's public
[track history](iheart-track-history.md). An iHeartRadio station's songs go
into the same two playlists as every other station's.

### Read Hubbard Radio stations, starting with MOViN 92.5

Accepted 2026-10-15. The user asked to add 92.5 in Seattle. That station is
MOViN 92.5 (KQMV), which Hubbard Broadcasting owns and neither Audacy nor
iHeartRadio carries, so Radio gained a third reader, for the public
[cue history](hubbard-listen-live-cues.md) behind Hubbard Radio's listen-live
player. Its songs go into the same two playlists as every other station's.

### Funnel every station into one playlist named "Radio"

Accepted 2026-10-13. This replaces the per-station playlists in the decision
above. The user asked to rename the playlist to something like "Radio" so
that every station feeds a single playlist. Radio creates the playlist on its
first sync and then tracks it by its ID. The playlist holds
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

### Add a larger "Radio Archive" playlist

Accepted 2026-10-13. The user asked for a second playlist, "Radio Archive",
that grows until it reaches Apple's size limit, until a
[later decision](#cap-radio-archive-at-10000-songs) the same day capped it.
It holds each song once, and a re-played song moves to its end, as in
"Radio". Radio syncs "Radio" first, so trouble in the archive can't stop it
from updating.

The user also considered removing the cap from "Radio" and building a smart
playlist of its 100 most recently added songs, and chose the archive instead.
A smart playlist's "most recently added" uses the date a song entered the
library, according to user reports; no Apple documentation was found
(searched 2026-10-13). Moving a re-played song wouldn't change that date, and
a song already in the library before Radio added it would never count as
recent.

### Cap "Radio Archive" at 10,000 songs

Accepted 2026-10-13. This replaces the archive's growth to Apple's limit.
After learning that the library held 3,787 of its 100,000 songs, the user
asked to cap the archive at 10,000. It drops its least recently played songs
the same way "Radio" does.

### Change the playlists only through Music.app

Accepted 2026-10-13. This replaces adding songs through the web API in the
decisions above. Music.app
[overwrites a playlist it edits](#constraints), which had wiped out most of
the songs the API added. The user accepted the recommendation to make
Music.app the only thing that changes the playlists:

- The web API asks Apple to add each new song to the library
  (`POST /v1/me/library?ids[songs]=…`, which answers 202 Accepted).
- Once the song's library track reaches the Mac, Music.app puts it at the end
  of the playlist, the same way it moves a re-played song. Music.app finds
  the track by title and artist, preferring the matched album.
- Songs are placed in play order. A song whose track hasn't reached the Mac
  holds back the songs played after it for up to an hour, and then they go
  ahead without it.
- Music.app also makes the playlists. If Radio's playlist is gone, Music.app
  makes a new one, and the next sync fills it in play order.
- Upgrading to this release places every entry again, in play order, which
  restores the songs that were wiped out.

The tradeoffs:

- A new song usually appears one sync later, about 15 minutes, while its
  library track reaches the Mac.
- Nothing changes while Music.app isn't working.
- Music.app can pick another version of a song with the same title, artist,
  and album, such as the clean one.

The rejected alternatives were to keep adding through the API and re-add
lost songs, which Music.app's next upload would wipe out again, and to avoid
Music.app edits just after API adds, which still races because Music.app
uploads at times Radio can't see.

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

On 2026-10-15 the user approved fixing gaps that held back songs Apple Music
credits differently (td-224df6). The artists now match when either credit's
lead artist appears anywhere in the other, so "21 Savage, Metro Boomin, The
Weeknd" matches "Metro Boomin, The Weeknd & 21 Savage". Matching also splits
"BEYONCE/JAY-Z" and "Usher f/ Pitbull" into two artists, and ignores a
featured credit at the end of a title, as in "Rein Me In Ft. Olivia Dean".
Song identity doesn't split or drop these, because doing so would also split
names like "HUNTR/X" and change the keys of logged songs. Each sync now
rechecks held songs against their stored candidates as well. Replayed against
the live database that day, the fix rejected none of the 539 automatic
matches, cleared five of the nine held songs, and would have matched four of
the 15 earlier manual picks.

### Let Jev resolve held-back songs

Accepted 2026-10-15 (td-810dd1). Each sync asks TypeSafe's Jev about every
held song it hasn't judged, with one Choice question: which of these
recordings did the station play, or none of them? Held songs now keep the
top ten Apple Music candidates instead of three. The review page shows three
and folds the rest away, keeping Jev's pick in view.

Before asking, Radio collapses copies of one recording into a single option,
since search results often list a recording on its album, its single, and
compilations. Copies share an ISRC, or have the same title and artist with
lengths within three seconds, which also pairs a clean edit, whose ISRC
differs, with its explicit original. A live or remixed copy must match the
full title too, so a live take and a remix stay apart.

- **Probability 0.9 or higher:** Radio adds that recording, as matched by
  Jev, using its explicit copy, or else its first in Apple's search order,
  which is usually the original release.
- **From 0.6 up to 0.9:** the review page and `radio unmatched` show that copy
  as Jev's suggestion.
- **Below 0.6, or "none":** the song waits for review as before.

Jev judges each held song once per model. Radio learns which model answered
from each answer, and when that changes, it asks about every held song judged
by an older model once more, leaving out songs the user sent back. So held
songs meet a new model after the next song is held. The user agreed to this
on 2026-10-15, since Radio follows the newest model and a newer one may be
sure where an older one wasn't. Songs held before candidates had ISRCs and
lengths were searched and judged again once, on upgrading to schema 9, at
the user's request the same day. When a request fails, the song waits for the
next sync and the dashboard shows the error. Without `JEV_API_KEY` in the env
file, Radio doesn't ask Jev.

After seeing the [evaluation](jev-matching-evaluation.md), the user chose the
newest model, jev-1.14.0, with the 0.9 bar, then set the suggestion bar to
0.6. Radio first asked one yes/no question per candidate, the design that
scored best before copies were collapsed. Its first live pick, Usher's "DJ Got
Us Fallin' In Love", went to a trimmed copy on a compilation instead of the
EP, because copies of one recording scored about the same. The user preferred
a Choice question, which fits picking one recording, and asked to give Jev
only the options it needs. With copies collapsed, the Choice question added
80 of 102 right recordings at the 0.9 bar against 86 for the yes/no design,
added no wrong song or trap in either, and used about a third of the tokens.
The user chose it on 2026-10-15.

The user also asked Radio to always use the newest model instead of a pinned
version, so Radio sends `jev-preview`, TypeSafe's alias for its newest
release, official or preview. `jev-latest`, the newest official release, was
jev-1.13.0 then. The tradeoff is that scores can shift when the alias moves,
with no change to Radio, while the bars were measured on jev-1.14.0. Radio
records the model that answered with each verdict, and the review page shows
it.

Strict matching was chosen because a wrong track couldn't be removed. Radio
now removes tracks through Music.app, and any Jev pick can be undone from the
review page.

### Review everything Jev or the user decided

Accepted 2026-10-15. The user asked the review page to show everything Jev or
they decided, so any of it can be undone, with what needs them at the top.
From top to bottom, the page lists songs needing review, each with Jev's
suggestion when it has one, then every song Jev or the user matched, newest
decision first. Songs the user ignored, meaning never add and never ask
again, are in that list too, so an ignore can be undone without Terminal. The
user agreed to this the same day. Automatic matches aren't
listed, since there were 539 of them.

Undo puts a song back at the top of the page at once. When the song was
matched, the next sync removes its track from the playlists, unless another
matched song still uses it. Neither the matching rules nor Jev match a song
the user sent back, so it waits for the user. `radio reviewed` and
`radio undo` do the same in Terminal.

### Review held-back songs on a home-network web page

Accepted 2026-10-13. An always-running LaunchAgent serves the review page at
`http://jubi.local:8102`, and any device on the home network can open it. The
page has no login or secret token, because the user said the information
isn't sensitive, so anyone on the home network can match or ignore songs. The
user chose a web page over the recommended terminal-only review. Later the
same day, the user asked to keep terminal commands as well: `radio unmatched`,
`radio match`, and `radio ignore` do the same work as the page.

On 2026-10-15, before making the repository public, the user asked the server
to refuse a POST whose `Origin` header names another site. Without that check,
a page on any website could match or ignore songs, or post a sign-in token,
through the browser of someone on the home network. Clients that send no
`Origin`, such as curl, are still accepted.

The same day, the user asked to close DNS rebinding as well, where a site
points its own domain at the Mac so a browser treats the dashboard as that
site's own. Radio now serves only requests whose `Host` is a `.local` name,
`localhost`, or an IP address, which no outside site can claim. Any other
name gets a 403. [Tailscale names](#open-the-dashboard-over-tailscale) were
added later.

The macOS application firewall was off on 2026-10-13, and port 8102 was free.

### Open the dashboard over Tailscale

Accepted 2026-10-19. The user asked to open the dashboard from their phone
away from home, over Tailscale. Radio now also serves requests whose `Host`
ends in `.ts.net`. Only Tailscale assigns and resolves those names, so no
outside site can claim one for this Mac. A short MagicDNS name, such as
`http://mac-mini:8102`, still gets a 403, so use the full `.ts.net` name or
the Mac's Tailscale IP address. Chromium's HSTS preload list didn't include
`ts.net` on 2026-10-19, so browsers don't force those names to HTTPS.

The server also listens on IPv4 alone. On 2026-10-19, under macOS 27, a
Network framework listener that took both IPv4 and IPv6 never answered IPv4
connections that arrived over Tailscale, while an IPv4-only listener and a
plain BSD socket did. A client that tries IPv6 first, such as a browser
opening `localhost` or `jubi.local`, is refused at once and falls back to
IPv4.

Changed 2026-10-19. The user asked for alert links to use the Tailscale name,
kept in a file in the checkout that Git ignores. `bin/deploy` reads
`RADIO_DASHBOARD_URL` from the checkout's `.env` and sets it in both
LaunchAgents' environment. Without it, links fall back to
`http://jubi.local:8102`. The sign-in alert still links to `localhost`, since
sign-in works only on the Mac, and the review email no longer says its link
opens only on the home network.

### Make the page a home-network activity dashboard

Accepted 2026-10-13. The user asked for a live site showing what has been
happening, and chose the recommended home-network dashboard over a public
site. The page at `http://jubi.local:8102` shows, for each station, the
current and recent plays and the songs its plays just added to the playlist.
It also
shows the review queue and health: last poll, last sync, and Apple Music
sign-in status. The page refreshes itself. Public hosting was deferred
because it would add a service to deploy, secure, and keep in sync.

### Color the dashboard by meaning

Accepted 2026-10-15. The user asked for green to mean all is well, red to
mean something needs them, and other colors for everything else, with more
variety than black, white, red, and green. Green marks a connected Apple
Music and an empty review queue. Red marks songs to review, failures, and
each song waiting on the review page. Links are blue, buttons are indigo, Jev's
suggestions and picks are purple, playlist links and "in playlist" are teal,
and "waiting to sync" is amber.

Each station takes one of eight colors from its ID and keeps it on every
page, as a stripe on its dashboard card and as tags on the playlist pages.
Colors from a hash of the station's name would likely have given two of the
five stations the same color.

### Show each song's stations and latest play

Accepted 2026-10-13. The user asked for each song's stations and latest play
in its Music comment, and for a way to see them without opening Get Info on
each song. Music's playlists [can't show comments](#constraints), so the user
accepted both recommendations:

- **Comments:** each sync gives every song in the playlists a comment such
  as `📻 2026-10-13 15:14 · Alt 102.1, 107.7 The End`. It has the song's
  latest play on any station, in the Mac's time zone, then every station
  that played it, most recently first. The time comes first, to the minute
  in 24-hour form, so sorting the Songs view by Comments puts Radio's songs
  in play order. Radio replaces only empty comments and its own, which start
  with 📻, so a comment someone writes stays. It remembers the comment it
  last gave each song and asks Music.app only when the song's plays change
  it. Songs already in the playlists get comments on the first sync after
  the upgrade.
- **Dashboard pages:** `/playlists/radio` and `/playlists/archive` list each
  playlist's songs, most recently played first, with each station's play
  count. The dashboard's playlist counts link to them.

The tradeoffs:

- Each new or re-played song costs one more Music.app call per sync.
- A song dropped from both playlists keeps its last comment.
- Music.app finds the song's track the way placing does, so a comment can
  land on another version with the same title and artist.

### Send a daily review reminder by Pushover and email

Accepted 2026-10-13. Once a week, Radio sends a Pushover message if songs were
held back since the last nudge. It says how many and links to
`http://jubi.local:8102`, and it sends nothing otherwise. This is in addition
to the failure alerts. The link opens only on the home network, which the user
accepted. The user accepted the recommendation, whose reason was that nobody
would otherwise remember to check.

Changed 2026-10-19. The user asked for an email that lists every song needing
review and links to the review page. They chose to keep it weekly rather than
daily, and to send it alongside the Pushover message rather than replace it.
Later that day, they asked for both to come daily instead.

- **When:** once a day, if any song is waiting for review, however long it has
  waited. Before, a song held more than a week earlier never came up again.
  Each day starts a whole number of days after the first check, so the
  reminder keeps its time of day: a late run, or a day without runs, doesn't
  make later reminders late. A reminder more than half a day late skips the
  next one, so two don't come close together. The days are counted in fixed
  24-hour steps, so the local time moves an hour when daylight saving time
  starts or ends.
- **What:** the push gives the count. The email, sent through Resend from
  `Radio <radio@jubishop.com>` to `EMAIL_TO`, lists each song with its plays,
  stations, latest play, and Jev's suggestion. Both link to the review page
  at [`RADIO_DASHBOARD_URL`](#open-the-dashboard-over-tailscale).
- **Failures:** each service counts as done for the day once it accepts its
  message. A refused email is retried on the next run without repeating the
  push, and a service whose keys are missing is skipped without holding up
  the other. `RESEND_API_KEY` and `EMAIL_TO` stay in `~/.env`, since other
  home tools use them too.

### Run application checks locally, not in CI

Accepted 2026-10-13. GitHub Actions keeps running only the document and
foundation checks (`bin/check`) on Ubuntu. The Swift build and tests need
macOS frameworks, so `bin/check --full` runs locally on the Mac before each
merge, which the [check policy](foundation/engineering-policy.md#checks)
allows when there's no enforced CI gate. The user chose this over the
recommended macOS CI job, which would have cost 10× Actions minutes on this
private repository. The tradeoff is that nothing enforces the application
checks.

## Accepted implementation defaults

Accepted 2026-10-13. The user approved these proposed defaults that day.
td-b818f2 records the user-approved deploys of the single "Radio" playlist
and "Radio Archive".

- **Upgrading to one playlist:** the web API can't rename a playlist or
  remove its entries, so the upgrade doesn't reuse a station's playlist. The
  first sync after it creates "Radio" with the 100 most recently played
  matched songs, in order of latest play. Each station's old playlist, such
  as "Alt 102.1", stops changing and stays in Music until it's deleted by
  hand.
- **Upgrading to the archive:** the first sync after the upgrade creates
  "Radio Archive" with every matched song, in order of latest play. "Radio"
  keeps its entries.
- **Dropping songs:** for each playlist, each sync first drops, through
  Music.app, every entry outside its limit of most recently played songs, and
  then places new and re-played songs. An entry to drop that Music.app can't
  find was removed by hand, and Radio forgets it.
- **Station credit:** a song added to "Radio" is credited to the station
  whose play placed it, which is its latest play at that time. The
  dashboard lists each station's credited songs as "just added".
- **Placing in practice:** Music.app finds a playlist by its persistent ID,
  then by name, and makes one if neither finds it. It finds an entry by its
  catalog title and artist, or for a new song, a library track. It deletes
  every entry for that library track and adds the track back, which appends
  it. A song removed by hand is placed again on its next play. Radio asks
  Apple to add every song it's about to place to the library, unless it
  asked within the hour; adding a song that's already there changes
  nothing.

## Proposed implementation defaults

These are conventional choices proposed on 2026-10-13. The user hasn't
explicitly approved them.

- **Package layout:** a `RadioCore` library with the logic, a thin `radio`
  executable, and Swift Testing tests. Fakes sit at the HTTP boundary, and
  tests use a real SQLite database in a temporary directory.
- **Commands:**
  - `radio station add <slug> [--source audacy|iheart|hubbard]` and
    `radio station list`
  - `radio poll` and `radio sync`
  - `radio run`, which polls, syncs, and handles alerts and the daily review reminder
  - `radio serve`
  - `radio unmatched`, `radio match`, and `radio ignore`
  - `radio credentials`
  - `radio export`
  - `radio status`
- **Schedule:** the `run` LaunchAgent fires every 15 minutes, which leaves
  most of Audacy's four-hour window as slack. The `serve` LaunchAgent stays
  running. Both use `launchctl bootstrap` in the `gui/<uid>` domain, and
  `bin/deploy` builds a release binary into `~/.local/bin/radio` and loads
  both agents. Logs go to `~/Library/Logs/Radio`.
- **Data directory:** `RADIO_HOME` overrides
  `~/Library/Application Support/Radio`, so development checkouts never touch
  the live database.
- **iHeartRadio stations:** the slug is the station's site name, such as
  `hits1061seattle` for hits1061seattle.iheart.com, the way an Audacy slug is
  the station's audacy.com path. The site's HTML gives the stream ID, and the
  station API gives the name. Each poll reads the 100 latest plays, about
  eight hours, so a long outage loses fewer. The feed has no play ID, so a
  play's start time identifies it.
- **Hubbard Radio stations:** the slug is the station site's domain, such as
  `movin925.com`, and its player's host, `live.movin925.com`, is the feed ID.
  The player's settings give the name. Each poll reads the 100 latest cues,
  about seven hours, keeps only songs, and uses each cue's ID as its play ID.
- **Song identity:** a song is its normalized primary artist plus its title
  without parenthetical suffixes. The playlist holds an Apple Music catalog
  ID at most once.
- **Rule changes apply to old matches:** each sync rechecks automatic matches
  against the current rules. Any the rules now reject are removed through
  Music.app and matched again. On 2026-10-13 the first release was found to
  have accepted four DJ-mix versions ("(Mixed)" titles from "(DJ Mix)"
  albums). The updated matcher rejects these. Music.app replaced them in
  "Alt 102.1" on 2026-10-13, once its access was approved. Each sync also
  matches any held song whose stored candidates the current rules accept.
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

- Whether songs Radio drops from "Radio" and "Radio Archive" should also
  leave the library. Radio keeps them there for now, and the user hasn't
  decided (td-b818f2, 2026-10-13).
