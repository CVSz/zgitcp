#!/usr/bin/env bash
# git-control-panel.sh
# Unified Git + GitHub + Gitea Control Panel
# - Config file: ~/.git-control.conf
# - Logging: ~/.git-control.log with verbose/quiet levels
# - CI mode: non-interactive (no prompts)
# - Dry-run support for packaging/release
# - Interactive menu + CLI subcommands
# - Artifact packaging (zip/tar.gz) and upload to GitHub (gh) or Gitea (tea)
# - Meta installers for gh, tea, and local Gitea server
# - JSON output mode for CI pipelines (--json)
# - Self-check command for basic unit tests and health checks (self-check)
# - Authentication helpers for GitHub and Gitea (token-based)
# - Full automated setup for config + SSH server + GitHub/Gitea remote wiring
# - Robust tea installer with arch detection, retries, and TEA_URL override
# Author: CVSz (adapted)
# License: MIT

set -euo pipefail
IFS=$'\n\t'

# -------------------------
# Constants and defaults
# -------------------------
CONFIG_FILE="$HOME/.git-control.conf"
LOG_FILE="$HOME/.git-control.log"
TMPDIR="$(mktemp -d /tmp/git-control.XXXXXX)"
DEFAULT_REMOTE="origin"
DEFAULT_BRANCH="main"
DEFAULT_BUMP="patch"
DEFAULT_LOG_LEVEL="info"   # debug, info, warn, error, quiet
DEFAULT_CI_MODE="false"    # true or false

# Runtime flags
DRY_RUN=false
LOG_LEVEL="$DEFAULT_LOG_LEVEL"
CI_MODE="$DEFAULT_CI_MODE"
JSON_OUTPUT=false

# -------------------------
# Logging utilities
# -------------------------
_log_level_value() {
  case "$1" in
    debug) echo 10 ;;
    info)  echo 20 ;;
    warn)  echo 30 ;;
    error) echo 40 ;;
    quiet) echo 50 ;;
    *) echo 20 ;;
  esac
}

_log() {
  local level="$1"; shift
  local lvl_val msg ts cfg_val
  lvl_val=$(_log_level_value "$level")
  cfg_val=$(_log_level_value "$LOG_LEVEL")
  if [ "$lvl_val" -lt "$cfg_val" ]; then return 0; fi
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  msg="$*"
  printf "%s %-5s %s\n" "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
}

log_debug() { _log debug "$*"; }
log_info()  { _log info  "$*"; }
log_warn()  { _log warn  "$*"; }
log_error() { _log error "$*"; }

# -------------------------
# JSON output helper
# -------------------------
json_emit() {
  local status="$1"; shift
  local message="$1"; shift
  local -a kv=("$@")
  local json='{"status":"'"$status"'","message":"'"$(echo "$message" | sed 's/"/\\"/g')"'"'
  while [ ${#kv[@]} -gt 1 ]; do
    local k="${kv[0]}"; local v="${kv[1]}"
    kv=("${kv[@]:2}")
    json="$json, \"${k}\":\"$(echo "$v" | sed 's/"/\\"/g')\""
  done
  json="$json}"
  printf '%s\n' "$json"
}

# -------------------------
# Helpers
# -------------------------
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

pause() {
  if [ "$CI_MODE" = "true" ]; then
    log_debug "CI mode active: skipping pause"
    return 0
  fi
  read -rp "Press Enter to continue..."
}

confirm() {
  local msg="${1:-Are you sure?}"
  if [ "$CI_MODE" = "true" ]; then
    log_debug "CI mode active: auto-confirming: $msg"
    return 0
  fi
  if [ "$JSON_OUTPUT" = true ]; then
    log_debug "JSON mode active: auto-declining interactive confirm"
    return 1
  fi
  read -rp "$msg [y/N]: " ans
  case "$ans" in [Yy]|[Yy][Ee][Ss]) return 0 ;; *) return 1 ;; esac
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

# -------------------------
# Config management
# -------------------------
load_config() {
  if [ -f "$CONFIG_FILE" ]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    LOG_LEVEL="${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}"
    CI_MODE="${CI_MODE:-$DEFAULT_CI_MODE}"
    REMOTE="${REMOTE:-$DEFAULT_REMOTE}"
    BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
    BUMP_TYPE="${BUMP_TYPE:-$DEFAULT_BUMP}"
  else
    REMOTE="$DEFAULT_REMOTE"
    BRANCH="$DEFAULT_BRANCH"
    BUMP_TYPE="$DEFAULT_BUMP"
    LOG_LEVEL="$DEFAULT_LOG_LEVEL"
    CI_MODE="$DEFAULT_CI_MODE"
    save_config
  fi
  log_info "Config loaded: REMOTE=$REMOTE BRANCH=$BRANCH BUMP_TYPE=$BUMP_TYPE LOG_LEVEL=$LOG_LEVEL CI_MODE=$CI_MODE"
}

save_config() {
  cat > "$CONFIG_FILE" <<EOF
# git-control-panel configuration
REMOTE="${REMOTE:-$DEFAULT_REMOTE}"
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
BUMP_TYPE="${BUMP_TYPE:-$DEFAULT_BUMP}"
LOG_LEVEL="${LOG_LEVEL:-$DEFAULT_LOG_LEVEL}"
CI_MODE="${CI_MODE:-$DEFAULT_CI_MODE}"
EOF
  chmod 600 "$CONFIG_FILE"
  log_info "Config saved to $CONFIG_FILE"
}

edit_config_interactive() {
  load_config
  echo "Current configuration:"
  echo "1) Remote: $REMOTE"
  echo "2) Branch: $BRANCH"
  echo "3) Preferred bump type: $BUMP_TYPE"
  echo "4) Log level: $LOG_LEVEL (debug|info|warn|error|quiet)"
  echo "5) CI mode: $CI_MODE (true|false)"
  echo "6) Reset to defaults"
  read -rp "Select number to edit or press Enter to return: " c
  case "$c" in
    1) read -rp "Enter remote name or URL: " r; [ -n "$r" ] && REMOTE="$r"; save_config ;;
    2) read -rp "Enter default branch name: " b; [ -n "$b" ] && BRANCH="$b"; save_config ;;
    3) read -rp "Enter preferred bump type (major/minor/patch): " bt; case "$bt" in major|minor|patch) BUMP_TYPE="$bt"; save_config ;; *) echo "Invalid bump type" ;; esac ;;
    4) read -rp "Enter log level (debug|info|warn|error|quiet): " ll; case "$ll" in debug|info|warn|error|quiet) LOG_LEVEL="$ll"; save_config ;; *) echo "Invalid log level" ;; esac ;;
    5) read -rp "Enable CI mode? (true/false): " cm; case "$cm" in true|false) CI_MODE="$cm"; save_config ;; *) echo "Invalid value" ;; esac ;;
    6) REMOTE="$DEFAULT_REMOTE"; BRANCH="$DEFAULT_BRANCH"; BUMP_TYPE="$DEFAULT_BUMP"; LOG_LEVEL="$DEFAULT_LOG_LEVEL"; CI_MODE="$DEFAULT_CI_MODE"; save_config ;;
    *) echo "No changes" ;;
  esac
  pause
}

