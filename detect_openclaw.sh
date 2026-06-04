#!/bin/bash

##########################################################
# Written by Colton Gillenwater
# Created on - 6/1/2026
##########################################################
# Script information
# Read-only detection script that scans a macOS system for
# all known artifacts of OpenClaw, ClawdBot, and MoltBot.
# Reports findings to a centralized log file without making
# any changes to the system. Must be run as root to inspect
# all user home directories. Intended for use with Iru.
##########################################################

########################################################################################
######################### SETUP ########################################################
########################################################################################

# Treat unset variables as errors
set -u

# Expand unmatched globs to nothing rather than leaving the literal pattern in place
shopt -s nullglob

# Log all findings to the log directory
LOG_DIR="/Library/Logs"
LOG_FILE="${LOG_DIR}/openclaw_detection.log"
mkdir -p "$LOG_DIR"

# Running tally of detected artifacts; used to determine the exit code at the end
TOTAL_FOUND=0

########################################################################################
######################### LOG HELPERS ##################################################
########################################################################################

# Writes a timestamped message to stdout and appends it to the log file
log() {
    echo "[$(date "+%Y-%m-%d %H:%M:%S")] $1" | tee -a "$LOG_FILE"
}

# Writes a titled separator block to the log to delimit major detection phases
log_section() {
    log "============================================"
    log "$1"
    log "============================================"
}

# Logs a confirmed detection hit and increments the global artifact counter
log_found() {
    log "FOUND: $1"
    TOTAL_FOUND=$((TOTAL_FOUND + 1))
}

# Abort early if not running as root; /Library/Logs also requires root to write
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root (via Iru)"
    exit 1
fi

log_section "Starting OpenClaw/ClawdBot/MoltBot Detection (Read-Only)"

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Application bundle names across all known product generations
APP_NAMES=(
    "OpenClaw"
    "ClawdBot"
    "MoltBot"
)

# macOS bundle identifiers covering all known app and gateway variants
BUNDLE_IDS=(
    "com.openclaw.app"
    "com.openclaw.gateway"
    "com.clawdbot.app"
    "com.clawdbot.gateway"
    "bot.molt.app"
    "bot.molt.gateway"
    "ai.openclaw.app"
    "ai.openclaw.gateway"
)

# launchd job labels covering both user-level agents and system-level daemons
LAUNCHD_LABELS=(
    "com.openclaw.gateway"
    "com.openclaw.app"
    "com.clawdbot.gateway"
    "com.clawdbot.app"
    "bot.molt.gateway"
    "bot.molt.app"
)

# Expected plist filenames in ~/Library/LaunchAgents
LAUNCHAGENT_PLISTS=(
    "com.openclaw.gateway.plist"
    "com.openclaw.app.plist"
    "com.clawdbot.gateway.plist"
    "com.clawdbot.app.plist"
    "bot.molt.gateway.plist"
    "bot.molt.app.plist"
)

# Package names as registered in npm, pnpm, and bun registries
NPM_PACKAGES=(
    "openclaw"
    "moltbot"
    "clawdbot"
)

# Homebrew formula and cask names (both base names and -cli variants)
BREW_FORMULAS=(
    "openclaw"
    "openclaw-cli"
    "clawdbot"
    "clawdbot-cli"
    "moltbot"
    "moltbot-cli"
)

# Process names checked against the running process table
PROCESS_NAMES=(
    "openclaw"
    "OpenClaw"
    "clawdbot"
    "ClawdBot"
    "moltbot"
    "MoltBot"
    "openclaw-gateway"
    "clawdbot-gateway"
    "moltbot-gateway"
)

# Top-level dot-directories expected in a user's home folder
CONFIG_DIRS=(
    ".openclaw"
    ".clawdbot"
    ".moltbot"
)

# Prefixes for profile-scoped config directories (e.g. .openclaw-myprofile)
PROFILE_PREFIXES=(
    ".openclaw-"
    ".clawdbot-"
    ".moltbot-"
)

########################################################################################
######################### HELPER FUNCTIONS #############################################
########################################################################################

