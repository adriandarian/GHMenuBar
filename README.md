# GHMenuBar

Native macOS menu bar app that syncs open GitHub pull requests through the local GitHub CLI.

Authenticate with `gh auth login`, then open the gear button in the menu to configure sync behavior, organization/repository filters, and optional agent-review prompts. Repository discovery uses the authenticated GitHub CLI account; no GitHub owner needs to be typed into the app.

Automatic refresh uses your configured interval while the menu or settings are open, and at least 15 minutes between idle refreshes. Sync refreshes only watched repositories and retains complete cached review data if an individual repository fails. The app reuses a verified account identity for an hour, checks the local CLI account for switches, and treats rate limits or network errors as temporary availability problems.

GitHub requests from the app and its settings share a serialized queue and respect quota cooldowns. Settings → General → GitHub CLI shows this app’s HTTP requests over the last hour, including pagination and retries; hover for the last observed shared account quotas. GraphQL request counts are not point costs: cost is recorded only when the response explicitly provides it. Local diagnostics retain account names and numeric request/quota information, never HTTP bodies or credentials. Requests from separately launched review agents and other apps are outside this counter.

## Requirements

- macOS 14 or newer
- Xcode/Swift toolchain
- GitHub CLI installed as `gh`
- Authenticated GitHub CLI session:

```bash
gh auth login -h github.com
```

## Development

```bash
scripts/setup.sh
swift test
swift build
```

## Codex Environment

Use these commands in the local environment settings:

Setup script:

```bash
./scripts/setup.sh
```

Cleanup script:

```bash
./scripts/cleanup.sh
```

Recommended actions:

| Name | Action script |
| --- | --- |
| Check | `./scripts/check.sh` |
| Build | `./scripts/build.sh` |
| Package | `./scripts/package_app.sh` |
| Run App | `./scripts/run_app.sh` |

## Build The App Bundle

```bash
swift build -c release
scripts/package_app.sh
```

The packaged app is written to `outputs/GHMenuBar.app`.
