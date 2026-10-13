---
status: current
---

# Audacy now-playing feed

Audacy publishes a public JSON feed of each station's recent plays. It returns
the artist, title, and time of each play, so the logger can read it directly
instead of decoding the audio stream's metadata. Verified 2026-10-13.

## Endpoint

```text
https://api.audacy.com/experience/v2/stations/<a2Id>/nowplaying?count=<n>
```

- Alt 102.1 (WRXL, Richmond) is `a2Id` `101-1041`, from `window.STATION_ROC_ID`
  in the HTML of <https://www.audacy.com/alt1021rva>. Its timezone is
  `US/Eastern`.
- The station page and its song history page,
  <https://www.audacy.com/alt1021rva/song-history>, call this endpoint from
  inline JavaScript. If a station has a numeric AmperWave ID, the page calls
  `https://api-nowplaying.amperwave.net/api/v1/prtplus/nowplaying/<n>/<awId>/nowplaying.json`
  instead. WRXL's AmperWave ID is an unrendered template, so its page uses the
  Audacy endpoint.
- No authentication is needed. Responses carry `cache-control: max-age=60`
  and come from a CDN cache.

## Response

```json
{"performances": [{
  "id": 936989371,
  "time": "2026-10-13T19:18:33Z",
  "artist": "Rise Against",
  "title": "Savior",
  "album": "", "label": "", "isrc": "",
  "smallimage": "https://enrichment.amperwave.net/image/...",
  "mediumimage": "...", "largeimage": "..."
}]}
```

- `performances` lists plays newest first. `id` is a numeric play ID that
  increases over time, and `time` is the start time in UTC.
- `album`, `label`, and `isrc` were empty for every play in the sample.
- All 50 entries in the 2026-10-13 sample were songs. No ads, station IDs, or
  show names appeared.

## Limits

- `count` accepts at most 50. A value of 51 or more returns an empty list.
- 50 plays covered about 3 hours 50 minutes (15:29 to 19:18 UTC on
  2026-10-13).
- There is no paging or date range. `offset`, `page`, `before`, `startDate`,
  `endDate`, `date`, `from`, `to`, and `endTime` were all ignored, so plays
  older than the last 50 cannot be recovered.
- OnlineRadioBox had no WRXL playlist data for 2026-10-07 through 2026-10-13.
