---
status: current
---

# Development workflow

This page records this project's own commands and integrations. Shared rules
are in the [foundation pages](foundation/README.md).

## Setup

```sh
bin/setup
bin/doctor
bin/check --full
```

Setup needs Git and Python 3.9 or later, and checks also need ShellCheck.
Radio is a Swift package with no third-party dependencies, so it has no
`bin/setup-application`; SwiftPM builds it on first use.
QMD and direnv are optional; setup reports skipped features. Install td and
run `td init` as described in [task tracking](foundation/task-tracking.md).
Create `.envrc` only when the project needs environment settings, and review
it before running `direnv allow`; search does not need it.

## Checks

Follow the [check schedule](foundation/engineering-policy.md#checks).
`bin/check-application` builds the package and runs its Swift Testing suite:

```sh
bin/check-application   # swift build --build-tests && swift test
swift test --filter SyncTests   # one suite while iterating
```

It needs macOS, so CI runs only `bin/check`, and `bin/check --full` runs
locally before each merge. The decision is in
[Radio design](design.md#run-application-checks-locally-not-in-ci). Tests fake
the network at `HTTPClient` and use a real SQLite database in a temporary
directory, so they never touch the live database or Apple Music.

When running the CLI from a checkout, set `RADIO_HOME` to a scratch directory
and `RADIO_ENV_FILE=/dev/null` so it uses its own database and sends no
Pushover alerts:

```sh
RADIO_HOME=/tmp/radio-dev RADIO_ENV_FILE=/dev/null swift run radio poll
```

## Runtime and toolchain versions

Radio needs macOS 26 or later and Swift 6.2 or later, declared in
`Package.swift` (`swift-tools-version: 6.2`, `.macOS(.v26)`) and enforced by
`bin/check-application`. Use the latest stable Xcode. The foundation tools are
Git and Python 3.9 or later for `bin/setup`, plus ShellCheck for `bin/check`.
Follow the
[version policy](foundation/engineering-policy.md#runtime-and-toolchain-versions).

## Deployment

Radio runs on the Mac mini. Deploy by running `bin/deploy` from an up-to-date
`main` checkout. It builds a release binary, installs it as `~/.local/bin/radio`,
and reloads both LaunchAgents. [Operations](operations.md) covers first-time
setup and day-to-day use.

Pushing never deploys. Changes to Markdown, tests, CI, or task tracking need no
`bin/deploy`. Run it after any change to `Package.swift`, `Sources/`, or
`bin/deploy`. When unsure, run it, since it's safe to repeat. Following the
[deployment policy](foundation/engineering-policy.md#deployment-decisions),
note when an install is skipped and which commit was last installed.

Before deploying a schema change, rehearse it on a copy of the live database.
Copy `radio.sqlite` with SQLite's `.backup` command into an empty scratch
directory, then run a command from the new checkout, such as
`RADIO_HOME=<scratch> RADIO_ENV_FILE=/dev/null swift run radio status`, so the
copy is migrated. Check the result against the live data before deploying.
The schema 3 and 4 migrations were rehearsed this way on 2026-10-13
(td-b818f2).

## Project Starter

`.project-starter.json` records the installed Project Starter release and the
hashes of its managed files. Update them with Project Starter's `bin/sync`,
and record any intentional local change as an override with its reason.
