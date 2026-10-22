# Status

Last review: 2026-10-22. `main` has PRs #1 (running sessions), #2 (status and credits), #3 (projects, models, heatmap) and #4 (mascot notes). 57 tests, CI (macOS runner) green on every PR. No open PRs or issues. Released 0.1.0 on 2026-10-22 (GitHub release + cask `juliobianco/tap/codexy`).

## Done (0.1.0, unreleased)
- SwiftPM package `CodexyCore` / `CodexyUsage` / `CodexyCoreTests`, copied from Claudy's provider-neutral code.
- Codex reader (`Usage.swift`): `codex app-server` → `account/rateLimits/read`; fallback to the last `token_count` event of the newest rollout file (plain or `.zst`). Tests with anonymised fixtures.
- Panel: 5h hero + bar, reset time, pace, week row, plan in the footer, 24h / week chart. Menu bar: two mini bars 5h / W.
- Own bundle id, data folder, log and defaults domain (`dev.julio.codexy`, `Application Support/Codexy`, `Logs/Codexy.log`).
- Details: turns and sessions, projects (click for models and busiest hours), models and the "When you use it" heatmap, 24 h or 7 days. `RolloutScanner` (`Projects.swift`) reads `~/.codex/sessions` and `archived_sessions` (`.jsonl` from where it stopped, `.jsonl.zst` once with `zstd`) and parses only `session_meta`, `turn_context` and `token_count` lines, picked by their first bytes. Tokens are the growth of the running totals; a fork's copy of its parent is skipped (same totals, same turn ids, its first seconds, its first count). Weight = fresh input + 0.1 × cached + 8 × output, × 0.2 for mini and 0.04 for nano models: an estimate, OpenAI does not say how each model counts against the plan. Scanned when Details opens, then every 15 min while it stays open. Export writes `codexy-projects.csv` again.
- OpenAI status (`Status.swift`): `status.openai.com/proxy/status.openai.com` (the incident.io JSON the page itself loads, has the groups), fallback `/api/v2/summary.json` (Statuspage shape, seen 2026-10-22 with only part of the components and no incidents). Only the "Codex" group (Codex Web, Codex API, CLI, VS Code extension) plus any component named "Codex" set the level. Every 2 minutes. The proxy URL is not a documented API: if it breaks, the fallback still gives the overall indicator.
- Credits (`CodexCredits`, `ResetCredits` in `Usage.swift`): shape from codex-rs `app-server-protocol` v2 (`GetAccountRateLimitsResponse`). Shown under the week row only when there is something (reset credits > 0, balance > 0 or unlimited). Session files carry `credits` but not reset credits.

## Mascot (`Pet.swift`, `Sources/CodexyUsage/pets/*.txt`)
Done:
- Four pets drawn from text files on the 18 x 12 grid: Theo (theo), Bit (bit), Coruja (owl), Livrinho (book). Each has `[normal] [slack] [crit] [sleep]` faces; they reuse the mascot brain (walk, hop, burrow, lie on the back).
- Theo is the default and first in the list. He is the owner's blue heeler, drawn from his photos (the photos stay out of the repo). The old id `heeler` still maps to him.
- Theo walks in side view (`[walk1] [walk2]`, mirrored when going left) and sits (`[sit]`) after ~3 s standing still, when idle or when a session waits for you. Side poses are optional per pet.
- Picker with a live preview in Settings → Aparência (Look) → Mascote. Own pets: `~/Library/Application Support/Codexy/pets/*.txt` (same id replaces a built-in one).
- `--pets DIR` renders every pet in every mood and pose; `CODEXY_PET=<id>` previews one in `--scenes`.

Pending:
- Side views (walk and sit) for Bit, Coruja and Livrinho: they walk facing forward.
- Accessories (skins) are hidden: they are drawn for Clawd's head. Redraw them for the new heads (or give each pet file a head anchor), then show them again.
- Clawd stays only in dev mode (`CODEXY_PET=clawd`): he is Anthropic's character and is not in the picker.

## Running sessions (`CodexSessions.swift`)
- Codex has no registry like `~/.claude/sessions`. A live thread keeps its rollout file open (codex-rs `rollout/src/recorder.rs`), so: list the user's processes named `codex*` (sysctl), their open files (libproc), keep `sessions/**/rollout-*.jsonl`. Checked live with codex-cli 0.163.0: the TUI starts an app-server child (`codex app-server --listen unix://`) and that child holds the file, so `pid` is the child, not the Terminal process. One process can hold several threads, so the id is the thread id. `source` says "vscode" even for the TUI; `originator` ("codex-tui") tells where a session came from. The Codex desktop app held no rollout file when checked.
- Read: the first line (`session_meta`: id, cwd, source) and the last 256 KB (1 MB if no turn marker): `task_started` / `task_complete` / `turn_aborted`, tool calls with no output yet. Never prompts or answers. Name: `session_index.jsonl` (renamed threads), else the folder.
- Sub-agents, guardian reviews and internal jobs (object `source`, `parent_thread_id`, `thread_source` ≠ user) are hidden.
- "Waiting for you" is a guess: approval prompts are not written to the file. A shell/patch call with no output, file quiet ≥ 3 s, no process started under codex since the call, and `approval_policy` ≠ never → waiting. `request_user_input` → waiting at once. Known misses: an auto-reviewer thinking for a few seconds looks like a prompt; an MCP tool approval is shown as working.

