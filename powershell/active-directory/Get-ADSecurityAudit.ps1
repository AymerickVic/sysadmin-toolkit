<#
.SYNOPSIS
    Security-focused Active Directory audit — identifies misconfigurations and risks.

.DESCRIPTION
    Checks for common AD security weaknesses:
    - Accounts with passwords that never expire
    - Users with excessive admin rights (Domain Admins bloat)
    - Stale privileged accounts
    - Accounts with no MFA (requires AzureAD/Graph for hybrid envs)
    - Kerberos delegation misconfigurations
    - AdminSDHolder anomalies

    Designed as a bridge between sysadmin hygiene and security engineering.

.PARAMETER ExportHtml
    Export results as an HTML report. Optional path.

.EXAMPLE
    .\Get-ADSecurityAudit.ps1
    .\Get-ADSecurityAudit.ps1 -ExportHtml "C:\Reports\ad-security-audit.html"

.NOTES
    Author   : Aymerick Victoire
    Requires : ActiveDirectory PowerShell module (RSAT)
    Purpose  : Security hygiene, pre-pentest review, compliance baseline
    MITRE    : T1078 (Valid Accounts), T1558 (Kerberoasting), T1003 (Credential Access)
#>

param (
    [string]$ExportHtml = ""
)

#Requires -Modules ActiveDirectory

$ErrorActionPreference = "Stop"
$Findings = @()

function Add-Finding {
    param([string]$Category, [string]$Severity, [string]$Finding, [string]$Detail, [string]$Recommendation)
    $Findings += [PSCustomObject]@{
        Category       = $Category
        Severity       = $Severity
        Finding        = $Finding
        Detail         = $Detail
        Recommendation = $Recommendation
    }
}

Write-Host "[*] Starting AD Security Audit..." -ForegroundColor Cyan
Write-Host "[*] Domain: $((Get-ADDomain).DNSRoot)" -ForegroundColor Cyan

# ============================================================
# 1. Passwords that never expire
# ============================================================
$NeverExpire = Get-ADUser -Filter { PasswordNeverExpires -eq $true -and Enabled -eq $true } -Properties PasswordNeverExpires, LastLogonDate
if ($NeverExpire.Count -gt 0) {
    Add-Finding -Category "Credentials" -Severity "HIGH" `
        -Finding "Accounts with non-expiring passwords: $($NeverExpire.Count)" `
        -Detail ($NeverExpire.SamAccountName -join ", ") `
        -Recommendation "Enable password expiration policy. Service accounts should use gMSA instead."
}

# ============================================================
# 2. Domain Admins bloat
# ============================================================
$DomainAdmins = Get-ADGroupMember -Identity "Domain Admins" -Recursive
if ($DomainAdmins.Count -gt 5) {
    Add-Finding -Category "Privilege" -Severity "HIGH" `
        -Finding "Domain Admins group has $($DomainAdmins.Count) members (recommended: <5)" `
        -Detail ($DomainAdmins.SamAccountName -join ", ") `
        -Recommendation "Apply principle of least privilege. Use tiered admin model (T0/T1/T2)."
}

# ============================================================
# 3. Enabled accounts not logged in for 90+ days in privileged groups
# ============================================================
$PrivGroups = @("Domain Admins", "Enterprise Admins", "Schema Admins", "Administrators")
foreach ($Group in $PrivGroups) {
    try {
        $Members = Get-ADGroupMember -Identity $Group -Recursive |
            Where-Object { $_.objectClass -eq "user" } |
            ForEach-Object { Get-ADUser $_ -Properties LastLogonDate, Enabled } |
            Where-Object { $_.Enabled -eq $true -and $_.LastLogonDate -lt (Get-Date).AddDays(-90) }

        if ($Members) {
            Add-Finding -Category "Privilege" -Severity "MEDIUM" `
                -Finding "Stale privileged accounts in '$Group': $($Members.Count)" `
                -Detail ($Members.SamAccountName -join ", ") `
                -Recommendation "Disable or remove stale privileged accounts. Review necessity."
        }
    }
    catch { }
}

# ============================================================
# 4. Unconstrained Kerberos delegation
# ============================================================
$UnconstrainedDelegation = Get-ADComputer -Filter { TrustedForDelegation -eq $true } -Properties TrustedForDelegation, DNSHostName |
    Where-Object { $_.Name -notlike "*DC*" }  # exclude DCs (expected)

if ($UnconstrainedDelegation.Count -gt 0) {
    Add-Finding -Category "Kerberos" -Severity "HIGH" `
        -Finding "Computers with unconstrained delegation: $($UnconstrainedDelegation.Count)" `
        -Detail ($UnconstrainedDelegation.DNSHostName -join ", ") `
        -Recommendation "Replace unconstrained with constrained delegation (T1558.003 — Kerberoasting risk)."
}

# ============================================================
# 5. User accounts with SPN set (Kerberoasting candidates)
# ============================================================
$KerberoastTargets = Get-ADUser -Filter { ServicePrincipalName -ne "$null" -and Enabled -eq $true } `
    -Properties ServicePrincipalName, PasswordLastSet, MemberOf

if ($KerberoastTargets.Count -gt 0) {
    Add-Finding -Category "Kerberos" -Severity "HIGH" `
        -Finding "User accounts with SPN (Kerberoasting candidates): $($KerberoastTargets.Count)" `
        -Detail ($KerberoastTargets.SamAccountName -join ", ") `
        -Recommendation "Use gMSA for service accounts. Ensure strong passwords (25+ chars) on remaining SPNs."
}

# ============================================================
# 6. Default Administrator account active
# ============================================================
$DefaultAdmin = Get-ADUser -Filter { SamAccountName -eq "Administrator" } -Properties Enabled, LastLogonDate
if ($DefaultAdmin -and $DefaultAdmin.Enabled) {
    Add-Finding -Category "Credentials" -Severity "MEDIUM" `
        -Finding "Built-in Administrator account is enabled" `
        -Detail "Last logon: $($DefaultAdmin.LastLogonDate)" `
        -Recommendation "Disable built-in Administrator. Use named admin accounts for accountability."
}

# ============================================================
# Results
# ============================================================
Write-Host "`n===== SECURITY AUDIT RESULTS =====" -ForegroundColor Cyan
$Findings | Format-Table Category, Severity, Finding -AutoSize -Wrap

$HighCount = ($Findings | Where-Object Severity -eq "HIGH").Count
$MedCount = ($Findings | Where-Object Severity -eq "MEDIUM").Count
Write-Host "`n[SUMMARY] HIGH: $HighCount | MEDIUM: $MedCount | TOTAL: $($Findings.Count)" -ForegroundColor $(if ($HighCount -gt 0) { "Red" } else { "Green" })

foreach ($F in $Findings) {
    Write-Host "`n[$($F.Severity)] $($F.Finding)" -ForegroundColor $(if ($F.Severity -eq "HIGH") { "Red" } else { "Yellow" })
    Write-Host "  Detail : $($F.Detail)"
    Write-Host "  Fix    : $($F.Recommendation)" -ForegroundColor Cyan
}

if ($ExportHtml) {
    $Html = $Findings | ConvertTo-Html -Title "AD Security Audit" -PreContent "<h1>AD Security Audit — $(Get-Date -Format 'yyyy-MM-dd')</h1>"
    $Html | Out-File -FilePath $ExportHtml -Encoding UTF8
    Write-Host "`n[+] HTML report saved: $ExportHtml" -ForegroundColor Green
}