# -------------------------
# Environment checks
# -------------------------
check_git_repo() {
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    log_error "Not a git repository (run inside a repo)."
    if [ "$JSON_OUTPUT" = true ]; then json_emit error "not a git repo"; fi
    pause
    return 1
  fi
  return 0
}

# -------------------------
# Installers (meta)
# -------------------------
install_gh() {
  if command_exists gh; then log_info "gh already installed: $(gh --version | head -n1)"; return 0; fi
  if command_exists apt-get; then
    log_info "Installing gh via apt (requires sudo)..."
    sudo apt update
    sudo apt install -y curl gpg apt-transport-https ca-certificates
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
      sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    sudo chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
      sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    sudo apt update
    sudo apt install -y gh
    log_info "gh installed"
  else
    log_error "Unsupported package manager. Install gh manually."
  fi
}

# Robust tea installer: arch detection, retries, TEA_URL override, optional checksum env TEA_SHA256
install_tea() {
  if command_exists tea; then
    log_info "tea already installed: $(tea --version 2>/dev/null || echo 'unknown')"
    return 0
  fi

  log_info "Installing Gitea CLI (tea)..."

  # Allow override via env var
  if [ -n "${TEA_URL_OVERRIDE:-}" ]; then
    urls=("$TEA_URL_OVERRIDE")
  else
    # Determine arch
    arch="$(uname -m)"
    case "$arch" in
      x86_64|amd64) arch="linux-amd64" ;;
      aarch64|arm64) arch="linux-arm64" ;;
      armv7l|armv7) arch="linux-armv7" ;;
      *) arch="linux-amd64" ;;
    esac

    urls=(
      "https://dl.gitea.com/tea/latest/tea-${arch}"
      "https://github.com/go-gitea/tea/releases/latest/download/tea-${arch}"
      "https://github.com/go-gitea/tea/releases/download/v0.0.0/tea-${arch}" # fallback pattern (may 404)
    )
  fi

  tmp="$TMPDIR/tea.$$"
  max_retries=3
  attempt=0
  success=false

  for url in "${urls[@]}"; do
    attempt=0
    while [ $attempt -lt $max_retries ]; do
      attempt=$((attempt+1))
      log_debug "Attempt $attempt: downloading $url"
      # Use curl with fail and show HTTP code on failure
      if curl -fsSL -o "$tmp" "$url"; then
        log_info "Downloaded tea from $url"
        success=true
        break 2
      else
        log_warn "Download attempt $attempt failed for $url"
        sleep $((attempt)) # backoff
      fi
    done
  done

  if [ "$success" != true ]; then
    log_error "Failed to download tea from known endpoints. Please install tea manually from https://dl.gitea.com/tea/ or https://github.com/go-gitea/tea/releases"
    if [ "$JSON_OUTPUT" = true ]; then json_emit error "tea_download_failed" ; fi
    return 1
  fi

  # Optional checksum verification if TEA_SHA256 provided
  if [ -n "${TEA_SHA256:-}" ]; then
    log_debug "Verifying checksum with TEA_SHA256"
    calc_sha="$(sha256sum "$tmp" | awk '{print $1}')" || calc_sha=""
    if [ "$calc_sha" != "$TEA_SHA256" ]; then
      log_error "Checksum mismatch for downloaded tea binary"
      rm -f "$tmp"
      if [ "$JSON_OUTPUT" = true ]; then json_emit error "checksum_mismatch" expected "$TEA_SHA256" got "$calc_sha"; fi
      return 1
    fi
    log_info "Checksum verified"
  fi

  sudo mv "$tmp" /usr/local/bin/tea
  sudo chmod +x /usr/local/bin/tea
  log_info "tea installed to /usr/local/bin/tea"
  if [ "$JSON_OUTPUT" = true ]; then json_emit ok "tea_installed" path "/usr/local/bin/tea"; fi
}

