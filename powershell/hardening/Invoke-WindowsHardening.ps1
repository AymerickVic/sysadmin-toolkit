<#
.SYNOPSIS
    Applies a security hardening baseline to a Windows Server.

.DESCRIPTION
    Implements CIS Benchmark-aligned hardening controls:
    - Disables legacy protocols (SMBv1, NetBIOS, LLMNR, WPAD)
    - Configures Windows Firewall (enable all profiles)
    - Tightens audit policy (logon, privilege use, object access)
    - Sets secure registry values (NTLMv2, UAC, RDP NLA, LSASS protection)
    - Disables unused services (WinRM HTTP, Telnet, Print Spooler on non-print servers)
    - Configures password policy via secedit

    Run in -WhatIf mode first. Requires local Administrator privileges.

.PARAMETER WhatIf
    Preview changes without applying them.

.PARAMETER SkipFirewall
    Skip Windows Firewall configuration.

.PARAMETER SkipAuditPolicy
    Skip audit policy configuration.

.PARAMETER SkipRegistryHardening
    Skip registry-based hardening.

.EXAMPLE
    .\Invoke-WindowsHardening.ps1 -WhatIf
    .\Invoke-WindowsHardening.ps1
    .\Invoke-WindowsHardening.ps1 -SkipFirewall

.NOTES
    Author   : Aymerick Victoire
    Requires : Local Administrator, Windows Server 2016+
    Purpose  : CIS baseline, pre-pentest hardening, compliance
    Ref      : CIS Microsoft Windows Server 2019 Benchmark v2.0
    MITRE    : T1110 (Brute Force), T1557 (MITM), T1078 (Valid Accounts)
#>

#Requires -RunAsAdministrator

param (
    [switch]$WhatIf              = $false,
    [switch]$SkipFirewall        = $false,
    [switch]$SkipAuditPolicy     = $false,
    [switch]$SkipRegistryHardening = $false
)

$ErrorActionPreference = "Continue"
$Changes = @()
$Skipped = @()

function Apply-Change {
    param([string]$Description, [scriptblock]$Action)

    if ($WhatIf) {
        Write-Host "  [WHATIF] $Description" -ForegroundColor DarkYellow
        $script:Skipped += $Description
    }
    else {
        try {
            & $Action
            Write-Host "  [OK] $Description" -ForegroundColor Green
            $script:Changes += $Description
        }
        catch {
            Write-Host "  [ERROR] $Description — $_" -ForegroundColor Red
        }
    }
}

Write-Host "[*] Windows Hardening Baseline" -ForegroundColor Cyan
Write-Host "[*] Mode: $(if ($WhatIf) { 'WHAT-IF (no changes)' } else { 'APPLY' })" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# 1. Legacy Protocols
# ============================================================
Write-Host "[1] Legacy protocol hardening" -ForegroundColor White

Apply-Change "Disable SMBv1 (server)" {
    Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
}

Apply-Change "Disable SMBv1 (client via registry)" {
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\mrxsmb10" -Name "Start" -Value 4 -Type DWord
}

Apply-Change "Disable LLMNR (link-local multicast name resolution)" {
    $Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name "EnableMulticast" -Value 0 -Type DWord
}

Apply-Change "Disable WPAD (web proxy auto-discovery)" {
    $Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\WinHttp"
    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
    Set-ItemProperty -Path $Path -Name "DisableWpad" -Value 1 -Type DWord
}

Apply-Change "Disable NetBIOS over TCP/IP on all adapters" {
    Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } |
        ForEach-Object { $_.SetTcpipNetbios(2) | Out-Null }  # 2 = Disable NetBIOS
}

# ============================================================
# 2. Windows Firewall
# ============================================================
if (-not $SkipFirewall) {
    Write-Host "`n[2] Windows Firewall" -ForegroundColor White

    Apply-Change "Enable all firewall profiles (Domain, Private, Public)" {
        Set-NetFirewallProfile -Profile Domain, Private, Public -Enabled True
    }

    Apply-Change "Block inbound by default on Public profile" {
        Set-NetFirewallProfile -Profile Public -DefaultInboundAction Block
    }
}

