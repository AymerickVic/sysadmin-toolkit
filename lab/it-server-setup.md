# Setup IT-Server — Socle KVM/libvirt (Groupe 1)

> Configuration du serveur hôte avant tout déploiement de VM. **Prérequis à tous les playbooks Ansible.**
> Sans ces étapes, les bridges/VLAN n'existent pas et les VMs ne sont pas accessibles depuis l'extérieur.

## 1. Système hôte

| Paramètre | Valeur |
|-----------|--------|
| OS | Rocky Linux 9.7 |
| Hyperviseur | KVM + libvirt |
| Gestion web | Cockpit (port 9090) |
| IP WAN | 10.29.200.127/22 |
| VPN | Tailscale → 100.98.133.72 |

```bash
# Installation KVM/libvirt + outils
sudo dnf install -y qemu-kvm libvirt virt-install bridge-utils \
    cockpit cockpit-machines socat tailscale

# Activer libvirt et Cockpit
sudo systemctl enable --now libvirtd
sudo systemctl enable --now cockpit.socket

# Vérifier le support de virtualisation
lscpu | grep -E "vmx|svm"     # doit retourner vmx (Intel) ou svm (AMD)
virt-host-validate
```

## 2. Bridges réseau

Deux bridges : `br-wan` (sortie internet, VLAN-aware) et `br-g1-lan` (LAN interne VLAN 100).

```bash
# Bridge WAN — VLAN-aware (trunk vers le réseau de l'établissement)
sudo nmcli connection add type bridge con-name br-wan ifname br-wan
sudo nmcli connection modify br-wan bridge.vlan-filtering yes
sudo nmcli connection add type bridge-slave con-name br-wan-port \
    ifname <interface_physique> master br-wan

# Bridge LAN Groupe 1 — 192.168.10.0/24, VLAN 100
sudo nmcli connection add type bridge con-name br-g1-lan ifname br-g1-lan
sudo nmcli connection modify br-g1-lan ipv4.method disabled ipv6.method ignore
sudo nmcli connection modify br-g1-lan bridge.vlan-filtering yes

sudo nmcli connection up br-wan
sudo nmcli connection up br-g1-lan
```

Déclarer les bridges dans libvirt :

```bash
cat > /tmp/br-g1-lan.xml <<'EOF'
<network>
  <name>br-g1-lan</name>
  <forward mode="bridge"/>
  <bridge name="br-g1-lan"/>
</network>
EOF

sudo virsh net-define /tmp/br-g1-lan.xml
sudo virsh net-start br-g1-lan
sudo virsh net-autostart br-g1-lan
```

## 3. Hook libvirt — VLAN 100 automatique

Le hook attribue le VLAN 100 aux interfaces des VMs Groupe 1 à chaque démarrage.

```bash
sudo tee /etc/libvirt/hooks/qemu > /dev/null <<'EOF'
#!/bin/bash
# Hook libvirt — tag VLAN 100 pour les VMs Groupe 1
# Appelé automatiquement par libvirt à chaque transition d'état de VM

GUEST_NAME="$1"
OPERATION="$2"

# S'applique uniquement aux VMs du Groupe 1 (préfixe G1-)
case "$GUEST_NAME" in
  G1-*)
    if [ "$OPERATION" = "started" ]; then
      # Récupérer les interfaces vnet de cette VM sur br-g1-lan
      for vnet in $(virsh domiflist "$GUEST_NAME" | awk '/br-g1-lan/ {print $1}'); do
        bridge vlan add dev "$vnet" vid 100 pvid untagged
      done
    fi
    ;;
esac
EOF

sudo chmod +x /etc/libvirt/hooks/qemu
sudo systemctl restart libvirtd
```

> Vérification après démarrage d'une VM : `bridge vlan show | grep vnet`

## 4. Pare-feu (firewalld)

Ouvrir les ports des tunnels SOCAT (SSH 1222-1225, VNC 15901-15904) + Cockpit.