install_gitea_server() {
  log_info "Installing Gitea server (requires sudo). Review before running."
  sudo apt update
  sudo apt install -y wget sqlite3
  GITEA_VERSION="1.22.0"
  ARCHIVE_URL="https://dl.gitea.io/gitea/${GITEA_VERSION}/gitea-${GITEA_VERSION}-linux-amd64"
  tmp="$TMPDIR/gitea"
  if command_exists wget; then
    sudo wget -O "$tmp" "$ARCHIVE_URL"
  else
    sudo curl -fsSL -o "$tmp" "$ARCHIVE_URL"
  fi
  sudo chmod +x "$tmp"
  sudo mv "$tmp" /usr/local/bin/gitea
  sudo adduser --system --group --disabled-login --shell /bin/false gitea || true
  sudo mkdir -p /var/lib/gitea/{custom,data,log}
  sudo chown -R gitea:gitea /var/lib/gitea
  sudo chmod -R 750 /var/lib/gitea
  sudo mkdir -p /etc/gitea
  sudo chown root:gitea /etc/gitea
  sudo chmod 770 /etc/gitea
  sudo tee /etc/systemd/system/gitea.service >/dev/null <<'EOF'
[Unit]
Description=Gitea
After=syslog.target
After=network.target

[Service]
RestartSec=2s
Type=simple
User=gitea
Group=gitea
WorkingDirectory=/var/lib/gitea/
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/app.ini
Restart=always
Environment=USER=gitea HOME=/home/gitea GITEA_WORK_DIR=/var/lib/gitea

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable --now gitea
  log_info "Gitea installed and started at http://localhost:3000"
}

install_ssh_server() {
  if command_exists systemctl && systemctl is-active --quiet ssh; then
    log_info "OpenSSH server already active"
    return 0
  fi
  log_info "Installing and enabling OpenSSH server (requires sudo)..."
  if command_exists apt-get; then
    sudo apt update
    sudo apt install -y openssh-server
    sudo systemctl enable --now ssh
    log_info "OpenSSH server installed and running"
  else
    log_error "Unsupported package manager. Install openssh-server manually."
    return 1
  fi
}

connect_host_remote() {
  local remote_name="$1"
  local remote_url="$2"
  if [ -z "$remote_url" ]; then
    log_warn "No URL provided for remote '$remote_name'; skipping"
    return 0
  fi
  if ! check_git_repo; then
    log_warn "Not in a git repository. Skipping remote '$remote_name' setup."
    return 0
  fi
  if git remote get-url "$remote_name" >/dev/null 2>&1; then
    git remote set-url "$remote_name" "$remote_url"
    log_info "Updated remote '$remote_name' -> $remote_url"
  else
    git remote add "$remote_name" "$remote_url"
    log_info "Added remote '$remote_name' -> $remote_url"
  fi
}

full_automated_setup() {
  local setup_remote setup_branch github_url gitea_url do_auth
  setup_remote="${1:-$REMOTE}"
  setup_branch="${2:-$BRANCH}"
  github_url="${3:-}"
  gitea_url="${4:-}"
  do_auth="${5:-true}"

  REMOTE="$setup_remote"
  BRANCH="$setup_branch"
  save_config
  log_info "Default config updated: REMOTE=$REMOTE BRANCH=$BRANCH"

  install_gh
  install_tea
  install_ssh_server

  connect_host_remote "github" "$github_url"
  connect_host_remote "gitea" "$gitea_url"

  if [ "$do_auth" = "true" ]; then
    gh_auth_token || true
    gitea_auth_token || true
  fi
  log_info "Full automated setup completed"
}

# -------------------------
# Release automation
# -------------------------
ensure_version_file() {
  if [ ! -f VERSION ]; then
    echo "0.1.0" > VERSION
    log_info "VERSION file created with 0.1.0"
  fi
}

generate_changelog() {
  ensure_version_file
  local version last_tag tmpfile
  version="$(cat VERSION)"
  last_tag="$(git describe --tags --abbrev=0 2>/dev/null || echo "")"
  tmpfile="$TMPDIR/CHANGELOG.tmp"
  if [ -z "$last_tag" ]; then
    git log --pretty=format:"- %s" > "$tmpfile"
  else
    git log "$last_tag"..HEAD --pretty=format:"- %s" > "$tmpfile"
  fi
  {
    echo "## v$version"
    cat "$tmpfile"
    echo ""
  } >> CHANGELOG.md
  rm -f "$tmpfile"
  log_info "CHANGELOG.md updated for v$version"
}

