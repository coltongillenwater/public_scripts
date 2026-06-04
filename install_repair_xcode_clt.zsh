#!/bin/zsh

##########################################################
# Written by Colton Gillenwater
# Created on - 1/8/2026
##########################################################
# Script information
# Installs or repairs the Xcode Command Line Tools using
# softwareupdate. Detects whether the CLT is missing or
# broken and acts accordingly, retrying installation with
# exponential backoff on failure. Also accepts the Xcode
# license if the full Xcode.app is present. Intended for
# deployment via Iru and must run as root.
##########################################################

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Maximum number of softwareupdate install attempts before giving up
MAX_RETRIES=3

# Initial wait time in seconds between retries; doubled after each failed attempt
RETRY_DELAY=30

# Canonical paths used to verify CLT presence and functionality
CLT_DIR="/Library/Developer/CommandLineTools"
CLT_XCRUN="/usr/bin/xcrun"
CLT_GIT="$CLT_DIR/usr/bin/git"

########################################################################################
######################### HELPER FUNCTIONS #############################################
########################################################################################

# Returns true if the CLT directory and xcrun binary both exist on disk.
# File existence is used rather than xcrun invocation to avoid triggering
# the interactive install prompt that xcrun emits when CLT is missing.
clt_installed() {
    [[ -d "$CLT_DIR" ]] && [[ -x "$CLT_XCRUN" ]]
}

# Returns true if the CLT is present AND xcrun executes without error.
# Only call after clt_installed confirms the files exist.
clt_functional() {
    clt_installed && "$CLT_XCRUN" --version &>/dev/null
}

########################################################################################
######################### INSTALLATION #################################################
########################################################################################

# Installs the Command Line Tools package via softwareupdate.
# The sentinel file at /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
# is required to make the CLT package appear in the softwareupdate catalog.
# Retries up to MAX_RETRIES times with exponential backoff between attempts.
install_clt() {
    local attempt=1
    local install_success=false

    while [[ $attempt -le $MAX_RETRIES ]]; do
        echo "Installation attempt $attempt of $MAX_RETRIES..."

        # The sentinel file signals to softwareupdate that a CLT install is in progress,
        # causing it to list the CLT package in the available updates catalog
        touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
        CLT_PACKAGE=$(softwareupdate -l 2>/dev/null | grep -o "Command Line Tools.*" | head -1)

        if [[ -z "$CLT_PACKAGE" ]]; then
            echo "ERROR: No Command Line Tools package found in softwareupdate"
            rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
            return 1
        fi

        echo "Installing: $CLT_PACKAGE"
        if softwareupdate -i "$CLT_PACKAGE" --verbose 2>&1; then
            # Confirm the install actually succeeded with a functional check rather
            # than trusting softwareupdate's exit code alone
            if clt_functional; then
                echo "Command Line Tools installed successfully"
                install_success=true
                rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
                return 0
            fi
        fi

        rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress

        if [[ $attempt -lt $MAX_RETRIES ]]; then
            echo "Installation failed, retrying in $RETRY_DELAY seconds..."
            sleep $RETRY_DELAY
            # Exponential backoff: double the delay before each subsequent attempt
            RETRY_DELAY=$((RETRY_DELAY * 2))
        fi

        ((attempt++))
    done

    echo "ERROR: Command Line Tools installation failed after $MAX_RETRIES attempts"
    return 1
}

########################################################################################
######################### LICENSE ACCEPTANCE ###########################################
########################################################################################

# Accepts the Xcode license agreement when the full Xcode.app is installed.
# CLT-only installs do not require license acceptance; this function returns
# immediately if Xcode.app is not present.
# Temporarily switches xcode-select to Xcode.app for the acceptance call,
# then restores the original developer path if it was pointing at the CLT.
accept_license() {
    local XCODE_PATH="/Applications/Xcode.app"
    local XCODE_BUILD="$XCODE_PATH/Contents/Developer/usr/bin/xcodebuild"
    local LICENSE_PLIST="/Library/Preferences/com.apple.dt.Xcode.plist"

    # No Xcode.app present — license acceptance not required
    if [[ ! -x "$XCODE_BUILD" ]]; then
        return 0
    fi

    # Check whether any license version has already been accepted; an exact version
    # match is not required — any prior acceptance is sufficient
    local ACCEPTED_VERSION=""
    if [[ -f "$LICENSE_PLIST" ]]; then
        ACCEPTED_VERSION=$(/usr/libexec/PlistBuddy -c "Print :IDEXcodeVersionForAgreedToGMLicense" "$LICENSE_PLIST" 2>/dev/null)
    fi

    if [[ -n "$ACCEPTED_VERSION" ]]; then
        echo "Xcode license previously accepted (version $ACCEPTED_VERSION)"
        return 0
    fi

    echo "Xcode license has never been accepted, accepting now..."

    # xcodebuild -license accept requires xcode-select to point at Xcode.app
    local ORIGINAL_PATH
    ORIGINAL_PATH=$(xcode-select -p 2>/dev/null)
    sudo xcode-select -s "$XCODE_PATH/Contents/Developer"

    if ! sudo "$XCODE_BUILD" -license accept; then
        echo "ERROR: xcodebuild -license accept failed"
        # Restore developer path before returning to leave the system in a clean state
        if [[ "$ORIGINAL_PATH" == "/Library/Developer/CommandLineTools" ]]; then
            sudo xcode-select -s "$ORIGINAL_PATH"
        fi
        return 1
    fi
    echo "Xcode license accepted successfully"

    # Restore the developer path to CLT if that is where it was before
    if [[ "$ORIGINAL_PATH" == "/Library/Developer/CommandLineTools" ]]; then
        sudo xcode-select -s "$ORIGINAL_PATH"
    fi

    return 0
}

########################################################################################
######################### MAIN #########################################################
########################################################################################

main() {
    if ! clt_installed; then
        # CLT directory is absent — perform a fresh install
        echo "Xcode CLT not installed, installing..."
        if ! install_clt; then
            echo "FATAL: Failed to install Command Line Tools"
            exit 1
        fi
        if ! accept_license; then
            exit 1
        fi
    elif ! clt_functional; then
        # CLT files exist but xcrun fails — directory is corrupt; nuke and reinstall
        echo "Xcode CLT is broken, reinstalling..."
        sudo rm -rf "$CLT_DIR"
        sudo xcode-select --reset 2>/dev/null || true
        if ! install_clt; then
            echo "FATAL: Failed to reinstall Command Line Tools"
            exit 1
        fi
        if ! accept_license; then
            exit 1
        fi
    else
        # CLT is present and functional — only license acceptance may be needed
        echo "Xcode CLT is installed and functional"
        if ! accept_license; then
            exit 1
        fi
    fi

    # Final functional check to confirm the system is in a good state before exiting
    if clt_functional; then
        echo "SUCCESS: Xcode Command Line Tools are installed and functional"
        exit 0
    else
        echo "FATAL: Xcode Command Line Tools verification failed"
        exit 1
    fi
}

main
