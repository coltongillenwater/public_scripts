#!/usr/bin/env python3

##########################################################
# Written by Colton Gillenwater
# Created on - 1/24/2026
##########################################################
# Script information
# Finds and removes numbered duplicate application copies
# from /Applications (e.g. "Chrome 2.app", "Firefox 3.app")
# that accumulate when an app is downloaded more than once.
# Only removes a numbered copy if the unnumbered base app
# is also present, preventing removal of the only installed
# copy. Moves to trash if the 'trash' utility is available,
# otherwise falls back to permanent deletion.
##########################################################

import os
import sys
import shutil
import re
from pathlib import Path

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Applications to scan for numbered duplicate copies.
# Only the base name needs to be listed; numbered variants (e.g. "Slack 2.app") are found automatically.
# Add or remove entries for apps your users commonly reinstall from Downloads.
app_list = [
    "Google Chrome.app",
    "Firefox.app",
    "Visual Studio Code.app",
    "Slack.app",
    "Postman.app",
    "Docker.app",
]

########################################################################################
######################### DISCOVERY FUNCTIONS ##########################################
########################################################################################

def find_duplicate_apps(base_apps, applications_dir="/Applications"):
    """
    Search for numbered duplicate apps in the Applications directory.

    Matches the pattern "AppName N.app" where N is a single digit 1-9.
    Does not match the base app itself or copies with multi-digit suffixes.

    Args:
        base_apps (list): List of base application names to check.
        applications_dir (str): Path to the Applications directory to scan.

    Returns:
        dict: Mapping of base app name to list of duplicate Path objects found.
    """
    duplicate_apps = {}
    applications_path = Path(applications_dir)

    if not applications_path.exists():
        print(f"ERROR: Applications directory not found: {applications_dir}")
        return duplicate_apps

    print(f"Searching for duplicate apps in: {applications_dir}")

    for base_app in base_apps:
        base_name = base_app.replace('.app', '')

        # Matches "AppName N.app" where N is a single digit 1-9
        pattern = re.compile(rf"^{re.escape(base_name)} [1-9]\.app$")

        duplicates = []

        try:
            for item in applications_path.iterdir():
                if item.is_dir() and pattern.match(item.name):
                    duplicates.append(item)
                    print(f"  Found duplicate: {item.name}")
        except PermissionError:
            print(f"WARNING: Permission denied accessing {applications_dir}")
            continue

        if duplicates:
            duplicate_apps[base_app] = duplicates

    return duplicate_apps


def validate_base_apps_exist(duplicate_apps, applications_dir="/Applications"):
    """
    Filter out entries where the unnumbered base app is not installed.

    If the base app is absent the numbered copy is assumed to be the only
    installed version and is excluded from deletion rather than removed blindly.

    Args:
        duplicate_apps (dict): Mapping of base app names to duplicate Path lists.
        applications_dir (str): Path to the Applications directory.

    Returns:
        dict: Subset of duplicate_apps where the base app was confirmed present.
    """
    validated_duplicates = {}
    applications_path = Path(applications_dir)

    print("\nValidating base applications exist...")

    for base_app, duplicates in duplicate_apps.items():
        base_app_path = applications_path / base_app

        if base_app_path.exists():
            print(f"  Base app confirmed present: {base_app}")
            validated_duplicates[base_app] = duplicates
        else:
            print(f"  Base app missing: {base_app} - keeping numbered version (assumed in use)")

    return validated_duplicates

########################################################################################
######################### REMOVAL FUNCTIONS ############################################
########################################################################################

def delete_duplicate_apps(duplicate_apps):
    """
    Remove the validated duplicate applications.

    Prefers the 'trash' utility when available so deleted apps are recoverable.
    Falls back to shutil.rmtree for permanent deletion if trash is not installed.

    Args:
        duplicate_apps (dict): Mapping of base app names to duplicate Path lists.

    Returns:
        tuple: (success_count, error_count)
    """
    success_count = 0
    error_count = 0

    print("\nDeleting duplicate applications...")

    for base_app, duplicates in duplicate_apps.items():
        print(f"\nProcessing duplicates for: {base_app}")

        for duplicate_path in duplicates:
            try:
                print(f"  Deleting: {duplicate_path.name}")

                # Use trash for recoverable deletion; fall back to permanent removal
                if shutil.which('trash'):
                    os.system(f"trash '{duplicate_path}'")
                else:
                    shutil.rmtree(duplicate_path)

                print(f"  Removed: {duplicate_path.name}")
                success_count += 1

            except Exception as e:
                print(f"  ERROR removing {duplicate_path.name}: {e}")
                error_count += 1

    return success_count, error_count

########################################################################################
######################### MAIN #########################################################
########################################################################################

def main():
    print("macOS Duplicate App Remover")
    print("-" * 40)

    # Step 1: Scan /Applications for numbered duplicate copies
    print("\nStep 1: Searching for duplicate applications...")
    duplicate_apps = find_duplicate_apps(app_list)

    total_duplicates = sum(len(d) for d in duplicate_apps.values())
    if not duplicate_apps or total_duplicates == 0:
        print("\nNo duplicate applications found.")
        sys.exit(0)

    print(f"\nFound {total_duplicates} duplicate(s) across {len(duplicate_apps)} base application(s)")

    # Step 2: Exclude entries where the base app is absent
    print("\nStep 2: Validating base applications exist...")
    validated_duplicates = validate_base_apps_exist(duplicate_apps)

    validated_count = sum(len(d) for d in validated_duplicates.values())
    if not validated_duplicates or validated_count == 0:
        print("\nNo valid duplicates to remove (base apps missing for all found duplicates).")
        sys.exit(0)

    print(f"\n{validated_count} duplicate(s) confirmed for removal")

    # Step 3: List what will be removed before acting
    print("\nStep 3: The following duplicate applications will be removed:")
    for base_app, duplicates in validated_duplicates.items():
        print(f"\n  Base app: {base_app}")
        for duplicate in duplicates:
            print(f"    -> {duplicate.name}")

    # Step 4: Remove the duplicates
    print("\nStep 4: Deleting duplicate applications...")
    success_count, error_count = delete_duplicate_apps(validated_duplicates)

    print("\n" + "-" * 40)
    print("Summary:")
    print(f"  Successfully removed: {success_count} app(s)")
    print(f"  Errors encountered:   {error_count} app(s)")

    if error_count > 0:
        print("\nSome apps could not be removed. You may need to:")
        print("  - Run the script with sudo for permission issues")
        print("  - Manually remove apps that are currently in use")
        sys.exit(1)
    else:
        print("\nAll duplicate applications successfully removed.")
        sys.exit(0)


if __name__ == "__main__":
    main()
