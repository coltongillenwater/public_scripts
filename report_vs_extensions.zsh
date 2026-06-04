#!/bin/zsh

##########################################################
# Written by Colton Gillenwater
# Created on - 3/14/2026
##########################################################
# Script information
# Reports all installed extensions for VS Code-family editors
# across every user profile on a macOS device. Covers VS Code,
# VS Code Insiders, Cursor, Windsurf, VSCodium, Positron, and
# Trae. When run as root it inspects all local user profiles;
# otherwise it reports only the invoking user. Designed for
# deployment via Iru (Kandji) MDM.
##########################################################

########################################################################################
######################### SETUP ########################################################
########################################################################################

# Treat unset variables as errors and propagate pipe failures
set -uo pipefail

# Resolve the currently logged-in console user for the report header
CONSOLE_USER=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Parallel arrays — index N in each array describes the same editor variant.
# VARIANT_DIRS holds the hidden dot-directory under each user's home where that
# editor stores its extensions; VARIANT_LABELS is the display name for the report.
VARIANT_DIRS=(".vscode" ".vscode-insiders" ".cursor" ".windsurf" ".vscode-oss" ".positron" ".trae")
VARIANT_LABELS=("VS Code" "VS Code Insiders" "Cursor" "Windsurf" "VSCodium" "Positron" "Trae")

# .app bundle names to probe in /Applications for version reporting
APP_NAMES=(
    "Visual Studio Code"
    "Visual Studio Code - Insiders"
    "Cursor"
    "Windsurf"
    "VSCodium"
    "Positron"
    "Trae"
)

########################################################################################
######################### HELPER FUNCTIONS #############################################
########################################################################################

# Returns a newline-delimited list of local usernames to inspect.
# When running as root, enumerates all home directories under /Users excluding Shared
# and .localized. When running as a normal user, returns only the invoking user.
get_users_to_check() {
    if [[ $EUID -eq 0 ]]; then
        for dir in /Users/*(N/); do
            local name="${dir:t}"
            [[ "$name" == "Shared" || "$name" == ".localized" ]] && continue
            echo "$name"
        done
    else
        whoami
    fi
}

# Resolves a user's home directory via dscl, falling back to /Users/<username>
# if dscl returns nothing or the returned path does not exist on disk
get_home_dir() {
    local user="$1"
    local result
    result=$(/usr/bin/dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null \
        | /usr/bin/sed 's/^[^\/]*//g') || true
    if [[ -z "$result" || ! -d "$result" ]]; then
        result="/Users/$user"
    fi
    echo "$result"
}

# Strips the version and platform suffix from an extension folder name to produce
# the canonical publisher.name identifier.
# Extension folders follow the pattern: publisher.name-version[-platform]
# e.g. ms-python.python-2025.6.1-darwin-arm64 -> ms-python.python
parse_extension_id() {
    echo "${1%-[0-9]*}"
}

# Lists all installed extension IDs from a given extensions directory,
# deduplicated and sorted. Skips hidden dot-entries.
collect_extensions() {
    local ext_dir="$1"

    for entry in "$ext_dir"/*(N/); do
        local name="${entry:t}"
        [[ "$name" == .* ]] && continue
        parse_extension_id "$name"
    done | /usr/bin/sort -uf
}

########################################################################################
######################### APPLICATION DETECTION ########################################
########################################################################################

# Probes /Applications for each known editor and reads its version from Info.plist
detect_installed_apps() {
    echo "=== INSTALLED APPLICATIONS ==="
    local found=false
    for app_name in "${APP_NAMES[@]}"; do
        local app_path="/Applications/${app_name}.app"
        if [[ -d "$app_path" ]]; then
            found=true
            local version="unknown"
            local plist="$app_path/Contents/Info.plist"
            if [[ -f "$plist" ]]; then
                version=$(/usr/bin/defaults read "$plist" CFBundleShortVersionString 2>/dev/null || echo "unknown")
            fi
            echo "  ${app_name}: $version"
        fi
    done
    if [[ "$found" == false ]]; then
        echo "  none"
    fi
    echo ""
}

########################################################################################
######################### MAIN #########################################################
########################################################################################

main() {
    # Report header with timestamp, hostname, and console user for log correlation
    echo "=== CODE EDITOR EXTENSION REPORT ==="
    echo "timestamp: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "hostname: $(/bin/hostname)"
    echo "console_user: ${CONSOLE_USER:-none}"
    echo ""

    detect_installed_apps

    echo "=== EXTENSIONS BY USER ==="

    local users
    users=$(get_users_to_check)

    if [[ -z "$users" ]]; then
        echo "  no user profiles found"
        echo ""
        echo "=== REPORT COMPLETE ==="
        return 0
    fi

    # Accumulate all extension IDs across all users for the final unique count
    local all_extensions=""

    while IFS= read -r user; do
        [[ -z "$user" ]] && continue

        local home_dir
        home_dir=$(get_home_dir "$user")
        echo "user: $user ($home_dir)"

        local user_has_extensions=false

        # Iterate each editor variant using 1-based index to walk the parallel arrays
        for i in {1..${#VARIANT_DIRS[@]}}; do
            local dir_name="${VARIANT_DIRS[$i]}"
            local label="${VARIANT_LABELS[$i]}"
            local ext_dir="$home_dir/$dir_name/extensions"

            [[ ! -d "$ext_dir" ]] && continue

            local ext_list
            ext_list=$(collect_extensions "$ext_dir")
            [[ -z "$ext_list" ]] && continue

            user_has_extensions=true
            local count
            count=$(echo "$ext_list" | /usr/bin/wc -l | /usr/bin/tr -d ' ')
            echo "  $label ($count):"
            echo "$ext_list" | while IFS= read -r ext; do
                echo "    $ext"
            done

            all_extensions+="${ext_list}"$'\n'
        done

        if [[ "$user_has_extensions" == false ]]; then
            echo "  no extensions found"
        fi
        echo ""
    done <<< "$users"

    # Deduplicate across all users to report how many distinct extensions exist on the device
    local total=0
    if [[ -n "$all_extensions" ]]; then
        total=$(printf '%s' "$all_extensions" | /usr/bin/sort -uf | /usr/bin/grep -c . 2>/dev/null || echo 0)
    fi

    echo "=== SUMMARY ==="
    echo "total_unique_extensions: $total"
    echo "=== REPORT COMPLETE ==="
}

main
exit 0
