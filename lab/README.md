# Lab Infrastructure — Fil Rouge B3 CPI (Groupe 1)

> Infrastructure SOC virtuelle déployée dans le cadre du projet fil rouge B3 CPI — Groupe 1.
> 6 VMs sur KVM/libvirt simulant un petit SOC d'entreprise avec Active Directory, SIEM, ITSM et IDS.

## Serveur hôte (IT-Server)

| Paramètre | Valeur |
|-----------|--------|
| OS | Rocky Linux 9.7 |
| Hyperviseur | KVM + libvirt |
| Interface de gestion | Cockpit — port 9090 |
| IP WAN | 10.29.200.127/22 |
| IP Tailscale VPN | 100.98.133.72 |
| Bridge WAN | `br-wan` (VLAN-aware) |
| Bridge LAN G1 | `br-g1-lan` — 192.168.10.0/24, VLAN 100 |

## Architecture

```
IT-Server (Rocky Linux 9.7 — KVM/libvirt)
│
└── br-g1-lan (192.168.10.0/24 — VLAN 100)
    │
    ├── G1-pfSense       — 192.168.10.1    (routeur, DHCP, NAT, firewall)
    ├── G1-SRV-AD        — 192.168.10.10   (Active Directory, DNS)
    ├── G1-SRV-APP       — 192.168.10.11   (Apache, PHP, MariaDB, GLPI)
    ├── G1-SURICATA      — 192.168.10.12   (IDS/IPS Suricata)
    ├── G1-WAZUH         — 192.168.10.13   (SIEM Wazuh all-in-one)
    └── G1-workstation   — 192.168.10.99   (Poste client, tests attaque/défense)

Accès externe : tunnels SOCAT systemd sur IT-Server
  SSH  : ports 1222–1225 → VMs .11/.12/.13/.99
  VNC  : ports 15901–15904 → VMs .11/.12/.13/.99
```

## VMs déployées

| VM | OS | IP | vCPU | RAM | Rôle |
|----|----|----|------|-----|------|
| G1-pfSense | pfSense 2.8 (FreeBSD) | 192.168.10.1 | 1 | 1 GB | Routeur, DHCP, NAT, Pare-feu |
| G1-SRV-AD | Windows Server 2025 | 192.168.10.10 | 2 | 4 GB | Active Directory, DNS |
| G1-SRV-APP | Debian 13 Trixie | 192.168.10.11 | 2 | 2 GB | Apache2, PHP 8.4, MariaDB, GLPI 11.0.6 |
| G1-SURICATA | Debian 13 Trixie | 192.168.10.12 | 2 | 2 GB | IDS/IPS Suricata 7.0.10 |
| G1-WAZUH | Debian 13 Trixie | 192.168.10.13 | 4 | 6 GB | SIEM Wazuh 4.14.4 (all-in-one) |
| G1-workstation | Debian 13 Trixie | 192.168.10.99 | 2 | 2 GB | Poste client, XFCE4, tests |

**Total :** ~13 vCPU, ~17 GB RAM

## Ordre de déploiement

```
1. IT-Server     — KVM, bridges, hook VLAN, firewall, SOCAT  → voir it-server-setup.md
2. Créer les 6 VMs — virt-install / Cockpit, attachées à br-g1-lan
3. G1-pfSense    — réseau, DHCP, NAT (playbook 07)
4. G1-SRV-AD     — Active Directory, DNS (g1soc.local) — installation manuelle
5. Playbooks Ansible — 01 → 06 (config, VNC, Suricata, Wazuh, GLPI)
6. G1-workstation — domain join (net ads join), sssd, tests
```

> **⚠️ Prérequis Ansible** — avant d'exécuter les playbooks :
> ```bash
> ansible-galaxy collection install -r ../ansible/requirements.yml
> pip install pywinrm[kerberos]   # pour le playbook AD
> ```

## Accès

