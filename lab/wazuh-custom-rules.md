# Règles Wazuh — Détection SOC Groupe 1

> Règles personnalisées déployées sur le manager Wazuh (G1-WAZUH — 192.168.10.13).
> Fichier : `/var/ossec/etc/rules/local_rules.xml`
>
> Active-response **désactivé** sur tout le subnet 192.168.10.0/24 — détection uniquement,
> aucun risque de blocage sur l'infrastructure interne.

## Vue d'ensemble

| ID | Groupe | Déclencheur | Niveau | MITRE |
|----|--------|-------------|--------|-------|
| 100101 | AD Auth | 6 échecs login / 120s — même IP | 10 | T1110.001 |
| 100110 | AD Auth | Event 4740 — compte verrouillé | 12 | T1110 |
| 100120 | AD Groups | Events 4728/4732/4756 — modification groupe | 10 | T1098 |
| 100121 | AD Groups | Groupe privilégié (Domain Admins…) | 14 | T1098 |
| 100130 | Suricata | Alerte IDS sévérité 1 | 14 | T1046 |
| 100131 | Suricata | Alerte IDS sévérité 2 | 10 | — |
| 100132 | Suricata | Alerte IDS sévérité 3 | 6 | — |
| 100133 | Suricata | 10 alertes / 60s — même IP source | 12 | T1046 |
| 100140 | AD Auth | Connexion admin réussie (type 2/10) | 3 | — |

---

## Règles Active Directory

### 100101 — Brute force AD

**MITRE :** T1110.001 — Password Guessing

```xml
<rule id="100101" level="10" frequency="6" timeframe="120">
  <if_matched_sid>60122</if_matched_sid>
  <same_field>win.eventdata.ipAddress</same_field>
  <description>Brute force AD — 6 échecs login/120s depuis $(win.eventdata.ipAddress)</description>
  <mitre><id>T1110.001</id></mitre>
</rule>
```

**Pourquoi :** Event 4625 (échec login) seul = level 5 dans Wazuh — insuffisant pour alerter.
Cette règle corrèle 6 events depuis la même IP pour détecter credential stuffing / spray.

---

### 100110 — Compte AD verrouillé

**MITRE :** T1110 — Brute Force

```xml
<rule id="100110" level="12">
  <if_sid>60115</if_sid>
  <field name="win.system.eventID">^4740$</field>
  <description>Compte AD verrouillé : $(win.eventdata.targetUserName)</description>
  <mitre><id>T1110</id></mitre>
</rule>
```

**Pourquoi :** Event 4740 indique un verrouillage de compte — indicateur fort d'attaque brute force
ou de credential stuffing réussi jusqu'au seuil de lockout.

---

### 100120 — Modification de groupe AD

**MITRE :** T1098 — Account Manipulation

```xml
<rule id="100120" level="10">
  <if_sid>60113</if_sid>
  <field name="win.system.eventID">^4728$|^4732$|^4756$</field>
  <description>Modification groupe AD : $(win.eventdata.targetUserName) → $(win.eventdata.targetObject)</description>
  <mitre><id>T1098</id></mitre>
</rule>
```

**Pourquoi :** Events 4728 (ajout groupe global), 4732 (ajout groupe local), 4756 (ajout groupe universel).
Tout changement de membership doit être tracé.

---

### 100121 — Modification de groupe AD privilégié

**MITRE :** T1098 — Account Manipulation

```xml
<rule id="100121" level="14">
  <if_sid>100120</if_sid>
  <field name="win.eventdata.targetObject" type="pcre2">(?i)domain admins|enterprise admins|schema admins</field>
  <description>CRITIQUE : Modification groupe AD privilégié — $(win.eventdata.targetObject)</description>
  <mitre><id>T1098</id></mitre>
</rule>
```

**Pourquoi :** Level 14 = alerte immédiate. Toute modification de Domain Admins / Enterprise Admins
est un événement Tier-0. Les faux positifs sont extrêmement rares en environnement géré.

