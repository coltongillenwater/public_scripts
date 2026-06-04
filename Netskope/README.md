# Netskope scripts

Scripts for distributing Netskope's certificate bundle to tools that don't respect the macOS system keychain. Intended to run in sequence as part of an MDM workflow.

---

*ns_certbundle_preinstall.zsh and ns_build_certbundle.zsh are designed to be deployed as a custom app (pre- and post-install scripts respectively) in Iru with a .zip of your tenant's Netskope certs as the package.*

### `ns_certbundle_preinstall.zsh`

Prepares the staging directory at `/Users/Shared/NetskopeCertBundles/`. If it already exists, the contents are cleared so downstream scripts start from a clean slate. If it doesn't exist, it's created with world-readable permissions. Run this before the other Netskope cert scripts.

### `ns_build_certbundle.zsh`

Builds a combined PEM certificate bundle by extracting all trusted certificates from the device's system keychains, then appending any supplemental `.pem` files staged in the shared directory. Writes the result to `netskope-cert-bundle.pem` in the same directory. Run this after the preinstall and before the distribution scripts.

---

*Once the above has been run, these scripts follow up and use that cert bundle and place it in the appropriate trust store, env variables, or paths for various developer tools.*

### `ns_certs_aws.zsh`

Installs the Netskope cert bundle into the AWS CLI's trusted certificate store. Supports both Homebrew and official release installs of the AWS CLI, resolving the correct cert path for each. Skips the copy if the destination is already up to date (SHA-256 comparison). Exits cleanly if AWS CLI is not installed.

### `ns_certs_zprofile.zsh`

Injects Netskope cert bundle environment variables into the console user's shell profiles. Writes the variables (`REQUESTS_CA_BUNDLE`, `AWS_CA_BUNDLE`, `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `CURL_CA_BUNDLE`, `GIT_SSL_CAINFO`) to `~/.netskope_vars` and adds a `source` line to `~/.zprofile` and `~/.bash_profile`, creating those files if they don't exist. Idempotent.