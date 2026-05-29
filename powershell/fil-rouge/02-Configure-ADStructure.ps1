<#
.SYNOPSIS
    Crée la structure AD du projet fil rouge : OUs, groupes, utilisateurs, GPO d'audit.

.DESCRIPTION
    Étape 2 du déploiement AD (après promotion DC et redémarrage).
    Idempotent : vérifie l'existence de chaque objet avant création.

    Crée :
      - 5 OUs (IT, Users, Computers, Security, Groups)
      - 3 groupes de sécurité (SOC-Analysts, SOC-Admins, IT-Support)
      - 3 utilisateurs (amartin, bdupont, cmoreau) avec appartenances
      - 1 GPO SOC-AuditPolicy (audit avancé) liée à la racine du domaine

.PARAMETER UserPassword
    Mot de passe initial des comptes utilisateurs. Demandé si non fourni.

.NOTES
    Domaine : g1soc.local
#>
[CmdletBinding()]
param(
    [securestring]$UserPassword = (Read-Host -AsSecureString -Prompt "Mot de passe initial des utilisateurs AD")
)

$ErrorActionPreference = "Stop"
Import-Module ActiveDirectory
Import-Module GroupPolicy

$domainDN = (Get-ADDomain).DistinguishedName   # DC=g1soc,DC=local
$domain   = (Get-ADDomain).DNSRoot             # g1soc.local

function New-OUIfMissing {
    param([string]$Name, [string]$Path)
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$dn'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $Name -Path $Path -ProtectedFromAccidentalDeletion $false
        Write-Host "    + OU créée : $dn" -ForegroundColor Green
    } else {
        Write-Host "    = OU existe : $dn" -ForegroundColor DarkGray
    }
}

# ── OUs ─────────────────────────────────────────────────────────────────────
Write-Host "[*] Création des OUs ..." -ForegroundColor Cyan
foreach ($ou in @("IT", "Users", "Computers", "Security", "Groups")) {
    New-OUIfMissing -Name $ou -Path $domainDN
}

$ouGroups = "OU=Groups,$domainDN"
$ouUsers  = "OU=Users,$domainDN"
$ouIT     = "OU=IT,$domainDN"

# ── Groupes de sécurité (scope Global) ──────────────────────────────────────
Write-Host "[*] Création des groupes de sécurité ..." -ForegroundColor Cyan
$groups = @(
    @{ Name = "SOC-Analysts"; Desc = "Analystes SOC — lecture alertes Wazuh" },
    @{ Name = "SOC-Admins";   Desc = "Administrateurs SOC — gestion Wazuh + règles" },
    @{ Name = "IT-Support";   Desc = "Support IT — accès GLPI + inventaire" }
)
foreach ($g in $groups) {
    if (-not (Get-ADGroup -Filter "Name -eq '$($g.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $g.Name -GroupScope Global -GroupCategory Security `
            -Path $ouGroups -Description $g.Desc
        Write-Host "    + Groupe créé : $($g.Name)" -ForegroundColor Green
    } else {
        Write-Host "    = Groupe existe : $($g.Name)" -ForegroundColor DarkGray
    }
}

# ── Utilisateurs ─────────────────────────────────────────────────────────────
Write-Host "[*] Création des utilisateurs ..." -ForegroundColor Cyan
$users = @(
    @{ Login="amartin"; First="Alice";  Last="Martin"; OU=$ouUsers; Groups=@("SOC-Analysts","IT-Support") },
    @{ Login="bdupont"; First="Bob";     Last="Dupont"; OU=$ouUsers; Groups=@("SOC-Analysts") },
    @{ Login="cmoreau"; First="Claire";  Last="Moreau"; OU=$ouIT;    Groups=@("SOC-Admins","IT-Support") }
)
foreach ($u in $users) {
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$($u.Login)'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name "$($u.First) $($u.Last)" `
            -GivenName $u.First -Surname $u.Last `
            -SamAccountName $u.Login `
            -UserPrincipalName "$($u.Login)@$domain" `
            -Path $u.OU `
            -AccountPassword $UserPassword `
            -Enabled $true `
            -ChangePasswordAtLogon $false
        Write-Host "    + Utilisateur créé : $($u.Login)" -ForegroundColor Green
    } else {
        Write-Host "    = Utilisateur existe : $($u.Login)" -ForegroundColor DarkGray
    }
    foreach ($grp in $u.Groups) {
        Add-ADGroupMember -Identity $grp -Members $u.Login -ErrorAction SilentlyContinue
    }
}