# Enumerate all local human users (UID >= 501) and their home directories.
# Done once at startup so all detection phases can iterate without re-querying dscl.
LOCAL_USERNAMES=()
LOCAL_USERHOMES=()

while IFS= read -r username; do
    uid=$(dscl . read /Users/"$username" UniqueID 2>/dev/null | awk '{print $2}')
    if [[ -n "$uid" && "$uid" -ge 501 ]]; then
        home=$(dscl . read /Users/"$username" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
        if [[ -d "$home" ]]; then
            LOCAL_USERNAMES+=("$username")
            LOCAL_USERHOMES+=("$home")
        fi
    fi
done < <(dscl . list /Users)

log "Found ${#LOCAL_USERNAMES[@]} local user(s): ${LOCAL_USERNAMES[*]}"

# Checks whether a path exists as a file, directory, or symlink and logs it as a hit
check_path() {
    local path="$1"
    if [[ -e "$path" || -L "$path" ]]; then
        log_found "$path"
        return 0
    fi
    return 1
}

########################################################################################
######################### PHASE 1: PROCESSES AND SERVICES ##############################
########################################################################################

log_section "Phase 1: Detecting running processes and services"

# Exact-name match against the running process table
log "Checking for running processes..."
for proc in "${PROCESS_NAMES[@]}"; do
    pids=$(pgrep -x "$proc")
    if [[ -n "$pids" ]]; then
        log_found "Running process: $proc (PIDs: $pids)"
    fi
done

# Pattern match to catch node processes hosting the gateway under a generic node binary name
for pattern in openclaw clawdbot moltbot; do
    pids=$(pgrep -f "$pattern")
    if [[ -n "$pids" ]]; then
        log_found "Running process matching pattern '$pattern' (PIDs: $pids)"
    fi
done

# Direct label lookup for loaded user-level LaunchAgents
log "Checking loaded LaunchAgents for all users..."
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"

    uid=$(id -u "$username")
    [[ -z "$uid" ]] && continue

    for label in "${LAUNCHD_LABELS[@]}"; do
        if launchctl print "gui/$uid/$label" &>/dev/null; then
            log_found "Loaded LaunchAgent: $label for user $username"
        fi
    done

    # Pattern-based scan to catch profile-scoped labels (e.g. bot.molt.gateway.myprofile)
    for pattern in openclaw clawdbot moltbot bot.molt; do
        while IFS= read -r loaded_label; do
            [[ -z "$loaded_label" ]] && continue
            if [[ "$loaded_label" == *"$pattern"* ]]; then
                log_found "Loaded LaunchAgent matching '$pattern': $loaded_label for user $username"
            fi
        done < <(launchctl print "gui/$uid" | grep -i "$pattern" | awk '{print $NF}')
    done
done

# System LaunchDaemons run in the system domain rather than per-user gui sessions
log "Checking loaded system LaunchDaemons..."
for label in "${LAUNCHD_LABELS[@]}"; do
    if launchctl list "$label" &>/dev/null; then
        log_found "Loaded LaunchDaemon: $label"
    fi
done

########################################################################################
######################### PHASE 2: APPLICATIONS ########################################
########################################################################################

log_section "Phase 2: Detecting applications"

# System-wide /Applications by exact bundle name
for app in "${APP_NAMES[@]}"; do
    check_path "/Applications/${app}.app"
done

# Per-user ~/Applications folders by exact bundle name
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    for app in "${APP_NAMES[@]}"; do
        check_path "$home/Applications/${app}.app"
    done
done

# Pattern-based glob for /Applications and /Applications/Utilities (catches renamed or versioned copies)
for dir in /Applications /Applications/Utilities; do
    for pattern in openclaw clawdbot moltbot; do
        for app in "$dir"/*"$pattern"*.app; do
            check_path "$app"
        done
    done
done

# Pattern-based glob for per-user ~/Applications folders
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    if [[ -d "$home/Applications" ]]; then
        for pattern in openclaw clawdbot moltbot; do
            for app in "$home/Applications"/*"$pattern"*.app; do
                check_path "$app"
            done
        done
    fi
done

########################################################################################
######################### PHASE 3: LAUNCHAGENT AND LAUNCHDAEMON PLISTS ################
########################################################################################

log_section "Phase 3: Detecting LaunchAgent/LaunchDaemon plists"

# Known plist filenames in each user's ~/Library/LaunchAgents
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"

    for plist in "${LAUNCHAGENT_PLISTS[@]}"; do
        check_path "$home/Library/LaunchAgents/$plist"
    done

    # Pattern-based glob to catch profile-scoped plists (e.g. bot.molt.gateway.myprofile.plist)
    for pattern in openclaw clawdbot moltbot "bot.molt"; do
        for plist in "$home/Library/LaunchAgents"/*"$pattern"*.plist; do
            check_path "$plist"
        done
    done
done

# Known labels as system LaunchDaemon plists in /Library/LaunchDaemons
for label in "${LAUNCHD_LABELS[@]}"; do
    check_path "/Library/LaunchDaemons/${label}.plist"
done

# Pattern-based glob for both system daemons and system-level agents
for pattern in openclaw clawdbot moltbot "bot.molt"; do
    for plist in /Library/LaunchDaemons/*"$pattern"*.plist; do
        check_path "$plist"
    done
    for plist in /Library/LaunchAgents/*"$pattern"*.plist; do
        check_path "$plist"
    done
done

########################################################################################
######################### PHASE 4: NPM/PNPM/BUN GLOBAL PACKAGES #######################
########################################################################################

log_section "Phase 4: Detecting npm/pnpm/bun global packages"

# Queries each package manager's global list running as the target user to respect
# their npm prefix and pnpm store configuration. Falls back gracefully if a manager
# is not present for this user.
detect_packages_native() {
    local user="$1"
    local home="$2"

    # Locate npm — prefer nvm-managed versions over system-level installs
    local npm_path=""
    for p in "$home/.nvm/versions/node"/*/bin/npm /opt/homebrew/bin/npm /usr/local/bin/npm /usr/bin/npm; do
        if [[ -x "$p" ]]; then
            npm_path="$p"
            break
        fi
    done

    # Locate pnpm — prefer the user's local share install over system paths
    local pnpm_path=""
    for p in "$home/.local/share/pnpm/pnpm" "$home/Library/pnpm/pnpm" /opt/homebrew/bin/pnpm /usr/local/bin/pnpm; do
        if [[ -x "$p" ]]; then
            pnpm_path="$p"
            break
        fi
    done

    # Locate bun — prefer the user's ~/.bun install over system paths
    local bun_path=""
    for p in "$home/.bun/bin/bun" /opt/homebrew/bin/bun /usr/local/bin/bun; do
        if [[ -x "$p" ]]; then
            bun_path="$p"
            break
        fi
    done

    if [[ -n "$npm_path" ]]; then
        log "Found npm at $npm_path for user $user"
        for pkg in "${NPM_PACKAGES[@]}"; do
            if sudo -u "$user" "$npm_path" list -g "$pkg" &>/dev/null; then
                log_found "npm global package: $pkg (user: $user)"
            fi
        done
    fi

    if [[ -n "$pnpm_path" ]]; then
        log "Found pnpm at $pnpm_path for user $user"
        for pkg in "${NPM_PACKAGES[@]}"; do
            if sudo -u "$user" "$pnpm_path" list -g "$pkg" &>/dev/null; then
                log_found "pnpm global package: $pkg (user: $user)"
            fi
        done
    fi

    if [[ -n "$bun_path" ]]; then
        log "Found bun at $bun_path for user $user"
        for pkg in "${NPM_PACKAGES[@]}"; do
            if sudo -u "$user" "$bun_path" pm ls -g | grep -q "$pkg"; then
                log_found "bun global package: $pkg (user: $user)"
            fi
        done
    fi
}

