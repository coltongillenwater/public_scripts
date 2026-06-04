#!/usr/bin/env zsh

##########################################################
# Written by Colton Gillenwater
# Created on - 3/2/2026
##########################################################
# Script information
# Fully removes OpenClaw and all associated artifacts from
# a macOS system without user interaction. Designed for
# deployment via Iru. Covers running processes, shell hooks,
# launchd services, package manager installs, binaries, app
# bundles, state/config/cache directories, and Docker artifacts.
#
# Reference:
# Official OpenClaw uninstall guide:
# https://docs.openclaw.ai/install/uninstall
# Original script structure from declaw.me;
# significantly modified by Colton Gillenwater.
##########################################################

########################################################################################
######################### SETUP ########################################################
########################################################################################

# Treat unset variables as errors and propagate pipe failures
set -uo pipefail

# Log file written to the user's home directory with a datestamp in the filename
LOG="${HOME}/.declaw_nuke_$(date +%Y%m%d_%H%M%S).log"

# Tee all stdout and stderr to the log file for the duration of the script
exec > >(tee -a "$LOG") 2>&1

########################################################################################
######################### LOG HELPERS ##################################################
########################################################################################

# Four severity levels used throughout; all output is captured by the exec tee above
ok()   { print -- "[OK]    $*"; }
info() { print -- "[INFO]  $*"; }
warn() { print -- "[WARN]  $*"; }
err()  { print -- "[ERROR] $*"; }

########################################################################################
######################### UTILITY FUNCTIONS ############################################
########################################################################################

# Creates a timestamped .bak copy of a file before it is modified
backup_file() {
  local f="$1"
  if [[ -f "$f" ]]; then
    local b="${f}.bak.$(date +%Y%m%d_%H%M%S)"
    cp -p "$f" "$b"
    ok "Backed up $f -> $b"
  fi
}

# Removes a path (file, directory, or symlink) if it exists; logs the outcome either way
safe_rm() {
  local target="$1"
  if [[ -e "$target" || -L "$target" ]]; then
    if rm -rf -- "$target" 2>/dev/null; then
      ok "Removed: $target"
    else
      warn "Failed to remove: $target (check permissions)"
    fi
  else
    info "Not found: $target"
  fi
}

########################################################################################
######################### REMOVAL FUNCTIONS ############################################
########################################################################################

# Sends SIGTERM to any running openclaw, clawdbot, moltbot, or molt.gateway processes.
# Skips this script's own PID and any direct children spawned by it.
kill_running_processes() {
  local killed=0
  local pattern pid ppid_of_pid
  for pattern in openclaw clawdbot moltbot molt.gateway; do
    local pids=("${(@f)$(pgrep -f "$pattern" 2>/dev/null)}")
    for pid in "${pids[@]}"; do
      [[ -z "$pid" ]] && continue
      [[ "$pid" == "$$" ]] && continue
      ppid_of_pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
      [[ "$ppid_of_pid" == "$$" ]] && continue
      if kill "$pid" 2>/dev/null; then
        killed=$((killed + 1))
        ok "Killed PID $pid matching: $pattern"
      fi
    done
  done
  (( killed > 0 )) || info "No running OpenClaw processes found"
}

