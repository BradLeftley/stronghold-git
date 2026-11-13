# Stronghold

A native macOS Git client (SwiftUI) in the style of Tower: a GUI over the real `git`, with multiple accounts (GitHub, GitLab, Bitbucket, self-hosted). Tokens are stored only in the macOS Keychain.

Status: early development. The app can open a repository and show its changes, history, branches, remotes and tags.

## Layout

| Path | What it is |
| --- | --- |
| `Packages/GitEngine` | The Git engine. It runs the system `git` (no libgit2) and parses machine-readable output: porcelain v2 with `-z`, and `--format` strings with NUL separators. It has an async API and no UI. |
| `Packages/GitEngine/Sources/GitTestSupport` | `TemporaryRepository`, a throwaway repo in a temp folder with isolated config and fixed timestamps, used by every test target. |
| `Packages/StrongholdCore` | The app's observable models (`AppModel`, `RepositoryModel`) and presentation helpers. They are kept outside the app target so they can be unit tested. |
| `Stronghold/` | The SwiftUI app target: views only. |
| `StrongholdUITests/` | UI tests that launch the real app against fixture repos. |
| `scripts/generate-xcodeproj.py` | Regenerates `Stronghold.xcodeproj`. Source folders are synchronised, so you only need it to change targets, settings or schemes. |

## How git is run

- `GitLocator` uses the git in Settings (later) or `STRONGHOLD_GIT` if set. Otherwise it tries `/opt/homebrew/bin/git`, then `/usr/local/bin/git`, then `/usr/bin/git`. Git 2.35 or later is required.
- Every call runs non-interactively: `GIT_TERMINAL_PROMPT=0`, no pager or editor, `LC_ALL=C`, and `GIT_OPTIONAL_LOCKS=0`. `-c` overrides pin output formats (quotepath, colour, diff prefixes, `log.showSignature`), so a user's config can't break parsing.
- `GIT_DIR`, `GIT_WORK_TREE` and askpass variables inherited from the parent process are removed.
- User-supplied revisions are passed after `--end-of-options` and paths after `--`, so they can never be read as options.
- Cancelling the Swift task terminates the git process.

## Build and test

Requires Xcode 26 or later. The app targets macOS 15.

```sh
# Everything that runs unattended: engine and core tests (66 tests)
xcodebuild test -project Stronghold.xcodeproj -scheme Stronghold -destination 'platform=macOS' -enableCodeCoverage YES

# Engine or core on their own
(cd Packages/GitEngine && swift test)
(cd Packages/StrongholdCore && swift test)

# UI tests need macOS Automation Mode enabled (one-time, needs an admin):
#   sudo automationmodetool enable-automationmode-without-authentication
xcodebuild test -project Stronghold.xcodeproj -scheme StrongholdUITests -destination 'platform=macOS'
```

The app makes no sound when `ILLUMI_SCRIPTED=1`. The test scheme and the UI tests set this variable.

Debug-build hooks for automation: `STRONGHOLD_OPEN_REPOSITORY=<path>` opens a repo at launch. `STRONGHOLD_SECTION=history` selects History. `STRONGHOLD_SNAPSHOT_PATH=<png>` renders the window to a PNG and quits.

The app is not sandboxed, because it has to run the user's git, SSH and credential helpers. It is signed to run locally until a Developer ID is set up.