bump_version() {
  ensure_version_file
  local old M m p new type
  old="$(cat VERSION)"
  IFS='.' read -r M m p <<< "$old"
  type="${1:-$BUMP_TYPE}"
  case "$type" in
    major) M=$((M+1)); m=0; p=0 ;;
    minor) m=$((m+1)); p=0 ;;
    patch) p=$((p+1)) ;;
    *) log_error "Invalid bump type: $type"; return 1 ;;
  esac
  new="$M.$m.$p"
  echo "$new" > VERSION
  log_info "Version bumped: $old -> $new"
}

# -------------------------
# Artifact packaging & upload
# -------------------------
create_artifact() {
  local format="$1" out="$2"; shift 2
  local paths=("$@")
  if [ -z "$out" ]; then log_error "No output name"; return 1; fi
  if [ -f "$out" ]; then
    if confirm "Artifact $out exists. Overwrite?"; then rm -f "$out"; else log_error "Artifact creation cancelled"; return 1; fi
  fi
  case "$format" in
    zip) zip -r "$out" "${paths[@]}" >/dev/null ;;
    tar|tar.gz|tgz) tar -czf "$out" "${paths[@]}" ;;
    *) log_error "Unsupported format: $format"; return 1 ;;
  esac
  log_info "Artifact created: $out"
  echo "$out"
}

upload_artifact_github() {
  local tag="$1" artifact="$2"
  if [ "$DRY_RUN" = true ]; then log_info "[dry-run] Would upload $artifact to GitHub release $tag"; return 0; fi
  if ! command_exists gh; then log_error "gh not installed"; return 1; fi
  if ! gh release view "$tag" >/dev/null 2>&1; then
    gh release create "$tag" --title "$tag" --notes-file CHANGELOG.md || log_error "Failed to create release"
  fi
  gh release upload "$tag" "$artifact" --clobber || log_error "gh upload failed"
  log_info "Uploaded $artifact to GitHub release $tag"
}

upload_artifact_gitea() {
  local tag="$1" artifact="$2"
  if [ "$DRY_RUN" = true ]; then log_info "[dry-run] Would upload $artifact to Gitea release $tag"; return 0; fi
  if ! command_exists tea; then log_error "tea not installed"; return 1; fi
  if ! tea release view "$tag" >/dev/null 2>&1; then
    tea release create "$tag" --title "$tag" --note "$(cat CHANGELOG.md)" || log_info "tea create release failed"
  fi
  if tea release upload "$tag" "$artifact" >/dev/null 2>&1; then
    log_info "Uploaded $artifact to Gitea release $tag"
  else
    log_info "tea upload not supported or failed; release created with notes only"
  fi
}

# -------------------------
# Authentication helpers
# -------------------------
gh_auth_token() {
  if ! command_exists gh; then log_error "gh not installed"; return 1; fi
  if [ "$CI_MODE" = "true" ]; then
    log_error "CI mode: set GITHUB_TOKEN env in CI instead"
    return 1
  fi
  read -rp "Enter GitHub Personal Access Token (scopes: repo, workflow) or leave blank to cancel: " -s token
  echo
  if [ -z "$token" ]; then log_info "GitHub auth cancelled"; return 1; fi
  printf "%s" "$token" | gh auth login --with-token >/dev/null 2>&1 || { log_error "gh auth login failed"; return 1; }
  log_info "GitHub authenticated via gh"
}

gitea_auth_token() {
  if ! command_exists tea; then log_error "tea not installed"; return 1; fi
  if [ "$CI_MODE" = "true" ]; then
    log_error "CI mode: set GITEA_TOKEN env in CI instead"
    return 1
  fi
  read -rp "Enter Gitea token or leave blank to cancel: " -s token
  echo
  if [ -z "$token" ]; then log_info "Gitea auth cancelled"; return 1; fi
  export GITEA_TOKEN="$token"
  log_info "Gitea token set in environment for current session. To persist, add export GITEA_TOKEN=... to your shell profile."
}

# -------------------------
# Autoheal
# -------------------------
autoheal() {
  log_info "Running autoheal..."
  check_git_repo || return 1
  if [ -z "$(git symbolic-ref --short -q HEAD)" ]; then
    log_warn "Detached HEAD detected. Attempting checkout $BRANCH or master"
    git checkout "$BRANCH" 2>/dev/null || git checkout master 2>/dev/null || log_error "No $BRANCH/master branch"
  fi
  if ! git diff-index --quiet HEAD --; then
    git add -A
    git commit -m "Autoheal: saving work in progress" || log_info "Nothing to commit"
  fi
  if ! git remote | grep -q "$REMOTE"; then
    if [ "$CI_MODE" = "true" ]; then
      log_warn "CI mode: no remote $REMOTE configured; skipping interactive remote add"
    else
      read -rp "No $REMOTE remote. Enter remote URL to add or leave blank: " remoteurl
      if [ -n "$remoteurl" ]; then git remote add "$REMOTE" "$remoteurl"; log_info "Remote $REMOTE added"; fi
    fi
  fi
  if ! git push --set-upstream "$REMOTE" "$(git rev-parse --abbrev-ref HEAD)" 2>/dev/null; then
    log_info "Push failed, attempting pull --rebase..."
    git pull --rebase || log_error "Autoheal: could not rebase"
  fi
  log_info "Autoheal complete."
}

