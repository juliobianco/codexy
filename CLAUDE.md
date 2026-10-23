# Codexy (macOS)

Menu bar app that shows OpenAI Codex plan limits (5h and weekly). Built from [Claudy Usage](https://github.com/juliobianco/claudy-usage-mac)
(`../claudy-usage-mac`), itself a port of [Enhed/clawd-usage-winwidget](https://github.com/Enhed/clawd-usage-winwidget). Both MIT.

**Claudy is a separate project: read and copy from `../claudy-usage-mac`, never write, build or run git there.**

Status and backlog: `docs/STATUS.md`. Keep it and `CHANGELOG.md` (*Unreleased*) current with every change.

## Layout
- `Sources/CodexyCore`: no UI, testable. `Usage.swift` (Codex reader: app-server + session-file fallback, `CodexLimits`), `Sessions.swift` (git reader + neutral `AgentSession`), `History.swift` (5h/week samples), `Projects.swift` (`RolloutScanner`: projects, models, turns from the rollout files), `Pace`, `Alerts`, `Export`, `Format`, `ChartMarks`, `Sky`, `Mascot` (movement brain) + `Clawd` (frame model; Clawd himself is dev-only), `Pet.swift` (mascots from text files).
- `Sources/CodexyUsage/pets/*.txt`: the four mascots, 18 x 12 grid, moods `[normal] [slack] [crit] [sleep]`, optional side poses `[walk1] [walk2] [sit]` facing right (mirrored for left). `--pets DIR` renders them all; `CODEXY_PET=<id>` previews one in `--scenes`.
- `Sources/CodexyUsage`: SwiftUI, same files as Claudy. `Model.swift` polls `CodexCLI.fetchUsage()` once a minute.
- Data: `~/Library/Application Support/Codexy`, log `~/Library/Logs/Codexy.log`, bundle id `dev.julio.codexy`. Never share files or defaults with Claudy.

## Orcy (second app in the package)
- `Sources/OrcyCore` (Orca readers: `Orca.swift`, `OrcaHistory.swift`, `OrcyLog`), `Sources/Orcy` (UI, a trimmed copy of `CodexyUsage` plus `pets/orca.txt`), `Tests/OrcyCoreTests`. Orcy imports `CodexyCore` for the mascot, pets, sky and format: a change there changes both apps.
- `scripts/bundle-orcy.sh`, `scripts/make-icon-orcy.sh`, `Resources/Orcy/` (icon, VERSION). Details and data sources: `docs/ORCY.md`.
- Never parse prompts, agent messages, tool input or terminal previews from Orca's answers; never call the Orca CLI while Orca is closed.
- `worktree ps` omits worktrees Orca did not create; `terminal list` (with `agentIdentity`) has their terminals and `OrcaParser.merge` rebuilds them. Each read is two CLI calls (~0.3 s CPU), hence the adaptive poll (10 s busy, 30 s quiet).

## Where the numbers come from
1. `codex app-server` over stdio (JSON-RPC lines): `initialize` (clientInfo name `codexy`), `initialized`, `account/rateLimits/read`.
   Answer: `result.rateLimits.{primary,secondary}.{usedPercent, windowDurationMins, resetsAt}` + `planType`. No model call.
2. Fallback: the newest `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` (older ones are `.jsonl.zst`, read with `zstd -dc` if installed),
   last `event_msg` of type `token_count`: `payload.rate_limits.{primary,secondary}.{used_percent, window_minutes, resets_at}` + `plan_type`.
   The panel says "from a session file" then. A reset already past means that window started over: 0%.
- Windows are picked by length (≤ 1 day = 5h bar, longer = week), not by primary/secondary order.
- Never print or store prompts, conversation content, `auth.json`, emails or account ids.

## Commands
```
S=$HOME/Library/Caches/codexy-build
swift build --scratch-path $S
swift test  --scratch-path $S
$S/debug/CodexyUsage --snapshot DIR     # panel.png + bar.png with live data (CODEXY_DETAILS=1 opens the chart, CODEXY_NO_FLOAT=1)
./scripts/bundle.sh                     # builds and signs ~/Applications/Codexy.app
```
Other dev modes and env vars are the same as Claudy's, with `CODEXY_` instead of `CLAUDY_`.

## Gotchas (from Claudy)
- **Build outside `~/Documents`** (`--scratch-path`): its file provider adds xattrs and `codesign` fails.
- Snapshots must not write to real files (`AppModel.persist = false`).
- `MenuBarExtra` drops custom shapes: the mini bars are an `ImageRenderer` bitmap.
- SwiftPM resources: `bundle.sh` copies `Codexy_CodexyUsage.bundle` (`<package>_<target>`: the package is "Codexy") into `Contents/Resources`.
- A menu bar app from Finder has a bare PATH: `CodexCLI` looks in `~/.local/bin`, Homebrew and `/usr/local/bin`.

## Text
Never hard-code a user-facing string: add it to `Strings.swift` in en and pt (`L.t("key")`).

## Routine
Git identity is not configured on this Mac: commit with `git -c user.name=... -c user.email=...` for the project owner, with the Co-Authored-By line. Remote: github.com/juliobianco/codexy (public). Never force-push.
