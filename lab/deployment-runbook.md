# Runbook de Déploiement — Projet Fil Rouge G1 (de zéro à opérationnel)

> Procédure complète pour reproduire l'intégralité de l'infrastructure SOC Groupe 1.
> Suivre les phases dans l'ordre — chaque phase dépend de la précédente.

## Vue d'ensemble des phases

```
Phase 0 — IT-Server (hôte KVM)          → lab/it-server-setup.md
Phase 1 — Création des 6 VMs            → virt-install / Cockpit
Phase 2 — pfSense (réseau)              → manuel + playbook 07
Phase 3 — Active Directory (Windows)    → powershell/fil-rouge/01 + 02
Phase 4 — VMs Linux (Ansible 01→06)     → ansible/playbooks/
Phase 5 — Agent Wazuh Windows           → powershell/fil-rouge/03
Phase 6 — Domain join workstation       → playbook 08
Phase 7 — Validation                    → tests bout-en-bout
```

---

## Phase 0 — IT-Server (socle hôte)

Suivre intégralement **[it-server-setup.md](it-server-setup.md)** :
- KVM/libvirt + Cockpit
- Bridges `br-wan` (VLAN-aware) + `br-g1-lan`
- Hook libvirt VLAN 100
- Pare-feu firewalld (ports 1222-1225, 15901-15904)
- 8 tunnels SOCAT systemd

**Vérification :** `bridge vlan show | grep vnet` + `systemctl list-units | grep socat`

---

## Phase 1 — Création des 6 VMs

Via Cockpit (`https://10.29.200.127:9090`) ou `virt-install`, toutes attachées à `br-g1-lan` :

| VM | OS | RAM | vCPU | Disque |
|----|----|----|------|--------|
| G1-pfSense | pfSense 2.8 ISO | 1 GB | 1 | 20 GB |
| G1-SRV-AD | Windows Server 2025 ISO (**FR**) | 4 GB | 2 | 60 GB |
| G1-SRV-APP | Debian 13 Trixie | 2 GB | 2 | 40 GB |
| G1-SURICATA | Debian 13 Trixie | 2 GB | 2 | 40 GB |
| G1-WAZUH | Debian 13 Trixie | 6 GB | 4 | 80 GB |
| G1-workstation | Debian 13 Trixie | 2 GB | 2 | 40 GB |

> Sur les VMs Debian : créer l'utilisateur `g1admin`, activer SSH, installer les invités QEMU.

---

## Phase 2 — pfSense

1. **Console pfSense** : assigner WAN (em0) et LAN (em1 = 192.168.10.1/24)
2. **Accès WebGUI** : `ssh -L 8441:192.168.10.1:443 g1admin@10.29.200.127` → `https://localhost:8441`
3. **Configuration automatisée** (depuis le control node Ansible) :
   ```bash
   ansible-galaxy collection install -r ansible/requirements.yml
   cd ansible
   ansible-playbook playbooks/07-configuration-pfsense.yml
   ```
   → DNS Unbound (override g1soc.local), DHCP LAN (.100-.200), 10 règles firewall

**Vérification :** depuis une VM LAN, `ping 192.168.10.1` + résolution DNS.

---

## Phase 3 — Active Directory (sur G1-SRV-AD)

> Exécuté **directement sur la VM** (console/RDP) — le domaine n'existe pas encore,
> donc WinRM Kerberos n'est pas disponible.

1. **Promotion DC** (redémarre la VM) :
   ```powershell
   .\powershell\fil-rouge\01-Install-ADDS.ps1
   # Demande le mot de passe DSRM. Crée la forêt g1soc.local.
   ```

2. **Après redémarrage — structure AD** :
   ```powershell
   .\powershell\fil-rouge\02-Configure-ADStructure.ps1
   # Demande le mot de passe initial des utilisateurs.
   # Crée OUs, groupes (SOC-Analysts/Admins, IT-Support), users (amartin/bdupont/cmoreau), GPO audit.
   ```

