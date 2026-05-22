<#
.SYNOPSIS
    Automates complete new user onboarding in Active Directory.

.DESCRIPTION
    Creates a new AD user with all required attributes, assigns group
    memberships, creates a home folder with proper permissions, and
    generates a temporary password. Reduces onboarding time from
    15 minutes to under 60 seconds.

.PARAMETER FirstName
    User's first name.

.PARAMETER LastName
    User's last name.

.PARAMETER Department
    Department name. Used for OU placement and group assignment.

.PARAMETER Title
    Job title.

.PARAMETER Manager
    SamAccountName of the user's manager.

.PARAMETER HomeSharePath
    UNC path to the home share root (e.g. \\fileserver\homes).

.EXAMPLE
    .\New-UserOnboarding.ps1 -FirstName "Alice" -LastName "Martin" -Department "IT" -Title "Sysadmin"
    .\New-UserOnboarding.ps1 -FirstName "Bob" -LastName "Dupont" -Department "Finance" -Manager "jsmith" -HomeSharePath "\\srv-files\homes"

.NOTES
    Author   : Aymerick Victoire
    Requires : ActiveDirectory PowerShell module (RSAT)
    Purpose  : Standardized user onboarding, reduces manual errors
#>

param (
    [Parameter(Mandatory)]
    [string]$FirstName,

    [Parameter(Mandatory)]
    [string]$LastName,

    [Parameter(Mandatory)]
    [string]$Department,

    [string]$Title = "",
    [string]$Manager = "",
    [string]$HomeSharePath = ""
)

#Requires -Modules ActiveDirectory

$ErrorActionPreference = "Stop"

# --- Build user attributes ---
$SamAccountName = ($FirstName[0] + $LastName).ToLower() -replace '[^a-z0-9]', ''
$UPN = "$SamAccountName@$((Get-ADDomain).DNSRoot)"
$DisplayName = "$FirstName $LastName"

# Generate temporary password
$TempPassword = "Temp$(Get-Random -Minimum 1000 -Maximum 9999)!" | ConvertTo-SecureString -AsPlainText -Force

# Determine OU from department
$DomainDN = (Get-ADDomain).DistinguishedName
$TargetOU = "OU=$Department,OU=Users,$DomainDN"

# Verify OU exists
if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$TargetOU'" -ErrorAction SilentlyContinue)) {
    Write-Host "[!] OU '$TargetOU' not found. Creating under OU=Users..." -ForegroundColor Yellow
    New-ADOrganizationalUnit -Name $Department -Path "OU=Users,$DomainDN"
}

Write-Host "[*] Creating user: $DisplayName ($SamAccountName)" -ForegroundColor Cyan

# --- Create AD user ---
$NewUserParams = @{
    SamAccountName        = $SamAccountName
    UserPrincipalName     = $UPN
    GivenName             = $FirstName
    Surname               = $LastName
    DisplayName           = $DisplayName
    Name                  = $DisplayName
    Department            = $Department
    Title                 = $Title
    AccountPassword       = $TempPassword
    ChangePasswordAtLogon = $true
    Enabled               = $true
    Path                  = $TargetOU
}

if ($Manager) {
    $ManagerDN = (Get-ADUser -Identity $Manager).DistinguishedName
    $NewUserParams.Manager = $ManagerDN
}

New-ADUser @NewUserParams
Write-Host "[+] User created: $SamAccountName" -ForegroundColor Green

# --- Add to department group ---
$GroupName = "GRP-$Department"
if (Get-ADGroup -Filter "Name -eq '$GroupName'" -ErrorAction SilentlyContinue) {
    Add-ADGroupMember -Identity $GroupName -Members $SamAccountName
    Write-Host "[+] Added to group: $GroupName" -ForegroundColor Green
}

# --- Create home folder ---
if ($HomeSharePath) {
    $HomePath = Join-Path $HomeSharePath $SamAccountName
    if (-not (Test-Path $HomePath)) {
        New-Item -Path $HomePath -ItemType Directory | Out-Null

        # Set ACL — user gets full control, admins retain access
        $Acl = Get-Acl $HomePath
        $Acl.SetAccessRuleProtection($true, $false)
        $AdminRule = New-Object Security.AccessControl.FileSystemAccessRule(
            "Domain Admins", "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")
        $UserRule = New-Object Security.AccessControl.FileSystemAccessRule(
            $SamAccountName, "Modify", "ContainerInherit,ObjectInherit", "None", "Allow")
        $Acl.AddAccessRule($AdminRule)
        $Acl.AddAccessRule($UserRule)
        Set-Acl -Path $HomePath -AclObject $Acl

        # Set home directory on AD object
        Set-ADUser -Identity $SamAccountName -HomeDirectory $HomePath -HomeDrive "H:"
        Write-Host "[+] Home folder created: $HomePath" -ForegroundColor Green
    }
}

# --- Summary ---
Write-Host "`n===== ONBOARDING COMPLETE =====" -ForegroundColor Green
Write-Host "Username    : $SamAccountName"
Write-Host "UPN         : $UPN"
Write-Host "Department  : $Department"
Write-Host "OU          : $TargetOU"
Write-Host "Temp Pwd    : (change required at first logon)"
Write-Host "==============================="
