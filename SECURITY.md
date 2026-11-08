# Security policy

## Reporting a vulnerability

Please **don't open a public issue** for security problems.

Report privately through GitHub instead: go to this repo's **Security** tab, then **Report a vulnerability**. Include steps to reproduce, and what an attacker could do. You'll get a reply within a week. Fixes for confirmed issues are released as soon as possible, and you'll be credited unless you'd rather not be.

Only the latest release is supported. Please update before reporting.

## How the app handles your data

Quota Goblin reads your Claude Code login, so it's built to be careful with it:

- **Login token:** read from the macOS Keychain (`Claude Code-credentials`) using Apple's `/usr/bin/security` tool. It's never written anywhere, never logged, and never refreshed or modified. It's held only in memory.
- **Network:** the app makes one kind of request, `GET https://api.anthropic.com/api/oauth/usage`, over HTTPS:
  - redirects are refused, so the token can't be forwarded elsewhere
  - nothing is cached to disk and no cookies are stored
  - there are no analytics, telemetry or other connections
- **Local data:** token totals are computed from Claude Code's logs and cached in `~/Library/Application Support/QuotaGoblin/`. That folder and file are readable only by you. Logs are only read, never modified.
- **Untrusted input:** log files, the server response and the optional custom icon are all parsed defensively:
  - size limits on files and on individual log lines
  - only regular files are read; FIFOs and devices are refused
  - numbers are clamped, so a corrupted log or bad response can't crash the app or exhaust memory
- **The app itself:**
  - signed with the hardened runtime, with no extra entitlements
  - no third-party dependencies
  - release builds come only from GitHub Actions, with SHA-pinned actions and signed build-provenance attestations

## Verifying a download

Each release includes a SHA-256 checksum for each download: `QuotaGoblin.zip.sha256` (the installer checks it automatically) and `QuotaGoblin.dmg.sha256` (check it with `shasum -a 256 QuotaGoblin.dmg`). To confirm a download was built by this repo's GitHub Actions from a specific commit, use the [GitHub CLI](https://cli.github.com):

```sh
gh attestation verify QuotaGoblin.dmg --repo dipvibe/claude-goblin-menubar
gh attestation verify QuotaGoblin.zip --repo dipvibe/claude-goblin-menubar
```
