# pfSense Firewall Baseline Configuration

> Configuration de référence pfSense pour le lab fil rouge. Documente les choix de configuration, les règles clés et les bonnes pratiques appliquées.

## Environment

| Parameter | Value |
|-----------|-------|
| pfSense version | 2.7.x CE |
| WAN interface | em0 (bridged to host NAT) |
| LAN interface | em1 (VLAN trunk to internal bridge) |
| Hostname | `pfsense.lab.local` |
| Admin access | HTTPS on MGMT VLAN only |

## Interface Configuration

### WAN (em0)
- Type: DHCP (from hypervisor NAT)
- Block private networks: **ON**
- Block bogon networks: **ON**

### VLAN Interfaces (em1 trunk)
| Interface | VLAN | IP | DHCP |
|-----------|------|----|----|
| LAN_SERVERS | 10 | 192.168.10.1/24 | OFF (static assignments) |
| LAN_WORKSTATIONS | 20 | 192.168.20.1/24 | ON (.100-.200) |
| LAN_MANAGEMENT | 30 | 192.168.30.1/24 | OFF (static) |

## Security Hardening

### Admin Interface
```
System > Advanced > Admin Access:
  Protocol          : HTTPS only
  TCP port          : 8443 (non-default)
  Max login attempts: 5
  Login protection  : ON
  Disable webGUI redirect rule: ON
  Allowed source    : 192.168.30.0/24 (MGMT VLAN only)
```

### System Tunables
```
System > Advanced > System Tunables:
  net.inet.ip.forwarding     = 1   (required for routing)
  net.inet.tcp.blackhole     = 2   (drop TCP to closed ports silently)
  net.inet.udp.blackhole     = 1   (drop UDP to closed ports silently)
  net.inet.icmp.drop_redirect = 1  (ignore ICMP redirects)
```

### SSH Access
```
System > Advanced > Admin Access > Secure Shell:
  Enable SSH  : ON
  Port        : 2222
  Auth method : Key only (no password auth)
  Allowed from: 192.168.30.5/32 (Ansible node only)
```

## NAT Configuration

### Outbound NAT
Mode: **Automatic** — all internal VLANs NAT through WAN interface.

### Port Forwards (inbound)
No inbound port forwards in baseline — lab is not externally exposed.

## DHCP Server (VLAN 20 — Workstations)

```
Services > DHCP Server > LAN_WORKSTATIONS:
  Range       : 192.168.20.100 — 192.168.20.200
  DNS servers : 192.168.10.10 (DC01)
  Gateway     : 192.168.20.1
  Domain name : lab.local
  Lease time  : 86400 (24h)

  Static mappings:
    CLIENT01  MAC: xx:xx:xx:xx:xx:01  IP: 192.168.20.10
```

## DNS Configuration

```
Services > DNS Resolver (Unbound):
  Enable                    : ON
  Network Interfaces        : All internal VLANs
  Outgoing Network Interfaces: WAN
  DNSSEC                    : ON
  DNS over TLS              : ON (forwarding to 1.1.1.1:853, 9.9.9.9:853)

  Host Overrides (internal zones):
    dc01.lab.local    → 192.168.10.10
    wazuh.lab.local   → 192.168.10.30
    glpi.lab.local    → 192.168.10.21
```

## Firewall Rules

### Anti-lockout Rule
Automatically maintained by pfSense — allows HTTPS/SSH from LAN to firewall.  
**Do not delete.**

### VLAN 10 — SERVERS
```
# Allow established connections (stateful)
pass  in  quick  proto tcp  from any  to any  flags S/SA  keep state

# DC inbound (from workstations and servers)
pass  in  proto tcp/udp  from 192.168.20.0/24  to 192.168.10.10  port {53, 88, 135, 389, 445, 636, 3268, 3269}

# Wazuh agent registration
pass  in  proto tcp  from any  to 192.168.10.30  port {1514, 1515, 55000}

# GLPI web access
pass  in  proto tcp  from 192.168.20.0/24  to 192.168.10.21  port {80, 443}

# Block all else inbound to servers
block in  log  all
```

### VLAN 20 — WORKSTATIONS
```
# Allow workstations to reach AD services on DC
pass  in  proto tcp/udp  from 192.168.20.0/24  to 192.168.10.10  port {53, 88, 135, 389, 445, 636}

# Allow internet access via WAN NAT
pass  in  proto tcp  from 192.168.20.0/24  to any  port {80, 443}

# Block workstation-to-server direct access (except above)
block in  log  from 192.168.20.0/24  to 192.168.10.0/24

# Block inter-workstation traffic
block in  log  from 192.168.20.0/24  to 192.168.20.0/24
```

### VLAN 30 — MANAGEMENT
```
# Allow Ansible to reach all servers (SSH + WinRM)
pass  in  proto tcp  from 192.168.30.5/32  to 192.168.10.0/24  port {22, 5985, 5986}

# Allow admin HTTPS to pfSense web UI
pass  in  proto tcp  from 192.168.30.0/24  to 192.168.30.1  port 8443

# Block management VLAN from reaching workstations (principle of least privilege)
block in  log  from 192.168.30.0/24  to 192.168.20.0/24

# Block all else
block in  log  all
```

## Logging & Monitoring

```
Status > System Logs > Settings:
  Log firewall default blocks: ON
  Log packets matched by rules: ON
  Remote logging              : ON
    Remote log servers        : 192.168.10.31:514 (SRV-SYSLOG)
    Remote syslog contents    : Firewall events, System events, DHCP
```

## NTP Configuration

```
Services > NTP:
  Time servers: 0.fr.pool.ntp.org, 1.fr.pool.ntp.org
  Interface   : LAN_SERVERS, LAN_WORKSTATIONS

  Internal clients use pfSense as NTP server:
    DC01 syncs from pfSense
    All domain members sync from DC01 (Windows Time Service)
```

## Backup

pfSense configuration backed up via:
1. **Auto-backup**: `Diagnostics > Backup & Restore > AutoConfigBackup` (Netgate cloud — free tier)
2. **Manual XML export**: after any significant change, export `config.xml` and store in `lab/backups/`

## Known Limitations (Lab vs Production)

| Aspect | Lab | Production |
|--------|-----|------------|
| HA | Single pfSense | CARP failover pair |
| IDS/IPS | Not enabled (resource) | Suricata on WAN |
| VPN | Not configured | IPsec or OpenVPN for remote admin |
| Certificate | Self-signed | Internal CA or Let's Encrypt |
| Log retention | 7 days local | SIEM with 90-day retention |
