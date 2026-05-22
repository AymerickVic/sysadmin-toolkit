# Active Directory Structure — lab.local

> Domain design for the fil rouge lab. Documents the OU structure, group policy design, and administrative model.

## Domain Information

| Parameter | Value |
|-----------|-------|
| Domain name (FQDN) | `lab.local` |
| NetBIOS name | `LAB` |
| Forest/Domain level | Windows Server 2016 |
| Domain Controller | DC01 — 192.168.10.10 |
| DNS zones | `lab.local` (primary), `10.168.192.in-addr.arpa` (reverse) |

## OU Structure

```
DC=lab,DC=local
│
├── OU=Computers
│   ├── OU=Workstations          ← CLIENT01 and future workstations
│   └── OU=Servers               ← Member servers (FILE01, GLPI01)
│
├── OU=Users
│   ├── OU=IT                    ← IT admin accounts
│   ├── OU=Finance               ← Finance department users
│   ├── OU=RH                    ← HR department users
│   └── OU=Direction             ← Management users
│
├── OU=Groups
│   ├── OU=Security              ← ACL groups (GRP-IT, GRP-Finance, etc.)
│   └── OU=Distribution          ← Email distribution lists
│
├── OU=Service_Accounts          ← Service accounts (gMSA preferred)
│   └── gMSA: svc-wazuh$         ← Wazuh agent service account
│
└── OU=Disabled                  ← Disabled accounts staging area
    ├── OU=Users_Disabled
    └── OU=Computers_Disabled
```

## Group Naming Convention

| Prefix | Type | Example |
|--------|------|---------|
| `GRP-` | Security group (resource access) | `GRP-IT`, `GRP-Finance` |
| `ADM-` | Administrative group | `ADM-Helpdesk`, `ADM-ServerAdmins` |
| `DL-` | Distribution list | `DL-AllUsers` |

## Security Groups

| Group | Members | Purpose |
|-------|---------|---------|
| Domain Admins | admin.it only | Full domain admin — Tier 0 |
| ADM-ServerAdmins | it-admins | Local admin on servers via GPO |
| ADM-Helpdesk | helpdesk users | Password reset, account unlock only |
| GRP-IT | IT dept users | Access to IT file shares |
| GRP-Finance | Finance dept users | Access to Finance shares |
| GRP-AllUsers | All enabled users | Basic shared resources |

## Group Policy Objects

### Computer GPOs

| GPO | Linked To | Purpose |
|-----|-----------|---------|
| `GPO-Computer-Baseline` | OU=Computers | Windows Update config, audit policy, firewall on |
| `GPO-Workstation-Security` | OU=Workstations | USB restriction, screen lock 5min, Windows Defender |
| `GPO-Server-Security` | OU=Servers | Restrict local logon, AppLocker, no RDP from workstations |
| `GPO-DC-Security` | Domain Controllers (default) | Strict audit policy, no non-admin logons |

### User GPOs

| GPO | Linked To | Purpose |
|-----|-----------|---------|
| `GPO-User-Baseline` | OU=Users | Drive mappings, printer, WSUS, desktop background |
| `GPO-User-IT` | OU=Users\IT | PowerShell unrestricted, RSAT tools |
| `GPO-HomeFolder-Redirect` | OU=Users | Folder redirection: Documents → \\SRV-FILE01\homes\%username% |

### Key GPO Settings — Computer Baseline

```
Computer Configuration > Policies > Windows Settings > Security Settings:
  Account Policies:
    Password Policy:
      Minimum length          : 12 characters
      Complexity requirements : Enabled
      Maximum password age    : 90 days
      Enforce history         : 10 passwords
    Account Lockout Policy:
      Lockout threshold       : 5 invalid attempts
      Lockout duration        : 30 minutes
      Reset counter after     : 30 minutes

  Local Policies > Audit Policy (Advanced):
    Logon Events              : Success, Failure
    Account Management        : Success, Failure
    Privilege Use             : Success, Failure
    Object Access             : Failure

  Security Options:
    Network security: LAN Manager auth level  : NTLMv2 only
    Network security: LDAP signing requirement : Require signing
    Interactive logon: Machine inactivity limit: 900 seconds
```

## Administrative Model (Tiered Admin)

Simplified three-tier model adapted for lab scale:

| Tier | Scope | Account type | Example |
|------|-------|--------------|---------|
| T0 | Domain controllers, AD schema | `admin.it` (Domain Admin) | DC management only |
| T1 | Member servers | `srv-admin` (local admin via GPO) | Server maintenance |
| T2 | Workstations | `help-desk` (Helpdesk group) | User support |

**Principle:** T1/T2 accounts cannot log onto Tier-0 assets (enforced by GPO logon rights restriction on DCs).

## DNS Zones

### Forward Zone: `lab.local`

| Record | Type | Value |
|--------|------|-------|
| `lab.local` | SOA/NS | DC01 |
| `dc01` | A | 192.168.10.10 |
| `srv-file01` | A | 192.168.10.20 |
| `srv-glpi01` | A | 192.168.10.21 |
| `srv-wazuh` | A | 192.168.10.30 |
| `srv-syslog` | A | 192.168.10.31 |
| `glpi` | CNAME | srv-glpi01 |
| `wazuh` | CNAME | srv-wazuh |
| `_ldap._tcp` | SRV | DC01 port 389 |
| `_kerberos._tcp` | SRV | DC01 port 88 |

### Reverse Zone: `10.168.192.in-addr.arpa`

PTR records for all static hosts — auto-created by AD DNS when A records are added with "create associated pointer record" checked.
