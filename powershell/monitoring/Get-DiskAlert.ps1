<#
.SYNOPSIS
    Monitors disk space across local or remote servers and alerts on low usage.

.DESCRIPTION
    Queries all fixed drives on one or more servers. Reports free space percentage
    and absolute free space. Generates alerts when free space falls below the
    configured threshold. Supports HTML report export and email notification.

.PARAMETER ComputerName
    Target server(s). Accepts array. Defaults to localhost.

.PARAMETER ThresholdPercent
    Alert threshold in percent free. Default: 15.

.PARAMETER CriticalPercent
    Critical threshold in percent free. Default: 5.

.PARAMETER ExportHtml
    Optional path to export an HTML report.

.PARAMETER EmailTo
    If specified, sends alert email via Send-MailMessage.

.PARAMETER SmtpServer
    SMTP relay. Required if -EmailTo is used.

.EXAMPLE
    .\Get-DiskAlert.ps1
    .\Get-DiskAlert.ps1 -ComputerName "SRV-AD01","SRV-FILE01" -ThresholdPercent 20
    .\Get-DiskAlert.ps1 -ComputerName (Get-Content servers.txt) -ExportHtml "C:\Reports\disk.html"

.NOTES
    Author   : Aymerick Victoire
    Requires : WMI/CIM access to target servers (WinRM or DCOM)
    Purpose  : Proactive disk monitoring, capacity planning
#>

param (
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [int]$ThresholdPercent = 15,
    [int]$CriticalPercent = 5,
    [string]$ExportHtml = "",
    [string]$EmailTo = "",
    [string]$SmtpServer = ""
)

$ErrorActionPreference = "Stop"
$Results = @()
$AlertCount = 0
$CriticalCount = 0

Write-Host "[*] Disk Space Monitor — Threshold: $ThresholdPercent% | Critical: $CriticalPercent%" -ForegroundColor Cyan
Write-Host "[*] Checking $($ComputerName.Count) server(s)...`n" -ForegroundColor Cyan

foreach ($Computer in $ComputerName) {
    try {
        $Disks = Get-CimInstance -ClassName Win32_LogicalDisk `
            -ComputerName $Computer `
            -Filter "DriveType = 3" `
            -ErrorAction Stop

        foreach ($Disk in $Disks) {
            $TotalGB  = [math]::Round($Disk.Size / 1GB, 2)
            $FreeGB   = [math]::Round($Disk.FreeSpace / 1GB, 2)
            $UsedGB   = [math]::Round(($Disk.Size - $Disk.FreeSpace) / 1GB, 2)
            $FreePct  = if ($Disk.Size -gt 0) { [math]::Round(($Disk.FreeSpace / $Disk.Size) * 100, 1) } else { 0 }

            $Status = switch ($FreePct) {
                { $_ -le $CriticalPercent }  { "CRITICAL"; $CriticalCount++; break }
                { $_ -le $ThresholdPercent } { "WARNING";  $AlertCount++;    break }
                default                      { "OK" }
            }

            $Color = switch ($Status) {
                "CRITICAL" { "Red"    }
                "WARNING"  { "Yellow" }
                default    { "Green"  }
            }

            Write-Host "  [$Status] $Computer — $($Disk.DeviceID) | Free: $FreeGB GB / $TotalGB GB ($FreePct%)" -ForegroundColor $Color

            $Results += [PSCustomObject]@{
                Server    = $Computer
                Drive     = $Disk.DeviceID
                TotalGB   = $TotalGB
                UsedGB    = $UsedGB
                FreeGB    = $FreeGB
                FreePct   = $FreePct
                Status    = $Status
                Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm")
            }
        }
    }
    catch {
        Write-Host "  [ERROR] Cannot reach $Computer — $_" -ForegroundColor Red
        $Results += [PSCustomObject]@{
            Server    = $Computer
            Drive     = "N/A"
            TotalGB   = 0
            UsedGB    = 0
            FreeGB    = 0
            FreePct   = 0
            Status    = "UNREACHABLE"
            Timestamp = (Get-Date -Format "yyyy-MM-dd HH:mm")
        }
    }
}

# --- Summary ---
Write-Host "`n===== DISK SPACE SUMMARY =====" -ForegroundColor Cyan
Write-Host "Servers checked : $($ComputerName.Count)"
Write-Host "Critical alerts : $CriticalCount" -ForegroundColor $(if ($CriticalCount -gt 0) { "Red" } else { "Green" })
Write-Host "Warnings        : $AlertCount"    -ForegroundColor $(if ($AlertCount -gt 0) { "Yellow" } else { "Green" })
Write-Host "==============================`n"

# --- HTML export ---
if ($ExportHtml) {
    $Html = $Results | ConvertTo-Html `
        -Title "Disk Space Report" `
        -PreContent "<h1>Disk Space Report</h1><p>Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Threshold: $ThresholdPercent% | Critical: $CriticalPercent%</p>"
    $Html | Out-File -FilePath $ExportHtml -Encoding UTF8
    Write-Host "[+] HTML report saved: $ExportHtml" -ForegroundColor Green
}

# --- Email alert ---
if ($EmailTo -and $SmtpServer -and ($AlertCount + $CriticalCount) -gt 0) {
    $Body = $Results | Where-Object { $_.Status -in "WARNING", "CRITICAL" } |
        Format-Table Server, Drive, FreeGB, FreePct, Status -AutoSize | Out-String

    Send-MailMessage `
        -To $EmailTo `
        -From "diskalert@$($env:USERDNSDOMAIN)" `
        -Subject "[DISK ALERT] $CriticalCount critical, $AlertCount warning — $(Get-Date -Format 'yyyy-MM-dd')" `
        -Body $Body `
        -SmtpServer $SmtpServer

    Write-Host "[+] Alert email sent to: $EmailTo" -ForegroundColor Green
}
