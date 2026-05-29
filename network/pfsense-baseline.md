# pfSense Baseline — Configuration Groupe 1

> Configuration de référence pfSense 2.8 pour le lab fil rouge Groupe 1.
> Déployée via le playbook Ansible `07-configuration-pfsense.yml` (pfsensible.core).

## Environnement

| Paramètre | Valeur |
|-----------|--------|
| Version pfSense | 2.8 (FreeBSD) |
| Interface WAN | em0 (bridge br-wan, VLAN-aware) |
| Interface LAN | em1 (bridge br-g1-lan, VLAN 100) |
| IP LAN (passerelle) | 192.168.10.1/24 |
| Domaine | g1soc.local |
| Accès Ansible | Via Tailscale 100.98.133.72 |

## Configuration des interfaces

### WAN (em0)
- Type : DHCP (depuis le réseau WAN de l'établissement — 10.29.200.0/22)
- Bridge VLAN-aware avec le réseau extérieur

### LAN (em1 — VLAN 100)
| Paramètre | Valeur |
|-----------|--------|
| IP | 192.168.10.1/24 |
| VLAN ID | 100 |
| Bridge | br-g1-lan |

## DHCP LAN

```
Services > DHCP Server > LAN:
  Activé       : oui
  Plage        : 192.168.10.100 — 192.168.10.200
  Passerelle   : 192.168.10.1
  DNS primaire : 192.168.10.10 (G1-SRV-AD)
  Domaine      : g1soc.local
  Durée bail   : 86400 s (24h)

  Réservations statiques :
    G1-SRV-AD        → 192.168.10.10
    G1-SRV-APP       → 192.168.10.11
    G1-SURICATA      → 192.168.10.12
    G1-WAZUH         → 192.168.10.13
    G1-workstation   → 192.168.10.99
```

## DNS Resolver (Unbound)

```
Services > DNS Resolver:
  Activé               : oui
  Domain override      : g1soc.local → 192.168.10.10 (G1-SRV-AD)
  DNSSEC               : oui
  Interfaces           : LAN (VLAN 100)
```

Le domain override redirige toutes les requêtes `*.g1soc.local` vers l'AD
plutôt que vers les serveurs DNS publics.

## Règles Firewall LAN (10 règles)

Déployées via `pfsensible.core.pfsense_rule` (playbook 07).
La règle permissive par défaut "allow all LAN → any" est **supprimée**.

| # | Nom | Proto | Source | Destination | Port | Action |
|---|-----|-------|--------|-------------|------|--------|
| 1 | LAN-to-pfSense-SSH | TCP | 192.168.10.0/24 | 192.168.10.1 | 22 | PASS |
| 2 | LAN-DNS-UDP | UDP | 192.168.10.0/24 | 192.168.10.1 | 53 | PASS |
| 3 | LAN-DNS-TCP | TCP | 192.168.10.0/24 | 192.168.10.1 | 53 | PASS |
| 4 | LAN-NTP | UDP | 192.168.10.0/24 | 192.168.10.1 | 123 | PASS |
| 5 | LAN-to-AD | Any | 192.168.10.0/24 | 192.168.10.10 | * | PASS |
| 6 | LAN-Wazuh-Agents | TCP | 192.168.10.0/24 | 192.168.10.13 | 1514–1515 | PASS |
| 7 | LAN-Wazuh-Dashboard | TCP | 192.168.10.0/24 | 192.168.10.13 | 443 | PASS |
| 8 | LAN-GLPI-HTTP | TCP | 192.168.10.0/24 | 192.168.10.11 | 80 | PASS |
| 9 | LAN-ICMP-Out | ICMP | 192.168.10.0/24 | any | * | PASS |
| 10 | LAN-HTTP-HTTPS-Out | TCP | 192.168.10.0/24 | any | 80–443 | PASS |
| — | LAN-BLOCK-ALL | Any | any | any | * | BLOCK |

## NAT

Mode : **Automatique** — toutes les VMs sortent par le WAN pfSense avec NAT masquerade.

## NTP

```
Services > NTP:
  Serveurs : 0.fr.pool.ntp.org, 1.fr.pool.ntp.org
  Interfaces : LAN

  Les clients synchronisent sur pfSense (192.168.10.1).
  G1-SRV-AD synchronise sur pfSense, les membres AD sur G1-SRV-AD (Windows Time Service).
  → Kerberos : décalage max toléré 5 minutes
```

## Bugs résolus lors du déploiement Ansible

| Problème | Cause | Solution |
|----------|-------|----------|
| Module `pfsense_dns_resolver_domain_override` inexistant | Nom de module incorrect | Utiliser `domainoverrides:` dans `pfsensible.core.pfsense_dns_resolver` |
| Module `pfsense_dhcp` inexistant | Nom de module incorrect | Utiliser `pfsensible.core.pfsense_dhcp_server` |
| `ports: "1514-1515"` invalide | Syntaxe pfSense — tiret non reconnu | Utiliser `ports: "1514:1515"` (deux-points) |
| Python interpreter non détecté | pfSense 2.8 utilise Python 3.11 | `ansible_python_interpreter: /usr/local/bin/python3.11` |
| DNS cassé après application règles | `resolv.conf` pointait sur 8.8.8.8, bloqué par nouvelles règles | Renouveler le bail DHCP : `ip link set enp1s0 down && ip link set enp1s0 up` |

## Limitations (lab vs production)

| Aspect | Lab | Production |
|--------|-----|------------|
| HA | pfSense unique | CARP failover pair |
| IDS/IPS sur pfSense | Non (Suricata sur VM dédiée) | Suricata inline sur pfSense |
| VPN admin | Tailscale (externe) | IPsec ou OpenVPN dédié |
| Certificat WebGUI | Auto-signé | PKI interne ou Let's Encrypt |
| Segmentation interne | VLAN unique (100) | VLANs séparés par rôle |
