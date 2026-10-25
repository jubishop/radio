---
name: music-test-dialogs
description: Don't open test dialogs in Music.app; they wait unseen until Music is opened, then the user must close them.
type: feedback
---

# Don't open test dialogs in Music.app

Don't run `display dialog` in Music.app, or anything else that opens an
alert there, to test how Radio sees Music.

**Why:** an alert from Music.app in the background waits, with no window,
until Music is brought forward, so its `giving up after` timer can't start.
On 2026-10-25, two test dialogs sent at 9:33 AM showed nothing until the
user clicked Music in the Dock a minute later, and then both appeared at
once and the user closed them by hand. While they waited, Music answered
scripting slowly; one query took 29 seconds.

**How to apply:** test against stand-ins, as `MusicAppTests` does for
`osascript` and `log`, or read what Music.app already logged. If a check
truly needs a live Music alert, ask the user first, and expect it to appear
only once Music is opened.
