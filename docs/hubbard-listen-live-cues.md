---
status: current
---

# Hubbard Radio listen-live cues

Hubbard Radio stations stream through a listen-live player that reads a public
JSON history of the station's cues. Each cue gives the artist, title, start
time, and an ID, so Radio reads it directly, as it does
[Audacy](audacy-now-playing-feed.md) and
[iHeartRadio](iheart-track-history.md). Verified 2026-10-15 with MOViN 92.5
(KQMV, Seattle), which neither Audacy nor iHeartRadio carries.

## Finding a station

- Each station's player is at `live.<domain>`, where the domain is the
  station's own site, such as <https://live.movin925.com/> for
  <https://www.movin925.com/>. Radio takes the domain as the station's slug
  and the player's host as its feed ID. KS95 (`live.ks95.com`) and WDRV
  (`live.wdrv.com`) answered the cue endpoint below too.
- `GET https://live.<domain>/wp-json/hll/v1/hll_settings_get` returns the
  player's settings. `data["hll-station-name"]` is the name (`MOViN 92.5`),
  and `data["hll-station-call-letters"]` the call letters (`KQMV`).
- These are WordPress routes. An unknown route answered 200 with an empty
  body, so a missing station name, not the status, shows a wrong domain.
- The station's main site, `www.movin925.com`, answered `curl` with a
  Cloudflare 403. The `live.` host answered with Radio's own `User-Agent`.

## Endpoint

```text
POST https://live.<domain>/wp-json/hll/v1/hll_cues_get
{"limit": <n>, "offset": <cue ID>}
```

- No authentication is needed. The player sends the body as JSON, and an
  `application/json` or form content type both worked.
- `limit` defaults to 6 and returned at most 300, about 21 hours, on
  2026-10-15. 100 plays covered 7 hours 28 minutes. Radio asks for 100.
- `offset` takes a cue ID and returns the cues before it, which is how the
  player's "load more" button pages. Radio doesn't page.
- `GET .../hll_timeline` returns the same cues, but only the latest 6, and
  ignored every count and paging parameter tried. A poll every 15 minutes
  would miss songs, so Radio doesn't use it.

## Response

```json
{"success": true, "data": {"code": 200, "response": [{
  "id": "40204096", "application": "25", "timestamp": "1792102901",
  "type": "song", "cut_id": "lzer",
  "data": {"cut_id": "lzer", "description": "Loser", "artist": "Tame Impala",
           "album": "", "time": "216000",
           "musicbrainz_recording": "ec87b2e6-3d7e-4121-96a3-051fe779de6f"},
  "likes": 23, "itunes_url": ""
 }]}}
```

- `response` lists cues newest first. `timestamp` is the start time in Unix
  seconds, and `id` and `timestamp` are strings.
- `data.description` is the title. `data.time` is the length in
  milliseconds.
- `id` names the play. IDs were distinct in a 300-cue sample, and cues from
  KS95 and WDRV came from the same sequence, so Radio uses `id` as the play
  ID.
- `application` identifies the station's stream (25 for KQMV, 4 for KS95, 13
  for WDRV). The player adds `?application_id=` only for a station's
  secondary streams.
- All 300 cues sampled on 2026-10-15 were `song`. The player's live updates
  also carry `ad` cues, which it skips, so Radio logs only `song` cues.
