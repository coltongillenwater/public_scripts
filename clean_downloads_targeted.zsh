#!/bin/zsh

##########################################################
# Written by Colton Gillenwater
# Created on - 2/14/2026
##########################################################
# Script information
# Removes a targeted list of .app bundles from the console
# user's Downloads folder. Designed to clean up leftover
# installer copies and duplicate application bundles that
# accumulate in Downloads during software deployments.
##########################################################

########################################################################################
######################### SETUP ########################################################
########################################################################################

# Treat references to unset variables as errors; -e omitted so a
# missing target file does not abort the entire run
set -u

# Writes a timestamped line to stdout for consistent log formatting
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Removes a file or directory bundle, logging the outcome either way
remove_file() {
    local file="$1"
    if [[ -e "$file" ]]; then
        log_message "Attempting to remove: $file"
        if rm -rf "$file" 2>/dev/null; then
            log_message "Successfully removed: $file"
            return 0
        else
            log_message "ERROR: Failed to remove: $file (may be in use or permission denied)"
            return 1
        fi
    else
        log_message "File not found (may have been already removed): $file"
        return 1
    fi
}

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Explicit list of .app bundles to remove from the console user's Downloads folder.
# Include installer .app copies and numbered duplicates (e.g. "YourApp 2.app").
# Customize this list for apps and installers your environment leaves in Downloads.
TARGET_APPS=(
    "Google Chrome.app"
    "Visual Studio Code 2.app"
    "Visual Studio Code 3.app"
    "Postman Agent.app"
    "Postman.app"
    "Example Installer.app"
    "Install Example App.app"
    "1Password Installer.app"
)

########################################################################################
######################### USER DETECTION ###############################################
########################################################################################

# Resolve the currently logged-in console user via SystemConfiguration
MACUSER=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && ! /loginwindow/ { print $3 }')

# Abort if scutil returned more than one result (e.g. Fast User Switching is active)
USER_COUNT=$(echo "$MACUSER" | wc -l | tr -d ' ')
if [ "$USER_COUNT" -ne 1 ]; then
    log_message "ERROR: Found $USER_COUNT users, expected exactly 1:"
    log_message "$MACUSER"
    log_message "Please modify the script to handle multiple users or filter more specifically."
    exit 1
fi

# Guard against an empty result from scutil
if [ -z "$MACUSER" ]; then
    log_message "ERROR: MACUSER variable is empty"
    exit 1
else
    log_message "Found user: $MACUSER"
fi

# Resolve the user's home directory path from the local Directory Service
USERHOME=$(/usr/bin/dscl . -read "/Users/$MACUSER" NFSHomeDirectory | /usr/bin/sed 's/^[^\/]*//g')

# Abort if dscl returned an empty path
if [ -z "$USERHOME" ]; then
    log_message "ERROR: Could not retrieve home directory for user $MACUSER"
    exit 1
fi

# Abort if the resolved home directory does not exist on disk
if [[ ! -d "$USERHOME" ]]; then
    log_message "ERROR: Home directory does not exist: $USERHOME"
    exit 1
fi

log_message "User home directory: $USERHOME"

########################################################################################
######################### CLEANUP ######################################################
########################################################################################

# Exit cleanly if the Downloads folder itself is missing — nothing to do
DOWNLOADS_DIR="$USERHOME/Downloads"
if [[ ! -d "$DOWNLOADS_DIR" ]]; then
    log_message "Downloads directory not found: $DOWNLOADS_DIR"
    exit 0
fi

log_message "Starting targeted Downloads cleanup for specific .app files"
log_message "Target user: $MACUSER"
log_message "Downloads directory: $DOWNLOADS_DIR"
log_message "Target files: ${TARGET_APPS[*]}"

# Enumerate all .app bundles currently in Downloads for diagnostic reference
log_message "Contents of Downloads directory:"
target_files=$(ls -la "$DOWNLOADS_DIR"/*.app 2>/dev/null || echo "No .app files found")
log_message "$target_files"

# Tracks how many target bundles were successfully removed this run
app_count=0

log_message "Searching for target .app files in Downloads..."

# Iterate over each target; remove it only if it exists
for target_app in "${TARGET_APPS[@]}"; do
    app_file="$DOWNLOADS_DIR/$target_app"
    log_message "Checking for: $app_file"

    if [[ -e "$app_file" ]]; then
        log_message "Found target file: $target_app"
        if remove_file "$app_file"; then
            app_count=$((app_count + 1))
            log_message "Successfully processed .app file, count now: $app_count"
        else
            log_message "Failed to remove .app file: $app_file"
        fi
    else
        log_message "Target file not found: $target_app"
    fi
done

########################################################################################
######################### RESULTS ######################################################
########################################################################################

log_message "Processing target .app files complete"
log_message "Cleanup complete:"
log_message "  .app files removed: $app_count"

if [[ $app_count -eq 0 ]]; then
    log_message "No target .app files found in Downloads"
fi

exit 0
