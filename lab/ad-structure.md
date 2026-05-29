# Structure Active Directory — g1soc.local

> Domaine AD du lab fil rouge Groupe 1. Documente les OUs, groupes, utilisateurs, GPO et configuration DNS.

## Informations domaine

| Paramètre | Valeur |
|-----------|--------|
| FQDN | `g1soc.local` |
| Nom NetBIOS | `G1SOC` |
| Niveau forêt/domaine | Windows Server 2025 |
| Contrôleur de domaine | G1-SRV-AD — 192.168.10.10 |
| Zones DNS | `g1soc.local` (primaire), zone inverse `10.168.192.in-addr.arpa` |

## Structure des OUs

```
DC=g1soc,DC=local
│
├── OU=IT                    ← Comptes IT admin (cmoreau)
├── OU=Users                 ← Utilisateurs SOC (amartin, bdupont)
├── OU=Computers             ← Postes clients domaine (g1-workstation)
├── OU=Security              ← Objets de sécurité
└── OU=Groups                ← Groupes de sécurité (scope: Global)
    ├── SOC-Analysts
    ├── SOC-Admins
    └── IT-Support
```

## Groupes de sécurité

| Groupe | OU | Membres | Rôle |
|--------|-----|---------|------|
| `SOC-Analysts` | OU=Groups | amartin, bdupont | Analystes SOC — lecture alertes Wazuh |
| `SOC-Admins` | OU=Groups | cmoreau | Administrateurs SOC — gestion Wazuh + règles |
| `IT-Support` | OU=Groups | amartin, cmoreau | Support IT — accès GLPI + inventaire |

## Utilisateurs

| Nom | Login | OU | Groupes | Rôle |
|-----|-------|----|---------|------|
| Alice Martin | `amartin` | OU=Users | SOC-Analysts, IT-Support | Analyste SOC |
| Bob Dupont | `bdupont` | OU=Users | SOC-Analysts | Analyste SOC |
| Claire Moreau | `cmoreau` | OU=IT | SOC-Admins, IT-Support | Admin IT & SOC |

> **Note Windows FR :** Le compte administrateur intégré est `Administrateur` (RID 500),
> pas `Administrator` — Windows Server 2025 installé en français.

## Group Policy Objects (GPO)

| GPO | Liée à | Objectif |
|-----|--------|----------|
| `SOC-AuditPolicy` | Racine du domaine | Active les audits de sécurité |

### Paramètres SOC-AuditPolicy

```
Computer Configuration > Policies > Windows Settings > Security Settings:
  Advanced Audit Policy:
    Logon/Logoff:
      Audit Logon                      : Success, Failure  → Events 4624, 4625
      Audit Logoff                     : Success
    Account Management:
      Audit User Account Management    : Success, Failure  → Events 4720, 4722, 4725, 4726
      Audit Security Group Management  : Success           → Events 4728, 4732, 4756
      Audit Computer Account Management: Success
    Account Logon:
      Audit Kerberos Authentication    : Success, Failure  → Event 4771, 4768
    DS Access:
      Audit Directory Service Changes  : Success           → Event 4740 (lockout)
```

## DNS — Zone g1soc.local

| Enregistrement | Type | Valeur |
|----------------|------|--------|
| `g1soc.local` | SOA / NS | G1-SRV-AD |
| `g1-srv-ad` | A | 192.168.10.10 |
| `g1-srv-app` | A | 192.168.10.11 |
| `g1-suricata` | A | 192.168.10.12 |
| `g1-wazuh` | A | 192.168.10.13 |
| `g1-workstation` | A | 192.168.10.99 |
| `glpi` | CNAME | g1-srv-app |
| `wazuh` | CNAME | g1-wazuh |
| `_ldap._tcp` | SRV | G1-SRV-AD port 389 |
| `_kerberos._tcp` | SRV | G1-SRV-AD port 88 |

## Intégration domaine — G1-workstation

G1-workstation (Debian 13 Trixie) est joint au domaine via `net ads join` avec `smb.conf` configuré.

```bash
# Prérequis : NTP synchronisé (Kerberos tolère 5 min max de décalage)
# realm join échoue (CONSTRAINT_ATT_TYPE userAccountControl sur Windows 2016+)
# → utiliser net ads join

net ads join -U amartin%<password>
```

**Fichiers de configuration :**

```ini
# /etc/samba/smb.conf
[global]
    workgroup = G1SOC
    realm = G1SOC.LOCAL
    security = ADS
    kerberos method = secrets and keytab
    server role = member server
```

```ini
# /etc/sssd/sssd.conf (chmod 600)
[sssd]
services = nss, pam
config_file_version = 2
domains = g1soc.local

[domain/g1soc.local]
id_provider = ad
ad_domain = g1soc.local
krb5_realm = G1SOC.LOCAL
use_fully_qualified_names = False
ldap_id_mapping = True
access_provider = ad
ad_gpo_access_control = disabled
fallback_homedir = /home/%u@%d
cache_credentials = True
```

**Vérification :**
```bash
id amartin          # retourne UID/GID AD
ssh amartin@192.168.10.99  # connexion SSH avec compte AD ✅
```

## Notes WinRM sur DC (G1-SRV-AD)

WinRM avec NTLM est **rejeté** après la promotion en Domain Controller (comportement Windows Server 2016+).
Kerberos requis pour WinRM. Alternative : utiliser Samba/SMB (`net ads`, `rpcclient`, `smbclient`).

```yaml
# Inventaire Ansible — transport Kerberos obligatoire
ansible_winrm_transport: kerberos
# Tunnel SSH prérequis : ssh -L 15985:192.168.10.10:5985 g1admin@10.29.200.127
```
