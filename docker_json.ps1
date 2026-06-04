##########################################################
# Written by Colton Gillenwater
# Created on - 4/12/2025
##########################################################
# Script information
# Ensures Docker Desktop's registry.json file exists and
# contains the required allowedOrgs restriction for your org.
# Creates the ProgramData\DockerDesktop directory and the
# registry.json file if either is absent. If the file
# already exists with the correct org entry, no changes
# are made.
##########################################################

param(
    # Optional override; otherwise uses $AllowedOrg from CONFIGURATION below.
    [string]$DockerOrgSlug
)

########################################################################################
######################### CONFIGURATION ################################################
########################################################################################

# Your company's Docker Hub organization slug for allowedOrgs (not the full domain).
# Example: if users sign in as mycompany, set "mycompany".
# You can also pass -DockerOrgSlug on the command line or set env DOCKER_ALLOWED_ORG.
$AllowedOrg = "<your Docker org slug here>"

if ($DockerOrgSlug) {
    $AllowedOrg = $DockerOrgSlug
}
elseif ($env:DOCKER_ALLOWED_ORG) {
    $AllowedOrg = $env:DOCKER_ALLOWED_ORG
}

# Expected Docker Desktop executable path used to detect installation
$dockerPath = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
$dockerInstalled = Test-Path $dockerPath

# Directory and file that Docker Desktop reads for organization restrictions
$folderPath = "C:\ProgramData\DockerDesktop"
$jsonFilePath = Join-Path $folderPath "registry.json"
$folderExists = Test-Path $folderPath

########################################################################################
######################### REGISTRY CONFIGURATION #######################################
########################################################################################

function Test-RegistryHasAllowedOrg {
    param($JsonObject, [string]$OrgSlug)
    if ($null -eq $JsonObject) { return $false }
    if ($JsonObject.PSObject.Properties.Name -notcontains 'allowedOrgs') { return $false }
    return (@($JsonObject.allowedOrgs) -contains $OrgSlug)
}

# All filesystem operations are wrapped in a single try/catch. -ErrorAction Stop
# converts non-terminating cmdlet errors into exceptions so the catch block fires
# on any failure and returns exit code 1 to Iru.
try {
    if ($AllowedOrg -match '^\s*<.*>\s*$' -or [string]::IsNullOrWhiteSpace($AllowedOrg)) {
        Write-Host "ERROR: Set `$AllowedOrg in CONFIGURATION to your Docker org slug, or use -DockerOrgSlug / DOCKER_ALLOWED_ORG."
        exit 1
    }

    if ($folderExists) {
        if (Test-Path $jsonFilePath) {
            # Read the existing file and check whether the org entry is already present
            $jsonContent = Get-Content -Path $jsonFilePath -Raw -ErrorAction Stop | ConvertFrom-Json

            if (Test-RegistryHasAllowedOrg -JsonObject $jsonContent -OrgSlug $AllowedOrg) {
                Write-Host "registry.json already contains the required allowedOrgs entry. No action taken."
                exit 0
            }
            else {
                # File exists but is missing the org entry — add it and write back
                $jsonContent | Add-Member -MemberType NoteProperty -Name "allowedOrgs" -Value @($AllowedOrg) -Force
                $updatedJsonContent = $jsonContent | ConvertTo-Json
                Set-Content -Path $jsonFilePath -Value $updatedJsonContent -ErrorAction Stop
                Write-Host "allowedOrgs entry added to existing registry.json: $jsonFilePath"
                exit 0
            }
        }
        else {
            # Folder exists but registry.json is absent — create it with the org entry
            $jsonContent = @{
                "allowedOrgs" = @($AllowedOrg)
            } | ConvertTo-Json
            Set-Content -Path $jsonFilePath -Value $jsonContent -ErrorAction Stop
            Write-Host "registry.json created with required allowedOrgs entry: $jsonFilePath"
            exit 0
        }
    }
    else {
        # Neither the folder nor the file exists — create both
        New-Item -ItemType Directory -Path $folderPath -ErrorAction Stop | Out-Null
        $jsonContent = @{
            "allowedOrgs" = @($AllowedOrg)
        } | ConvertTo-Json
        Set-Content -Path $jsonFilePath -Value $jsonContent -ErrorAction Stop
        Write-Host "Created directory: $folderPath"
        Write-Host "Created registry.json with required allowedOrgs entry: $jsonFilePath"
        exit 0
    }
}
catch {
    Write-Host "ERROR: $_"
    exit 1
}
