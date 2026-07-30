# ================================================================================
# MODULE: SuperAuditor.ps1  |  VERSION: 2.0
#
# v2.0 changes (console UX + reporting accuracy, folded in from the v1.5/v1.6
# patch notes applied during the MAT V2 consolidation):
#   - Stats rollup fix: Critical/Warning/Healthy counts previously excluded
#     Manual Check/Error/Info rows, so the total could silently under-count.
#     A new $manualCount bucket (computed as a remainder, not a fourth set of
#     -match filters) makes the total exhaustive, and a fourth stat-card span
#     surfaces it instead of letting it disappear.
#   - Write-Progress added across the three-phase Auditor/Protector/Licensor
#     run, so a multi-minute Super Auditor pass isn't silent between banners.
#   - Cancelled-run and connection-required waits now use Wait-MATContinue
#     (keypress) instead of a fixed Start-Sleep.
#
# v1.3 HTML report additions vs v1.2:
#   - Per-section issue badges on both the nav links and section headers
#     (red = critical present, amber = warnings only, green = clean)
#   - Filter bar in nav — real-time row filtering across all tables
#   - Print / PDF button in nav (calls window.print())
#   - Active nav highlight via IntersectionObserver
#   - Stacked health bar in the stats card (critical / warning / healthy ratio)
#   - CONFIDENTIAL diagonal watermark on print output
#   - Hidden rows use display:none so filtered rows collapse cleanly
# Fix v1.3.1:
#   - Sticky <th> header no longer merges with first data row.
#     Root causes: (1) th background was semi-transparent so the row beneath
#     bled through; (2) no box-shadow separator meant the header and first row
#     had no visual gap; (3) first tbody row lacked a top border.
#     Resolved by: opaque th background, box-shadow bottom line on thead,
#     explicit border-top on tbody tr:first-child, and z-index layering.
# ================================================================================

function Invoke-SuperAuditor {
    if (-not $script:MAT_Global.IsConnected) {
        Write-Host "`n[!] Connection Required. Use [C] to connect first." -ForegroundColor Red
        Wait-MATContinue; return
    }

    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  SUPER AUDITOR - COMPREHENSIVE SECURITY ASSESSMENT" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "[*] Target Tenant    : $($script:MAT_Global.TenantName)" -ForegroundColor White
    Write-Host "[*] Authenticated As : $($script:MAT_Global.UserPrincipal)" -ForegroundColor White
    Write-Host "[*] M365 Role        : $($script:MAT_Global.UserRole)" -ForegroundColor Cyan
    Write-Host "[*] Azure Role       : $($script:MAT_Global.AzureStatus)" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "[!] This will run ALL audit operations and may take several minutes." -ForegroundColor Yellow
    $confirm = Read-Host "Continue? (Y/N)"
    if ($confirm -ne "Y" -and $confirm -ne "y") {
        Write-Host "[!] Cancelled." -ForegroundColor Yellow; Wait-MATContinue; return
    }

    $startTime  = Get-Date
    $tenantName = if ([string]::IsNullOrWhiteSpace($script:MAT_Global.TenantName) -or
                      $script:MAT_Global.TenantName -eq "DISCONNECTED") {
        "Unknown_Tenant"
    } else { $script:MAT_Global.TenantName }

    $targetPath = Get-MATReportPath -TenantName $tenantName
    Write-Host "[+] Report Directory: $targetPath" -ForegroundColor Gray
    Write-Host ""

    $successCount = 0; $totalModes = 3

    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host " [1/3] AUDITOR MODE - Forensic Health + Copilot Telemetry" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Progress -Activity "Super Auditor" -Status "[1/3] Auditor Mode" -PercentComplete 0
    try { Invoke-AuditorMode -Silent; $successCount++; Write-Host "[✓] Auditor complete" -ForegroundColor Green }
    catch { Write-Host "[✗] Auditor failed: $_" -ForegroundColor Red }
    Write-Host ""

    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host " [2/3] PROTECTOR MODE - Posture + Copilot Governance" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Progress -Activity "Super Auditor" -Status "[2/3] Protector Mode" -PercentComplete 33
    try { Invoke-ProtectorMode -Silent; $successCount++; Write-Host "[✓] Protector complete" -ForegroundColor Green }
    catch { Write-Host "[✗] Protector failed: $_" -ForegroundColor Red }
    Write-Host ""

    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host " [3/3] LICENSOR MODE - Defensive Stack + Copilot License" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Progress -Activity "Super Auditor" -Status "[3/3] Licensor Mode" -PercentComplete 66
    try { Invoke-LicensorMode -Silent; $successCount++; Write-Host "[✓] Licensor complete" -ForegroundColor Green }
    catch { Write-Host "[✗] Licensor failed: $_" -ForegroundColor Red }
    Write-Host ""
    Write-Progress -Activity "Super Auditor" -Completed

    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue
    Write-Host " GENERATING EXECUTIVE DASHBOARD..." -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Blue

    $htmlPath = $null
    try {
        $htmlPath = New-MATHtmlReport -ReportDirectory $targetPath -TenantName $tenantName
        Write-Host "[✓] HTML report: $htmlPath" -ForegroundColor Green
    } catch {
        Write-Host "[✗] HTML generation failed: $_" -ForegroundColor Red
    }

    $duration = ((Get-Date) - $startTime).ToString("mm\:ss")
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  SUPER AUDIT COMPLETE" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Tenant     : $tenantName"  -ForegroundColor White
    Write-Host "  Operations : $successCount/$totalModes" -ForegroundColor $(if ($successCount -eq $totalModes) { "Green" } else { "Yellow" })
    Write-Host "  Duration   : $duration"    -ForegroundColor White
    Write-Host "  Reports    : $targetPath"  -ForegroundColor Cyan
    if ($htmlPath) {
        Write-Host ""
        Write-Host "  Dashboard  : $htmlPath" -ForegroundColor Yellow
        Write-Host "  Tip        : Open in browser. Section 5 = Copilot AI audit." -ForegroundColor Gray
    }
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green

    Write-MATLog -OperationName "SuperAuditor" -Details "Full spectrum ($successCount/$totalModes). Duration: $duration. HTML: $htmlPath"
    Pause
}

