# GHMenuBar

Native macOS menu bar app that syncs open GitHub pull requests through the local GitHub CLI.

Authenticate with `gh auth login`, then open the gear button in the menu to configure sync behavior, organization/repository filters, and optional agent-review prompts. Repository discovery uses the authenticated GitHub CLI account; no GitHub owner needs to be typed into the app.

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
