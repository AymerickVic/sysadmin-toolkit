<#
.SYNOPSIS
    Identifies inactive Active Directory users and computer accounts.

.DESCRIPTION
    Reports AD objects (users and/or computers) that have not authenticated
    for a specified number of days. Inactive accounts expand the attack surface
    and should be disabled or removed as part of regular hygiene.

.PARAMETER DaysInactive
    Threshold in days. Accounts with no logon beyond this are flagged. Default: 90.

.PARAMETER ObjectType
    What to scan: Users, Computers, or Both. Default: Both.

.PARAMETER ExportCsv
    Optional CSV export path.

.PARAMETER DisableObjects
    If specified, automatically disables found inactive objects. USE WITH CAUTION.

.EXAMPLE
    .\Get-InactiveObjects.ps1
    .\Get-InactiveObjects.ps1 -DaysInactive 60 -ObjectType Users
    .\Get-InactiveObjects.ps1 -DaysInactive 90 -ExportCsv "C:\Reports\inactive.csv"

.NOTES
    Author   : Aymerick Victoire
    Requires : ActiveDirectory PowerShell module (RSAT)
    Purpose  : Attack surface reduction, access hygiene
#>

param (
    [int]$DaysInactive = 90,
    [ValidateSet("Users", "Computers", "Both")]
    [string]$ObjectType = "Both",
    [string]$ExportCsv = "",
    [switch]$DisableObjects = $false
)

#Requires -Modules ActiveDirectory

$ErrorActionPreference = "Stop"
$CutoffDate = (Get-Date).AddDays(-$DaysInactive)
$Results = @()

Write-Host "[*] Scanning for objects inactive since: $($CutoffDate.ToString('yyyy-MM-dd'))" -ForegroundColor Cyan

# --- Users ---
if ($ObjectType -in "Users", "Both") {
    $InactiveUsers = Get-ADUser -Filter {
        LastLogonDate -lt $CutoffDate -and Enabled -eq $true
    } -Properties LastLogonDate, Department, PasswordLastSet, Created |
        Select-Object @{N = "Type"; E = { "User" } },
        @{N = "Name"; E = { $_.Name } },
        @{N = "SamAccountName"; E = { $_.SamAccountName } },
        @{N = "Department"; E = { $_.Department } },
        @{N = "LastLogon"; E = { $_.LastLogonDate } },
        @{N = "DaysInactive"; E = { (New-TimeSpan -Start $_.LastLogonDate -End (Get-Date)).Days } },
        @{N = "Created"; E = { $_.Created } },
        @{N = "PasswordLastSet"; E = { $_.PasswordLastSet } },
        @{N = "DistinguishedName"; E = { $_.DistinguishedName } }

    Write-Host "[+] Inactive users found: $($InactiveUsers.Count)" -ForegroundColor Yellow
    $Results += $InactiveUsers

    if ($DisableObjects -and $InactiveUsers.Count -gt 0) {
        $InactiveUsers | ForEach-Object {
            Disable-ADAccount -Identity $_.SamAccountName
            Write-Host "  [!] Disabled: $($_.SamAccountName)" -ForegroundColor Red
        }
    }
}

# --- Computers ---
if ($ObjectType -in "Computers", "Both") {
    $InactiveComputers = Get-ADComputer -Filter {
        LastLogonDate -lt $CutoffDate -and Enabled -eq $true
    } -Properties LastLogonDate, OperatingSystem, Created |
        Select-Object @{N = "Type"; E = { "Computer" } },
        @{N = "Name"; E = { $_.Name } },
        @{N = "SamAccountName"; E = { $_.SamAccountName } },
        @{N = "Department"; E = { $_.OperatingSystem } },
        @{N = "LastLogon"; E = { $_.LastLogonDate } },
        @{N = "DaysInactive"; E = { (New-TimeSpan -Start $_.LastLogonDate -End (Get-Date)).Days } },
        @{N = "Created"; E = { $_.Created } },
        @{N = "PasswordLastSet"; E = { "N/A" } },
        @{N = "DistinguishedName"; E = { $_.DistinguishedName } }

    Write-Host "[+] Inactive computers found: $($InactiveComputers.Count)" -ForegroundColor Yellow
    $Results += $InactiveComputers
}

# --- Output ---
if ($ExportCsv) {
    $Results | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`n[+] Exported to: $ExportCsv" -ForegroundColor Green
}
else {
    $Results | Sort-Object DaysInactive -Descending | Format-Table Type, Name, SamAccountName, LastLogon, DaysInactive -AutoSize
}

Write-Host "`n[*] Total inactive objects: $($Results.Count)" -ForegroundColor Cyan
if (-not $DisableObjects) {
    Write-Host "[i] Run with -DisableObjects to automatically disable these accounts." -ForegroundColor Gray
}