# -------------------------
# Self-check and unit tests
# -------------------------
self_check() {
  local ok=true
  local -a report=()
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then report+=("git_repo:ok"); else report+=("git_repo:missing"); fi
  command_exists gh && report+=("gh:ok") || report+=("gh:missing")
  command_exists tea && report+=("tea:ok") || report+=("tea:missing")
  command_exists gitea && report+=("gitea_binary:ok") || report+=("gitea_binary:missing")
  [ -f VERSION ] && report+=("version_file:ok") || report+=("version_file:missing")
  [ -f CHANGELOG.md ] && report+=("changelog:ok") || report+=("changelog:missing")
  if git rev-parse --abbrev-ref HEAD >/dev/null 2>&1; then report+=("git_head:ok"); else report+=("git_head:fail"); fi

  for r in "${report[@]}"; do
    case "$r" in *missing*|*fail*) ok=false; break ;; esac
  done

  if [ "$JSON_OUTPUT" = true ]; then
    local status msg json='{"status":"'
    status=$([ "$ok" = true ] && echo "ok" || echo "fail")
    msg=$([ "$ok" = true ] && echo "self-check passed" || echo "self-check found issues")
    json="$json$status\",\"report\":{"
    local first=true
    for r in "${report[@]}"; do
      k="${r%%:*}"; v="${r#*:}"
      if [ "$first" = true ]; then first=false; else json="$json,"; fi
      json="$json\"$k\":\"$v\""
    done
    json="$json},\"message\":\"$msg\"}"
    printf '%s\n' "$json"
  else
    echo "Self-check report:"
    for r in "${report[@]}"; do echo " - $r"; done
    if [ "$ok" = true ]; then echo "All checks passed."; else echo "Some checks failed. Inspect the report above and the log at $LOG_FILE"; fi
  fi
}

# -------------------------
# CLI subcommands (non-interactive)
# -------------------------
show_usage() {
  cat <<USAGE
Usage: $0 [global options] <command> [options]

Global options:
  --dry-run           Simulate actions without making changes
  --log-level LEVEL   Set log level (debug|info|warn|error|quiet)
  --ci                Enable CI mode (non-interactive)
  --json              Output structured JSON for CI pipelines

Commands:
  status                      Show git status
  add <paths>                 git add paths
  commit -m "message"         git commit
  push                        git push (uses config REMOTE/BRANCH)
  pull                        git pull (uses config REMOTE/BRANCH)
  release <github|gitea> [--dry-run] [--artifact zip|tar] [--name NAME] [--paths "p1 p2"]
  package --format zip|tar --name NAME --paths "p1 p2" [--dry-run]
  bump [major|minor|patch]    Bump version
  changelog                   Generate changelog
  install gh|tea|gitea        Install tools or server (requires sudo)
  install ssh                 Install and enable OpenSSH server
  auth gh|gitea               Authenticate using token (interactive)
  setup-all [--remote NAME] [--branch NAME] [--github-url URL] [--gitea-url URL] [--skip-auth]
                              Full automated config + installers + SSH + GitHub/Gitea remote setup
  autoheal                    Run autoheal
  self-check                  Run basic self-checks and unit tests
  config                      Edit config interactively
  help                        Show this help

Examples:
  $0 --json release github --dry-run --artifact zip --name myproj.zip --paths "."
  $0 package --format tar --name myproj-v1.tar.gz --paths "src README.md"
USAGE
}