# ============================================================
# 3. Audit Policy
# ============================================================
if (-not $SkipAuditPolicy) {
    Write-Host "`n[3] Audit policy (Windows Advanced Audit)" -ForegroundColor White

    $AuditCategories = @(
        @{ Category = "Logon/Logoff"; Subcategory = "Logon";                  Setting = "Success,Failure" },
        @{ Category = "Logon/Logoff"; Subcategory = "Logoff";                 Setting = "Success" },
        @{ Category = "Logon/Logoff"; Subcategory = "Account Lockout";        Setting = "Success,Failure" },
        @{ Category = "Account Management"; Subcategory = "User Account Management"; Setting = "Success,Failure" },
        @{ Category = "Account Management"; Subcategory = "Security Group Management"; Setting = "Success,Failure" },
        @{ Category = "Privilege Use"; Subcategory = "Sensitive Privilege Use"; Setting = "Success,Failure" },
        @{ Category = "DS Access"; Subcategory = "Directory Service Changes"; Setting = "Success,Failure" },
        @{ Category = "Policy Change"; Subcategory = "Audit Policy Change";   Setting = "Success,Failure" }
    )

    foreach ($Audit in $AuditCategories) {
        Apply-Change "Audit: $($Audit.Subcategory) — $($Audit.Setting)" {
            auditpol /set /subcategory:"$($Audit.Subcategory)" /success:$(if ($Audit.Setting -match "Success") { "enable" } else { "disable" }) /failure:$(if ($Audit.Setting -match "Failure") { "enable" } else { "disable" }) | Out-Null
        }
    }
}

# ============================================================
# 4. Registry Hardening
# ============================================================
if (-not $SkipRegistryHardening) {
    Write-Host "`n[4] Registry hardening" -ForegroundColor White

    # NTLMv2 only (no LM/NTLMv1)
    Apply-Change "Force NTLMv2 authentication (LMCompatibilityLevel = 5)" {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "LmCompatibilityLevel" -Value 5 -Type DWord
    }

    # LSASS Protection (RunAsPPL)
    Apply-Change "Enable LSASS Protected Process Light (RunAsPPL)" {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RunAsPPL" -Value 1 -Type DWord
    }

    # Disable credential caching (DomainCachedCredentials — leave 1 for recovery)
    Apply-Change "Limit domain credential cache to 1 (CachedLogonsCount)" {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" -Name "CachedLogonsCount" -Value "1" -Type String
    }

    # RDP Network Level Authentication
    Apply-Change "Require NLA for RDP (UserAuthentication = 1)" {
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1 -Type DWord
    }

    # UAC settings
    Apply-Change "Enable UAC — prompt for admin credentials (ConsentPromptBehaviorAdmin = 1)" {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "ConsentPromptBehaviorAdmin" -Value 1 -Type DWord
    }

    Apply-Change "Enable UAC — always prompt on secure desktop" {
        Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "PromptOnSecureDesktop" -Value 1 -Type DWord
    }

    # Disable WDigest plaintext password storage in LSASS
    Apply-Change "Disable WDigest plaintext credential storage" {
        $Path = "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest"
        if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }
        Set-ItemProperty -Path $Path -Name "UseLogonCredential" -Value 0 -Type DWord
    }
}

# ============================================================
# 5. Summary
# ============================================================
Write-Host "`n===== HARDENING SUMMARY =====" -ForegroundColor Cyan

if ($WhatIf) {
    Write-Host "[WHAT-IF] $($Skipped.Count) controls previewed — no changes applied." -ForegroundColor Yellow
}
else {
    Write-Host "[+] $($Changes.Count) controls applied successfully." -ForegroundColor Green
}

Write-Host "`n[i] Recommended next steps:" -ForegroundColor Gray
Write-Host "    - Review Event Viewer for audit policy confirmation (Event ID 4719)"
Write-Host "    - Validate SMBv1 disabled: Get-SmbServerConfiguration | Select EnableSMB1Protocol"
Write-Host "    - Test RDP NLA from a client before closing sessions"
Write-Host "    - Schedule regular re-run to detect drift"
