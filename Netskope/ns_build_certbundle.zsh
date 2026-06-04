#!/bin/zsh

##########################################################
# Written by Colton Gillenwater
# Created on - 3/23/2026
##########################################################
# Script information
# Builds a combined PEM certificate bundle for Netskope by
# extracting all trusted certificates from the device's
# system keychains, then appending any supplemental .pem
# files staged in the source directory. The resulting bundle
# is written to a single output file consumed by the
# Netskope cert bundle installer.
##########################################################

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Shared staging directory where supplemental .pem files are dropped before bundling
SOURCE_DIR="/Users/Shared/NetskopeCertBundles"

# Combined output bundle consumed by the Netskope cert bundle installer
OUTPUT_FILE="${SOURCE_DIR}/netskope-cert-bundle.pem"

# Abort if the staging directory has not been created; the installer depends on it
if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "Error: ${SOURCE_DIR} does not exist."
    exit 1
fi

########################################################################################
######################### KEYCHAIN EXPORT ##############################################
########################################################################################

# Truncate (or create) the output file before writing to ensure a clean bundle
: > "$OUTPUT_FILE"

# Extract all trusted certificates in PEM format from the system root and system keychains
echo "Extracting certificates from system keychains..."
if ! security find-certificate -a -p \
    /System/Library/Keychains/SystemRootCertificates.keychain \
    /Library/Keychains/System.keychain >> "$OUTPUT_FILE"; then
    echo "ERROR: Failed to extract certificates from system keychains"
    exit 1
fi

# Validate that at least one certificate was written; an empty bundle would break Netskope
keychain_certs=$(/usr/bin/grep -c "BEGIN CERTIFICATE" "$OUTPUT_FILE" 2>/dev/null || echo 0)
if [ "$keychain_certs" -eq 0 ]; then
    echo "ERROR: No certificates were extracted from system keychains"
    exit 1
fi
echo "Added $keychain_certs certificate(s) from system keychains"

########################################################################################
######################### SUPPLEMENTAL CERTIFICATES ####################################
########################################################################################

# Append any additional .pem files staged in the source directory (e.g. corporate CAs).
# The output file itself is skipped to prevent it from being appended to itself.
pem_files=("${SOURCE_DIR}"/*.pem(N))

for pem in "${pem_files[@]}"; do
    [[ "$pem" == "$OUTPUT_FILE" ]] && continue
    echo "Adding: ${pem:t}"
    cat "$pem" >> "$OUTPUT_FILE"
    # Blank line between concatenated PEM files to ensure clean certificate boundaries
    echo "" >> "$OUTPUT_FILE"
done

########################################################################################
######################### SUMMARY ######################################################
########################################################################################

echo "Bundle created at ${OUTPUT_FILE} ($(grep -c 'BEGIN CERTIFICATE' "$OUTPUT_FILE") certificates)"
exit 0