| VM | SSH (WAN) | SSH (Tailscale) | VNC |
|----|-----------|-----------------|-----|
| G1-SRV-APP | `ssh -p 1222 g1admin@10.29.200.127` | `ssh -p 1222 g1admin@100.98.133.72` | `10.29.200.127:15901` |
| G1-SURICATA | `ssh -p 1223 g1admin@10.29.200.127` | `ssh -p 1223 g1admin@100.98.133.72` | `10.29.200.127:15902` |
| G1-WAZUH | `ssh -p 1224 g1admin@10.29.200.127` | `ssh -p 1224 g1admin@100.98.133.72` | `10.29.200.127:15903` |
| G1-workstation | `ssh -p 1225 g1admin@10.29.200.127` | `ssh -p 1225 g1admin@100.98.133.72` | `10.29.200.127:15904` |

**RDP vers G1-SRV-AD :**
```bash
ssh -L 13389:192.168.10.10:3389 g1admin@10.29.200.127
# Puis : mstsc localhost:13389
```

**Interfaces web :**

| Service | URL | Tunnel SSH requis |
|---------|-----|-------------------|
| pfSense WebGUI | `https://localhost:8441` | `ssh -L 8441:192.168.10.1:443 g1admin@10.29.200.127` |
| GLPI | `http://localhost:8080` | `ssh -L 8080:localhost:80 -p 1222 g1admin@100.98.133.72` |
| Wazuh Dashboard | `https://100.98.133.72` (direct Tailscale) | `ssh -L 8443:localhost:443 -p 1224 g1admin@100.98.133.72` |
| Cockpit IT-Server | `https://10.29.200.127:9090` | — |

## Intégrations clés

| Intégration | Mécanisme |
|-------------|-----------|
| AD → Wazuh | Agent Windows sur G1-SRV-AD (events 4624, 4625, 4728, 4740…) |
| Suricata → Wazuh | Agent local sur G1-SURICATA lit `/var/log/suricata/eve.json` |
| GLPI Agent | 4 VMs inventoriées toutes les heures (tag `Groupe1-SOC`) |
| Workstation → AD | `net ads join -U amartin` + sssd (`id amartin` retourne UID AD) |
| pfSense → Wazuh | Logs firewall via règles Wazuh (events syslog pfSense) |

## Isolation réseau

- VLAN 100 dédié au Groupe 1 — isolation complète des autres groupes
- Bridge `br-g1-lan` séparé, aucun routage inter-VLAN
- Tests validés : 100% packet loss vers autres groupes (ping)
- Hook libvirt `/etc/libvirt/hooks/qemu` — attribution automatique VLAN 100

## État des services (mai 2026)

| Service | Statut |
|---------|--------|
| Apache2 + MariaDB + GLPI 11.0.6 | ✅ actif |
| Suricata 7.0.10 | ✅ actif |
| Wazuh Manager + Indexer + Dashboard 4.14.4 | ✅ actif |
| Wazuh agents (4/4 — incl. Windows) | ✅ actifs |
| VNC x4 (TigerVNC port 5901) | ✅ actif |
| Active Directory (g1soc.local) | ✅ opérationnel |
| GLPI Agent 1.11 (4 VMs inventoriées) | ✅ actif |
| pfSense config + règles firewall | ✅ opérationnel |
| G1-workstation joint au domaine | ✅ (net ads join + sssd) |

## Documentation

| Fichier | Description |
|---------|-------------|
| [it-server-setup.md](it-server-setup.md) | **Socle hôte** — KVM, bridges, hook VLAN 100, firewall, tunnels SOCAT |
| [ad-structure.md](ad-structure.md) | Structure AD g1soc.local — OUs, groupes, utilisateurs, GPO |
| [wazuh-custom-rules.md](wazuh-custom-rules.md) | Règles de détection SOC personnalisées avec mapping MITRE |
| [../network/vlan-design.md](../network/vlan-design.md) | Architecture réseau, VLAN 100, tunnels SOCAT |
| [../network/pfsense-baseline.md](../network/pfsense-baseline.md) | Configuration pfSense — DHCP, DNS Unbound, 10 règles firewall |
