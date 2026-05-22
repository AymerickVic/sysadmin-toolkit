# Wazuh Custom Detection Rules

> Custom rules written for the fil rouge lab. Each rule targets a specific attack technique or security event relevant to a Windows/AD environment.

## Rule File Location

Custom rules are stored in `/var/ossec/etc/rules/local_rules.xml` on the Wazuh manager.

## Rules

### Rule 100001 — Multiple Failed Logons (Brute Force)

**MITRE:** T1110.001 — Password Guessing

```xml
<!-- Detect 5+ failed logon attempts within 2 minutes from the same source -->
<group name="windows,authentication,brute_force">

  <rule id="100001" level="10" frequency="5" timeframe="120">
    <if_matched_sid>60122</if_matched_sid>  <!-- Windows failed logon -->
    <same_field>win.eventdata.ipAddress</same_field>
    <description>Possible brute force attack — 5+ failed logons in 2 min from $(win.eventdata.ipAddress)</description>
    <mitre>
      <id>T1110.001</id>
    </mitre>
    <group>authentication_failures</group>
  </rule>

</group>
```

**Why:** Event 4625 (failed logon) alone is level 5 in Wazuh defaults — not enough for alerting. This rule correlates 5 events from the same source IP to detect credential stuffing or spray attempts.

---

### Rule 100002 — New Member Added to Domain Admins

**MITRE:** T1098 — Account Manipulation

```xml
<group name="windows,active_directory,privilege_escalation">

  <rule id="100002" level="14">
    <if_sid>60144</if_sid>  <!-- Security group membership change -->
    <field name="win.eventdata.targetUserName" type="pcre2">(?i)domain admins</field>
    <description>CRITICAL: User added to Domain Admins group — $(win.eventdata.subjectUserName) added $(win.eventdata.memberName)</description>
    <mitre>
      <id>T1098</id>
    </mitre>
    <group>privilege_escalation,pci_dss_10.2.5</group>
  </rule>

</group>
```

**Why:** Any modification to Domain Admins is a Tier-0 event. Level 14 triggers immediate PagerDuty/email alert. False positives are extremely rare in a well-managed environment.

---

### Rule 100003 — Scheduled Task Created (Persistence)

**MITRE:** T1053.005 — Scheduled Task

```xml
<group name="windows,persistence">

  <rule id="100003" level="10">
    <if_sid>60634</if_sid>  <!-- Sysmon Event 1 — Process Create, or Event ID 4698 -->
    <field name="win.system.eventID">4698</field>
    <description>Scheduled task created: $(win.eventdata.taskName) by $(win.eventdata.subjectUserName)</description>
    <mitre>
      <id>T1053.005</id>
    </mitre>
    <group>persistence,rootkit</group>
  </rule>

</group>
```

**Why:** Event 4698 (scheduled task created) is not alerted by default in Wazuh. Attackers commonly use scheduled tasks for persistence post-compromise. Any unexpected task creation on servers should be investigated.

---

### Rule 100004 — Service Installed (Possible Lateral Movement)

**MITRE:** T1569.002 — System Services: Service Execution

```xml
<group name="windows,lateral_movement">

  <rule id="100004" level="10">
    <if_sid>18107</if_sid>  <!-- Event 7045 — new service installed -->
    <description>New Windows service installed: $(win.eventdata.serviceName) on $(win.system.computer)</description>
    <mitre>
      <id>T1569.002</id>
    </mitre>
    <group>rootkit</group>
  </rule>

</group>
```

**Why:** Tools like Mimikatz, PsExec, and Metasploit often install a service on the target host. Event 7045 in the System log fires when any new service is registered.

---

### Rule 100005 — Wazuh Agent Disconnected

```xml
<group name="wazuh,availability">

  <rule id="100005" level="12">
    <if_sid>503</if_sid>  <!-- Agent disconnected -->
    <description>Wazuh agent OFFLINE: $(agent.name) — possible tampering or system shutdown</description>
    <group>availability,integrity_monitoring</group>
  </rule>

</group>
```

**Why:** An attacker who gains admin access may stop the Wazuh agent to blind the SIEM. An unexpected agent disconnect (especially during business hours) is a high-fidelity indicator of compromise.

---

### Rule 100006 — LSASS Access (Credential Dumping)

**MITRE:** T1003.001 — LSASS Memory

Requires **Sysmon** Event ID 10 (ProcessAccess targeting lsass.exe).

```xml
<group name="windows,credential_access">

  <rule id="100006" level="15">
    <if_sid>61613</if_sid>  <!-- Sysmon ProcessAccess -->
    <field name="win.eventdata.targetImage" type="pcre2">(?i)lsass\.exe</field>
    <field name="win.eventdata.grantedAccess" type="pcre2">0x1010|0x1410|0x1fffff</field>
    <description>CRITICAL: LSASS memory access detected — possible credential dumping by $(win.eventdata.sourceImage)</description>
    <mitre>
      <id>T1003.001</id>
    </mitre>
    <group>credential_access,rootkit</group>
  </rule>

</group>
```

**Why:** Mimikatz and similar tools open lsass.exe with `PROCESS_VM_READ` (0x0010) or `PROCESS_ALL_ACCESS` (0x1fffff). Level 15 = highest severity — immediate response required. Requires Sysmon deployed to endpoints.

---

## Sysmon Configuration

Sysmon deployment on CLIENT01 and DC01 uses the [SwiftOnSecurity Sysmon config](https://github.com/SwiftOnSecurity/sysmon-config) as a base, with the following additions:

- ProcessAccess to `lsass.exe` — enabled (disabled in base config for noise)
- NetworkConnect from PowerShell, cmd, wscript, cscript — logged

## Alert Routing

| Level | Destination |
|-------|------------|
| 1–6   | Log only (Kibana) |
| 7–11  | Kibana alert + daily digest email |
| 12–14 | Immediate email to admin |
| 15    | Email + (future: PagerDuty webhook) |

## Testing Rules

```bash
# Replay a test event against a specific rule
/var/ossec/bin/ossec-logtest

# Test rule 100002 manually
echo '{"win":{"eventdata":{"targetUserName":"Domain Admins","subjectUserName":"test.user"}}}' | \
  /var/ossec/bin/ossec-logtest -V
```
