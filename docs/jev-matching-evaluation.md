---
status: current
---

# Jev matching evaluation

On 2026-10-15, before Radio used Jev, Jev was tested on Radio's own data to see
whether it could resolve held-back songs safely, which question design worked
best, and where to set its bars. The [design](design.md#let-jev-resolve-held-back-songs)
records what the user chose from these results.

## Method

The test used 104 songs from the live database: the user's 15 manual picks,
the 4 songs then held, the 5 that the matching fix had just cleared, and 80
automatic matches sampled at random. Each song's candidates were the top ten
results of the Apple Music catalog search Radio itself runs, fetched through
Radio's own client. The public iTunes Search API was tried first and dropped:
it returned one result where Apple Music returned three, and missed the
explicit original.

For each automatic match, a second case removed every candidate that was the
right recording. In these 80 trap cases, the right answer is that none of the
candidates fits, so they show how often Jev would add a wrong song.

A pick counted as right when it was the labeled song, or the same song by the
same artist in the same kind of version. The held songs were labeled by hand.
This rule treats every live version alike, so it counted one wrong live
recording as right; see [Observations](#observations).

Two question designs were compared on `jev-1.13.0` and `jev-1.14.0`:

- **Choice:** one Choice question per song, with an option for each candidate
  and a "none" option. Radio uses this, with copies of one recording
  collapsed first; see [Collapsing copies](#collapsing-copies). The wording
  is in `Sources/RadioCore/Jev.swift`.
- **Noul:** one yes/no question per candidate, asking whether it's the
  recording the station played. Radio used this first.

The first 736 requests used about one million input tokens, roughly $0.04 at
the listed price.

## Results

The right recording was in the top ten for 14 of the 15 manual picks, 3 of
the 4 held songs, and all the others. In the table, "added" counts the right
recordings Jev would add at each bar, out of the 102 cases where the right
recording was listed. "Traps added" counts the 82 cases without the right
recording, including two held and manual songs, where Jev would add a song
anyway.

| Design and model | Bar | Added | Wrong added | Traps added |
| --- | --- | --- | --- | --- |
| Choice, 1.13 | 0.8 | 61 | 1 | 0 |
| Choice, 1.14 | 0.9 | 33 | 1 | 0 |
| Noul, 1.13 | 0.8 | 90 | 1 | 0 |
| Noul, 1.13 | 0.9 | 67 | 1 | 0 |
| Noul, 1.14 | 0.8 | 92 | 1 | 0 |
| Noul, 1.14 | 0.9 | 86 | 1 | 0 |

The Choice design picked the right song as often, 99 to 100 of 102, but its
probabilities separated right from wrong less well: at a 0.5 bar it would have
added a song in 3 trap cases. With the Noul design, no wrong candidate scored
above 0.46 on 1.13 or 0.58 on 1.14, and the median right pick scored 0.92 on
1.13 and 0.95 on 1.14.

## Collapsing copies

Most search results list the right recording more than once: on its album,
its single, and compilations. That was true in 89 of the 102 cases where it
was listed. A Choice question spreads its probability over those copies, so
with several copies only 24 of 89 cases had one copy at 0.9 or higher on 1.14.
Apple's catalog gives every song an ISRC, which identifies the recording. Of
23 copies checked across 5 songs, most shared their recording's ISRC, but a
clean edit has its own, and a few copies were other takes or a trimmed edit
under the same title.

So the Choice question was tested again with copies collapsed into one option
each: those sharing an ISRC, or with the same title and artist and lengths
within three seconds, unless one is a live or remixed version with another
title. Options per song fell from up to ten to about seven.

| Choice with copies collapsed, model | Bar | Added | Wrong added | Traps added | Tokens per song |
| --- | --- | --- | --- | --- | --- |
| 1.14 | 0.8 | 91 | 0 | 0 | 796 |
| 1.14 | 0.9 | 80 | 0 | 0 | 796 |
| 1.13 | 0.9 | 78 | 0 | 0 | 778 |

The 1.13 row used a slightly looser collapse rule that didn't keep live takes
and remixes apart. The Noul design used 2,239 tokens per song. On 1.14, the
highest wrong option in a trap case scored 0.66, and the highest Choice
probability for the Bad Omens original was 0.79. Of the 19 hard cases, 7 would
be added at the 0.9 bar and 8 more suggested at the 0.6 bar.

## Observations

- The one wrong addition in every row of the first table is Bad Omens' "Death
  Of Peace Of Mind".
  Jev picked the band's own recording, scoring it 0.90, where the user had
  picked Daughtry's cover. The user then asked for the original.
- With the Noul design on 1.14, 7 of the 19 hard cases (the manual picks and
  held songs) would be added at the 0.9 bar, Bad Omens aside, and 4 more
  suggested at the 0.6 bar.
  These songs are harder than automatic matches, since the matching rules
  failed on them.
- For "The Man Who Sold The World", 1.13's best guess, at 0.52, was a 1993 Los
  Angeles live recording rather than the Unplugged one the user chose. The
  scoring rule counted it as right.
- On 1.14, the highest trap score was 0.57, for "Holiday / Boulevard of
  Broken Dreams" when the station played "Boulevard Of Broken Dreams". The 0.6
  suggestion bar leaves it out.

## Limits

The sample is small, and only 19 cases were as hard as the songs Radio will
actually ask about. The bars were measured on `jev-1.14.0`, and Radio follows
the `jev-preview` alias, which can move to a newer model. On 2026-10-15 the
user chose not to keep the evaluation script, since the review page shows the
model behind each Jev pick and can undo it. To repeat the test, dump catalog
search results for a set of songs through `AppleMusicClient`, ask Jev with the
question in `Jev.swift`, and compare the picks with the user's matches.
