#!/bin/zsh

##########################################################
# Written by Colton Gillenwater
# Created on - 3/15/2026
##########################################################
# Script information
# Installs the Netskope certificate bundle into the AWS
# CLI's trusted certificate store. Supports both the
# Homebrew and official release installs of the AWS CLI,
# resolving the correct cert path for each. Skips the copy
# if the destination is already up to date. Expects the
# bundle to exist at the shared path produced by the cert
# bundle generation script.
##########################################################

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Combined PEM bundle produced by ns_build_certbundle.zsh
CERT_BUNDLE="/Users/Shared/NetskopeCertBundles/netskope-cert-bundle.pem"

########################################################################################
######################### BUNDLE VALIDATION ############################################
########################################################################################

# Abort if the bundle file is missing — this script must run after the bundle is built
if [ ! -f "$CERT_BUNDLE" ]; then
    echo "ERROR: Certificate bundle not found at $CERT_BUNDLE"
    echo "Run the cert bundle generation script first."
    exit 1
fi

# Abort if the bundle contains no certificates — an empty file would silently break AWS CLI TLS
CERT_COUNT=$(/usr/bin/grep -c "BEGIN CERTIFICATE" "$CERT_BUNDLE" 2>/dev/null || echo 0)
if [ "$CERT_COUNT" -eq 0 ]; then
    echo "ERROR: No certificates found in $CERT_BUNDLE"
    exit 1
fi

echo "Certificate bundle verified ($CERT_COUNT certificates)"

########################################################################################
######################### AWS CLI DETECTION ############################################
########################################################################################

# The Homebrew and official release installs place their binaries and cert stores
# in different locations; resolve the correct paths before attempting the copy
awsHomeBrew="/opt/homebrew/bin/aws"
awsRelease="/usr/local/bin/aws"

if [[ -x "$awsHomeBrew" ]]; then
    awsBinary="$awsHomeBrew"
    awsCertPath="/opt/homebrew/etc/ca-certificates/cert.pem"
    echo "Found AWS CLI (Homebrew): $awsHomeBrew"
    echo "AWS certificate path: $awsCertPath"
elif [[ -x "$awsRelease" ]]; then
    awsBinary="$awsRelease"
    awsCertPath="/usr/local/bin/aws/awscli/botocore/cacert.pem"
    echo "Found AWS CLI (Official Release): $awsRelease"
    echo "AWS certificate path: $awsCertPath"
else
    # AWS CLI is not installed on this machine — nothing to update
    echo "AWS CLI not found. Skipping adding the AWS Cert Bundle"
    exit 0
fi

########################################################################################
######################### CERTIFICATE INSTALL ##########################################
########################################################################################

# Skip the copy if the destination already contains an identical bundle.
# SHA-256 comparison avoids an unnecessary write on machines that are already current.
if [ -f "$awsCertPath" ]; then
    srcHash=$(/usr/bin/shasum -a 256 "$CERT_BUNDLE" | /usr/bin/awk '{print $1}')
    dstHash=$(/usr/bin/shasum -a 256 "$awsCertPath" | /usr/bin/awk '{print $1}')
    if [ "$srcHash" = "$dstHash" ]; then
        echo "AWS CLI certificate bundle is already up to date"
        exit 0
    fi
    echo "AWS CLI certificate bundle exists but is outdated, updating..."
fi

# Create the destination directory if it does not yet exist
awsCertDir=$(dirname "$awsCertPath")
if [ ! -d "$awsCertDir" ]; then
    echo "Creating AWS certificate directory: $awsCertDir"
    if mkdir -p "$awsCertDir"; then
        echo "Successfully created AWS certificate directory"
    else
        echo "ERROR: Failed to create AWS certificate directory"
        exit 1
    fi
fi

# Copy the bundle into the AWS CLI cert store
echo "Copying certificate bundle to AWS CLI path..."
if cp "$CERT_BUNDLE" "$awsCertPath" 2>&1; then
    echo "Successfully copied certificate bundle to: $awsCertPath"
else
    echo "ERROR: Failed to copy certificate bundle to AWS CLI path"
    exit 1
fi

exit 0
