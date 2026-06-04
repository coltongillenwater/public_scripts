#!/bin/zsh

##########################################################
# Written by Colton Gillenwater
# Created on - 3/23/2026
##########################################################
# Script information
# Preinstall script that prepares the Netskope certificate
# staging directory before the cert bundle scripts run.
# If the directory already exists its contents are cleared
# so downstream scripts start from a clean slate. If it
# does not exist it is created with standard permissions.
##########################################################

########################################################################################
######################### MAIN ################################################
########################################################################################

# Shared staging directory where supplemental .pem files are assembled before bundling
CERT_DIR="/Users/Shared/NetskopeCertBundles"

if [ -d "$CERT_DIR" ]; then
    # Directory exists — clear its contents so the bundle build starts from a clean slate.
    # The :? guard causes zsh to abort if CERT_DIR is unset or empty, preventing rm -rf /*
    echo "Clearing existing contents of $CERT_DIR"
    rm -rf "${CERT_DIR:?}"/*
else
    # Directory does not exist — create it with world-readable/executable permissions
    # so all users can stage supplemental .pem files into it
    echo "Creating $CERT_DIR"
    mkdir -p "$CERT_DIR"
    chmod 755 "$CERT_DIR"
fi

echo "Done — $CERT_DIR is ready"
exit 0
