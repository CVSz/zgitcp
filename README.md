# Git Control Panel

A unified **Git + GitHub + Gitea** control panel script for day-to-day repository workflows, releases, packaging, lightweight CI automation, and basic repo health checks.

- Script: `git-control-panel.sh`
- Config file: `~/.git-control.conf`
- Log file: `~/.git-control.log`
- Mode support: interactive menu + CLI subcommands
- Optional machine-readable output: `--json`

---

## Table of Contents

1. [What this script does](#what-this-script-does)
2. [Key features](#key-features)
3. [Requirements](#requirements)
4. [Installation](#installation)
5. [Quick start](#quick-start)
6. [Configuration](#configuration)
7. [Global options](#global-options)
8. [CLI commands](#cli-commands)
9. [Interactive menu](#interactive-menu)
10. [Release and artifact workflow](#release-and-artifact-workflow)
11. [Authentication workflow](#authentication-workflow)
12. [JSON output examples](#json-output-examples)
13. [Logging](#logging)
14. [CI mode behavior](#ci-mode-behavior)
15. [Environment variables](#environment-variables)
16. [Troubleshooting](#troubleshooting)
17. [Known behaviors and caveats](#known-behaviors-and-caveats)
18. [Security notes](#security-notes)
19. [License](#license)

---

## What this script does

`git-control-panel.sh` wraps common Git operations and release tasks into a single entrypoint. It can:

- Run common Git commands (`status`, `add`, `commit`, `push`, `pull`).
- Maintain a config file with defaults (remote, branch, version bump strategy, log level, CI mode).
- Bump semantic versions in a `VERSION` file and append release notes to `CHANGELOG.md`.
- Build artifacts (`zip` or `tar.gz`) and upload them to GitHub Releases (`gh`) or Gitea Releases (`tea`).
- Install helper tools (`gh`, `tea`) and even a local Gitea server.
- Perform authentication with token prompts for GitHub and Gitea.
- Run `self-check` diagnostics.
- Run an interactive menu for one-click operations.

---

## Key features

- **Config persistence** in `~/.git-control.conf` (auto-created with secure permissions).
- **Structured logging** with levels: `debug`, `info`, `warn`, `error`, `quiet`.
- **CI-friendly mode** (`--ci`) that removes prompts and auto-confirms where possible.
- **Dry-run support** for packaging and release steps.
- **JSON output** (`--json`) for automation pipelines.
- **Robust `tea` installer** with architecture detection, retries, optional URL override, and optional checksum verification.
- **Autoheal mode** for detached HEAD, missing remote setup, unstaged changes, and push/rebase recovery.

---

## Requirements

### Required

- Bash (script uses `#!/usr/bin/env bash` and strict mode).
- Git.

### Optional (feature-dependent)

- `gh` (GitHub CLI): required for GitHub release upload and GitHub auth helper.
- `tea` (Gitea CLI): required for Gitea release upload and Gitea auth helper.
- `zip`: required if you package artifacts in zip format.
- `tar`: required for `tar.gz`/`tgz` packaging.
- `sudo`, `curl`, `wget`, `apt-get`: used by installer flows.
- `openssh-server`: installed automatically when running SSH server setup.

---

## Installation

1. Place `git-control-panel.sh` in your repository or a directory on your `PATH`.
2. Make it executable:

```bash
chmod +x git-control-panel.sh
```

3. (Optional) Add an alias:

```bash
alias gcp='./git-control-panel.sh'
```

---

## Quick start

### Open interactive mode

```bash
./git-control-panel.sh
```

### Show CLI help

```bash
./git-control-panel.sh help
```

### Typical non-interactive flow

```bash
./git-control-panel.sh status
./git-control-panel.sh add .
./git-control-panel.sh commit -m "feat: update docs"
./git-control-panel.sh push
```

---

## Configuration

Configuration is stored in:

```text
~/.git-control.conf
```

Auto-generated defaults:

- `REMOTE="origin"`
- `BRANCH="main"`
- `BUMP_TYPE="patch"`
- `LOG_LEVEL="info"`
- `CI_MODE="false"`

You can edit config from the interactive menu (option 21) or by running:

```bash
./git-control-panel.sh config
```

---

## Global options

These flags can appear before a command:

- `--dry-run` — simulate actions without changing state.
- `--log-level LEVEL` — override log level (`debug|info|warn|error|quiet`).
- `--ci` — non-interactive CI mode.
- `--no-ci` — force interactive behavior back on.
- `--json` — machine-readable output for selected commands.

Example:

```bash
./git-control-panel.sh --ci --json self-check
```

---

## CLI commands

### Core Git

- `status` — `git status`
- `add <paths>` — `git add <paths>`
- `commit -m "message"` — create commit
- `push` — push to configured remote/branch
- `pull` — pull from configured remote/branch

### Release and packaging

- `release <github|gitea> [--dry-run] [--artifact zip|tar] [--name NAME] [--paths "p1 p2"]`
- `package --format zip|tar --name NAME --paths "p1 p2" [--dry-run]`
- `bump [major|minor|patch]`
- `changelog`

### Tooling and auth

- `install gh|tea|gitea`
- `install ssh`
- `auth gh|gitea`
- `setup-all [--remote NAME] [--branch NAME] [--github-url URL] [--gitea-url URL] [--skip-auth]`

### Maintenance and diagnostics

- `autoheal`
- `self-check`
- `config`
- `set-log-level <level>`
- `set-ci-mode <true|false>`
- `help`

---

## Interactive menu

Running without arguments opens a full-screen interactive panel with options for:

- Standard Git operations
- Branch and tag management
- One-click release flows for GitHub/Gitea
- Tool installation (`gh`, `tea`, Gitea server)
- Workflow trigger (`gh workflow run`)
- Config management
- Authentication helpers
- Autoheal and self-check
- Full automated bootstrap: config defaults + `gh`/`tea` installers + OpenSSH server + remote wiring for GitHub/Gitea

### Full automated setup (new)

You can run a one-shot setup to prepare a machine for GitHub/Gitea workflows:

```bash
./git-control-panel.sh setup-all \
  --remote origin \
  --branch main \
  --github-url git@github.com:your-org/your-repo.git \
  --gitea-url git@gitea.example.com:your-org/your-repo.git
```

What it does:

1. Saves default `REMOTE`/`BRANCH` into `~/.git-control.conf`.
2. Installs GitHub CLI (`gh`) and Gitea CLI (`tea`) if missing.
3. Installs and enables `openssh-server`.
4. Adds/updates git remotes named `github` and `gitea` (when URLs are provided).
5. Runs GitHub/Gitea token auth prompts unless `--skip-auth` is set.

Use this mode for guided execution when you prefer prompts over CLI arguments.

---

## Release and artifact workflow

### Release flow (high level)

When release flow executes, it does the following:

1. Verifies the current directory is a git repository.
2. Bumps version using configured/default bump strategy.
3. Appends commit summaries to `CHANGELOG.md`.
4. Builds an artifact (`zip` or `tar.gz`) unless dry-run.
5. Commits `VERSION` and `CHANGELOG.md`, tags `vX.Y.Z`, and pushes tags unless dry-run.
6. Uploads artifact to GitHub or Gitea release unless dry-run.

### Packaging only

If you only need artifacts (without tags/releases), use:

```bash
./git-control-panel.sh package --format tar --name mybuild.tar.gz --paths "."
```

---

## Authentication workflow

### GitHub

```bash
./git-control-panel.sh auth gh
```

- Prompts for a GitHub PAT (recommended scopes noted by script: `repo`, `workflow`).
- Uses `gh auth login --with-token`.

### Gitea

```bash
./git-control-panel.sh auth gitea
```

- Prompts for a Gitea token.
- Exports `GITEA_TOKEN` in the current session.

> In CI mode, interactive auth prompts are blocked; set environment tokens instead.

---

## JSON output examples

### Self-check in JSON

```bash
./git-control-panel.sh --json self-check
```

Returns a JSON object containing `status`, `report`, and `message` fields.

### Dry-run package in JSON

```bash
./git-control-panel.sh --json package --format zip --name out.zip --paths "." --dry-run
```

Returns JSON summary of planned artifact output.

---

## Logging

- Logs are appended to `~/.git-control.log`.
- Each log entry includes UTC timestamp, level, and message.
- Console output and logfile output are mirrored via `tee`.

Log levels:

- `debug` (most verbose)
- `info`
- `warn`
- `error`
- `quiet` (minimal)

---

## CI mode behavior

When `CI_MODE=true` or `--ci` is used:

- Pause prompts are skipped.
- Confirmation prompts auto-confirm.
- Interactive auth commands return with guidance to use env vars.
- Flows are more deterministic for pipeline usage.

---

## Environment variables

- `TEA_URL_OVERRIDE` — custom URL for `tea` binary download.
- `TEA_SHA256` — expected SHA-256 for downloaded `tea` binary.
- `GITHUB_TOKEN` — recommended for CI GitHub auth.
- `GITEA_TOKEN` — recommended for CI Gitea auth.

---

## Troubleshooting

### “Not a git repository”
Run the script from inside a valid git repository.

### `gh` or `tea` not installed
Use installers:

```bash
./git-control-panel.sh install gh
./git-control-panel.sh install tea
```

### Release upload fails

- Ensure authentication is valid (`gh auth status`, configured `GITEA_TOKEN`).
- Verify remote push permissions and tag creation permissions.
- Retry with `--dry-run` first to validate control flow.

### Artifact creation fails

- Confirm `zip`/`tar` utilities are installed.
- Verify included paths are valid and readable.

---

## Known behaviors and caveats

- The script uses strict Bash mode (`set -euo pipefail`), so unset variables and command failures can stop execution early by design.
- The `release` subcommand path in `main()` currently forwards `--dry-run` to `cli_release` unconditionally, which means the CLI release route behaves as dry-run even if you do not pass `--dry-run`.
- Artifact format labels accept `zip`, `tar`, `tar.gz`, and `tgz` in lower-level packing logic, while CLI help emphasizes `zip|tar`.

---

## Security notes

- Config file permissions are tightened to `600`.
- Token prompts use silent input (`read -s`) in interactive auth helpers.
- If you set persistent tokens in shell profiles, follow least-privilege and secret-management best practices.

---

## License

This script header declares **MIT** license.
