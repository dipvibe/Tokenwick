# Contributing

Thanks for helping! Issues and pull requests are welcome.

Found a security problem? Please report it privately. See [SECURITY.md](SECURITY.md).

1. Fork the repo and create a branch.
2. Make your change. Keep parsing and logic in `Sources/UsageCore` and add tests there.
3. Run `./scripts/test.sh` and `./scripts/bundle.sh`, then check that the app still works.
4. Open a pull request describing what changed and why.

Guidelines:
- **Privacy first.** Usage data stays local. The only network call is the optional plan-limits request to `api.anthropic.com`. Don't add analytics or other network calls.
- **Never write or refresh Claude Code's credentials.** Only read them, and never log them.
- **Parse leniently.** Claude Code's log format and the usage endpoint can change, so unknown or missing fields must never crash the app.
- **Treat every input as untrusted.** Logs, server responses and user files can be corrupted or crafted. Read files with `SafeFile` (size-capped, regular files only), clamp numbers before converting them to `Int`, and use saturating math for totals.
- **Pin GitHub Actions to full commit SHAs** (Dependabot keeps them updated).
- **Branding:** the app ships the Claude Code mascot as its menu bar icon (`assets/`). Don't add other Anthropic logos or make the app look official. It must stay clearly unaffiliated.
