#!/bin/zsh

##########################################################
# Written by Colton Gillenwater
# Created on - 3/24/2026
##########################################################
# Script information
# Detects indicators of the litellm supply chain compromise
# introduced in versions 1.82.7 and 1.82.8. Checks every
# Python interpreter found on the system for the affected
# package version and searches all site-packages directories
# for the malicious litellm_init.pth persistence file.
#
# Reference:
# https://github.com/BerriAI/litellm/issues/24512
##########################################################

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Versions of litellm confirmed to contain the malicious payload
affected_versions=("1.82.7" "1.82.8")

# Filename of the malicious .pth file dropped into site-packages
pth_filename="litellm_init.pth"

# Detection flags used to determine the exit condition
found_affected_version=false
found_pth_file=false

########################################################################################
######################### PYTHON DISCOVERY #############################################
########################################################################################

# Collect Python interpreters from common system and Homebrew install locations
python_paths=()
while IFS= read -r -d '' p; do
    python_paths+=("$p")
done < <(find /usr/local/bin /opt/homebrew/bin /usr/bin /Library/Frameworks/Python.framework \
    2>/dev/null -name 'python3*' -o -name 'python' 2>/dev/null \
    | sort -u | tr '\n' '\0')

# Also collect interpreters from pyenv and user-local install paths for each user
for user_home in /Users/*/; do
    while IFS= read -r -d '' p; do
        python_paths+=("$p")
    done < <(find "${user_home}.pyenv" "${user_home}.local/bin" "${user_home}Library/Python" \
        2>/dev/null -name 'python3*' -o -name 'python' 2>/dev/null \
        | sort -u | tr '\n' '\0')
done

# Deduplicate by resolving symlinks to their real paths, avoiding redundant pip queries
typeset -A seen_pythons
unique_pythons=()
for p in "${python_paths[@]}"; do
    real=$(/usr/bin/stat -f "%Y" "$p" 2>/dev/null || echo "$p")
    if [[ -z "${seen_pythons[$real]}" ]]; then
        seen_pythons[$real]=1
        unique_pythons+=("$p")
    fi
done

########################################################################################
######################### VERSION DETECTION ############################################
########################################################################################

# Query pip for the installed litellm version under each unique Python interpreter
# and flag any that match a known-compromised release
for py in "${unique_pythons[@]}"; do
    if [[ -x "$py" ]]; then
        installed_version=$("$py" -m pip show litellm 2>/dev/null | awk '/^Version:/ {print $2}')
        for av in "${affected_versions[@]}"; do
            if [[ "$installed_version" == "$av" ]]; then
                echo "ALERT: Affected litellm version ${av} is installed via ${py}"
                found_affected_version=true
            fi
        done
    fi
done

########################################################################################
######################### PTH FILE DETECTION ###########################################
########################################################################################

# Build the list of directories to search for the malicious .pth file,
# covering system, Homebrew, and per-user Python environments
search_paths=(
    /usr/local/lib
    /opt/homebrew/lib
    /Library/Frameworks/Python.framework
    /Library/Python
)
for user_home in /Users/*/; do
    search_paths+=(
        "${user_home}.pyenv"
        "${user_home}.local/lib"
        "${user_home}Library/Python"
    )
done

# Search all site-packages directories for the malicious persistence file
while IFS= read -r pth_path; do
    echo "ALERT: Malicious file found at ${pth_path}"
    found_pth_file=true
done < <(find "${search_paths[@]}" -path '*/site-packages/litellm_init.pth' -type f 2>/dev/null)

########################################################################################
######################### SUMMARY ######################################################
########################################################################################

# Both indicators present — active compromise with persistence in place
if $found_affected_version && $found_pth_file; then
    echo "CRITICAL: Both affected litellm version and malicious .pth file detected."
    exit 1
# Affected version only — payload may have been partially cleaned but package remains
elif $found_affected_version; then
    echo "WARNING: Affected litellm version installed, but .pth file not found (may have been partially cleaned)."
    exit 1
# .pth file only — package was likely upgraded but the persistence file was not removed
elif $found_pth_file; then
    echo "WARNING: Malicious ${pth_filename} found, but litellm version does not match a known affected version (version may have been upgraded without removing the .pth file)."
    exit 1
# No indicators found
else
    echo "OK: No indicators of litellm supply chain compromise (Issue #24512) detected."
    exit 0
fi