# Checks for package module directories and binaries directly on disk.
# Covers installs done outside the standard prefix and cases where the
# package manager binary is no longer accessible.
detect_npm_package_files() {
    local user="$1"
    local home="$2"

    for pkg in "${NPM_PACKAGES[@]}"; do
        check_path "$home/.npm-global/lib/node_modules/$pkg"
        check_path "/usr/local/lib/node_modules/$pkg"

        # pnpm stores globals under a versioned subdirectory (e.g. global/5/)
        check_path "$home/.local/share/pnpm/global/5/node_modules/$pkg"
        for pnpm_global in "$home/Library/pnpm/global"/*"/node_modules/$pkg"; do
            check_path "$pnpm_global"
        done

        check_path "$home/.bun/install/global/node_modules/$pkg"
        check_path "/opt/homebrew/lib/node_modules/$pkg"
        check_path "/usr/local/lib/node_modules/$pkg"
    done

    # Check installed binaries separately from module directories
    for pkg in "${NPM_PACKAGES[@]}"; do
        check_path "$home/.npm-global/bin/$pkg"
        check_path "$home/.local/share/pnpm/$pkg"
        check_path "$home/.bun/bin/$pkg"
        check_path "/usr/local/bin/$pkg"
        check_path "/opt/homebrew/bin/$pkg"
    done
}

# Run both detection methods for every local user
for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"
    log "Checking npm/pnpm/bun packages for user: $username"

    detect_packages_native "$username" "$home"
    detect_npm_package_files "$username" "$home"
done

########################################################################################
######################### PHASE 5: HOMEBREW PACKAGES ###################################
########################################################################################

log_section "Phase 5: Detecting Homebrew packages"

# Resolve the Homebrew binary; Apple Silicon installs to /opt/homebrew, Intel to /usr/local
BREW_PATH=""
if [[ -x "/opt/homebrew/bin/brew" ]]; then
    BREW_PATH="/opt/homebrew/bin/brew"
elif [[ -x "/usr/local/bin/brew" ]]; then
    BREW_PATH="/usr/local/bin/brew"
fi

if [[ -n "$BREW_PATH" ]]; then
    log "Found Homebrew at: $BREW_PATH"

    # Homebrew must be invoked as its installation owner, not as root
    brew_owner=$(stat -f '%Su' "$BREW_PATH")
    log "Homebrew owned by: $brew_owner"

    for formula in "${BREW_FORMULAS[@]}"; do
        if sudo -u "$brew_owner" "$BREW_PATH" list --formula "$formula" &>/dev/null; then
            log_found "Homebrew formula: $formula"
        fi

        if sudo -u "$brew_owner" "$BREW_PATH" list --cask "$formula" &>/dev/null; then
            log_found "Homebrew cask: $formula"
        fi
    done
else
    log "Homebrew not found"
fi

# Check Cellar/Caskroom directories and binaries on disk in case brew list is unreliable
for formula in "${BREW_FORMULAS[@]}"; do
    check_path "/opt/homebrew/Cellar/$formula"
    check_path "/opt/homebrew/Caskroom/$formula"
    check_path "/usr/local/Cellar/$formula"
    check_path "/usr/local/Caskroom/$formula"
    check_path "/opt/homebrew/bin/$formula"
    check_path "/usr/local/bin/$formula"
done

########################################################################################
######################### PHASE 6: CONFIGURATION AND DATA DIRECTORIES #################
########################################################################################

log_section "Phase 6: Detecting configuration and data directories"

for i in "${!LOCAL_USERNAMES[@]}"; do
    username="${LOCAL_USERNAMES[$i]}"
    home="${LOCAL_USERHOMES[$i]}"

    log "Checking config directories for user: $username"

    # Top-level dot-directories in the home folder
    for config_dir in "${CONFIG_DIRS[@]}"; do
        check_path "$home/$config_dir"
    done

    # Profile-scoped dot-directories (e.g. .openclaw-myprofile, .clawdbot-work)
    for prefix in "${PROFILE_PREFIXES[@]}"; do
        for profile_dir in "$home"/"${prefix}"*; do
            check_path "$profile_dir"
        done
    done

    # ~/Library/Application Support — exact names and pattern-matched variants
    for app in "${APP_NAMES[@]}"; do
        check_path "$home/Library/Application Support/$app"
        check_path "$home/Library/Application Support/com.$app"
    done
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Application Support"/*"$pattern"*; do
            check_path "$dir"
        done
    done

    # ~/Library/Caches — exact names and pattern-matched variants
    for app in "${APP_NAMES[@]}"; do
        check_path "$home/Library/Caches/$app"
        check_path "$home/Library/Caches/com.$app"
    done
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Caches"/*"$pattern"*; do
            check_path "$dir"
        done
    done

    # ~/Library/Preferences — plist files by bundle ID and by pattern
    for bid in "${BUNDLE_IDS[@]}"; do
        check_path "$home/Library/Preferences/${bid}.plist"
    done
    for pattern in openclaw clawdbot moltbot; do
        for plist in "$home/Library/Preferences"/*"$pattern"*.plist; do
            check_path "$plist"
        done
    done

    # ~/Library/Saved Application State
    for bid in "${BUNDLE_IDS[@]}"; do
        check_path "$home/Library/Saved Application State/${bid}.savedState"
    done

    # ~/Library/Logs
    for app in "${APP_NAMES[@]}"; do
        check_path "$home/Library/Logs/$app"
    done
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Logs"/*"$pattern"*; do
            check_path "$dir"
        done
    done

    # ~/Library/Containers — used by sandboxed application variants
    for bid in "${BUNDLE_IDS[@]}"; do
        check_path "$home/Library/Containers/$bid"
    done

    # ~/Library/Group Containers — shared data between app and its extensions
    for pattern in openclaw clawdbot moltbot; do
        for dir in "$home/Library/Group Containers"/*"$pattern"*; do
            check_path "$dir"
        done
    done

    # ~/Library/HTTPStorages and ~/Library/WebKit — browser-engine data stores
    for bid in "${BUNDLE_IDS[@]}"; do
        check_path "$home/Library/HTTPStorages/$bid"
        check_path "$home/Library/WebKit/$bid"
    done

done

########################################################################################
######################### PHASE 7: SYSTEM-LEVEL FILES AND RECEIPTS ####################
########################################################################################

log_section "Phase 7: Detecting system-level files and receipts"

# Package receipts registered with pkgutil (created by .pkg installers)
log "Checking package receipts via pkgutil..."
for pattern in openclaw clawdbot moltbot; do
    while IFS= read -r pkg_id; do
        [[ -z "$pkg_id" ]] && continue
        log_found "Package receipt: $pkg_id"
    done < <(pkgutil --pkgs | grep -i "$pattern")
done

# Physical receipt files in /var/db/receipts (both .bom and .plist forms)
for pattern in openclaw clawdbot moltbot; do
    for receipt in /var/db/receipts/*"$pattern"*.bom /var/db/receipts/*"$pattern"*.plist; do
        check_path "$receipt"
    done
done

# macOS per-user temp containers under /private/var/folders (hashed path structure)
for pattern in openclaw clawdbot moltbot; do
    for dir in /private/var/folders/*/*/"$pattern"*; do
        check_path "$dir"
    done
done

# /tmp and /private/tmp for any transient files left behind by the installer or runtime
for pattern in openclaw clawdbot moltbot; do
    for tmpfile in /tmp/*"$pattern"*; do
        check_path "$tmpfile"
    done
    for tmpfile in /private/tmp/*"$pattern"*; do
        check_path "$tmpfile"
    done
done

########################################################################################
######################### SUMMARY ######################################################
########################################################################################

log_section "Detection Complete"

# Exit 0 if clean; exit 1 if any artifacts were found (allows Iru to act on the result)
if [[ $TOTAL_FOUND -eq 0 ]]; then
    log "RESULT: No OpenClaw/ClawdBot/MoltBot components detected."
    log "The system appears clean."
    exit 0
else
    log "RESULT: Detected $TOTAL_FOUND OpenClaw/ClawdBot/MoltBot component(s)."
    log "Review the log at $LOG_FILE for details."
    log ""
    log "To remove these components, run the uninstall script."
    exit 1
fi
