# public_scripts

A collection of scripts I've written for device management, security response, and developer tooling. Most were built for use at my company and deployed via Iru (formerly Kandji) or Intune. They've been tested in our specific environment and may need modification before they work in yours. This is also mostly meant to be a random smattering of things I've worked on and may not all relate as well too each other or make total sense out of context. I'll continue to add ones that turn out intersting as I go.

A brief description of each script is below:

---

### `clean_downloads_targeted.zsh`

Removes a hardcoded list of `.app` bundles from the console user's Downloads folder. Designed to clean up installer copies and duplicate app bundles that accumulate after app installs. Edit the `TARGET_APPS` array to match the apps in your environment.

---

### `detect_litellm_infostealer.zsh`

Detects indicators of the litellm supply chain compromise introduced in versions `1.82.7` and `1.82.8`. Scans all Python interpreters on the system for the affected package version and searches site-packages directories for the malicious `litellm_init.pth` persistence file. Exits `0` if clean, `1` if anything is found.

---

### `detect_openclaw.sh`

Read-only detection script for OpenClaw artifacts on macOS. Runs through seven detection phases: running processes and loaded LaunchAgents, application bundles, LaunchAgent/LaunchDaemon plists, npm/pnpm/bun global packages, Homebrew packages, configuration and data directories, and system-level receipts. Logs all findings to `/Library/Logs/openclaw_detection.log`. Must be run as root. Intended as a companion to `remove_openclaw.zsh`. These two could easily be one script, it ended up as two in our environment mainly because I was playing around with different ways of handling this.

---

### `remove_openclaw.zsh`

Fully removes OpenClaw from macOS without user interaction. Runs 12 steps: kills running processes, strips shell hooks, runs the official uninstaller, removes launchd services, uninstalls global npm/pnpm/bun/Homebrew packages, cleans nodenv binaries and shims, removes user-writable binaries, removes app bundles, removes state/config/cache directories, removes Docker artifacts, and runs a final verification pass. Logs everything to a timestamped file in `$HOME`.

---

### `detect_trivy_compromise.zsh`

Detects indicators of the Trivy supply chain compromise (CVE-2026-33634), which affected binary versions `v0.69.4`, `v0.69.5`, and `v0.69.6`. Checks for affected trivy binaries on disk, compromised Docker images, the malicious `aquasecurity/homebrew-trivy` tap, and the `tpcp-docs` exfiltration artifact directory. Prints targeted remediation steps for any findings.

---

### `docker_json.ps1`

Windows PowerShell. Ensures Docker Desktop's `registry.json` file exists at `C:\ProgramData\DockerDesktop\` with the required `allowedOrgs` entry for your Docker Hub organization. Creates the directory and file if either is missing. Idempotent — no changes are made if the org entry is already present. Set `$AllowedOrg` in the configuration section to your org slug before deploying.

---

### `install_repair_xcode_clt.zsh`

Installs or repairs the Xcode Command Line Tools via `softwareupdate`. Detects whether the CLT is missing or broken and acts accordingly, with exponential backoff retry on failure. Also accepts the Xcode license if the full `Xcode.app` is present.

---

### `pat_url_reachability.py`

Validates URL reachability under a labeled network condition (e.g., `netskope`, `nordlayer`, `bare`) and writes per-label result columns back to a CSV. For each URL it records DNS resolution, curl exit status, HTTP status code, a bucketed failure category, the final URL after redirects, and a block-page heuristic match. Results from multiple labeled runs are preserved side-by-side in the same CSV. Written for ad-hoc testing of corporate network filtering behavior. Requires editing `CSV_PATH` before use.

---

### `remove_duplicate_apps.py`

Finds and removes numbered duplicate application copies from `/Applications` (e.g. `Chrome 2.app`, `Firefox 3.app`). Only removes a numbered copy if the unnumbered base app is also present — preventing accidental removal of the only installed version. Prefers the `trash` utility for recoverable deletion, falling back to permanent removal if unavailable. Edit `app_list` to match the apps you want to target.

---

### `report_vs_extensions.zsh`

Reports all installed extensions for VS Code-family editors across every user profile on a macOS device. Covers VS Code, VS Code Insiders, Cursor, Windsurf, VSCodium, Positron, and Trae. When run as root it inspects all local user home directories; otherwise it reports only the invoking user. Designed for use with Iru — output goes to the Iru audit log.

---

### `uwp_loopback_fix.ps1`

Windows PowerShell. Grants loopback network exemptions to the UWP packages required for Okta Verify FastPass authentication to function inside Microsoft UWP and Office 365 apps. Iterates every local user profile and runs `CheckNetIsolation.exe` for any matching packages found. Must be run as Administrator. Based on Okta's official guidance.

---

### `/Netskope`

These are mostly focused on managing certificates for SSL inspection for various dev tools to cooperate with Netskope. There's a separate readme in there with more details.