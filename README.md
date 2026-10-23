# Codexy

**Your OpenAI Codex plan limits, at a glance in the Mac menu bar.**

Two mini bars (5h and week), a panel with the reset times, a pace forecast, your running Codex sessions and a 24h / week chart, with Theo, a pixel blue heeler, keeping you company. Built with Swift and SwiftUI, no third-party dependencies.

<p align="center">
  <img src="docs/images/panel-collapsed.png" width="280" alt="Compact panel with the 5h and week limits, Theo and running sessions">
  <img src="docs/images/panel-details.png" width="280" alt="Expanded panel with the usage chart, projects and models">
</p>

It reads the limits from your local Codex install (`codex app-server`, falling back to the last session file in `~/.codex/sessions`). No login of its own, no tokens spent, nothing leaves the Mac. Details are counted from Codex's own session files; no conversation text is read.

> A fan project, not affiliated with OpenAI. Codex belongs to OpenAI.

Status and plans: [docs/STATUS.md](docs/STATUS.md) · [Changelog](CHANGELOG.md)

## Install
**Requirements:** macOS 14 or later and the `codex` CLI installed and logged in.

Download `Codexy-<version>-macos.zip` from the [latest release](https://github.com/juliobianco/codexy/releases/latest), unzip it and move `Codexy.app` to `/Applications`. The app is ad-hoc signed and **not notarized**: if macOS blocks it, use **System Settings → Privacy & Security → Open Anyway**, or:
```sh
xattr -dr com.apple.quarantine /Applications/Codexy.app
```
Each release has a `.sha256` file to compare with `shasum -a 256 Codexy-<version>-macos.zip`.

### Build from source
```sh
S=$HOME/Library/Caches/codexy-build
swift build --scratch-path $S && swift test --scratch-path $S
./scripts/bundle.sh        # ~/Applications/Codexy.app
```
Build outside `~/Documents`: its file provider adds attributes that break `codesign`.

## Orcy, for Orca

This package also builds **Orcy**, a sibling app for [Orca](https://github.com/stablyai/orca): agents working and waiting for you, worktrees by state, today and the last 7 days, with a pixel orca. See [docs/ORCY.md](docs/ORCY.md); build it with `./scripts/bundle-orcy.sh`.

## Credits
Built on [Claudy Usage](https://github.com/juliobianco/claudy-usage-mac), a Swift port of [Enhed/clawd-usage-winwidget](https://github.com/Enhed/clawd-usage-winwidget) (both MIT).
