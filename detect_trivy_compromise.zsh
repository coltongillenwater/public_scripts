#!/bin/zsh

##########################################################
# Written by Colton Gillenwater
# Created on - 3/24/2026
##########################################################
# Script information
# Detects indicators of the Trivy supply chain compromise
# (CVE-2026-33634). Checks for affected trivy binary
# versions in system and user-local paths, compromised
# Docker images, the malicious aquasecurity/homebrew-trivy
# tap, and the tpcp-docs exfiltration artifact directory.
# Prints remediation actions for any findings.
#
# Reference:
# https://github.com/aquasecurity/trivy/security/advisories/GHSA-69fq-xp46-6x23
# Affected: trivy v0.69.4, v0.69.5, v0.69.6 binaries and
# images; aquasecurity/homebrew-trivy tap
##########################################################

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Binary and image versions confirmed to contain the malicious payload
affected_versions=("0.69.4" "0.69.5" "0.69.6")

# Detection flags used to determine exit condition and print targeted remediation steps
found_affected_binary=false
found_affected_image=false
found_compromised_tap=false
found_exfil_repo=false

########################################################################################
######################### BINARY DETECTION #############################################
########################################################################################

# Collect trivy binaries from common system and Homebrew install locations
trivy_paths=()
while IFS= read -r -d '' p; do
    trivy_paths+=("$p")
done < <(find /usr/local/bin /opt/homebrew/bin /usr/bin \
    2>/dev/null -name 'trivy' -type f 2>/dev/null \
    | sort -u | tr '\n' '\0')

# Also check user-local and aquasecurity-specific paths under each home directory
for user_home in /Users/*/; do
    while IFS= read -r -d '' p; do
        trivy_paths+=("$p")
    done < <(find "${user_home}.local/bin" "${user_home}bin" "${user_home}.aquasecurity" \
        2>/dev/null -name 'trivy' -type f 2>/dev/null \
        | sort -u | tr '\n' '\0')
done

# Pick up any trivy on the current PATH not already captured above
if command -v trivy &>/dev/null; then
    trivy_paths+=("$(command -v trivy)")
fi

# Deduplicate by resolving symlinks to their real paths to avoid checking the same binary twice
typeset -A seen_trivys
unique_trivys=()
for p in "${trivy_paths[@]}"; do
    real=$(/usr/bin/stat -f "%Y" "$p" 2>/dev/null || echo "$p")
    if [[ -z "${seen_trivys[$real]}" ]]; then
        seen_trivys[$real]=1
        unique_trivys+=("$p")
    fi
done

# Query each unique binary for its version string and flag any affected release
for trivy_bin in "${unique_trivys[@]}"; do
    if [[ -x "$trivy_bin" ]]; then
        installed_version=$("$trivy_bin" version 2>/dev/null | awk '/^Version:/ {print $2}')
        # Some builds output just the version string on the first line rather than a labeled field
        if [[ -z "$installed_version" ]]; then
            installed_version=$("$trivy_bin" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+')
        fi
        for av in "${affected_versions[@]}"; do
            if [[ "$installed_version" == "$av" ]]; then
                echo "ALERT: Compromised trivy version v${av} found at ${trivy_bin}"
                found_affected_binary=true
            fi
        done
    fi
done

########################################################################################
######################### DOCKER IMAGE DETECTION #######################################
########################################################################################

# Check locally cached Docker images against all known registry paths for trivy.
# Skipped entirely if Docker is not installed or its daemon is not running.
if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
    docker_images=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null)
    for av in "${affected_versions[@]}"; do
        for repo in "aquasec/trivy" "ghcr.io/aquasecurity/trivy" "public.ecr.aws/aquasecurity/trivy"; do
            if echo "$docker_images" | grep -qF "${repo}:${av}"; then
                echo "ALERT: Compromised Docker image ${repo}:${av} found locally"
                found_affected_image=true
            fi
        done
    done
fi

########################################################################################
######################### HOMEBREW TAP DETECTION #######################################
########################################################################################

# The official homebrew-core formula builds trivy from source and was NOT affected.
# The custom tap (aquasecurity/homebrew-trivy) distributed pre-built bottles and WAS
# compromised as part of the v0.69.4 supply chain attack.
homebrew_tap_dir=""
if [[ -d /opt/homebrew/Library/Taps/aquasecurity/homebrew-trivy ]]; then
    homebrew_tap_dir="/opt/homebrew/Library/Taps/aquasecurity/homebrew-trivy"
elif [[ -d /usr/local/Homebrew/Library/Taps/aquasecurity/homebrew-trivy ]]; then
    homebrew_tap_dir="/usr/local/Homebrew/Library/Taps/aquasecurity/homebrew-trivy"
fi

if [[ -n "$homebrew_tap_dir" ]]; then
    echo "ALERT: Compromised custom Homebrew tap 'aquasecurity/homebrew-trivy' is installed at ${homebrew_tap_dir}. This tap was part of the supply chain attack."
    found_compromised_tap=true
fi

########################################################################################
######################### EXFILTRATION ARTIFACT DETECTION ##############################
########################################################################################

# The malware's fallback exfiltration mechanism creates a local directory named 'tpcp-docs'
# (mirroring a public GitHub repo used as a dead drop) before uploading stolen secrets.
# Its presence in a home directory or Documents folder is a strong indicator of execution.
for user_home in /Users/*/; do
    if [[ -d "${user_home}tpcp-docs" ]] || [[ -d "${user_home}Documents/tpcp-docs" ]]; then
        echo "ALERT: Possible exfiltration artifact 'tpcp-docs' directory found under ${user_home}"
        found_exfil_repo=true
    fi
done

########################################################################################
######################### SUMMARY ######################################################
########################################################################################

if $found_affected_binary || $found_affected_image || $found_compromised_tap || $found_exfil_repo; then
    echo ""
    # Print a targeted remediation action for each indicator that was found
    $found_affected_binary && echo "ACTION: Remove compromised trivy binary and install safe version (v0.69.3 or earlier)."
    $found_affected_image  && echo "ACTION: Remove compromised Docker images (docker rmi) and pull safe version (0.69.3)."
    $found_compromised_tap && echo "ACTION: Remove compromised tap (brew untap aquasecurity/trivy) and use official formula."
    $found_exfil_repo      && echo "ACTION: Investigate tpcp-docs directory; rotate all secrets that may have been exfiltrated."
    echo ""
    echo "CRITICAL: Rotate all secrets, SSH keys, cloud credentials, and tokens accessible on this machine. See GHSA-69fq-xp46-6x23."
    exit 1
else
    echo "OK: No indicators of Trivy supply chain compromise (CVE-2026-33634) detected."
    exit 0
fi