**Vérification :** `Get-ADUser -Filter * | ft Name,SamAccountName` + `Get-GPO -All`

> **RDP vers la VM :** `ssh -L 13389:192.168.10.10:3389 g1admin@10.29.200.127` puis `mstsc localhost:13389`

---

## Phase 4 — VMs Linux (Ansible 01 → 06)

Depuis le control node Ansible (peut être G1-workstation ou un poste externe avec accès SOCAT) :

```bash
cd ansible

# Prérequis (une seule fois)
ansible-galaxy collection install -r requirements.yml
pip install pywinrm[kerberos] pymysql

# Créer le vault avec les credentials
ansible-vault create group_vars/vault.yml
#   vault_g1admin_password: "..."
#   vault_glpi_db_password: "..."
#   vault_ad_join_password: "..."

# Tester la connectivité
ansible groupe1 -m ping --ask-vault-pass

# Déploiement séquentiel
ansible-playbook playbooks/01-configuration-initiale.yml   --ask-vault-pass
ansible-playbook playbooks/02-configuration-reseau.yml     --ask-vault-pass
ansible-playbook playbooks/03-deploiement-vnc-xfce4.yml    --ask-vault-pass
ansible-playbook playbooks/04-deploiement-suricata.yml     --ask-vault-pass
ansible-playbook playbooks/05-deploiement-wazuh.yml        --ask-vault-pass
ansible-playbook playbooks/06-deploiement-applications.yml --ask-vault-pass
```

**Vérifications :**
- VNC : `vncviewer 10.29.200.127:15901`
- Suricata : `ssh -p 1223 ... "systemctl status suricata"`
- Wazuh Dashboard : `https://100.98.133.72` (credentials dans `/root/wazuh-install-files.tar`)
- GLPI : `http://localhost:8080` via tunnel — login `glpi`/`glpi` (à changer)

---

## Phase 5 — Agent Wazuh Windows (sur G1-SRV-AD)

```powershell
.\powershell\fil-rouge\03-Install-WazuhAgent.ps1
# Télécharge le MSI, enregistre auprès de 192.168.10.13, démarre WazuhSvc.
```

**Vérification :** Dashboard Wazuh > Agents → G1-SRV-AD actif (5e agent).

---

## Phase 6 — Domain join G1-workstation

```bash
cd ansible
ansible-playbook playbooks/08-domain-join-workstation.yml --ask-vault-pass
```

**Vérification :**
```bash
ssh -p 1225 g1admin@10.29.200.127 "id amartin"   # retourne UID/groupes AD
ssh amartin@192.168.10.99                          # connexion avec compte AD
```

---

## Phase 7 — Validation bout-en-bout

| Test | Commande / Action | Attendu |
|------|-------------------|---------|
| Isolation réseau | `ping` vers autre groupe | 100% packet loss |
| DNS interne | `nslookup g1-srv-ad.g1soc.local` | 192.168.10.10 |
| AD auth Linux | `id amartin` sur workstation | UID/groupes AD |
| Wazuh agents | Dashboard > Agents | 4 Linux + 1 Windows actifs |
| Suricata → Wazuh | `nmap -sS 192.168.10.0/24` depuis workstation | Règle 100133 (scan) remonte |
| Brute force AD | 6 logins échoués sur amartin | Règle 100101 remonte |
| GLPI inventaire | Parc > Ordinateurs | 4 VMs (tag Groupe1-SOC) |
| Firewall pfSense | Tester un port bloqué | Bloqué + loggé |

---

## Récapitulatif des dépendances

```
IT-Server ──► VMs ──► pfSense ──► AD (g1soc.local)
                                   │
        ┌──────────────────────────┴───────────┐
        ▼                                        ▼
  Ansible 01-06 (Linux)              PowerShell 03 (agent Win)
        │                                        │
        ▼                                        │
  Playbook 08 (domain join) ◄────────────────────┘
        │
        ▼
  Validation bout-en-bout
```