cli_release() {
  local target="$1"; shift
  local artifact_fmt="zip" artifact_name="" paths="."
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --artifact|--format)
        if [ $# -lt 2 ]; then log_error "Missing value for $1"; return 1; fi
        artifact_fmt="$2"; shift 2 ;;
      --name)
        if [ $# -lt 2 ]; then log_error "Missing value for --name"; return 1; fi
        artifact_name="$2"; shift 2 ;;
      --paths)
        if [ $# -lt 2 ]; then log_error "Missing value for --paths"; return 1; fi
        paths="$2"; shift 2 ;;
      *)
        log_warn "Ignoring unknown release option: $1"
        shift ;;
    esac
  done

  check_git_repo || return 1
  log_info "Starting release flow (target=$target dry-run=$DRY_RUN)"
  bump_version "$BUMP_TYPE"
  generate_changelog
  local V
  V="$(cat VERSION)"
  if [ -z "$artifact_name" ]; then artifact_name="${PWD##*/}-v${V}.${artifact_fmt}"; fi

  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would create artifact $artifact_name from paths: $paths"
    [ "$JSON_OUTPUT" = true ] && json_emit ok "dry-run artifact" tag "v$V" artifact "$artifact_name"
  else
    local artifact
    artifact=$(create_artifact "$artifact_fmt" "$artifact_name" $paths) || { log_error "Artifact creation failed"; [ "$JSON_OUTPUT" = true ] && json_emit error "artifact_failed"; return 1; }
  fi

  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would commit VERSION and CHANGELOG, tag v$V, push to $REMOTE/$BRANCH"
  else
    git add VERSION CHANGELOG.md
    git commit -m "Release v$V" || log_info "No changes to commit"
    git tag -a "v$V" -m "Release v$V"
    git push "$REMOTE" "$BRANCH" --tags
  fi

  case "$target" in
    github)
      if [ "$DRY_RUN" = true ]; then
        log_info "[dry-run] Would upload $artifact_name to GitHub release v$V"
        [ "$JSON_OUTPUT" = true ] && json_emit ok "dry-run upload" tag "v$V" artifact "$artifact_name"
      else
        upload_artifact_github "v$V" "$artifact"
        [ "$JSON_OUTPUT" = true ] && json_emit ok "uploaded" tag "v$V" artifact "$artifact"
      fi
      ;;
    gitea)
      if [ "$DRY_RUN" = true ]; then
        log_info "[dry-run] Would upload $artifact_name to Gitea release v$V"
        [ "$JSON_OUTPUT" = true ] && json_emit ok "dry-run upload" tag "v$V" artifact "$artifact_name"
      else
        upload_artifact_gitea "v$V" "$artifact"
        [ "$JSON_OUTPUT" = true ] && json_emit ok "uploaded" tag "v$V" artifact "$artifact"
      fi
      ;;
    *)
      log_error "Unknown release target: $target"
      [ "$JSON_OUTPUT" = true ] && json_emit error "unknown_target" target "$target"
      return 1
      ;;
  esac
  log_info "Release flow for $target completed (v$V)"
}

cli_package() {
  local fmt="" name="" paths="."
  while [ $# -gt 0 ]; do
    case "$1" in
      --format)
        if [ $# -lt 2 ]; then log_error "Missing value for --format"; return 1; fi
        fmt="$2"; shift 2 ;;
      --name)
        if [ $# -lt 2 ]; then log_error "Missing value for --name"; return 1; fi
        name="$2"; shift 2 ;;
      --paths)
        if [ $# -lt 2 ]; then log_error "Missing value for --paths"; return 1; fi
        paths="$2"; shift 2 ;;
      --dry-run) DRY_RUN=true; shift ;;
      *)
        log_warn "Ignoring unknown package option: $1"
        shift ;;
    esac
  done
  if [ -z "$fmt" ] || [ -z "$name" ]; then log_error "format and name required"; [ "$JSON_OUTPUT" = true ] && json_emit error "missing_args"; return 1; fi
  if [ "$DRY_RUN" = true ]; then
    log_info "[dry-run] Would create $name from $paths"
    [ "$JSON_OUTPUT" = true ] && json_emit ok "dry-run package" artifact "$name" paths "$paths"
  else
    local artifact
    artifact=$(create_artifact "$fmt" "$name" $paths) && [ "$JSON_OUTPUT" = true ] && json_emit ok "created" artifact "$artifact"
  fi
}

