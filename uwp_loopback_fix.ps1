##########################################################
# Written by Colton Gillenwater
# Created on - 6/2/2026
##########################################################
# Script information
# Grants loopback network exemptions to the UWP packages
# required for the Okta Verify FastPass authentication flow
# to function inside Microsoft UWP and Office 365 apps.
# UWP apps disable loopback IPC by default for network
# isolation; FastPass relies on a loopback channel between
# Okta Verify and the authenticating app to prove device
# trust. Iterates every local user profile and adds the
# exemption for any matching package found.
#
# Reference:
# https://help.okta.com/oie/en-us/content/topics/identity-engine/authenticators/pr-uwp-script.htm
# Must be run as Administrator (CheckNetIsolation -a requires elevation).
##########################################################

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# System-managed profile directories to skip during enumeration
$excludedProfiles = @("Public", "Default", "Default User")

# UWP package name patterns that require loopback exemption per Okta's official guidance.
# AuthHost is the Web Authentication Host that brokers OAuth WebViews for UWP apps;
# BrokerPlugin is the Microsoft Account / AAD authentication broker.
$targetPackagePatterns = @(
    "Microsoft\.AAD\.BrokerPlugin",
    "AuthHost"
)

########################################################################################
######################### ELEVATION CHECK ##############################################
########################################################################################

# CheckNetIsolation.exe -a silently no-ops without elevation, which would let the
# script falsely report success. Hard-fail up front if we're not running as admin.
$currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "ERROR: This script must be run as Administrator. CheckNetIsolation -a requires elevation."
    exit 1
}

########################################################################################
######################### LOOPBACK EXEMPTION ###########################################
########################################################################################

# Track results across all users and packages so the final exit code reflects
# whether every CheckNetIsolation call actually succeeded
$attempts = 0
$failures = 0

# Enumerate all local user profiles, skipping system-managed directories
$userProfiles = Get-ChildItem "C:\Users" -Directory |
    Where-Object { $_.Name -notin $excludedProfiles }

foreach ($profile in $userProfiles) {
    $packageFolder = Join-Path $profile.FullName "AppData\Local\Packages"

    # Skip profiles where the Packages directory has not been initialized
    if (-not (Test-Path $packageFolder)) { continue }

    # Find installed packages whose name matches any of the target patterns.
    # Folder names under Packages\ are the package family names that CheckNetIsolation expects.
    $packages = Get-ChildItem -Path $packageFolder -Directory |
        Where-Object { $name = $_.Name; $targetPackagePatterns | Where-Object { $name -match $_ } } |
        Select-Object -ExpandProperty Name

    foreach ($package in $packages) {
        $attempts++
        try {
            # Capture both stdout and stderr; rely on $LASTEXITCODE for the actual result
            $output = & CheckNetIsolation.exe LoopbackExempt -a "-n=$package" 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Host "ERROR: CheckNetIsolation failed for $package (exit code $LASTEXITCODE): $output"
                $failures++
            }
            else {
                Write-Host "Added loopback exemption: $package (user: $($profile.Name))"
            }
        }
        catch {
            Write-Host "ERROR: Exception while exempting $package for user $($profile.Name): $_"
            $failures++
        }
    }
}

########################################################################################
######################### SUMMARY ######################################################
########################################################################################

# Zero attempts means none of the target packages were found on this device.
# Treated as success because the script ran cleanly — nothing required action.
# Persistent zero-attempt results across many devices may indicate the target
# pattern list needs updating.
if ($attempts -eq 0) {
    Write-Host "WARN: No target UWP packages were found across any user profile. Nothing to exempt."
    exit 0
}

if ($failures -gt 0) {
    Write-Host "FAIL: $failures of $attempts exemption attempts failed."
    exit 1
}

Write-Host "SUCCESS: $attempts loopback exemption(s) added."
exit 0