```bash
# Zone dédiée pour l'accès distant
sudo firewall-cmd --permanent --new-zone=remote-access 2>/dev/null || true

# Ports SSH (1222-1225) et VNC (15901-15904)
for port in 1222 1223 1224 1225 15901 15902 15903 15904; do
  sudo firewall-cmd --permanent --add-port=${port}/tcp
done

# Cockpit + SSH hôte
sudo firewall-cmd --permanent --add-port=9090/tcp
sudo firewall-cmd --permanent --add-service=ssh

sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
```

## 5. Tunnels SOCAT (services systemd)

Chaque VM interne est exposée via un tunnel SOCAT supervisé par systemd (`Restart=always`).
Mapping : SSH 1222-1225 et VNC 15901-15904 → IPs .11/.12/.13/.99.

### Template de service SSH

```bash
# Exemple : G1-SRV-APP (192.168.10.11) sur le port 1222
sudo tee /etc/systemd/system/socat-ssh-g1-srv-app.service > /dev/null <<'EOF'
[Unit]
Description=SOCAT SSH tunnel — G1-SRV-APP (1222 -> 192.168.10.11:22)
After=network.target libvirtd.service

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:1222,fork,reuseaddr TCP:192.168.10.11:22
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

### Tableau complet des tunnels à créer

| Service systemd | Port hôte | Destination |
|-----------------|-----------|-------------|
| `socat-ssh-g1-srv-app` | 1222 | 192.168.10.11:22 |
| `socat-ssh-g1-suricata` | 1223 | 192.168.10.12:22 |
| `socat-ssh-g1-wazuh` | 1224 | 192.168.10.13:22 |
| `socat-ssh-g1-workstation` | 1225 | 192.168.10.99:22 |
| `socat-vnc-g1-srv-app` | 15901 | 192.168.10.11:5901 |
| `socat-vnc-g1-suricata` | 15902 | 192.168.10.12:5901 |
| `socat-vnc-g1-wazuh` | 15903 | 192.168.10.13:5901 |
| `socat-vnc-g1-workstation` | 15904 | 192.168.10.99:5901 |

### Script de génération des 8 tunnels

```bash
#!/bin/bash
# Génère et active les 8 services SOCAT
declare -A SSH_MAP=( [1222]=11 [1223]=12 [1224]=13 [1225]=99 )
declare -A VNC_MAP=( [15901]=11 [15902]=12 [15903]=13 [15904]=99 )

gen_service() {
  local name="$1" port="$2" dest_ip="$3" dest_port="$4"
  sudo tee /etc/systemd/system/${name}.service > /dev/null <<EOF
[Unit]
Description=SOCAT tunnel ${name}
After=network.target libvirtd.service

[Service]
ExecStart=/usr/bin/socat TCP-LISTEN:${port},fork,reuseaddr TCP:${dest_ip}:${dest_port}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

for port in "${!SSH_MAP[@]}"; do
  gen_service "socat-ssh-${SSH_MAP[$port]}" "$port" "192.168.10.${SSH_MAP[$port]}" 22
done
for port in "${!VNC_MAP[@]}"; do
  gen_service "socat-vnc-${VNC_MAP[$port]}" "$port" "192.168.10.${VNC_MAP[$port]}" 5901
done

sudo systemctl daemon-reload
sudo systemctl enable --now socat-ssh-* socat-vnc-*
```

## 6. Vérification finale

```bash
# Bridges et VLAN
ip addr show br-g1-lan
bridge vlan show | grep vnet

# Tunnels SOCAT actifs
systemctl list-units | grep "socat.*g1"

# Test connectivité (depuis un poste externe via Tailscale)
ssh -p 1222 g1admin@100.98.133.72 "hostname; ip addr show enp1s0"

# Ports ouverts
nmap -p 1222-1225,15901-15904 10.29.200.127
```

## Ordre global de déploiement

```
1. CE GUIDE (IT-Server)  ← socle : KVM, bridges, hook VLAN, firewall, SOCAT
2. Créer les 6 VMs       ← virt-install / Cockpit, attachées à br-g1-lan
3. G1-pfSense            ← config réseau, DHCP, NAT (manuel ou playbook 07)
4. G1-SRV-AD             ← Windows Server 2025, promotion AD DS (manuel)
5. Playbooks Ansible     ← 01 → 07 (voir ansible/playbooks/)
6. Domain join           ← G1-workstation : net ads join + sssd
```