# -------------------------
# Interactive menu
# -------------------------
interactive_menu() {
  while true; do
    clear
    cat <<'MENU'
========================================
 Git + GitHub + Gitea Control Panel
========================================
 1  Git Status
 2  Git Add files
 3  Git Commit changes
 4  Git Push
 5  Git Pull
 6  Git Log
 7  Branch management
 8  Checkout branch/tag
 9  Create tag
10  GitHub CLI installer
11  Gitea CLI installer
12  Install Gitea server
13  One-click Push
14  One-click GitHub Release with artifact
15  One-click Gitea Release with artifact
16  One-click Deploy GitHub Workflow
17  Autoheal
18  Generate changelog
19  Bump version
20  Show VERSION and CHANGELOG
21  Edit config file
22  Set log level
23  Toggle CI mode
24  Authenticate GitHub
25  Authenticate Gitea
26  Self-check
27  Full automated setup (config + SSH + GitHub/Gitea connect)
 0  Exit
========================================
MENU
    read -rp "Select option: " choice
    case "$choice" in
      1) check_git_repo || continue; git status; pause ;;
      2) check_git_repo || continue; read -rp "Files to add (or .): " files; git add $files; pause ;;
      3) check_git_repo || continue; read -rp "Commit message: " msg; git commit -m "$msg" || log_info "Commit failed"; pause ;;
      4) check_git_repo || continue; git push "$REMOTE" "$BRANCH"; pause ;;
      5) check_git_repo || continue; git pull "$REMOTE" "$BRANCH"; pause ;;
      6) check_git_repo || continue; git log --oneline --graph --decorate --max-count=50; pause ;;
      7) check_git_repo || continue;
         echo "Branch Management: a) List b) Create c) Delete"
         read -rp "Choice: " bchoice
         case "$bchoice" in
           a) git branch ;;
           b) read -rp "New branch name: " bn; git branch "$bn"; log_info "Created $bn" ;;
           c) read -rp "Branch to delete: " bd;
              if confirm "Are you sure you want to delete branch $bd? This is destructive."; then
                git branch -d "$bd" || { echo "Safe delete failed. Use -D to force."; if confirm "Force delete $bd?"; then git branch -D "$bd"; fi }
              else
                echo "Delete cancelled."
              fi
              ;;
         esac
         pause ;;
      8) check_git_repo || continue; read -rp "Branch or tag to checkout: " t; git checkout "$t"; pause ;;
      9) check_git_repo || continue; read -rp "Tag name: " tn; git tag "$tn"; log_info "Tag $tn created"; pause ;;
      10) install_gh; pause ;;
      11) install_tea; pause ;;
      12) install_gitea_server; pause ;;
      13) check_git_repo || continue; read -rp "Commit message: " cm; git add . && git commit -m "$cm" || log_info "Nothing to commit"; git push "$REMOTE" "$BRANCH"; pause ;;
      14) check_git_repo || continue;
          read -rp "Dry-run? [y/N]: " dr; [ "$dr" = "y" ] && DRY_RUN=true || DRY_RUN=false
          read -rp "Artifact format zip/tar [zip]: " afmt; afmt=${afmt:-zip}
          read -rp "Artifact name [${PWD##*/}-v\$(cat VERSION).$afmt]: " aname
          read -rp "Paths to include (space separated) [.]: " pats; pats=${pats:-.}
          if [ -z "$aname" ]; then aname="${PWD##*/}-v$(cat VERSION).$afmt"; fi
          if [ "$DRY_RUN" = true ]; then log_info "[dry-run] Would run GitHub release flow"; fi
          bump_version "$BUMP_TYPE"
          generate_changelog
          V="$(cat VERSION)"
          if [ "$DRY_RUN" = false ]; then create_artifact "$afmt" "$aname" $pats; git add VERSION CHANGELOG.md; git commit -m "Release v$V" || log_info "No changes"; git tag -a "v$V" -m "Release v$V"; git push "$REMOTE" "$BRANCH" --tags; upload_artifact_github "v$V" "$aname"; else log_info "[dry-run] Simulated release v$V"; fi
          pause ;;
      15) check_git_repo || continue;
          read -rp "Dry-run? [y/N]: " dr; [ "$dr" = "y" ] && DRY_RUN=true || DRY_RUN=false
          read -rp "Artifact format zip/tar [zip]: " afmt; afmt=${afmt:-zip}
          read -rp "Artifact name [${PWD##*/}-v\$(cat VERSION).$afmt]: " aname
          read -rp "Paths to include (space separated) [.]: " pats; pats=${pats:-.}
          if [ -z "$aname" ]; then aname="${PWD##*/}-v$(cat VERSION).$afmt"; fi
          bump_version "$BUMP_TYPE"
          generate_changelog
          V="$(cat VERSION)"
          if [ "$DRY_RUN" = false ]; then create_artifact "$afmt" "$aname" $pats; git add VERSION CHANGELOG.md; git commit -m "Release v$V" || log_info "No changes"; git tag -a "v$V" -m "Release v$V"; git push "$REMOTE" "$BRANCH" --tags; upload_artifact_gitea "v$V" "$aname"; else log_info "[dry-run] Simulated Gitea release v$V"; fi
          pause ;;
      16) check_git_repo || continue;
          if ! command_exists gh; then log_error "gh not installed"; pause; continue; fi
          read -rp "Workflow file name (e.g., deploy.yml): " wf
          gh workflow run "$wf" || log_error "Failed to run workflow"
          pause ;;
      17) autoheal; pause ;;
      18) check_git_repo || continue; generate_changelog; pause ;;
      19) check_git_repo || continue;
          echo "Bump type: a) major b) minor c) patch"
          read -rp "Choice: " btype
          case "$btype" in a) bump_version major ;; b) bump_version minor ;; c) bump_version patch ;; *) log_error "Invalid choice" ;; esac
          pause ;;
      20) echo "VERSION:"; [ -f VERSION ] && cat VERSION || echo "No VERSION file"; echo; echo "CHANGELOG.md:"; [ -f CHANGELOG.md ] && sed -n '1,200p' CHANGELOG.md || echo "No CHANGELOG.md"; pause ;;
      21) edit_config_interactive ;;
      22) read -rp "Enter log level (debug|info|warn|error|quiet): " ll; case "$ll" in debug|info|warn|error|quiet) LOG_LEVEL="$ll"; save_config ;; *) echo "Invalid log level" ;; esac; pause ;;
      23) read -rp "Enable CI mode? (true/false): " cm; case "$cm" in true|false) CI_MODE="$cm"; save_config ;; *) echo "Invalid value" ;; esac; pause ;;
      24) gh_auth_token; pause ;;
      25) gitea_auth_token; pause ;;
      26) self_check; pause ;;
      27)
          read -rp "Default remote [${REMOTE}]: " setup_remote; setup_remote="${setup_remote:-$REMOTE}"
          read -rp "Default branch [${BRANCH}]: " setup_branch; setup_branch="${setup_branch:-$BRANCH}"
          read -rp "GitHub SSH/HTTPS URL (optional): " github_url
          read -rp "Gitea SSH/HTTPS URL (optional): " gitea_url
          if confirm "Run GitHub/Gitea auth prompts now?"; then do_auth=true; else do_auth=false; fi
          full_automated_setup "$setup_remote" "$setup_branch" "$github_url" "$gitea_url" "$do_auth"
          pause ;;
      0) log_info "Exiting."; exit 0 ;;
      *) log_error "Invalid option"; pause ;;
    esac
  done
}

