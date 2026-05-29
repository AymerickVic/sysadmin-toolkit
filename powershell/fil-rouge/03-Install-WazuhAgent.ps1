<#
.SYNOPSIS
    Installe et enregistre l'agent Wazuh sur G1-SRV-AD (Windows Server 2025).

.DESCRIPTION
    Étape 3 — déploie l'agent Wazuh Windows et le connecte au manager (G1-WAZUH).
    Remonte les événements Windows Security (4624, 4625, 4728, 4740…) vers le SIEM.

    Note réseau (cf. incidents projet) : l'upload du MSI via WinRM échoue
    (limite cmd.exe 8191 chars + encodage). G1-SRV-AD a internet sur TCP/443
    malgré ICMP bloqué → téléchargement direct via Invoke-WebRequest.

.PARAMETER ManagerIP
    IP du manager Wazuh (défaut 192.168.10.13).

.PARAMETER AgentVersion
    Version de l'agent (défaut 4.14.4).

.NOTES
    Tester la connectivité avant : Test-NetConnection -ComputerName 192.168.10.13 -Port 1514
    (ne pas utiliser ping — ICMP bloqué par pfSense)
#>
[CmdletBinding()]
param(
    [string]$ManagerIP    = "192.168.10.13",
    [string]$AgentVersion = "4.14.4",
    # "default" existe toujours sur le manager. Pour un groupe custom
    # (ex. windows-servers), le créer d'abord sur le manager sinon
    # l'enregistrement agent-auth échoue.
    [string]$AgentGroup   = "default"
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Vérifier si l'agent est déjà installé ───────────────────────────────────
if (Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue) {
    Write-Host "[=] Agent Wazuh déjà installé. Sortie." -ForegroundColor DarkGray
    return
}

# ── Vérifier la connectivité au manager (TCP, pas ICMP) ─────────────────────
Write-Host "[*] Test connectivité manager ${ManagerIP}:1514 ..." -ForegroundColor Cyan
$test = Test-NetConnection -ComputerName $ManagerIP -Port 1514 -WarningAction SilentlyContinue
if (-not $test.TcpTestSucceeded) {
    Write-Warning "Port 1514 injoignable sur $ManagerIP — vérifier les règles pfSense. Poursuite quand même."
}

# ── Télécharger le MSI directement depuis packages.wazuh.com ────────────────
$msiUrl  = "https://packages.wazuh.com/4.x/windows/wazuh-agent-$AgentVersion-1.msi"
$msiPath = "$env:TEMP\wazuh-agent-$AgentVersion.msi"

Write-Host "[*] Téléchargement de l'agent Wazuh $AgentVersion ..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $msiUrl -OutFile $msiPath -UseBasicParsing

# ── Installation silencieuse + enregistrement auprès du manager ─────────────
Write-Host "[*] Installation et enregistrement auprès de $ManagerIP ..." -ForegroundColor Cyan
$arguments = @(
    "/i", "`"$msiPath`"",
    "/q",
    "WAZUH_MANAGER=`"$ManagerIP`"",
    "WAZUH_AGENT_GROUP=`"$AgentGroup`"",
    "WAZUH_REGISTRATION_SERVER=`"$ManagerIP`""
)
$proc = Start-Process -FilePath "msiexec.exe" -ArgumentList $arguments -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "Échec de l'installation MSI (code $($proc.ExitCode))"
}

# ── Démarrer le service ─────────────────────────────────────────────────────
Write-Host "[*] Démarrage du service WazuhSvc ..." -ForegroundColor Cyan
Start-Service -Name "WazuhSvc"
Set-Service  -Name "WazuhSvc" -StartupType Automatic

$svc = Get-Service -Name "WazuhSvc"
Write-Host ""
Write-Host "[+] Agent Wazuh $AgentVersion installé — statut : $($svc.Status)" -ForegroundColor Green
Write-Host "    Vérifier dans le Dashboard Wazuh > Agents que G1-SRV-AD apparaît actif." -ForegroundColor Yellow
