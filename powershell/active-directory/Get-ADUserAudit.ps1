<#
.SYNOPSIS
    Generates a full Active Directory user audit report.

.DESCRIPTION
    Exports all AD user accounts with key attributes: last logon date,
    account status, password expiry, group memberships, and OU location.
    Useful for access reviews, compliance audits, and security assessments.

.PARAMETER DomainController
    Target domain controller. Defaults to current DC.

.PARAMETER ExportCsv
    Path to export results as CSV. Optional.

.PARAMETER IncludeDisabled
    Include disabled accounts in the report. Default: false.

.EXAMPLE
    .\Get-ADUserAudit.ps1
    .\Get-ADUserAudit.ps1 -ExportCsv "C:\Reports\ad-audit.csv"
    .\Get-ADUserAudit.ps1 -IncludeDisabled -ExportCsv "C:\Reports\ad-full-audit.csv"

.NOTES
    Author   : Aymerick Victoire
    Requires : ActiveDirectory PowerShell module (RSAT)
    Purpose  : Access review, compliance, attack surface reduction
#>

param (
    [string]$DomainController = $env:LOGONSERVER -replace '\\\\', '',
    [string]$ExportCsv = "",
    [switch]$IncludeDisabled = $false
)

#Requires -Modules ActiveDirectory

$ErrorActionPreference = "Stop"

Write-Host "[*] Starting AD User Audit..." -ForegroundColor Cyan
Write-Host "[*] Domain Controller: $DomainController" -ForegroundColor Cyan

# Build filter
$Filter = if ($IncludeDisabled) { "*" } else { "Enabled -eq 'True'" }

# Retrieve users
$Users = Get-ADUser -Filter $Filter -Properties `
    DisplayName, SamAccountName, EmailAddress, Department,
    Title, Enabled, PasswordNeverExpires, PasswordLastSet,
    LastLogonDate, Created, DistinguishedName, MemberOf,
    LockedOut, BadLogonCount |
    Select-Object @{N = "DisplayName"; E = { $_.DisplayName } },
    @{N = "Username"; E = { $_.SamAccountName } },
    @{N = "Email"; E = { $_.EmailAddress } },
    @{N = "Department"; E = { $_.Department } },
    @{N = "Title"; E = { $_.Title } },
    @{N = "Enabled"; E = { $_.Enabled } },
    @{N = "PasswordNeverExpires"; E = { $_.PasswordNeverExpires } },
    @{N = "PasswordLastSet"; E = { $_.PasswordLastSet } },
    @{N = "LastLogon"; E = { $_.LastLogonDate } },
    @{N = "DaysSinceLogon"; E = {
            if ($_.LastLogonDate) {
                (New-TimeSpan -Start $_.LastLogonDate -End (Get-Date)).Days
            }
            else { "Never" }
        }
    },
    @{N = "Created"; E = { $_.Created } },
    @{N = "LockedOut"; E = { $_.LockedOut } },
    @{N = "BadLogonCount"; E = { $_.BadLogonCount } },
    @{N = "OU"; E = { ($_.DistinguishedName -split ',', 2)[1] } },
    @{N = "Groups"; E = {
            ($_.MemberOf | ForEach-Object {
                (Get-ADGroup $_).Name
            }) -join "; "
        }
    }

# Display summary
Write-Host "`n[+] Total users found: $($Users.Count)" -ForegroundColor Green
Write-Host "[+] Enabled accounts: $(($Users | Where-Object Enabled).Count)" -ForegroundColor Green
Write-Host "[+] Password never expires: $(($Users | Where-Object PasswordNeverExpires).Count)" -ForegroundColor Yellow
Write-Host "[+] Locked out: $(($Users | Where-Object LockedOut).Count)" -ForegroundColor Yellow
Write-Host "[+] Never logged in: $(($Users | Where-Object { $_.DaysSinceLogon -eq 'Never' }).Count)" -ForegroundColor Yellow

# Export or display
if ($ExportCsv) {
    $Users | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`n[+] Report exported to: $ExportCsv" -ForegroundColor Green
}
else {
    $Users | Format-Table -AutoSize
}