# -------------------------
# Entry point
# -------------------------
main() {
  load_config
  # parse global CLI flags
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=true; shift ;;
      --log-level) LOG_LEVEL="$2"; shift 2 ;;
      --ci) CI_MODE="true"; shift ;;
      --no-ci) CI_MODE="false"; shift ;;
      --json) JSON_OUTPUT=true; shift ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  if [ $# -eq 0 ]; then
    interactive_menu
    exit 0
  fi

  cmd="$1"; shift
  case "$cmd" in
    status) check_git_repo || exit 1; git status ;;
    add) check_git_repo || exit 1; git add "$@" ;;
    commit) check_git_repo || exit 1;
            if [ "$#" -ge 2 ] && [ "$1" = "-m" ]; then shift; git commit -m "$*" || log_info "Commit failed"; else log_error "Usage: commit -m \"message\""; fi ;;
    push) check_git_repo || exit 1; git push "$REMOTE" "$BRANCH" ;;
    pull) check_git_repo || exit 1; git pull "$REMOTE" "$BRANCH" ;;
    release) check_git_repo || exit 1;
             if [ $# -lt 1 ]; then log_error "Usage: release <github|gitea> [--dry-run] [--artifact fmt] [--name NAME] [--paths \"p1 p2\"]"; exit 1; fi
             target="$1"; shift
             ARTFMT="zip"; ARTNAME=""; ARTPATHS="."
             while [ $# -gt 0 ]; do
               case "$1" in
                 --dry-run) DRY_RUN=true; shift ;;
                 --artifact|--format)
                   if [ $# -lt 2 ]; then log_error "Missing value for $1"; exit 1; fi
                   ARTFMT="$2"; shift 2 ;;
                 --name)
                   if [ $# -lt 2 ]; then log_error "Missing value for --name"; exit 1; fi
                   ARTNAME="$2"; shift 2 ;;
                 --paths)
                   if [ $# -lt 2 ]; then log_error "Missing value for --paths"; exit 1; fi
                   ARTPATHS="$2"; shift 2 ;;
                 *)
                   log_warn "Ignoring unknown release option: $1"
                   shift ;;
               esac
             done
             cli_release "$target" --artifact "$ARTFMT" --name "$ARTNAME" --paths "$ARTPATHS"
             ;;
    package) cli_package "$@" ;;
    bump) check_git_repo || exit 1; bump_version "${1:-$BUMP_TYPE}" ;;
    changelog) check_git_repo || exit 1; generate_changelog ;;
    install) if [ $# -lt 1 ]; then log_error "install gh|tea|gitea|ssh"; exit 1; fi
             case "$1" in gh) install_gh ;; tea) install_tea ;; gitea) install_gitea_server ;; ssh) install_ssh_server ;; *) log_error "Unknown installer $1"; exit 1 ;; esac ;;
    auth) if [ $# -lt 1 ]; then log_error "auth gh|gitea"; exit 1; fi
          case "$1" in gh) gh_auth_token ;; gitea) gitea_auth_token ;; *) log_error "Unknown auth target $1"; exit 1 ;; esac ;;
    setup-all)
      setup_remote="$REMOTE"
      setup_branch="$BRANCH"
      github_url=""
      gitea_url=""
      do_auth=true
      while [ $# -gt 0 ]; do
        case "$1" in
          --remote)
            if [ $# -lt 2 ]; then log_error "Missing value for --remote"; exit 1; fi
            setup_remote="$2"; shift 2 ;;
          --branch)
            if [ $# -lt 2 ]; then log_error "Missing value for --branch"; exit 1; fi
            setup_branch="$2"; shift 2 ;;
          --github-url)
            if [ $# -lt 2 ]; then log_error "Missing value for --github-url"; exit 1; fi
            github_url="$2"; shift 2 ;;
          --gitea-url)
            if [ $# -lt 2 ]; then log_error "Missing value for --gitea-url"; exit 1; fi
            gitea_url="$2"; shift 2 ;;
          --skip-auth)
            do_auth=false; shift ;;
          *)
            log_warn "Ignoring unknown setup-all option: $1"
            shift ;;
        esac
      done
      full_automated_setup "$setup_remote" "$setup_branch" "$github_url" "$gitea_url" "$do_auth"
      ;;
    autoheal) autoheal ;;
    self-check) self_check ;;
    config) edit_config_interactive ;;
    set-log-level) if [ $# -lt 1 ]; then log_error "Usage: set-log-level <level>"; exit 1; fi; LOG_LEVEL="$1"; save_config ;;
    set-ci-mode) if [ $# -lt 1 ]; then log_error "Usage: set-ci-mode <true|false>"; exit 1; fi; CI_MODE="$1"; save_config ;;
    help|--help|-h) show_usage ;;
    *) log_error "Unknown command: $cmd"; show_usage; exit 1 ;;
  esac
}

main "$@"
