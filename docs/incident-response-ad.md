# Incident Response Playbook — Active Directory Compromise

> Structured response guide for suspected AD compromise events. Covers detection signals, triage, containment, eradication, and recovery steps for common AD attack scenarios.

**Author:** Aymerick Victoire  
**Applies to:** Windows Server / Active Directory environments  
**MITRE ATT&CK:** T1078, T1003.001, T1558.003, T1136.001, T1098  

---

## Scenario 1 — Kerberoasting Detected

### Detection Signals
- Wazuh alert: multiple Kerberos TGS requests (Event 4769) for service accounts in short succession
- Source: single workstation, user account with no service-admin role
- Requested encryption type: `0x17` (RC4 — weak, targeted by Kerberoasting tools)

### Triage (< 15 min)

```powershell
# Identify the source account and targeted SPNs
Get-WinEvent -LogName Security -FilterXPath "*[System[EventID=4769] and EventData[Data[@Name='TicketEncryptionType']='0x17']]" |
    Select-Object TimeCreated, Message | Format-List

# Check if requesting account is a normal user (not a service account)
Get-ADUser -Identity "<SuspiciousAccount>" -Properties MemberOf, LastLogonDate, PasswordLastSet
```

### Containment
1. **Disable the suspicious user account** immediately
   ```powershell
   Disable-ADAccount -Identity "<SuspiciousAccount>"
   ```
2. **Block the source workstation** at the pfSense firewall (VLAN 20 → VLAN 10 rule)
3. **Do NOT change service account passwords yet** — confirm scope first

### Eradication
4. **Reset all targeted service account passwords** (32+ char random)
   ```powershell
   Set-ADAccountPassword -Identity "<ServiceAccount>" -Reset -NewPassword (Read-Host -AsSecureString)
   ```
5. **Migrate service accounts to gMSA** (Group Managed Service Accounts — auto-rotating passwords)
   ```powershell
   New-ADServiceAccount -Name "gMSA-IIS" -DNSHostName "iis.lab.local" -PrincipalsAllowedToRetrieveManagedPassword "IIS-Servers"
   ```

### Recovery
6. Re-enable user account after investigation and user acknowledgment
7. Monitor for 30 days: TGS requests from the same source IP

### Lessons Learned Template
- Were service accounts using RC4 (weak)? → Force AES encryption: `Set-ADUser -KerberosEncryptionType AES256`
- Minimum password length on service accounts? → Enforce 25+ chars
- Were any SPNs on user objects? → Move to computer objects or gMSA

---

## Scenario 2 — Unauthorized Domain Admin Account Creation

### Detection Signals
- Wazuh Rule 100002 fired: user added to Domain Admins (Event 4728)
- Event 4720: new user account created immediately before
- Actor: non-IT account

### Triage (< 10 min)

```powershell
# Who was added to Domain Admins and when?
Get-WinEvent -LogName Security -FilterXPath "*[System[EventID=4728]]" -MaxEvents 20 |
    ForEach-Object { $_.Message } | Select-String "Domain Admins"

# Check the new account
Get-ADUser -Identity "<NewAccount>" -Properties Created, MemberOf, PasswordLastSet, LastLogonDate
```

### Containment
1. **Immediately remove from Domain Admins**
   ```powershell
   Remove-ADGroupMember -Identity "Domain Admins" -Members "<NewAccount>" -Confirm:$false
   ```
2. **Disable the account**
   ```powershell
   Disable-ADAccount -Identity "<NewAccount>"
   ```
3. **Disable the actor's account** (whoever created it)
4. **Check for other privilege escalations** in the same timeframe:
   ```powershell
   Get-WinEvent -LogName Security -FilterXPath "*[System[EventID=4728 or EventID=4732 or EventID=4756]]" |
       Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-4) }
   ```

### Eradication
5. **Audit all privileged group memberships** — compare against expected baseline
   ```powershell
   .\Get-ADSecurityAudit.ps1 -ExportHtml "C:\IR\ad-audit-$(Get-Date -Format yyyyMMdd).html"
   ```
6. **Check for persistence mechanisms**: new GPOs, scheduled tasks, services

### Recovery
7. Reset the actor's password and re-enable only after confirmed business justification
8. Brief the user's manager

### Lessons Learned Template
- Was MFA enforced for the actor's account?
- Was the actor's account over-privileged for their role?
- Alert response time from event to containment?

---

## Scenario 3 — Pass-the-Hash / Lateral Movement

### Detection Signals
- Wazuh: multiple Type 3 network logons (Event 4624) from a single source to multiple servers
- Logons occur with the same account from a non-admin workstation
- Timestamps: rapid succession (automated tooling pattern)

### Triage

```powershell
# Look for Type 3 logon pattern (network logon)
Get-WinEvent -LogName Security -FilterXPath "*[System[EventID=4624] and EventData[Data[@Name='LogonType']='3']]" |
    Where-Object { $_.TimeCreated -gt (Get-Date).AddHours(-2) } |
    ForEach-Object {
        $xml = [xml]$_.ToXml()
        [PSCustomObject]@{
            Time     = $_.TimeCreated
            Account  = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "TargetUserName" } | Select-Object -Expand '#text'
            Source   = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "IpAddress" } | Select-Object -Expand '#text'
            TargetMachine = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "WorkstationName" } | Select-Object -Expand '#text'
        }
    } | Sort-Object Time | Format-Table -AutoSize
```

### Containment
1. **Isolate source workstation** — block at pfSense
2. **Force password reset** for compromised account across all systems
3. **Invalidate all Kerberos tickets** for the account:
   ```powershell
   # Requires replication delay — follow with account disable/re-enable cycle
   Set-ADUser -Identity "<Account>" -Replace @{pwdLastSet=0}
   Set-ADUser -Identity "<Account>" -Replace @{pwdLastSet=-1}
   ```

### Eradication
4. **Check for persistence on all visited hosts**: scheduled tasks (Event 4698), new services (Event 7045)
5. **Run Invoke-WindowsHardening.ps1** on affected hosts post-clean
6. **Verify LSASS protection** is enabled (RunAsPPL) on all servers

---

## Quick Reference — Key Event IDs

| Event ID | Log | Description |
|----------|-----|-------------|
| 4624 | Security | Successful logon |
| 4625 | Security | Failed logon |
| 4648 | Security | Logon with explicit credentials |
| 4720 | Security | User account created |
| 4726 | Security | User account deleted |
| 4728 | Security | Member added to security-enabled global group |
| 4756 | Security | Member added to security-enabled universal group |
| 4769 | Security | Kerberos service ticket requested |
| 4771 | Security | Kerberos pre-auth failed |
| 4776 | Security | NTLM credential validation |
| 7045 | System | New service installed |
| 4698 | Security | Scheduled task created |
| 1102 | Security | Audit log cleared ← **immediate escalation** |

## Tools Used

| Tool | Purpose |
|------|---------|
| `Get-ADSecurityAudit.ps1` | Post-incident AD baseline check |
| `Get-InactiveObjects.ps1` | Identify stale accounts used as attack vectors |
| `Export-GPOReport.ps1` | Verify GPOs haven't been tampered with |
| Wazuh Kibana | Event correlation and timeline reconstruction |
| `auditpol /get /category:*` | Verify audit policy is intact |