# ── GPO d'audit avancé ───────────────────────────────────────────────────────
Write-Host "[*] Configuration de la GPO SOC-AuditPolicy ..." -ForegroundColor Cyan
$gpoName = "SOC-AuditPolicy"
$gpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
if (-not $gpo) {
    $gpo = New-GPO -Name $gpoName -Comment "Audit de sécurité SOC — connexions, comptes, groupes"
    New-GPLink -Name $gpoName -Target $domainDN -LinkEnabled Yes | Out-Null
    Write-Host "    + GPO créée et liée à la racine du domaine" -ForegroundColor Green
} else {
    Write-Host "    = GPO existe : $gpoName" -ForegroundColor DarkGray
}

# Forcer la prise en compte de l'audit avancé (sinon les sous-catégories
# sont ignorées au profit des catégories legacy) — registre via GPO (fiable)
Set-GPRegistryValue -Name $gpoName `
    -Key "HKLM\System\CurrentControlSet\Control\Lsa" `
    -ValueName "SCENoApplyLegacyAuditPolicy" -Type DWord -Value 1 | Out-Null

# ── Audit avancé : auditpol directement sur le DC ───────────────────────────
# On N'écrit PAS l'audit.csv à la main dans SYSVOL : sans enregistrement des
# CSE GUIDs dans gPCMachineExtensionNames + bump de version GPT.ini, la GPO
# ignorerait le fichier. auditpol applique l'audit immédiatement sur le DC,
# là où sont générés les events 4624/4625/4740/4728 lus par l'agent Wazuh.
# GUIDs de sous-catégorie (indépendants de la langue — Windows FR).
Write-Host "[*] Application de l'audit avancé sur le DC (auditpol) ..." -ForegroundColor Cyan
$auditSubcats = @(
    @{ Guid="{0cce9215-69ae-11d9-bed3-505054503030}"; Success="enable"; Failure="enable"; Name="Logon" },
    @{ Guid="{0cce9216-69ae-11d9-bed3-505054503030}"; Success="enable"; Failure="disable"; Name="Logoff" },
    @{ Guid="{0cce9235-69ae-11d9-bed3-505054503030}"; Success="enable"; Failure="enable"; Name="User Account Management" },
    @{ Guid="{0cce9237-69ae-11d9-bed3-505054503030}"; Success="enable"; Failure="disable"; Name="Security Group Management" },
    @{ Guid="{0cce9236-69ae-11d9-bed3-505054503030}"; Success="enable"; Failure="disable"; Name="Computer Account Management" },
    @{ Guid="{0cce9242-69ae-11d9-bed3-505054503030}"; Success="enable"; Failure="enable"; Name="Kerberos Authentication Service" },
    @{ Guid="{0cce923c-69ae-11d9-bed3-505054503030}"; Success="enable"; Failure="disable"; Name="Directory Service Changes" }
)
foreach ($sc in $auditSubcats) {
    & auditpol /set /subcategory:"$($sc.Guid)" /success:$($sc.Success) /failure:$($sc.Failure) | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    + Audit : $($sc.Name)" -ForegroundColor Green
    } else {
        Write-Warning "    ! Échec auditpol sur $($sc.Name) (code $LASTEXITCODE)"
    }
}

Write-Host ""
Write-Host "[+] Structure AD configurée. Vérifier avec : Get-ADUser -Filter * | ft" -ForegroundColor Green
Write-Host "    Vérifier l'audit : auditpol /get /category:* | findstr /i 'Ouverture Compte'" -ForegroundColor Yellow
Write-Host "    NB : pour un audit avancé DOMAINE-WIDE (postes/serveurs membres)," -ForegroundColor Yellow
Write-Host "         configurer les sous-catégories dans la GPO via GPMC (gpme.msc)" -ForegroundColor Yellow
Write-Host "         — l'UI enregistre automatiquement les CSE GUIDs requis." -ForegroundColor Yellow
