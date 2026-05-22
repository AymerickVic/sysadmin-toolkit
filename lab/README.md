# Lab Infrastructure — Fil Rouge B3 CPI

> Virtual lab built on KVM/libvirt as part of the B3 CPI (Concepteur et Pilote d'Infrastructures) program. Simulates a small enterprise IT environment with Active Directory, SIEM, ITSM, and security monitoring.

## Overview

| Component | Role | OS |
|-----------|------|----|
| DC01 | Primary Domain Controller — AD DS, DNS, GPO | Windows Server 2019 |
| SRV-FILE01 | File server — DFS shares, home folders | Windows Server 2019 |
| SRV-GLPI01 | ITSM — GLPI + OCS Inventory | Debian 12 |
| SRV-WAZUH | SIEM — Wazuh Manager + Kibana | Debian 12 |
| SRV-SYSLOG | Log collector — rsyslog central relay | Debian 12 |
| CLIENT01 | Domain workstation (test & attack simulation) | Windows 10 Pro |

**Hypervisor:** KVM/libvirt on Debian 12 host  
**Network:** pfSense CE 2.7 with VLAN segmentation  
**Automation:** Ansible from management VLAN  

## Architecture

See [`../network/vlan-design.md`](../network/vlan-design.md) for the full network diagram and VLAN table.

```
Host (KVM)
├── pfSense VM        — firewall / VLAN routing
├── DC01              — VLAN 10 (.10)
├── SRV-FILE01        — VLAN 10 (.20)
├── SRV-GLPI01        — VLAN 10 (.21)
├── SRV-WAZUH         — VLAN 10 (.30)
├── SRV-SYSLOG        — VLAN 10 (.31)
└── CLIENT01          — VLAN 20 (.10)
```

## VM Specifications

| VM | vCPU | RAM | Disk |
|----|------|-----|------|
| pfSense | 1 | 1 GB | 20 GB |
| DC01 | 2 | 4 GB | 60 GB |
| SRV-FILE01 | 2 | 2 GB | 60 GB + 100 GB data |
| SRV-GLPI01 | 2 | 2 GB | 40 GB |
| SRV-WAZUH | 4 | 6 GB | 80 GB |
| SRV-SYSLOG | 1 | 1 GB | 40 GB |
| CLIENT01 | 2 | 4 GB | 60 GB |

**Total:** ~16 vCPU, ~20 GB RAM, ~460 GB storage

## Deployment Order

```
1. pfSense       — network foundation (VLANs, DHCP, DNS forward)
2. DC01          — AD domain, DNS authority
3. CLIENT01      — domain join test
4. SRV-FILE01    — DFS shares, home folder redirection via GPO
5. SRV-WAZUH     — Wazuh manager, then agent deployment via Ansible
6. SRV-GLPI01    — GLPI install, OCS agent on all hosts
7. SRV-SYSLOG    — rsyslog relay, forward to Wazuh
```

## Key Integrations

- **AD → Wazuh**: Active Directory security events forwarded via Windows event forwarding (WEF) and Wazuh agent
- **pfSense → rsyslog → Wazuh**: Firewall logs aggregated at SRV-SYSLOG and parsed by Wazuh
- **GLPI ↔ Active Directory**: LDAP authentication + user/computer sync for CMDB
- **Ansible → All**: Automated configuration management from MGMT VLAN

## What This Lab Demonstrates

| Skill | Evidence |
|-------|---------|
| Active Directory administration | AD structure, GPO design, user lifecycle |
| Linux server administration | Debian hardening, service configuration |
| Network segmentation | pfSense VLANs, inter-VLAN firewall rules |
| SIEM deployment | Wazuh installation, custom detection rules |
| ITSM | GLPI asset management, incident tickets |
| Automation | Ansible playbooks for configuration management |
| Security monitoring | Log forwarding, correlation, alerting |

## Documentation

| File | Description |
|------|-------------|
| [ad-structure.md](ad-structure.md) | AD domain design, OU structure, GPO list |
| [wazuh-custom-rules.md](wazuh-custom-rules.md) | Custom Wazuh detection rules and their rationale |
| [../network/vlan-design.md](../network/vlan-design.md) | VLAN diagram and firewall rules |
| [../network/pfsense-baseline.md](../network/pfsense-baseline.md) | pfSense configuration reference |