# Strips OpenClaw, Clawdbot, and Moltbot shell completion hooks from common rc files.
# Backs up each file before modifying it.
remove_shell_hooks() {
  local shell_files=(
    "${HOME}/.zshrc"
    "${HOME}/.zprofile"
    "${HOME}/.zlogin"
    "${HOME}/.bashrc"
    "${HOME}/.bash_profile"
    "${HOME}/.profile"
  )

  local f
  for f in "${shell_files[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -qi 'openclaw\|clawdbot\|moltbot\|molthub' "$f" 2>/dev/null; then
      backup_file "$f"
      local tmp="${f}.tmp.$$"
      awk '
        BEGIN { IGNORECASE=1 }
        {
          line=$0
          if (line ~ /openclaw[[:space:]]+completion/) next
          if (line ~ /source[[:space:]]*<\([[:space:]]*openclaw[[:space:]]+completion/) next
          if (line ~ /^[[:space:]]*#[[:space:]]*openclaw[[:space:]]+completion/) next
          if (line ~ /clawdbot[[:space:]]+completion/) next
          if (line ~ /source[[:space:]]*<\([[:space:]]*clawdbot[[:space:]]+completion/) next
          if (line ~ /^[[:space:]]*#[[:space:]]*clawdbot[[:space:]]+completion/) next
          if (line ~ /moltbot[[:space:]]+completion/) next
          if (line ~ /source[[:space:]]*<\([[:space:]]*moltbot[[:space:]]+completion/) next
          if (line ~ /^[[:space:]]*#[[:space:]]*moltbot[[:space:]]+completion/) next
          print $0
        }
      ' "$f" > "$tmp" && mv "$tmp" "$f"
      ok "Cleaned hooks from ${f}"
    else
      info "No hooks in ${f} (skipping)"
    fi
  done
}

# Attempts the official OpenClaw uninstaller if openclaw is on PATH.
# Failure here is non-fatal; the manual steps below are the authoritative cleanup path.
try_official_uninstall() {
  if command -v openclaw >/dev/null 2>&1; then
    info "Trying official uninstall"
    openclaw uninstall --all --yes --non-interactive >/dev/null 2>&1 || \
      warn "Official uninstall failed/skipped (likely Node mismatch). Continuing with manual removal."
  else
    info "openclaw not on PATH (skipping official uninstall)"
  fi
}

# Unloads and disables all OpenClaw-related launchd jobs for the current user,
# then removes their plist files from ~/Library/LaunchAgents.
remove_launchd_services_macos() {
  local uid="${UID:-$(id -u)}"
  local la="${HOME}/Library/LaunchAgents"
  local labels=("bot.molt.gateway")

  # Discover any matching plists dynamically in addition to the known labels above
  if [[ -d "$la" ]]; then
    local f base
    for f in "$la"/*.plist(N); do
      base="${f:t:r}"
      if [[ "$base" == bot.molt.* || "$base" == com.openclaw.* || "$base" == com.clawdbot.* || "$base" == com.moltbot.* \
         || "$base" == *openclaw* || "$base" == *molt* || "$base" == *clawdbot* ]]; then
        labels+=("$base")
      fi
    done
  fi

  # Deduplicate the labels array before iterating
  labels=("${(@u)labels}")

  local lbl
  for lbl in "${labels[@]}"; do
    info "Stopping launchd job: $lbl"
    launchctl bootout "gui/$uid/$lbl" >/dev/null 2>&1 || true
    launchctl disable "gui/$uid/$lbl" >/dev/null 2>&1 || true
  done

  safe_rm "${HOME}/Library/LaunchAgents/bot.molt.gateway.plist"
  safe_rm "${HOME}/Library/LaunchAgents/com.clawdbot.gateway.plist"
  safe_rm "${HOME}/Library/LaunchAgents/com.moltbot.gateway.plist"

  # Catch any additional matching plists via glob
  if [[ -d "$la" ]]; then
    local p
    for p in "$la"/(com.openclaw.*|bot.molt.*|com.clawdbot.*|com.moltbot.*|*openclaw*|*molt*|*clawdbot*).plist(N); do
      safe_rm "$p"
    done
  fi

  ok "launchd cleanup done"
}

# Removes openclaw and clawdbot global packages via npm, pnpm, and bun (whichever are present),
# and uninstalls Homebrew casks or formulae if applicable.
remove_global_packages() {
  local mgr attempted=0
  for mgr in npm pnpm bun; do
    if command -v "$mgr" >/dev/null 2>&1; then
      info "Removing $mgr global OpenClaw/Clawdbot packages"
      "$mgr" uninstall -g openclaw >/dev/null 2>&1 || true
      "$mgr" uninstall -g clawdbot >/dev/null 2>&1 || true
      attempted=$((attempted + 1))
    fi
  done

  if command -v brew >/dev/null 2>&1; then
    local pkg
    for pkg in openclaw clawdbot; do
      if brew list "$pkg" >/dev/null 2>&1; then
        info "Removing Homebrew package: $pkg"
        brew uninstall --force "$pkg" >/dev/null 2>&1 || true
        attempted=$((attempted + 1))
      fi
    done
  fi

  (( attempted > 0 )) && ok "Global package cleanup done" \
                       || warn "No package managers found; skipping global uninstall"
}

# Removes openclaw binaries and node_modules directories from nodenv version directories.
# These must be cleaned before the shim rehash to prevent nodenv from regenerating stale shims.
remove_nodenv_version_binaries() {
  local root="${HOME}/.nodenv"
  [[ -d "$root" ]] || { info "nodenv not present (skipping)"; return 0; }

  local verbin
  for verbin in "$root"/versions/*/bin/openclaw(N); do
    if [[ -w "$verbin" ]]; then
      safe_rm "$verbin"
    else
      warn "Found but not writable: $verbin"
    fi
  done

  local pkgdir
  for pkgdir in "$root"/versions/*/lib/node_modules/openclaw(N); do
    if [[ -w "$pkgdir" ]]; then
      safe_rm "$pkgdir"
    else
      warn "Found but not writable: $pkgdir"
    fi
  done

  ok "nodenv version binaries cleaned"
}

# Removes openclaw-related shims from ~/.nodenv/shims, then runs nodenv rehash
# to regenerate the shim directory without the removed entries.
remove_nodenv_shims_and_rehash() {
  local shims="${HOME}/.nodenv/shims"
  [[ -d "$shims" ]] || { info "nodenv shims dir missing (skipping)"; return 0; }

  safe_rm "$shims/openclaw"
  safe_rm "$shims/clawhub"
  safe_rm "$shims/clawdhub"

  if command -v nodenv >/dev/null 2>&1; then
    nodenv rehash >/dev/null 2>&1 || true
    ok "nodenv rehash complete"
  else
    warn "nodenv command not found on PATH; skipped rehash"
  fi

  # Clear the shell's command hash table to drop any cached binary locations
  hash -r 2>/dev/null || true
}

# Removes openclaw and clawdbot binaries from user-writable bin locations
# (~/.local/bin, ~/.volta/bin, ~/.nvm/current/bin, ~/bin, and system paths if writable).
# This script does not use sudo, so system paths are skipped if not writable.
remove_user_bins() {
  safe_rm "${HOME}/.local/bin/openclaw"
  safe_rm "${HOME}/.local/bin/clawdbot"
  safe_rm "${HOME}/.local/bin/clawhub"
  safe_rm "${HOME}/.local/bin/clawdhub"

  safe_rm "${HOME}/.volta/bin/openclaw"
  safe_rm "${HOME}/.volta/bin/clawdbot"
  safe_rm "${HOME}/.nvm/current/bin/openclaw"
  safe_rm "${HOME}/.nvm/current/bin/clawdbot"
  safe_rm "${HOME}/bin/openclaw"
  safe_rm "${HOME}/bin/clawdbot"

  local b
  for b in "/opt/homebrew/bin/openclaw" "/usr/local/bin/openclaw" "/usr/bin/openclaw" \
           "/opt/homebrew/bin/clawdbot" "/usr/local/bin/clawdbot" "/usr/bin/clawdbot"; do
    if [[ -e "$b" || -L "$b" ]]; then
      if [[ -w "$b" ]]; then
        safe_rm "$b"
      else
        warn "Found $b but not writable (no sudo in this script)"
      fi
    fi
  done
}

# Removes the OpenClaw, Clawdbot, and Moltbot .app bundles from /Applications,
# and any Homebrew Caskroom/Cellar/opt directories for those packages.
remove_app_bundle() {
  safe_rm "/Applications/OpenClaw.app"
  safe_rm "/Applications/Clawdbot.app"
  safe_rm "/Applications/Moltbot.app"

  # Homebrew install paths require write access; skipped silently if not writable
  local prefix
  for prefix in "/opt/homebrew" "/usr/local"; do
    local d
    for d in "${prefix}/Caskroom/openclaw" \
             "${prefix}/Cellar/openclaw" \
             "${prefix}/opt/openclaw"; do
      if [[ -e "$d" || -L "$d" ]]; then
        if [[ -w "$d" ]]; then
          safe_rm "$d"
        else
          warn "Found $d but not writable (no sudo in this script)"
        fi
      fi
    done
  done

  ok "App bundle cleanup done"
}

# Removes OpenClaw state, config, cache, log directories, wildcard dot-directories,
# and the system-level molt logging plist if writable.
remove_state_and_config() {
  local state="${OPENCLAW_STATE_DIR:-$HOME/.openclaw}"
  safe_rm "$state"

  safe_rm "${HOME}/.openclaw"
  safe_rm "${HOME}/.config/openclaw"
  safe_rm "${HOME}/.cache/openclaw"

  safe_rm "${HOME}/.clawdbot"
  safe_rm "${HOME}/.moltbot"
  safe_rm "${HOME}/.molthub"

  safe_rm "${HOME}/clawd"
  safe_rm "${HOME}/.vscode/extensions/clawdbot"

  safe_rm "${HOME}/Library/Logs/OpenClaw"

  # Catch any additional versioned or variant dot-directories under HOME
  local d
  for d in "${HOME}"/.openclaw-*(N); do
    safe_rm "$d"
  done

  for d in "${HOME}"/.clawdbot-*(N); do
    safe_rm "$d"
  done

  # System-level plist requires sudo to remove; log a warning if not writable
  if [[ -f "/Library/Preferences/Logging/Subsystems/bot.molt.plist" ]]; then
    if [[ -w "/Library/Preferences/Logging/Subsystems/bot.molt.plist" ]]; then
      safe_rm "/Library/Preferences/Logging/Subsystems/bot.molt.plist"
    else
      warn "Found /Library/Preferences/Logging/Subsystems/bot.molt.plist but not writable (requires sudo)"
    fi
  fi
}

# Stops and removes Docker containers and images whose name matches openclaw or clawdbot.
# Skipped entirely if Docker is not installed.
remove_docker_artifacts() {
  command -v docker >/dev/null 2>&1 || { info "Docker not installed (skipping)"; return 0; }

  local containers
  containers=$(docker ps -aq --filter "name=openclaw" 2>/dev/null || true)
  containers+=$'\n'$(docker ps -aq --filter "name=clawdbot" 2>/dev/null || true)
  containers=${containers##$'\n'}
  containers=${containers%%$'\n'}
  if [[ -n "$containers" ]]; then
    info "Stopping and removing Docker containers"
    echo "$containers" | while read -r cid; do
      [[ -n "$cid" ]] && docker rm -f "$cid" >/dev/null 2>&1 || true
    done
  else
    info "No OpenClaw Docker containers found"
  fi

  local images
  images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -iE "openclaw|clawdbot" || true)
  if [[ -n "$images" ]]; then
    info "Removing Docker images"
    echo "$images" | while read -r img; do
      [[ -n "$img" ]] && docker rmi -f "$img" >/dev/null 2>&1 || true
    done
  else
    info "No OpenClaw Docker images found"
  fi

  ok "Docker cleanup done"
}

########################################################################################
######################### VERIFICATION #################################################
########################################################################################

# Verifies that openclaw has been fully removed by checking for residual processes,
# launchd entries, PATH resolution, and shell file references.
# Prints manual steps for revoking OAuth tokens, which cannot be scripted.
final_checks() {
  hash -r 2>/dev/null || true
  info "Running final checks"

  # Check for any surviving OpenClaw-related processes
  local procs
  procs=$(ps aux 2>/dev/null | grep -i '[o]penclaw\|[c]lawdbot\|[m]oltbot\|[m]olt.gateway' || true)
  if [[ -n "$procs" ]]; then
    warn "OpenClaw-related processes still running:"
    print "$procs"
  else
    ok "No running OpenClaw processes found"
  fi

  # Confirm launchd no longer lists any related services
  if launchctl list 2>/dev/null | grep -qi 'molt\|openclaw\|clawdbot'; then
    warn "launchd still lists OpenClaw-related services:"
    launchctl list 2>/dev/null | grep -i 'molt\|openclaw\|clawdbot' || true
  else
    ok "No launchd services found"
  fi

  # Verify openclaw no longer resolves on PATH; return 1 to signal failure if it does
  if command -v openclaw >/dev/null 2>&1; then
    warn "openclaw STILL resolves to: $(command -v openclaw)"
    info "type -a openclaw:"
    type -a openclaw || true

    if [[ -d "${HOME}/.nodenv/versions" ]]; then
      info "nodenv versions still providing openclaw (if any):"
      ls -la "${HOME}/.nodenv/versions/"*/bin/openclaw 2>/dev/null || true
    fi
    return 1
  else
    ok "openclaw is gone from PATH"
  fi

  # Scan shell rc files for any remaining OpenClaw references
  info "Searching shell files for remaining OpenClaw references"
  grep -ni 'openclaw\|clawdbot\|moltbot\|molthub' \
    "${HOME}/.zshrc" "${HOME}/.zprofile" "${HOME}/.zlogin" \
    "${HOME}/.bashrc" "${HOME}/.bash_profile" "${HOME}/.profile" 2>/dev/null \
    && warn "Found remaining references above" \
    || ok "No shell references found"

  # OAuth tokens on external services must be revoked manually after local removal
  print ""
  warn "Remember to manually revoke OAuth tokens for OpenClaw in:"
  info "  - GitHub  -> Settings -> Applications -> Authorized OAuth Apps"
  info "  - Google  -> myaccount.google.com -> Security -> Third-party apps"
  info "  - Slack   -> Workspace Settings -> Manage Apps"
  info "  - Discord -> User Settings -> Authorized Apps"
  info "  Credentials may persist on external servers even after local removal."
  print ""

  ok "Done. Log saved to: $LOG"
}

########################################################################################
######################### MAIN #########################################################
########################################################################################

main() {
  info "Starting OpenClaw removal. Log: $LOG"

  info "Step  1/12: Killing running OpenClaw processes"
  kill_running_processes

  info "Step  2/12: Removing shell auto-run hooks"
  remove_shell_hooks

  info "Step  3/12: Trying official uninstaller (if runnable)"
  try_official_uninstall

  info "Step  4/12: Removing launchd services"
  remove_launchd_services_macos

  info "Step  5/12: Removing global packages (npm/pnpm/bun/brew)"
  remove_global_packages

  info "Step  6/12: Removing nodenv version binaries"
  remove_nodenv_version_binaries

  info "Step  7/12: Removing nodenv shims and rehashing"
  remove_nodenv_shims_and_rehash

  info "Step  8/12: Removing leftover binaries"
  remove_user_bins

  info "Step  9/12: Removing app bundles"
  remove_app_bundle

  info "Step 10/12: Removing state, config, cache, and logs"
  remove_state_and_config

  info "Step 11/12: Removing Docker artifacts"
  remove_docker_artifacts

  info "Step 12/12: Running final verification"
  if ! final_checks; then
    err "Declaw finished but openclaw still resolves on PATH. See log: $LOG"
    exit 1
  fi

  ok "All done. OpenClaw should be fully removed."
  exit 0
}

main "$@"
