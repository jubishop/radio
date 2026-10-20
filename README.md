# Radio

Radio follows radio stations and builds Apple Music playlists from the songs
they play.

Radio is a Swift command-line tool that runs on a Mac. Every 15 minutes it
logs each followed station's plays from the station's public now-playing feed.
Each newly heard song goes into two Apple Music playlists that every station
feeds: "Radio" keeps the 100 most recently played songs, and "Radio Archive"
keeps the 10,000 most recent. A dashboard on the home network shows recent activity, charts of
what the stations play most, and songs that need a manual match. The first station is Alt 102.1 (WRXL, Richmond).
See [operations](docs/operations.md) to install and use it, and
[Radio design](docs/design.md) for the decisions behind it.

Licensed under the [MIT License](LICENSE).

## Development

Run `bin/setup` after cloning; it needs Git and Python 3.9 or later. QMD and
direnv are optional, and setup reports skipped features. See the
[development workflow](docs/development-workflow.md) for this project's
commands and the [check schedule](docs/foundation/engineering-policy.md#checks)
for when to run `bin/check --documents-only`, `bin/check`, and
`bin/check --full`. The checks need ShellCheck; `bin/doctor` diagnoses setup.

Hosted projects record their primary remote in
[Git remotes](docs/git-remotes.md); `bin/setup` never publishes repositories.

## Knowledge

- [Memory](memory/README.md): durable guidance and non-derivable context.
- [Docs](docs/README.md): designs, decisions, research, and reference guides.
- [Task tracking](docs/foundation/task-tracking.md): install td, run `td init`
  in the primary checkout, and use `td status` or `td monitor` for progress.

Keep the existing issue tracker for shared work and link related issues from
td. This project uses [Project Starter](https://github.com/jubishop/project-starter);
`.project-starter.json` records its release.
