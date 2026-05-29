<#
.SYNOPSIS
    Installe le rôle AD DS et promeut G1-SRV-AD en contrôleur de domaine g1soc.local.

.DESCRIPTION
    Étape 1 du déploiement Active Directory du projet fil rouge (Groupe 1).
    À exécuter directement sur G1-SRV-AD (console / RDP) — le domaine n'existe
    pas encore, donc WinRM Kerberos n'est pas disponible à ce stade.

    Le serveur REDÉMARRE automatiquement à la fin de la promotion.

.PARAMETER DsrmPassword
    Mot de passe DSRM (Directory Services Restore Mode). Demandé si non fourni.

.PARAMETER IPAddress
    IP statique à appliquer (défaut 192.168.10.10). Mettre à $null pour conserver le DHCP.

.NOTES
    Windows Server 2025 installé en FRANÇAIS → compte intégré = Administrateur (pas Administrator).
    Domaine : g1soc.local | NetBIOS : G1SOC
#>
[CmdletBinding()]
param(
    [securestring]$DsrmPassword = (Read-Host -AsSecureString -Prompt "Mot de passe DSRM"),
    [string]$IPAddress  = "192.168.10.10",
    [string]$Gateway    = "192.168.10.1",
    [string]$DnsServer  = "127.0.0.1",
    [string]$DomainName = "g1soc.local",
    [string]$NetbiosName = "G1SOC"
)

$ErrorActionPreference = "Stop"

# ── Configuration IP statique (optionnelle) ────────────────────────────────
if ($IPAddress) {
    Write-Host "[*] Configuration IP statique $IPAddress ..." -ForegroundColor Cyan
    $adapter = Get-NetAdapter | Where-Object Status -eq "Up" | Select-Object -First 1

    # Supprimer une éventuelle config IP existante sur l'adaptateur
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Get-NetRoute -InterfaceIndex $adapter.ifIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $IPAddress `
        -PrefixLength 24 -DefaultGateway $Gateway | Out-Null
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DnsServer
}

# ── Installation du rôle AD DS ──────────────────────────────────────────────
Write-Host "[*] Installation du rôle AD-Domain-Services ..." -ForegroundColor Cyan
Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

# ── Promotion en contrôleur de domaine (nouvelle forêt) ─────────────────────
Write-Host "[*] Promotion en DC — création de la forêt $DomainName ..." -ForegroundColor Cyan
Import-Module ADDSDeployment

Install-ADDSForest `
    -DomainName $DomainName `
    -DomainNetbiosName $NetbiosName `
    -ForestMode "WinThreshold" `
    -DomainMode "WinThreshold" `
    -InstallDns:$true `
    -SafeModeAdministratorPassword $DsrmPassword `
    -CreateDnsDelegation:$false `
    -DatabasePath "C:\Windows\NTDS" `
    -LogPath "C:\Windows\NTDS" `
    -SysvolPath "C:\Windows\SYSVOL" `
    -NoRebootOnCompletion:$false `
    -Force:$true

# Le serveur redémarre automatiquement.
# Étape suivante après reboot : 02-Configure-ADStructure.ps1
