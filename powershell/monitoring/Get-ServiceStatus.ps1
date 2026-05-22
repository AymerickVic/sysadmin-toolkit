<#
.SYNOPSIS
    Monitors Windows service status across one or more servers.

.DESCRIPTION
    Checks a defined list of critical services on target servers. Reports
    stopped services that should be running, and optionally attempts
    auto-restart. Exports results to HTML or CSV.

.PARAMETER ComputerName
    Target server(s). Defaults to localhost.

.PARAMETER ServiceNames
    List of service names to check. Defaults to a baseline of common critical services.

.PARAMETER AutoRestart
    If specified, attempts to restart stopped services. USE WITH CAUTION.

.PARAMETER ExportCsv
    Optional path for CSV export.

.PARAMETER ExportHtml
    Optional path for HTML report.

.EXAMPLE
    .\Get-ServiceStatus.ps1
    .\Get-ServiceStatus.ps1 -ComputerName "SRV-AD01","SRV-FILE01"
    .\Get-ServiceStatus.ps1 -ServiceNames "Wazuh","WinDefend","EventLog" -AutoRestart

.NOTES
    Author   : Aymerick Victoire
    Requires : WinRM access to remote servers (or run locally)
    Purpose  : Service health monitoring, SOC baseline checks, uptime assurance
#>

param (
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string[]]$ServiceNames = @(
        "EventLog",         # Windows Event Log — critical for audit trail
        "WinDefend",        # Windows Defender
        "wuauserv",         # Windows Update
        "NTDS",             # AD Domain Services (DC only)
        "DNS",              # DNS Server (DC only)
        "Netlogon",         # Domain logon service
        "W32Time",          # Time synchronization
        "SamSs",            # Security Accounts Manager
        "Spooler"           # Print Spooler (often targeted — flag if running on DCs)
    ),
    [switch]$AutoRestart = $false,
    [string]$ExportCsv  = "",
    [string]$ExportHtml = ""
)

$ErrorActionPreference = "Continue"
$Results = @()
$StoppedCount = 0

Write-Host "[*] Service Monitor — Checking $($ServiceNames.Count) services on $($ComputerName.Count) server(s)" -ForegroundColor Cyan
Write-Host ""

foreach ($Computer in $ComputerName) {
    Write-Host "  [>] $Computer" -ForegroundColor Gray

    foreach ($SvcName in $ServiceNames) {
        try {
            $Svc = Get-Service -Name $SvcName -ComputerName $Computer -ErrorAction Stop

            $Status   = $Svc.Status
            $Severity = if ($Status -ne "Running") { "STOPPED"; $StoppedCount++ } else { "OK" }
            $Color    = if ($Severity -eq "STOPPED") { "Red" } else { "Green" }

            Write-Host "    [$Severity] $SvcName — $Status" -ForegroundColor $Color

            # Auto-restart if requested and service is stopped
            if ($AutoRestart -and $Status -ne "Running") {
                try {
                    (Get-Service -Name $SvcName -ComputerName $Computer).Start()
                    Write-Host "      [!] Restart attempted for: $SvcName" -ForegroundColor Yellow
                    Start-Sleep -Seconds 3
                    $NewStatus = (Get-Service -Name $SvcName -ComputerName $Computer).Status
                    Write-Host "      [>] New status: $NewStatus" -ForegroundColor Cyan
                    $Status = $NewStatus
                }
                catch {
                    Write-Host "      [ERROR] Restart failed: $_" -ForegroundColor Red
                }
            }

            $Results += [PSCustomObject]@{
                Server       = $Computer
                ServiceName  = $SvcName
                DisplayName  = $Svc.DisplayName
                Status       = $Status
                StartType    = $Svc.StartType
                Severity     = $Severity
                AutoRestart  = $AutoRestart.ToString()
                Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm")
            }
        }
        catch {
            # Service not found — might be expected (e.g., NTDS on a member server)
            $Results += [PSCustomObject]@{
                Server       = $Computer
                ServiceName  = $SvcName
                DisplayName  = "N/A"
                Status       = "NOT_FOUND"
                StartType    = "N/A"
                Severity     = "INFO"
                AutoRestart  = "N/A"
                Timestamp    = (Get-Date -Format "yyyy-MM-dd HH:mm")
            }
        }
    }
}

# --- Summary ---
$Stopped = $Results | Where-Object Severity -eq "STOPPED"
Write-Host "`n===== SERVICE STATUS SUMMARY =====" -ForegroundColor Cyan
Write-Host "Total checks : $($Results.Count)"
Write-Host "Stopped      : $StoppedCount" -ForegroundColor $(if ($StoppedCount -gt 0) { "Red" } else { "Green" })

if ($Stopped) {
    Write-Host "`n[!] Stopped services:" -ForegroundColor Red
    $Stopped | ForEach-Object {
        Write-Host "    $($_.Server) — $($_.ServiceName) ($($_.DisplayName))" -ForegroundColor Red
    }
}

# --- Exports ---
if ($ExportCsv) {
    $Results | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`n[+] CSV saved: $ExportCsv" -ForegroundColor Green
}

if ($ExportHtml) {
    $Html = $Results | ConvertTo-Html `
        -Title "Service Status Report" `
        -PreContent "<h1>Service Status — $(Get-Date -Format 'yyyy-MM-dd HH:mm')</h1><p>Servers: $($ComputerName -join ', ')</p>"
    $Html | Out-File -FilePath $ExportHtml -Encoding UTF8
    Write-Host "[+] HTML saved: $ExportHtml" -ForegroundColor Green
}
