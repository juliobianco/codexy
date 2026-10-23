# Changelog

## [Unreleased]
### Added
- Orcy 0.1.0, a second app in the package for Orca (the agent orchestrator): a menu bar orca with agents working (▶) and waiting for you (?), worktrees as Waiting for you / Running / Stopped, today's tasks, agents and agent time, the last 7 days. Read-only: `orca worktree ps --json` and `orca terminal list --json` every 10 s while something works or the panel is open (30 s when quiet), orca-stats.json and orchestration.db every minute. Shows the worktrees Orca hides (it did not create them: `worktree ps` omits them), who runs in each terminal (an Open agents section for idle codex, claude, opencode…), the repo name when there are several, and counts an opencode session running in a worktree's folder as working. Reuses `CodexyCore`. See docs/ORCY.md.

## [0.1.0] - 2026-10-22
### Added
- First version, built from Claudy Usage: Codex 5h and weekly limits in the menu bar and the panel.
- Reads `codex app-server` (`account/rateLimits/read`), with the newest session file in `~/.codex/sessions` as fallback.
- Four mascots drawn from text files, picked in Settings → Aparência (Look) with a live preview: Theo (default), Bit, Coruja and Livrinho. Each has a normal, slack (low use), near-the-limit and sleeping face. Your own go in `~/Library/Application Support/Codexy/pets`.
- Theo is the owner's blue heeler, drawn from his photos. He walks in side view (two steps, turning with the direction) and sits after a few seconds standing still, also while a session waits for you.
- Plan name in the panel footer; a note when the numbers come from a session file.
- Details: turns and sessions, projects (click one for its models and busiest hours), models and the "When you use it" heatmap, for 24 hours or 7 days. Counted on this Mac from Codex's own session files; no conversation text is read.
- Running Codex sessions in the panel (project, branch / worktree, working / waiting for you / idle), the blinking "?" and the optional notification when one waits for you. Read from the rollout files the `codex` processes keep open; "waiting" is inferred, since Codex does not write approval prompts to disk.
- OpenAI status in the panel and the floating card, Codex only: the components of the "Codex" group on status.openai.com set the dot; other OpenAI services being off is mentioned, not alarmed. A click opens the page. Switch in Settings → Look.
- Reset credits and paid credits under the week row, when Codex reports any (`rateLimitResetCredits`, `rateLimits.credits`): how many, and when the next one expires. Read-only: Codexy never redeems one.
- Extra limits: when Codex reports other buckets (`rateLimitsByLimitId`, a model or feature with its own limits) each gets a line under the week row, and `rateLimitReachedType` shows which limit stopped you. Plus plans report only the main bucket today, so this is covered by tests, not yet seen live.
- Codex version in the Details footer, with "update available" when GitHub's latest release is newer and the command to run in a terminal. Show only: Codexy never updates Codex.
- App icon with Theo, `scripts/package.sh` (universal ad-hoc signed zip with SHA-256) and a README with pictures.
- CI on a macOS runner: `swift build` and `swift test` on every pull request.

### Fixed
- `scripts/bundle.sh` copied a resource bundle that does not exist (`CodexyUsage_CodexyUsage.bundle`); SwiftPM names it `Codexy_CodexyUsage.bundle` after the package, so the script stopped halfway and the app would not open.

### Not yet
- Side views for Bit, Coruja and Livrinho (they walk facing forward); accessories redrawn for the new heads (hidden for now); an app icon with Theo. Clawd, Claudy's crab, is only in dev mode.
