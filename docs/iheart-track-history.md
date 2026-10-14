---
status: current
---

# iHeartRadio track history

iHeartRadio publishes a public JSON feed of each station's recent plays. It
returns the artist, title, and start time of each play, so Radio reads it
directly, as it does Audacy's
[now-playing feed](audacy-now-playing-feed.md). Verified 2026-10-13 with
Hits 106.1 (KBKS-FM, Seattle).

## Finding a station

- Each station has a site at `<name>.iheart.com`, such as
  <https://hits1061seattle.iheart.com/>. Its HTML embeds the station's stream
  ID as `"stream":{"id":4257,...}`. Radio takes the site name as the
  station's slug and reads the stream ID from the page.
- `https://us.api.iheart.com/api/v2/content/liveStations/<id>` returns the
  station as `hits[0]`, with `name` (`Hits 106.1`), `callLetters`
  (`KBKS-FM`), `freq`, and `markets`. An unknown ID returns 404.
- The station's player URL, <https://www.iheart.com/live/1061-kiss-fm-4257/>,
  ends in the same ID but keeps the station's former KISS FM name, so it
  makes a poor slug.
- `https://us.api.iheart.com/api/v3/search/all?keywords=KBKS` with
  `station=true`, and the other result types set to `false`, found the station
  by its call letters.

## Endpoint

```text
https://us.api.iheart.com/api/v3/live-meta/stream/<id>/trackHistory?limit=<n>
```

- No authentication is needed, and Radio's own `User-Agent` is accepted.
  Responses came through a CDN (`X-Cache: MISS`) with no `Cache-Control`
  header.
- An unknown stream ID returns 400 with `stream not found`.

## Response

```json
{"meta": {"offset": 0, "pageSize": 50, "totalSize": 1865},
 "data": [{
  "artistId": 33471063, "albumId": 352012876, "trackId": 352012881,
  "title": "So Easy (To Fall In Love)", "artist": "Olivia Dean",
  "album": "The Art of Loving", "trackDuration": 169,
  "startTime": 1791948091, "endTime": 1791948257,
  "explicitLyrics": false, "dataSource": "Pnp",
  "imagePath": "http://image.iheart.com/...",
  "playbackRights": {"onDemand": true}
 }],
 "links": {"next": "AAAAAGrO9oYAAAAAAAAAMgAAB0k"}}
```

- `data` lists plays newest first. `startTime` and `endTime` are Unix
  seconds.
- There is no play ID; `trackId` names the song, not the play. Radio uses
  `startTime` as the play ID. All 200 start times in a sample were distinct.
- All 200 entries in the 2026-10-13 sample were songs, with `dataSource`
  `Pnp`. No ads, station IDs, or show names appeared.

## Limits

- `limit` accepted 200, the largest value tried. On 2026-10-13, 50 plays
  covered 4 hours 36 minutes and 200 covered 18 hours 37 minutes. Radio asks
  for 100, and its first poll covered 8 hours 14 minutes.
- `meta.totalSize` was 1,865, and `links.next` holds a paging cursor, so
  older plays may be reachable. Radio doesn't page, and the way to pass the
  cursor wasn't tested.