# ============================================================================
# HTML REPORT GENERATION
# ============================================================================
function New-MATHtmlReport {
    param(
        [Parameter(Mandatory=$true)][string]$ReportDirectory,
        [string]$TenantName = "Unknown Tenant"
    )

    $timeStamp       = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $currentUser     = if ([string]::IsNullOrWhiteSpace($script:MAT_Global.UserPrincipal) -or
                           $script:MAT_Global.UserPrincipal -eq "None") {
        [Environment]::UserName
    } else { $script:MAT_Global.UserPrincipal }

    $safeTenantHtml  = [System.Net.WebUtility]::HtmlEncode($TenantName)
    $safeUserHtml    = [System.Net.WebUtility]::HtmlEncode($currentUser)
    $htmlFileName    = "MAT_Executive_Report_$((Get-Date).ToString('yyyyMMdd_HHmmss')).html"
    $destinationPath = Join-Path $ReportDirectory $htmlFileName

    # ── HELPER: format a single <td> ─────────────────────────────────────────
    function Format-HtmlCell ([string]$PropName, [string]$Val) {
        $style = if     ($Val -match "CRITICAL|Fail|Failed|Error|Disabled|Not Found|Not Licensed|High Risk") {
                     "style='color:#ff7b72;font-weight:600'"
                 } elseif ($Val -match "Warning|Medium|Review|Optimizable|Auth Limited|Inactive|enabledForReportingButNotEnforced") {
                     "style='color:#d29922;font-weight:500'"
                 } elseif ($Val -match "Healthy|Success|Pass|Enabled|Licensed|Active|Connected|Low") {
                     "style='color:#3fb950;font-weight:500'"
                 } elseif ($Val -match "Info|Manual|Unknown|Not Available|Not Checked") {
                     "style='color:#58a6ff'"
                 } else { "" }
        $noTrunc = @("Forensic_Impact","Description","Notes","Details","Impact","Current_Value")
        if ($Val.Length -gt 200 -and $PropName -notin $noTrunc) { $Val = $Val.Substring(0,197) + "..." }
        "<td $style>$([System.Net.WebUtility]::HtmlEncode($Val))</td>"
    }

    # ── HELPER: render in-memory array as HTML rows ───────────────────────────
    function Get-HtmlRowsFromData ([object[]]$Data, [int]$ColCount = 6) {
        if (-not $Data -or $Data.Count -eq 0) {
            return "<tr><td colspan='$ColCount' style='text-align:center;color:#8b949e;padding:30px'>No findings recorded.</td></tr>"
        }
        ($Data | ForEach-Object {
            $rowVals  = ($_.PSObject.Properties | ForEach-Object { if ($_.Value) { [string]$_.Value } else { "" } }) -join " "
            $rowClass = if   ($rowVals -match "CRITICAL|Not Licensed")                                    { " class='rc'" }
                        elseif ($rowVals -match "Warning|Disabled|Inactive|enabledForReportingButNotEnforced") { " class='rw'" }
                        else { "" }
            $row = "<tr$rowClass>"
            foreach ($p in $_.PSObject.Properties) { $row += Format-HtmlCell $p.Name ([string]$p.Value) }
            $row + "</tr>"
        }) -join "`n"
    }

    # ── HELPER: safe CSV load ─────────────────────────────────────────────────
    function Load-CsvSafe ([string]$Path) {
        if (-not (Test-Path $Path)) { return @() }
        try { return @(Import-Csv $Path -ErrorAction Stop) } catch { return @() }
    }

    # ── SINGLE-PASS CSV LOADING ───────────────────────────────────────────────
    Write-Host "[-] Loading report data (single-pass)..." -ForegroundColor Gray

    $auditorData   = Load-CsvSafe (Join-Path $ReportDirectory "Auditor_Report.csv")
    $protectorData = Load-CsvSafe (Join-Path $ReportDirectory "Protector_Inventory.csv")
    $defensiveData = Load-CsvSafe (Join-Path $ReportDirectory "Defensive_Stack.csv")
    $licensorData  = Load-CsvSafe (Join-Path $ReportDirectory "Licenses_Inventory.csv")

    function Get-HeadersFromData ([object[]]$D) {
        if (-not $D -or $D.Count -eq 0) { return @() }
        return $D[0].PSObject.Properties.Name
    }

    $auditorHdrs   = Get-HeadersFromData $auditorData
    $protectorHdrs = Get-HeadersFromData $protectorData
    $defensiveHdrs = Get-HeadersFromData $defensiveData
    $licensorHdrs  = Get-HeadersFromData $licensorData

    $auditorRows   = Get-HtmlRowsFromData $auditorData   $auditorHdrs.Count
    $protectorRows = Get-HtmlRowsFromData $protectorData $protectorHdrs.Count
    $defensiveRows = Get-HtmlRowsFromData $defensiveData $defensiveHdrs.Count
    $licensorRows  = Get-HtmlRowsFromData $licensorData  $licensorHdrs.Count

    # Copilot sub-section rows — filtered from in-memory data, zero extra reads
    $cpAudData  = @($auditorData   | Where-Object { $_.Category     -eq "Copilot" })
    $cpProtData = @($protectorData | Where-Object { $_.Type         -eq "Copilot" })
    $cpLicData  = @($licensorData  | Where-Object { $_.License_Name -like "*Copilot*" })

    $cpAudHtml  = if ($cpAudData.Count  -gt 0) { Get-HtmlRowsFromData $cpAudData  $auditorHdrs.Count }  else { "<tr><td colspan='$($auditorHdrs.Count)'  style='text-align:center;color:#8b949e;padding:16px'>No Copilot telemetry data.</td></tr>" }
    $cpProtHtml = if ($cpProtData.Count -gt 0) { Get-HtmlRowsFromData $cpProtData $protectorHdrs.Count } else { "<tr><td colspan='$($protectorHdrs.Count)' style='text-align:center;color:#8b949e;padding:16px'>No Copilot governance data.</td></tr>" }
    $cpLicHtml  = if ($cpLicData.Count  -gt 0) { Get-HtmlRowsFromData $cpLicData  $licensorHdrs.Count }  else { "<tr><td colspan='$($licensorHdrs.Count)'  style='text-align:center;color:#8b949e;padding:16px'>No Copilot license data.</td></tr>" }

    $cpAudHdr  = ($auditorHdrs   | ForEach-Object { "<th>$_</th>" }) -join ""
    $cpProtHdr = ($protectorHdrs | ForEach-Object { "<th>$_</th>" }) -join ""
    $cpLicHdr  = ($licensorHdrs  | ForEach-Object { "<th>$_</th>" }) -join ""

    # ── STATISTICS ────────────────────────────────────────────────────────────
    $totalChecks   = $auditorData.Count + $protectorData.Count + $defensiveData.Count + $licensorData.Count
    $criticalCount = (($auditorData   | Where-Object { $_.Status -match "CRITICAL"         }).Count) +
                     (($protectorData | Where-Object { $_.State  -match "CRITICAL"         }).Count) +
                     (($defensiveData | Where-Object { $_.Status -eq   "Not Licensed"      }).Count)
    $warningCount  = (($auditorData   | Where-Object { $_.Status -match "Warning"          }).Count) +
                     (($protectorData | Where-Object { $_.State  -match "Warning|enabledForReportingButNotEnforced" }).Count) +
                     (($defensiveData | Where-Object { $_.Status -eq   "Inactive"          }).Count) +
                     (($licensorData  | Where-Object { $_.Health -match "Warning|Optimizable" }).Count)
    $healthyCount  = (($auditorData   | Where-Object { $_.Status -eq "Healthy"             }).Count) +
                     (($protectorData | Where-Object { $_.State  -match "Healthy|Enabled|Licensed" }).Count) +
                     (($defensiveData | Where-Object { $_.Status -eq "Active"              }).Count) +
                     (($licensorData  | Where-Object { $_.Health -match "Healthy"          }).Count)

    # v2.0 — everything not already counted as Critical/Warning/Healthy (Manual
    # Check, Error, Info rows) is folded into its own bucket instead of silently
    # vanishing from the executive summary total. Computed as a remainder rather
    # than a fourth set of -match filters across four data sources — shorter,
    # and mathematically guaranteed to make the total add up regardless of which
    # exact status strings each mode uses now or in the future.
    $manualCount = $totalChecks - $criticalCount - $warningCount - $healthyCount
    if ($manualCount -lt 0) { $manualCount = 0 }   # defensive guard, should not trigger

    # ── PER-SECTION ISSUE COUNTS ──────────────────────────────────────────────
    $s1Crit = ($auditorData   | Where-Object { $_.Status -match "CRITICAL" }).Count
    $s1Warn = ($auditorData   | Where-Object { $_.Status -match "Warning"  }).Count
    $s2Crit = ($protectorData | Where-Object { $_.State  -match "CRITICAL" }).Count
    $s2Warn = ($protectorData | Where-Object { $_.State  -match "Warning"  }).Count
    $s3Crit = ($defensiveData | Where-Object { $_.Status -eq   "Not Licensed" }).Count
    $s3Warn = ($defensiveData | Where-Object { $_.Status -eq   "Inactive"     }).Count
    $s4Warn = ($licensorData  | Where-Object { $_.Health -match "Warning|Optimizable" }).Count
    $s5Crit = ($cpAudData  | Where-Object { $_.Status -match "CRITICAL" }).Count +
              ($cpProtData | Where-Object { $_.State  -match "CRITICAL" }).Count
    $s5Warn = ($cpAudData  | Where-Object { $_.Status -match "Warning"  }).Count +
              ($cpProtData | Where-Object { $_.State  -match "Warning"  }).Count

    function Get-SectionBadge ([int]$Crit, [int]$Warn) {
        if ($Crit -gt 0) { return "<span class='sb sb-er'>$Crit critical</span>" }
        if ($Warn -gt 0) { return "<span class='sb sb-wn'>$Warn warning$(if($Warn -ne 1){'s'})</span>" }
        return "<span class='sb sb-ok'>clean</span>"
    }
    function Get-NavBadge ([int]$Crit, [int]$Warn) {
        $n = $Crit + $Warn
        if ($n -eq 0) { return "" }
        $cls = if ($Crit -gt 0) { "nb-er" } else { "nb-wn" }
        return " <span class='nb $cls'>$n</span>"
    }

    $ib1 = Get-SectionBadge $s1Crit $s1Warn
    $ib2 = Get-SectionBadge $s2Crit $s2Warn
    $ib3 = Get-SectionBadge $s3Crit $s3Warn
    $ib4 = Get-SectionBadge 0       $s4Warn
    $ib5 = Get-SectionBadge $s5Crit $s5Warn

    $nb1 = Get-NavBadge $s1Crit $s1Warn
    $nb2 = Get-NavBadge $s2Crit $s2Warn
    $nb3 = Get-NavBadge $s3Crit $s3Warn
    $nb4 = Get-NavBadge 0       $s4Warn
    $nb5 = Get-NavBadge $s5Crit $s5Warn

    # ── HEALTH BAR ────────────────────────────────────────────────────────────
    $barTotal    = $criticalCount + $warningCount + $healthyCount
    $barCritPct  = if ($barTotal -gt 0) { [math]::Round(($criticalCount / $barTotal) * 100) } else { 0 }
    $barWarnPct  = if ($barTotal -gt 0) { [math]::Round(($warningCount  / $barTotal) * 100) } else { 0 }
    $barOkPct    = if ($barTotal -gt 0) { [math]::Round(($healthyCount  / $barTotal) * 100) } else { 0 }
    $healthBar   = "<div class='hbar' title='$criticalCount critical / $warningCount warnings / $healthyCount healthy'>" +
                   "<div class='hb-seg hb-er' style='width:${barCritPct}%'></div>" +
                   "<div class='hb-seg hb-wn' style='width:${barWarnPct}%'></div>" +
                   "<div class='hb-seg hb-ok' style='width:${barOkPct}%'></div>" +
                   "</div>"

    # ── KEY FINDINGS PANEL ────────────────────────────────────────────────────
    $kfItems = [System.Text.StringBuilder]::new()
    $kfCount = 0

    foreach ($r in $auditorData) {
        if ($r.Status -match "CRITICAL") {
            $n = [System.Net.WebUtility]::HtmlEncode($r.Audit_Control)
            $v = [System.Net.WebUtility]::HtmlEncode($r.Current_Value)
            [void]$kfItems.Append("<div class='kfi'><span class='kft'>Forensic</span><span class='kfn'>$n</span><span class='kfv'>$v</span></div>`n")
            $kfCount++
        }
    }
    foreach ($r in $protectorData) {
        if ($r.State -match "CRITICAL") {
            $n = [System.Net.WebUtility]::HtmlEncode($r.Name)
            $d = $r.Description; if ($d.Length -gt 90) { $d = $d.Substring(0,87) + "..." }
            $d = [System.Net.WebUtility]::HtmlEncode($d)
            [void]$kfItems.Append("<div class='kfi'><span class='kft'>Identity</span><span class='kfn'>$n</span><span class='kfv'>$d</span></div>`n")
            $kfCount++
        }
    }
    foreach ($r in $defensiveData) {
        if ($r.Status -eq "Not Licensed") {
            $n = [System.Net.WebUtility]::HtmlEncode($r.Solution)
            [void]$kfItems.Append("<div class='kfi'><span class='kft'>Defensive</span><span class='kfn'>$n</span><span class='kfv'>Not Licensed</span></div>`n")
            $kfCount++
        }
    }

    $kfLabel = if ($kfCount -gt 0) {
        "$kfCount critical finding$(if($kfCount -ne 1){'s'}) requiring immediate attention"
    } else { "No critical findings — tenant posture is within acceptable parameters" }
    $kfClass  = if ($kfCount -gt 0) { "kf-panel kf-bad" } else { "kf-panel kf-ok" }
    $kfBody   = if ($kfCount -gt 0) { "<div class='kf-list'>$($kfItems.ToString())</div>" } else { "" }
    $keyFindingsHtml = "<div class='$kfClass'><div class='kf-hdr'>$kfLabel</div>$kfBody</div>"

    # Table header strings
    $audHdrHtml  = ($auditorHdrs   | ForEach-Object { "<th>$_</th>" }) -join ""
    $protHdrHtml = ($protectorHdrs | ForEach-Object { "<th>$_</th>" }) -join ""
    $defHdrHtml  = ($defensiveHdrs | ForEach-Object { "<th>$_</th>" }) -join ""
    $licHdrHtml  = ($licensorHdrs  | ForEach-Object { "<th>$_</th>" }) -join ""

    Write-Host "[-] Compiling HTML dashboard..." -ForegroundColor Gray

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0">
<title>MAT Executive Report | $safeTenantHtml</title>
<style>
:root{--pr:#58a6ff;--cp:#a371f7;--ok:#3fb950;--wn:#d29922;--er:#ff7b72;
      --bg:#0d1117;--cd:#161b22;--tx:#c9d1d9;--bd:#30363d;--hb:#21262d;--mt:#8b949e}
*{box-sizing:border-box;margin:0;padding:0}
html{scroll-behavior:smooth}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;
     background:var(--bg);color:var(--tx);line-height:1.6;padding-top:52px}

/* ── NAV ── */
.topnav{position:fixed;top:0;left:0;right:0;z-index:300;background:var(--hb);
        border-bottom:1px solid var(--bd);padding:7px 16px;
        display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.topnav a{color:var(--mt);text-decoration:none;font-size:12px;font-weight:500;
           padding:4px 11px;border-radius:20px;border:1px solid var(--bd);
           transition:all .15s;white-space:nowrap;display:flex;align-items:center;gap:5px}
.topnav a:hover{color:var(--tx);border-color:var(--pr)}
.topnav a.active{color:#fff;border-color:var(--pr);background:rgba(88,166,255,.12)}
.topnav .cp-link:hover,.topnav .cp-link.active{border-color:var(--cp);background:rgba(163,113,247,.1)}
.nb{font-size:10px;font-weight:700;padding:1px 6px;border-radius:8px}
.nb-er{background:rgba(255,123,114,.2);color:var(--er)}
.nb-wn{background:rgba(210,153,34,.2);color:var(--wn)}
.nav-spacer{flex:1}
.nav-filter{background:var(--bg);border:1px solid var(--bd);border-radius:16px;
            color:var(--tx);font-size:12px;padding:4px 12px;outline:none;width:180px;transition:border-color .2s}
.nav-filter:focus{border-color:var(--pr)}
.nav-filter::placeholder{color:var(--mt)}
.nav-btn{cursor:pointer;font-size:11px;font-weight:500;padding:4px 12px;border-radius:16px;
         background:transparent;border:1px solid var(--bd);color:var(--mt);transition:all .15s}
.nav-btn:hover{border-color:var(--pr);color:var(--tx)}

.container{max-width:1400px;margin:0 auto;padding:34px 20px}

/* ── HEADER ── */
.hdr{border-bottom:2px solid var(--pr);padding-bottom:26px;margin-bottom:34px;
     display:flex;justify-content:space-between;align-items:flex-start;flex-wrap:wrap;gap:14px}
h1{color:var(--pr);font-size:34px;font-weight:700;letter-spacing:-.5px;margin-bottom:5px}
.sub{font-weight:300;font-size:18px;color:var(--mt)}
.cls{color:var(--er);font-weight:700;font-size:11px;letter-spacing:2px;text-transform:uppercase;margin-bottom:5px}
.tag{font-size:13px;color:var(--mt)}

/* ── STATS ── */
.sgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:16px;margin-bottom:32px}
.scard{background:var(--cd);border:1px solid var(--bd);padding:20px;border-radius:12px;
       transition:transform .2s,box-shadow .2s}
.scard:hover{transform:translateY(-2px);box-shadow:0 8px 24px rgba(0,0,0,.4)}
.slbl{font-size:11px;text-transform:uppercase;color:var(--mt);margin-bottom:7px;font-weight:600;letter-spacing:1px}
.sval{font-size:21px;color:#fff;font-weight:600;line-height:1.2}
.sval.lg{font-size:30px}
.ssub{font-size:12px;color:var(--mt);margin-top:8px;display:flex;gap:6px;flex-wrap:wrap}
.bx{display:inline-block;padding:2px 8px;border-radius:8px;font-size:11px;font-weight:600;text-transform:uppercase}
.bx-er{background:rgba(255,123,114,.15);color:var(--er)}
.bx-wn{background:rgba(210,153,34,.15);color:var(--wn)}
.bx-ok{background:rgba(63,185,80,.15);color:var(--ok)}
.hbar{display:flex;height:5px;border-radius:3px;overflow:hidden;margin-top:10px;background:var(--bd)}
.hb-seg{height:100%;min-width:0;transition:width .4s}
.hb-er{background:var(--er)}.hb-wn{background:var(--wn)}.hb-ok{background:var(--ok)}

/* ── KEY FINDINGS ── */
.kf-panel{border-radius:12px;margin-bottom:32px;overflow:hidden}
.kf-bad{border:1px solid rgba(255,123,114,.45)}
.kf-ok{border:1px solid rgba(63,185,80,.35)}
.kf-hdr{padding:13px 20px;font-size:14px;font-weight:600}
.kf-bad .kf-hdr{background:rgba(255,123,114,.07);color:var(--er)}
.kf-ok  .kf-hdr{background:rgba(63,185,80,.07);color:var(--ok)}
.kf-list{padding:4px 0}
.kfi{display:flex;align-items:flex-start;gap:11px;padding:8px 20px;border-bottom:1px solid var(--bd);font-size:13px}
.kfi:last-child{border-bottom:none}
.kft{flex-shrink:0;font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.4px;
     padding:2px 7px;border-radius:7px;margin-top:1px;background:rgba(255,123,114,.15);color:var(--er)}
.kfn{font-weight:500;min-width:160px;flex-shrink:0}
.kfv{color:var(--mt);font-size:12px;line-height:1.5}

/* ── SECTIONS ── */
.section{background:var(--cd);border:1px solid var(--bd);border-radius:12px;
         margin-bottom:32px;overflow:hidden;box-shadow:0 4px 14px rgba(0,0,0,.3)}
.section.cps{border-color:var(--cp)}
.shdr{background:var(--hb);padding:20px 26px;border-bottom:1px solid var(--bd);
      cursor:pointer;user-select:none;transition:background .15s}
.shdr:hover{background:rgba(255,255,255,.025)}
.section.cps .shdr{border-bottom:1px solid var(--cp)}
.shdr-row{display:flex;justify-content:space-between;align-items:center;gap:12px}
.shdr-left{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.snum{display:inline-flex;align-items:center;justify-content:center;background:var(--pr);color:var(--bg);
      width:26px;height:26px;border-radius:50%;font-weight:700;font-size:13px;flex-shrink:0}
.section.cps .snum{background:var(--cp)}
.stitle{font-size:19px;font-weight:600;color:#fff}
.sb{font-size:10px;font-weight:600;text-transform:uppercase;letter-spacing:.3px;padding:2px 8px;border-radius:8px}
.sb-er{background:rgba(255,123,114,.15);color:var(--er)}
.sb-wn{background:rgba(210,153,34,.15);color:var(--wn)}
.sb-ok{background:rgba(63,185,80,.12);color:var(--ok)}
.sdesc{font-size:13px;color:var(--mt);margin-top:6px;line-height:1.5}
.chev{color:var(--mt);font-size:13px;transition:transform .3s;flex-shrink:0}
.chev.up{transform:rotate(180deg)}

/* ── COLLAPSIBLE BODY ── */
.sbody{transition:max-height .35s ease,opacity .35s ease;max-height:9999px;opacity:1;overflow:hidden}
.sbody.col{max-height:0;opacity:0}

/* ── COPILOT SUBSECTION LABELS ── */
.ssect{font-size:12px;font-weight:600;text-transform:uppercase;letter-spacing:.7px;
       color:var(--cp);padding:10px 20px;background:rgba(163,113,247,.05);
       border-bottom:1px solid rgba(163,113,247,.15)}

/* ── TABLES ── */
.tcon{overflow-x:auto}
table{width:100%;border-collapse:collapse}

/*
 * FIX: sticky <th> header / first-row merge.
 *
 * Root causes fixed here:
 *   1. th background must be fully opaque so the tbody row beneath cannot
 *      bleed through when the header sticks at the top during scroll.
 *      Using a solid color instead of a semi-transparent rgba.
 *   2. A box-shadow on <thead> acts as a persistent bottom separator line
 *      that travels with the sticky header — a border-bottom alone
 *      collapses into the first row at certain zoom levels.
 *   3. The first tbody row gets an explicit top border so there is always
 *      a clear visual gap between the header row and data row 1.
 *   4. z-index: 10 on th ensures it layers above td cells with backgrounds
 *      (severity-tinted rows) that would otherwise render over the header.
 */
thead{position:sticky;top:52px;z-index:10;
      box-shadow:0 2px 0 0 var(--bd)}          /* separator that sticks */
th{background:#1c2128;                          /* opaque — no rgba bleed */
   color:var(--pr);text-align:left;padding:12px 15px;
   font-size:11px;text-transform:uppercase;font-weight:600;
   white-space:nowrap;border-bottom:none}       /* box-shadow handles the line */
.section.cps th{background:#1a1d27;color:var(--cp)}

tbody tr:first-child td{border-top:1px solid var(--bd)}  /* clear gap after header */

td{padding:12px 15px;font-size:13px;border-bottom:1px solid var(--bd);
   vertical-align:top;word-wrap:break-word;max-width:460px}
td:last-child,td:nth-last-child(2){max-width:360px;white-space:normal;line-height:1.55}
tr:last-child td{border-bottom:none}

/* Row severity */
tr.rc{background:rgba(255,123,114,.05) !important}
tr.rc td:first-child{border-left:3px solid rgba(255,123,114,.6)}
tr.rw{background:rgba(210,153,34,.04) !important}
tr.rw td:first-child{border-left:3px solid rgba(210,153,34,.5)}
/* Zebra */
tbody tr:nth-child(even):not(.rc):not(.rw){background:rgba(255,255,255,.013)}
tbody tr:hover{background:rgba(255,255,255,.028) !important}
/* Filter hide */
tr.fhide{display:none}

/* ── FOOTER ── */
.footer{text-align:center;margin-top:54px;padding-top:26px;border-top:1px solid var(--bd)}
.ftxt{font-size:13px;color:var(--mt);margin-bottom:5px}
.fleg{font-size:11px;color:#484f58}

/* ── PRINT ── */
@media print{
  .topnav{display:none}
  body{padding-top:0;background:#fff;color:#111}
  .container{padding:16px}
  h1{color:#1a56db}.sub{color:#555}.slbl{color:#666}
  .section{box-shadow:none;border:1px solid #ccc;page-break-inside:avoid}
  .shdr{cursor:default;background:#f8f8f8}.shdr:hover{background:#f8f8f8}
  .sbody{max-height:none !important;opacity:1 !important}
  thead{position:static;box-shadow:none}
  th{background:#eef2ff;color:#333;border-bottom:2px solid #bbb}
  tbody tr:first-child td{border-top:none}
  td{color:#222;border-bottom:1px solid #e0e0e0;max-width:none}
  .kf-panel{border-color:#ccc}
  .kf-bad .kf-hdr{background:#fff1f0;color:#c0392b}
  .kf-ok  .kf-hdr{background:#f0fff4;color:#1a7a3c}
  tr.rc{background:#fff1f0 !important}
  tr.rc td:first-child{border-left:3px solid #e74c3c}
  tr.rw{background:#fffbee !important}
  tr.rw td:first-child{border-left:3px solid #d4a017}
  body::before{content:"CONFIDENTIAL";position:fixed;top:50%;left:50%;
    transform:translate(-50%,-50%) rotate(-45deg);font-size:90px;font-weight:900;
    color:rgba(0,0,0,0.035);z-index:9999;pointer-events:none;white-space:nowrap;
    letter-spacing:8px}
}
@media(max-width:768px){
  h1{font-size:26px}.sgrid{grid-template-columns:1fr}
  td{padding:9px 8px;font-size:12px}
  .nav-filter{width:120px}
}
</style>
</head>
<body>

<nav class="topnav">
  <a href="#sec1">1. Forensic$nb1</a>
  <a href="#sec2">2. Identity$nb2</a>
  <a href="#sec3">3. Defensive$nb3</a>
  <a href="#sec4">4. Licenses$nb4</a>
  <a href="#sec5" class="cp-link">5. Copilot$nb5</a>
  <div class="nav-spacer"></div>
  <input class="nav-filter" type="text" placeholder="Filter rows..." oninput="filterRows(this.value)" title="Filter rows across all tables">
  <button class="nav-btn" onclick="window.print()">Print / PDF</button>
</nav>

<div class="container">

  <div class="hdr">
    <div>
      <h1>Microsoft Audit Tracker</h1>
      <div class="sub">Executive Security Assessment Report</div>
    </div>
    <div style="text-align:right">
      <div class="cls">CONFIDENTIAL REPORT</div>
      <div class="tag">Cloud Response &amp; Auditing Utility</div>
    </div>
  </div>

  <div class="sgrid">
    <div class="scard"><div class="slbl">Target Tenant</div><div class="sval">$safeTenantHtml</div></div>
    <div class="scard"><div class="slbl">Auditor Principal</div><div class="sval" style="font-size:15px;line-height:1.4">$safeUserHtml</div></div>
    <div class="scard"><div class="slbl">Audit Timestamp</div><div class="sval" style="font-size:15px">$timeStamp</div></div>
    <div class="scard">
      <div class="slbl">Total Checks</div>
      <div class="sval lg">$totalChecks</div>
      <div class="ssub">
        <span class="bx bx-er">Critical: $criticalCount</span>
        <span class="bx bx-wn">Warnings: $warningCount</span>
        <span class="bx bx-ok">Healthy: $healthyCount</span>
        <span class="bx" style="color:#58a6ff">Manual Review: $manualCount</span>
      </div>
      $healthBar
    </div>
  </div>

  $keyFindingsHtml

  <div class="section" id="sec1">
    <div class="shdr" onclick="tog(this)">
      <div class="shdr-row">
        <div class="shdr-left"><span class="snum">1</span><span class="stitle">Forensic Health Check</span>$ib1</div>
        <span class="chev">&#9660;</span>
      </div>
      <div class="sdesc">UAL status and retention, Entra ID diagnostic logging, Azure Activity Log export, mailbox auditing, external auto-forwarding, and Copilot AI telemetry.</div>
    </div>
    <div class="sbody"><div class="tcon"><table><thead><tr>$audHdrHtml</tr></thead><tbody>$auditorRows</tbody></table></div></div>
  </div>

  <div class="section" id="sec2">
    <div class="shdr" onclick="tog(this)">
      <div class="shdr-row">
        <div class="shdr-left"><span class="snum">2</span><span class="stitle">Identity &amp; Posture Check</span>$ib2</div>
        <span class="chev">&#9660;</span>
      </div>
      <div class="sdesc">Security Defaults, Conditional Access with MFA grant analysis, legacy auth enforcement, PIM standing access, MFA correlation, security service plans, and Copilot data governance.</div>
    </div>
    <div class="sbody"><div class="tcon"><table><thead><tr>$protHdrHtml</tr></thead><tbody>$protectorRows</tbody></table></div></div>
  </div>

  <div class="section" id="sec3">
    <div class="shdr" onclick="tog(this)">
      <div class="shdr-row">
        <div class="shdr-left"><span class="snum">3</span><span class="stitle">Defensive Stack Analysis</span>$ib3</div>
        <span class="chev">&#9660;</span>
      </div>
      <div class="sdesc">Licensing and deployment status of Microsoft Defender suite and Sentinel SIEM across endpoint, email, identity, cloud applications, and XDR.</div>
    </div>
    <div class="sbody"><div class="tcon"><table><thead><tr>$defHdrHtml</tr></thead><tbody>$defensiveRows</tbody></table></div></div>
  </div>

  <div class="section" id="sec4">
    <div class="shdr" onclick="tog(this)">
      <div class="shdr-row">
        <div class="shdr-left"><span class="snum">4</span><span class="stitle">License &amp; SKU Inventory</span>$ib4</div>
        <span class="chev">&#9660;</span>
      </div>
      <div class="sdesc">Full Microsoft 365 license allocation. Identifies unused capacity, over-consumed SKUs, and expiring seat counts.</div>
    </div>
    <div class="sbody"><div class="tcon"><table><thead><tr>$licHdrHtml</tr></thead><tbody>$licensorRows</tbody></table></div></div>
  </div>

  <div class="section cps" id="sec5">
    <div class="shdr" onclick="tog(this)">
      <div class="shdr-row">
        <div class="shdr-left"><span class="snum">5</span><span class="stitle">Microsoft 365 Copilot AI Audit</span>$ib5</div>
        <span class="chev">&#9660;</span>
      </div>
      <div class="sdesc">Consolidated Copilot AI findings across all audit dimensions: forensic telemetry, data governance controls, and license deployment.</div>
    </div>
    <div class="sbody">
      <div class="ssect">Forensic Telemetry — UAL capture &amp; audit retention</div>
      <div class="tcon"><table><thead><tr>$cpAudHdr</tr></thead><tbody>$cpAudHtml</tbody></table></div>
      <div class="ssect">Data Governance — sensitivity labels &amp; MFA enforcement</div>
      <div class="tcon"><table><thead><tr>$cpProtHdr</tr></thead><tbody>$cpProtHtml</tbody></table></div>
      <div class="ssect">License Deployment — seat utilisation &amp; usage</div>
      <div class="tcon"><table><thead><tr>$cpLicHdr</tr></thead><tbody>$cpLicHtml</tbody></table></div>
    </div>
  </div>

  <div class="footer">
    <div class="ftxt"><strong>Generated by Microsoft Audit Tracker (MAT) v2.0</strong><br>Cloud Response &amp; Auditing Utility</div>
    <div class="fleg">This report contains confidential security information. Distribution limited to authorised personnel only.</div>
  </div>

</div>

<script>
function tog(hdr) {
  var body = hdr.parentElement.querySelector('.sbody');
  var chev = hdr.querySelector('.chev');
  body.classList.toggle('col');
  if (chev) chev.classList.toggle('up');
}

function filterRows(q) {
  q = q.toLowerCase().trim();
  var rows = document.querySelectorAll('tbody tr');
  rows.forEach(function(r) {
    if (q === '') {
      r.classList.remove('fhide');
    } else {
      var text = r.textContent.toLowerCase();
      if (text.indexOf(q) === -1) {
        r.classList.add('fhide');
      } else {
        r.classList.remove('fhide');
      }
    }
  });
}

(function() {
  var secs  = document.querySelectorAll('.section');
  var links = document.querySelectorAll('.topnav a[href^="#"]');
  if (!secs.length || !links.length || !window.IntersectionObserver) return;
  var obs = new IntersectionObserver(function(entries) {
    entries.forEach(function(e) {
      if (e.isIntersecting) {
        links.forEach(function(l) { l.classList.remove('active'); });
        var a = document.querySelector('.topnav a[href="#' + e.target.id + '"]');
        if (a) a.classList.add('active');
      }
    });
  }, { threshold: 0.15, rootMargin: '-52px 0px 0px 0px' });
  secs.forEach(function(s) { if (s.id) obs.observe(s); });
})();
</script>

</body>
</html>
"@

    Set-Content -Path $destinationPath -Value $html -Encoding UTF8 -ErrorAction Stop
    Write-Host "[✓] HTML report written" -ForegroundColor Green
    return $destinationPath
}