## Hidden or stubbed (the provider data is not wired yet)
- Usage profile (context size, skills, MCP) and the token stats window: Claude-only reports, no Codex counterpart. A tokens-per-day window could be built from the same rollout scan.
- CLI version/update row: removed (Claudy read `claude --version` and ran `claude update`). Status is back, from OpenAI.
- Settings: the Claude Code settings editor tab is gone. The Fable toggle is gone (status is back); "Running sessions" and "Plan and account" toggles stay.
- `Strings.swift`: the Claudy keys for removed features are gone (profile, tokens window, Fable, changes). Keys the tokens window needs are written again when it is built.

## Checked live vs not checked (as of 2026-10-22, codex-cli 0.163.0, Plus plan)
- Checked on the owner's Mac: limits from `app-server`; sessions list with a TUI open (1 session, idle, named by its thread title); Details with a real week (turns, sessions, projects, models, heatmap filled).
- Not checked: "waiting for you" (the owner runs with approval = never, so it never fires); the `.zst` path of the project scan (only with sample data: every file of the last 7 days was plain `.jsonl`); the project weights against the 5h bar; why 16 files changed in a week show as 6 sessions (likely forks and auto-reviews being merged or dropped, not verified); reset credits and paid credits with a non-zero value.

## Done after the review (branch `claude/extra-limits-version`, not merged)
- Extra limits (`ExtraLimit`, `reachedType` in `Usage.swift`; `ExtraLimitsLine` in `StatusUI.swift`). Real answer checked 2026-10-22 on Plus: `rateLimitsByLimitId` has only `codex`, `rateLimitReachedType` and `individualLimit` are null, `spendControlReached` false (not read). The extra-bucket and reached lines are tested with fixtures only.
- Distribution pieces: app icon with Theo (`scripts/make-icon.sh`, `Resources/AppIcon.icns`), `scripts/package.sh` (universal zip + sha256, tested: `x86_64 arm64`), README with pictures from `CODEXY_DEMO=1 ... -language en --readme docs/images` (made-up data). Still to do: release 0.1.0 on GitHub and the cask (both outward, need the owner's go).
- Codex version (`Version.swift`): `codex --version` plus GitHub `releases/latest` (tag `rust-v0.163.0`), every 6 h, in the Details footer.

## Done after 0.1.0 (branch `weekly-top-and-resets`, contribution)
- Week on top when Codex reports no 5h window (Plus on 2026-10-22: `primary` is the 10080-min window, `secondary` null): `AppModel.top` / `topIsWeek` feed the hero, its bar, the reset line, the hearts, the mascot and the bubble; the week row is hidden then. Menu bar: one `W` row that always shows the number.
- Resets card (`Resets.swift`, `ResetsLine` in `StatusUI.swift`): available from `rateLimitResetCredits.availableCount`; used counted by `ResetLog` from the longest window's snapshots (rollout `token_count` lines, oldest first, then the live read): a later window end whose window starts before the newest one ended, with less used, is one reset. Older windows seen again (stale session, second account) never count. Checked on a real history (Dec 2025 → Oct 2026, ~31k snapshots): 24 early resets, used % dropping to ~0, often from 100. First scan ~30 s at utility priority, then only files changed since (~0.04 s). Kept in `resets.json`.
- Not distinguishable: a global early reset from OpenAI counts as used. `ResetsTests` (7) ran through a harness on a Mac without Xcode (Command Line Tools ship no XCTest); CI runs them for real.

## Pending
Checks (cheap, no code unless they fail):
- "Waiting for you" in a session with approvals on (`codex -a on-request` or similar): does the "?" show, and does it clear after the answer?
- Codex desktop app sessions: it held no rollout file when checked. Find where its threads live (app-server daemon socket, `state_5.sqlite`?) before deciding to read them.
- Project weights: compare a few hours of the scan with how much the 5h bar moved.

Limits and data:
- Tokens window: tokens per day / per model from the same rollout scan (Claudy's token stats window has no Codex source otherwise).
- Keep one `codex app-server` running: measured 2026-10-22, one probe costs ~0.4 s of CPU a minute (about 0.7% of a core). Decided to keep the fresh process per probe; revisit only if it shows up in battery use.
- Exact "waiting": opt-in Codex `PermissionRequest`/`Stop` hook or the app-server daemon socket (`thread/loaded/list` reports `waitingOnApproval`).
- `~/.codex/config.toml` editor (like Claudy's `settings.json` tab): read-only view first; any write only after a click, keeping comments and order.

Mascot: see the Mascot section (side poses for Bit, Coruja and Livrinho; accessories; app icon with Theo).

Distribution:
- `scripts/package.sh` (universal zip + `.sha256`, ad-hoc signed), app icon (`Resources/AppIcon.icns`, with Theo), README pictures (`CODEXY_DEMO=1`, never real names or paths), first GitHub release, Homebrew cask in `juliobianco/homebrew-tap`. Copy the steps from Claudy's "Release" section.

Later:
- Claudex: Claude and Codex in one app. Wait until Codexy is released and both readers have settled, then decide between one app with two providers or a shared core package.

Housekeeping: the merged branches `claude/project-thread-{qwaplz,xtdazr,j1w6nj}` are still on GitHub (can be deleted).

## Next (proposed order for 2026-10-23)
1. The three checks above (waiting with approvals, desktop app, weights): they decide whether sessions and Details need fixes before a release.
2. Release 0.1.0 and the cask (icon, package.sh and README are done).
3. Then: tokens window, `config.toml` editor, side poses and accessories, long-lived app-server.
