# Quota Goblin: Claude Code usage in your Mac menu bar

> ### 🌙 The backstory
>
> It was 3 a.m. on a random Saturday night, and I had an exam in the morning. A responsible person would have been studying.
>
> My ADHD brain had other plans: *"You know what would be cool? Seeing your Claude usage right in the menu bar."* So instead of studying, I vibe-coded this.
>
> What you're looking at is a **premium, 100% vibe-coded product**, and you get it for **freeeee**. You're welcome.
>
> If it helps you, amazing. If something breaks, remember it was 3 a.m. Either way, please [leave a suggestion or open an issue](../../issues). I have plans for this thing… muhehehe. 😈
>
> *(Exam results: still pending.)*

A small macOS menu bar app that shows your Claude plan's **current session (5-hour) and weekly limits** and your **Claude Code token usage**.

- **Hover** the icon for a quick summary.
- **Click** it to open a panel showing:
  - **Current session (5h)** and **weekly** limits: % used, with a countdown to each reset.
  - **Extra usage**: whether it's on, and if it is, how much you've spent this month against your monthly limit. Extra usage is the pay-as-you-go credit that keeps Claude working after you reach your plan limits.
  - **Claude Code tokens**: today, the last 7 days, this month and all time. The big number is input + output + cache writes, with cache reads on a line of their own (see [How it works](#how-it-works)).
  - The models you used in the last 7 days, by name (e.g. "Opus 5.5").
- By default the menu bar shows only the icon. Tick **Show session · weekly % in menu bar** in the panel to show the percentages next to it (e.g. `✦ 23% · 41%`).

> **Not affiliated with Anthropic.** "Claude", "Claude Code" and the Claude Code mascot are trademarks of Anthropic. This is an independent, community-made tool.

## How it works

| Data | Source | Leaves your Mac? |
|---|---|---|
| Token usage | Claude Code's local session logs in `~/.claude/projects/**/*.jsonl` (plus `$CLAUDE_CONFIG_DIR` and `~/.config/claude`) | No |
| Session & weekly limits, extra usage | The endpoint Claude Code's `/usage` command uses, signed in with your existing Claude Code login | One small request to `api.anthropic.com` when you open the panel or hover the icon (at most once a minute), and once right after each reset. If you show the % in the menu bar, also every 5 minutes. |

**Built to be light**

| | Typical |
|---|---|
| Memory before you first open the panel | ~15 MB |
| Memory after the panel has been opened | ~28 MB (macOS keeps SwiftUI, which draws the panel, loaded until the app quits) |
| Memory while the panel opens | briefly up to ~80 MB, back down within 2 seconds of closing |
| CPU while Claude Code is busy (panel closed) | ~0.03 s per 2 minutes |
| CPU while Claude Code is idle (panel closed) | 0 |
| CPU to open the panel | ~0.2 s each time |

How it gets there:
- **No polling.** macOS tells the app when a log file changes (FSEvents), and it reads only the new lines of that one file.
- **No idle timers.** The panel and tooltip are built only when you open or hover them, and the panel is freed completely when it closes.
- **Limits are fetched only when needed:** when you look, right after a reset, or every 5 minutes if you show the % in the menu bar.
- **Low-priority scanning.** Logs are scanned at background priority, which runs on the efficiency cores on Apple silicon.

**Token usage**
- New lines are read incrementally, in small chunks, so even large logs use little memory.
- **The headline number leaves out cache reads.** Each time Claude Code replies, it re-reads the conversation so far from a cache. Those cache reads are usually over 90% of all tokens, but they cost about a tenth as much and count far less toward your limits, so including them would make your usage look dozens of times bigger. They're shown on their own line instead.
- Each response is counted once (deduplicated by message ID and request ID), even if it appears in several files.
- Totals are kept in the app's own cache in `~/Library/Application Support/QuotaGoblin/`, readable only by you. Claude Code deletes logs after 30 days by default, but your totals stay. **All time** therefore starts from the oldest log Claude Code still had when you first ran the app.
- Days follow your local time zone.
- Only usage that Claude Code logs is counted. Chats on claude.ai or in the desktop app aren't included.

**Session & weekly limits**
- ⚠️ The endpoint is **unofficial and undocumented**, so Anthropic can change or remove it at any time. If it stops working, the limits section shows a message and token stats keep working. You can turn it off in the panel.
- Your login is read from the macOS Keychain (`Claude Code-credentials`) using the same `security` tool Claude Code itself uses.
- The token is never refreshed, written, logged or sent anywhere except `api.anthropic.com` over HTTPS. Redirects are refused, and responses aren't cached to disk.
- If a refresh fails, the last good numbers stay visible with a note saying why they may be out of date.
- If the login has expired, open Claude Code once and it will refresh.

## Install

Requires macOS 14 (Sonoma) or later, on Apple Silicon or Intel. For the numbers to appear, you also need [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and signed in.

### One command (recommended)

Paste this into Terminal:

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/dipvibe/claude-goblin-menubar/main/scripts/install.sh | bash
```

The installer:
1. downloads the latest release
2. verifies it: SHA-256 checksum, zip contents, bundle ID and code signature (if anything's off, nothing is installed)
3. installs it to `/Applications` (or `~/Applications` if you can't write there)
4. opens it

The icon appears in your menu bar. Run the same command again to update.

To uninstall (this also removes the app's saved data, but never your Claude Code logs):

```sh
curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/dipvibe/claude-goblin-menubar/main/scripts/install.sh | bash -s -- --uninstall
```

Prefer to read a script before running it? Open [`scripts/install.sh`](scripts/install.sh) first. It's short.

### Ask Claude Code to install it

In Claude Code, say:

> Install Quota Goblin by running `curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/dipvibe/claude-goblin-menubar/main/scripts/install.sh | bash`

Claude Code will ask your permission, run it, and the icon will appear in your menu bar.

### Download the app (DMG)

1. Download `QuotaGoblin.dmg` from [Releases](https://github.com/dipvibe/claude-goblin-menubar/releases/latest).
2. Open it and drag **QuotaGoblin** onto the **Applications** folder.
3. Open it from Applications. The first time, macOS blocks it: the app isn't notarized by Apple, which needs a paid developer account. Go to **System Settings → Privacy & Security** and click **Open Anyway**. You only do this once.

The one-command installer avoids step 3. A `QuotaGoblin.zip` of the same app is on the Releases page too.

### Build from source

You need either Xcode or just the Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/dipvibe/claude-goblin-menubar.git
cd claude-goblin-menubar
./scripts/bundle.sh
open build/QuotaGoblin.app
```

To keep it, move `build/QuotaGoblin.app` to `/Applications`, then tick **Launch at login** in the panel.

### For AI agents

If you're an AI coding agent asked to install this app for a user:

1. **Requirements:** macOS 14 or later (`sw_vers -productVersion`). No other dependencies.
2. **Install or update:** `curl --proto '=https' --tlsv1.2 -fsSL https://raw.githubusercontent.com/dipvibe/claude-goblin-menubar/main/scripts/install.sh | bash`. It exits non-zero with a clear message on any failure, and installs nothing if verification fails.
3. **Check it worked:** `pgrep -x QuotaGoblin` prints a process ID once it's running.
4. **Options:** `QG_INSTALL_DIR=<dir>` installs elsewhere. `QG_NO_LAUNCH=1` skips opening the app.
5. **Uninstall:** add `-s -- --uninstall` after `bash`.
6. **Tell the user:** the icon is in the menu bar. Click it for details. Tick "Launch at login" to start it automatically. Limits need Claude Code to be signed in.
7. **Check usage before long tasks:** run `/Applications/QuotaGoblin.app/Contents/MacOS/QuotaGoblin --status`. It prints JSON like `{"session":{"percent_used":84,"resets_at":"…"},"weekly":{…},"extra_usage":{"enabled":false,…}}`, or `{"error":"…"}` with exit code 1. If the session is nearly used up, pause until `resets_at`. It never prints the login token.

## Command line

```sh
/Applications/QuotaGoblin.app/Contents/MacOS/QuotaGoblin --status
```

This prints your current session and weekly limits and your extra usage as JSON, then exits. Use it in scripts, status lines, or to let an AI agent pace itself. It prints only percentages, reset times and amounts spent, never your login token.

## Custom menu bar icon

The app shows the little orange Claude Code mascot (from [`assets/`](assets)) in your menu bar. To use a different icon, put an image named `MenuBarIcon` in `~/Library/Application Support/QuotaGoblin/`, then quit and reopen the app. No rebuild is needed.

- **Formats:** PDF, SVG or PNG, up to 2 MB. It's scaled to fit 18×18 pt.
- **Looks best:** a square image with a transparent background.
- **Color:** name it `MenuBarIcon.png` to show it in black or white so it matches the menu bar in light and dark mode. Name it `MenuBarIcon-color.png` to keep its colors.

To go back to the mascot, delete your file and reopen the app.

## Troubleshooting

| Problem | Fix |
|---|---|
| I can't see the icon | macOS hides menu bar icons that don't fit, and on MacBooks with a notch they can end up behind it. Quit a few other menu bar apps, or hold ⌘ and drag the icon further right. Run `pgrep -x QuotaGoblin` to check it's running. |
| "Claude Code login expired" | Open Claude Code and send any message. It refreshes its login, and the app picks it up within a few minutes. |
| "Sign in to Claude Code to see your limits" | Install [Claude Code](https://docs.claude.com/en/docs/claude-code) and run `claude` to sign in. |
| "No Claude Code usage found yet" | Use Claude Code once. Token stats appear within a minute. |
| Limits show an error, but token stats work | The limits come from an unofficial endpoint that may have changed. Please [open an issue](../../issues). |
| macOS says the app "can't be opened" | You downloaded the DMG or zip in a browser. Go to System Settings → Privacy & Security → **Open Anyway** (once), or use the one-command installer. |
| I want it to start automatically | Click the icon and tick **Launch at login**. |
| The menu bar stays visible over a full-screen app | Fixed in current versions: closing the panel hands focus back to your app, so the menu bar auto-hides again. If it still happens, quit Quota Goblin and check **System Settings → Menu Bar → Automatically hide and show the menu bar** ("In Full Screen Only" is the macOS default). |

## Development

```sh
./scripts/test.sh                       # unit tests (Swift Testing)
UNIVERSAL=0 ./scripts/bundle.sh         # faster app build, this Mac's architecture only
./scripts/dmg.sh                        # disk image of build/QuotaGoblin.app
swift build --build-system native       # debug build
.build/debug/QuotaGoblin             # run without bundling (launch at login won't work)
```

With only the Command Line Tools installed, plain `swift build` fails ("Unknown error parsing property list") and `swift test` can't find Swift Testing. Use `--build-system native` and the scripts above, which handle both.

To test the installer without publishing a release, point it at a local build:

```sh
UNIVERSAL=0 ./scripts/bundle.sh
QG_DOWNLOAD_BASE="file://$PWD/build" QG_INSTALL_DIR=/tmp/cub-test QG_NO_LAUNCH=1 bash scripts/install.sh
```

Code layout:
- `Sources/UsageCore`: log scanning, aggregation, the plan-limits client, safe file reading and formatting. No UI, and fully unit-tested (including corrupted and hostile input).
- `Sources/QuotaGoblin`: the app. An AppKit `NSStatusItem` (for the hover tooltip) and an `NSPopover` hosting the SwiftUI panel, which is created when it opens and released when it closes.
- `assets/`: the bundled menu bar icon.
- `scripts/`: build, test, packaging and install scripts.

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

- The app reads your Claude Code login only to fetch your limits, and sends it only to `api.anthropic.com`.
- It has no analytics, no third-party dependencies, and nothing sensitive is written to disk.
- Releases are built by GitHub Actions, with a checksum and a signed provenance attestation. You can check where a download came from with `gh attestation verify QuotaGoblin.dmg --repo dipvibe/claude-goblin-menubar` (or `.zip`).

See [SECURITY.md](SECURITY.md) for the details, and to **report a vulnerability privately**.

## License

[MIT](LICENSE)