---

### 100140 — Connexion admin réussie (traçabilité)

```xml
<rule id="100140" level="3">
  <if_sid>60106</if_sid>
  <field name="win.eventdata.logonType">^2$|^10$</field>
  <field name="win.eventdata.targetUserName" type="pcre2">(?i)administrateur|cmoreau</field>
  <description>Connexion admin réussie — $(win.eventdata.targetUserName) type $(win.eventdata.logonType)</description>
</rule>
```

**Pourquoi :** Traçabilité des connexions admins (type 2 = interactif, type 10 = remote). Level 3 = log only,
pas d'alerte — uniquement pour la corrélation forensic post-incident.

---

## Règles Suricata IDS

### 100130 — Alerte IDS critique (sévérité 1)

**MITRE :** T1046 — Network Service Scanning

```xml
<rule id="100130" level="14">
  <if_sid>86601</if_sid>
  <field name="event_type">alert</field>
  <field name="alert.severity">^1$</field>
  <description>Alerte IDS Suricata CRITIQUE (sév. 1) : $(alert.signature)</description>
  <mitre><id>T1046</id></mitre>
</rule>
```

**Pourquoi :** Sévérité 1 dans les règles Suricata = menace critique (exploit, C2, intrusion confirmée).
Level 14 déclenche une alerte immédiate.

---

### 100131 — Alerte IDS majeure (sévérité 2)

```xml
<rule id="100131" level="10">
  <if_sid>86601</if_sid>
  <field name="event_type">alert</field>
  <field name="alert.severity">^2$</field>
  <description>Alerte IDS Suricata majeure (sév. 2) : $(alert.signature)</description>
</rule>
```

---

### 100132 — Alerte IDS info (sévérité 3)

```xml
<rule id="100132" level="6">
  <if_sid>86601</if_sid>
  <field name="event_type">alert</field>
  <field name="alert.severity">^3$</field>
  <description>Alerte IDS Suricata info (sév. 3) : $(alert.signature)</description>
</rule>
```

---

### 100133 — Scan réseau détecté

**MITRE :** T1046 — Network Service Scanning

```xml
<rule id="100133" level="12" frequency="10" timeframe="60">
  <if_matched_sid>86601</if_matched_sid>
  <same_field>src_ip</same_field>
  <description>Scan réseau détecté — 10 alertes Suricata/60s depuis $(src_ip)</description>
  <mitre><id>T1046</id></mitre>
</rule>
```

**Pourquoi :** 10 alertes Suricata en 60 secondes depuis la même IP source = comportement de scanner.
Corrèle les alertes individuelles pour réduire le bruit et remonter un seul événement de niveau 12.

---

## Intégration Suricata → Wazuh

L'agent Wazuh sur G1-SURICATA lit directement le fichier `eve.json` de Suricata :

```xml
<!-- Dans ossec.conf de l'agent g1-suricata -->
<localfile>
  <log_format>json</log_format>
  <location>/var/log/suricata/eve.json</location>
  <label key="@source">suricata</label>
</localfile>
```

Le parent SID `86601` est le décodeur Wazuh natif pour les alertes Suricata au format eve.json.

## Niveaux d'alerte

| Niveau | Action |
|--------|--------|
| 1–5 | Log uniquement (Wazuh Dashboard) |
| 6–9 | Alerte Dashboard |
| 10–13 | Alerte Dashboard + notification |
| 14–15 | Alerte critique — investigation immédiate requise |

## Tester les règles

```bash
# Tester la syntaxe des règles
/var/ossec/bin/wazuh-logtest

# Tester la règle 100101 (brute force AD)
# Simuler sur G1-workstation : 6 tentatives de login échouées sur un compte AD
# → Vérifier l'alerte dans Wazuh Dashboard > Security Events

# Tester Suricata → Wazuh
# Depuis G1-workstation : nmap -sS 192.168.10.0/24
# → Vérifie que la règle 100133 (scan réseau) remonte dans Wazuh
```
