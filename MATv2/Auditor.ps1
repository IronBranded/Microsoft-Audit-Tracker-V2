function Invoke-AuditorMode {
    <#
    .SYNOPSIS
    Forensic Health Audit Mode
    .DESCRIPTION
    Checks: UAL status and retention, Entra ID diagnostic logging,
    Azure Activity Log export, mailbox auditing, external auto-forwarding,
    and Copilot AI telemetry (UAL capture, Purview tier, email access logging).

    v1.6: Connection-gate wait replaced with a keypress instead of a fixed
    sleep; console now recaps actual Critical/Warning findings, not just counts.
    v1.5: The Copilot Interaction Logging check (6a) now resumes a still-running
    Graph audit query from a previous run (cached in $script:MAT_Global) instead
    of always submitting a new job — see Core\MAT_GraphAudit.ps1's
    -ExistingQueryId support.
    v1.4: Copilot Interaction Logging (6a) now queries Microsoft Graph's Purview
    Audit Search API (auditLogQuery) instead of the Exchange Online cmdlet
    Search-UnifiedAuditLog — see Core\MAT_GraphAudit.ps1. UAL ingestion/retention
    (section 1), org-level mailbox audit config (section 4), and auto-forwarding
    policy (section 5) remain on Exchange Online PowerShell: Microsoft Graph has
    no read or write surface for Get/Set-AdminAuditLogConfig,
    Get-OrganizationConfig, or Get-RemoteDomain as of this release — see README
    "PowerShell -> Graph Migration Notes" for sourcing.
    v1.2: SKU cache; entraDiag multi-setting flatten; TimeSpan null guard;
    retention thresholds evaluated; external auto-forwarding check added;
    UAL Copilot sample count labeled accurately.
    #>
    param([switch]$Silent)

    if (-not $script:MAT_Global.IsConnected) {
        Write-Host "`n[!] Connection Required. Use [C] to connect first." -ForegroundColor Red
        Wait-MATContinue; return
    }

    Write-Host "`n[*] Executing Forensic Health Audit..." -ForegroundColor Cyan
    Write-Host "[*] Tenant : $($script:MAT_Global.TenantName)"     -ForegroundColor White
    Write-Host "[*] User   : $($script:MAT_Global.UserPrincipal)"  -ForegroundColor White
    Write-Host ""

    $reportPath   = Get-MATReportPath -TenantName $script:MAT_Global.TenantName
    $outFile      = Join-Path $reportPath "Auditor_Report.csv"
    $auditResults = [System.Collections.Generic.List[PSObject]]::new()

    function Add-AuditRow ($Category, $Control, $Status, $Severity, $CurrentValue, $Risk) {
        $auditResults.Add([PSCustomObject]@{
            Category        = $Category
            Audit_Control   = $Control
            Status          = $Status
            Severity        = $Severity
            Current_Value   = $CurrentValue
            Forensic_Impact = $Risk
        })
    }

    # Safely convert a TimeSpan, its string representation, or $null to whole days.
    function ConvertTo-RetentionDays ([object]$Value) {
        if ($null -eq $Value) { return $null }
        if ($Value -is [TimeSpan]) { return [math]::Round($Value.TotalDays, 0) }
        $ts = [TimeSpan]::Zero
        if ([TimeSpan]::TryParse([string]$Value, [ref]$ts)) { return [math]::Round($ts.TotalDays, 0) }
        return $null
    }

    # ---- 1. M365 TENANT AUDITING -----------------------------------------------
    # Get-AdminAuditLogConfig remains Exchange Online PowerShell-only: Microsoft
    # Graph has no endpoint exposing UnifiedAuditLogIngestionEnabled or
    # AdminAuditLogAgeLimit as of this release (confirmed against the current
    # Microsoft Purview "Search the audit log" documentation).
    Write-Host "[-] Auditing M365 Foundation..." -ForegroundColor Gray
    $ualEnabled = $false
    try {
        $ual        = Get-AdminAuditLogConfig -ErrorAction Stop |
                      Select-Object UnifiedAuditLogIngestionEnabled, AdminAuditLogAgeLimit
        $ualEnabled = [bool]$ual.UnifiedAuditLogIngestionEnabled
        Add-AuditRow "M365" "Unified Audit Log (UAL)" `
            $(if ($ualEnabled) {"Healthy"} else {"CRITICAL"}) "Critical" `
            "$($ual.UnifiedAuditLogIngestionEnabled)" `
            "Core evidence source. If disabled, zero visibility into M365 file and admin activity."

        $retDays = ConvertTo-RetentionDays $ual.AdminAuditLogAgeLimit
        if ($null -ne $retDays) {
            $retSt = if ($retDays -ge 90) {"Healthy"} elseif ($retDays -ge 30) {"Warning"} else {"CRITICAL"}
            Add-AuditRow "M365" "Admin Audit Log Retention" $retSt "Medium" "$retDays days" `
                "Exchange-level configuration change history. Recommended minimum: 90 days."
        } else {
            Add-AuditRow "M365" "Admin Audit Log Retention" "Manual Check" "Medium" "Unable to parse" `
                "Retention value could not be read. Verify manually in Exchange admin center."
        }
    } catch {
        Write-Host "[!] Exchange audit query failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Add-AuditRow "M365" "Core Auditing" "Error" "High" "Query Failed" "Check Exchange Online permissions."
    }

    # ---- 2. ENTRA ID DIAGNOSTIC LOGGING ----------------------------------------
    Write-Host "[-] Auditing Entra ID Telemetry..." -ForegroundColor Gray
    try {
        $entraDiag = Get-AzDiagnosticSetting `
            -ResourceId "/providers/Microsoft.aadiam/diagnosticSettings" `
            -ErrorAction SilentlyContinue

        if ($entraDiag) {
            # A tenant may have multiple diagnostic settings on this endpoint.
            # Flatten logs across all settings before filtering by category.
            $allLogs   = @($entraDiag) | ForEach-Object { $_.Logs } | Where-Object { $_ -ne $null }
            $hasSignIn = $allLogs | Where-Object { $_.Category -eq "SignInLogs" -and $_.Enabled }
            $hasAudit  = $allLogs | Where-Object { $_.Category -eq "AuditLogs"  -and $_.Enabled }

            if ($hasSignIn -and $hasAudit) {
                Add-AuditRow "Identity" "Entra ID Diagnostic Settings" "Healthy" "High" `
                    "SignInLogs + AuditLogs enabled" `
                    "Identity logs exported beyond the default 7-30 day window. Historical sign-in investigation supported."
            } else {
                $missing = @()
                if (-not $hasSignIn) { $missing += "SignInLogs" }
                if (-not $hasAudit)  { $missing += "AuditLogs"  }
                Add-AuditRow "Identity" "Entra ID Diagnostic Settings" "Warning" "High" `
                    "Missing: $($missing -join ', ')" `
                    "Diagnostic setting exists but critical log categories are absent. Identity investigation will be incomplete."
            }
        } else {
            Add-AuditRow "Identity" "Entra ID Diagnostic Settings" "Warning" "High" "NOT CONFIGURED" `
                "Sign-in and Audit logs expire in 7-30 days without export. Critical for IR timelines."
        }
    } catch {
        Write-Host "[!] Entra ID diagnostic: requires Az.Monitor + Monitoring Reader Azure role." -ForegroundColor Yellow
        Add-AuditRow "Identity" "Entra ID Diagnostic Settings" "Manual Check" "Medium" "Unknown" `
            "Install Az.Monitor and assign Monitoring Reader. Note: subscription-level Reader is insufficient for this endpoint."
    }

    # ---- 3. AZURE ACTIVITY LOG EXPORT ------------------------------------------
    Write-Host "[-] Auditing Azure Activity..." -ForegroundColor Gray
    try {
        $azCtx = Get-AzContext -ErrorAction SilentlyContinue
        if ($null -ne $azCtx) {
            $subDiag = Get-AzDiagnosticSetting `
                -ResourceId "/subscriptions/$($azCtx.Subscription.Id)" `
                -ErrorAction SilentlyContinue
            if ($subDiag) {
                Add-AuditRow "Platform" "Azure Activity Export" "Healthy" "Low" `
                    "Active (sub: $($azCtx.Subscription.Id.Substring(0,8))...)" `
                    "Infrastructure-level evidence preserved beyond 90-day default."
            } else {
                Add-AuditRow "Platform" "Azure Activity Export" "Warning" "Medium" "90-Day Default" `
                    "No export configured. Limits long-term persistence hunting on the current subscription."
            }
        } else {
            Add-AuditRow "Platform" "Azure Context" "Info" "Low" "Not Connected" `
                "Azure context unavailable. Connect Az.Accounts if subscription auditing is required."
        }
    } catch {
        Write-Host "[!] Azure activity check requires active Az connection." -ForegroundColor Yellow
    }

    # ---- 4. MAILBOX AUDITING ----------------------------------------------------
    # Get-OrganizationConfig also has no Graph equivalent yet. The new Graph
    # "admin/exchange" API (public preview, 2026) covers OrganizationConfig
    # MailTips, AcceptedDomain, Mailbox properties, and MailboxFolderPermission —
    # not the AuditDisabled / AuditLogAgeLimit properties this check needs.
    Write-Host "[-] Auditing Mailbox Logging..." -ForegroundColor Gray
    $mailboxAuditEnabled = $false
    try {
        $org = Get-OrganizationConfig -ErrorAction Stop | Select-Object AuditLogAgeLimit, AuditDisabled
        $mailboxAuditEnabled = ($org.AuditDisabled -eq $false)
        Add-AuditRow "Mailbox" "Mailbox Auditing" `
            $(if ($mailboxAuditEnabled) {"Healthy"} else {"CRITICAL"}) "High" `
            "GlobalEnabled:$mailboxAuditEnabled" `
            "Mailbox-level operations log. Essential for Business Email Compromise (BEC) investigation."

        $mbxDays = ConvertTo-RetentionDays $org.AuditLogAgeLimit
        if ($null -ne $mbxDays) {
            $mbxSt = if ($mbxDays -ge 90) {"Healthy"} elseif ($mbxDays -ge 30) {"Warning"} else {"CRITICAL"}
            Add-AuditRow "Mailbox" "Mailbox Audit Log Retention" $mbxSt "Medium" "$mbxDays days" `
                "How long mailbox audit records are retained. Recommended minimum: 90 days."
        } else {
            Add-AuditRow "Mailbox" "Mailbox Audit Log Retention" "Manual Check" "Medium" "Unable to parse" `
                "Retention value could not be read. Verify in Exchange admin center."
        }
    } catch {
        Write-Host "[!] Mailbox audit query failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Add-AuditRow "Mailbox" "Mailbox Auditing" "Error" "High" "Query Failed" "Verify Exchange Online permissions."
    }

    # ---- 5. EXTERNAL AUTO-FORWARDING --------------------------------------------
    # Get-RemoteDomain: same story — mail-flow configuration is not yet exposed
    # through Microsoft Graph in any form (v1.0 or beta).
    Write-Host "[-] Checking External Auto-Forwarding Policy..." -ForegroundColor Gray
    try {
        $defaultDomain = Get-RemoteDomain -Identity "Default" -ErrorAction Stop
        if ($defaultDomain.AutoForwardEnabled) {
            Add-AuditRow "Mailbox" "External Auto-Forwarding" "Warning" "High" "ENABLED (Default domain)" `
                "Auto-forwarding to external recipients is ALLOWED. Primary BEC exfiltration path. Disable unless required: Set-RemoteDomain Default -AutoForwardEnabled `$false. Also audit per-mailbox rules via Get-InboxRule."
        } else {
            Add-AuditRow "Mailbox" "External Auto-Forwarding" "Healthy" "High" "Blocked (Default domain)" `
                "Org-level auto-forwarding to external domains is blocked. BEC actors cannot silently exfiltrate email via mailbox rules. Verify per-mailbox inbox rules independently."
        }
    } catch {
        Write-Host "[!] Remote domain check failed: $($_.Exception.Message)" -ForegroundColor Yellow
        Add-AuditRow "Mailbox" "External Auto-Forwarding" "Error" "High" "Query Failed" `
            "Verify Exchange connection and View-Only Configuration role."
    }

    # ---- 6. COPILOT AI TELEMETRY ------------------------------------------------
    Write-Host "[-] Auditing Copilot AI Telemetry..." -ForegroundColor Gray

    # 6a. CopilotInteraction event capture — via the Microsoft Graph Purview Audit
    #     Search API (auditLogQuery). Replaces the previous Search-UnifiedAuditLog
    #     probe: Microsoft now points new automation at this Graph API (GA at
    #     v1.0), and Microsoft-Extractor-Suite's Get-UALGraph made the same move.
    #     Requires the AuditLogsQuery.Read.All Graph scope (requested by
    #     Connect-MAT). See Core\MAT_GraphAudit.ps1 for the query/poll/fetch logic.
    #
    #     v1.5: resumes a still-running job from a previous run instead of always
    #     submitting a new one. Without this, re-running Auditor mode after a
    #     "Pending" result just piled up a fresh audit job every time.
    if ($ualEnabled) {
        $cachedId = $script:MAT_Global.PendingCopilotQueryId
        $cacheAge = if ($script:MAT_Global.PendingCopilotQuerySubmittedAt) {
            (Get-Date) - $script:MAT_Global.PendingCopilotQuerySubmittedAt
        } else { $null }

        if ($cachedId -and $cacheAge -and $cacheAge.TotalHours -lt 24) {
            Write-Host "    Found a pending job from a previous run (Job ID: $cachedId) — checking it first..." -ForegroundColor DarkGray
            $cpQuery = Invoke-MATAuditLogQuery -ExistingQueryId $cachedId `
                -ExistingApiVersion $script:MAT_Global.PendingCopilotQueryVersion -PollSeconds 60
        } else {
            Write-Host "    Submitting Graph audit search for CopilotInteraction (async job)..." -ForegroundColor DarkGray
            $cpQuery = Invoke-MATAuditLogQuery `
                -DisplayName "MAT-CopilotProbe-$(Get-Date -Format 'yyyyMMddHHmmss')" `
                -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
                -OperationFilters @("CopilotInteraction") `
                -PollSeconds 60
        }

        # A resumed job that turned out to be gone/expired reports Failed with a
        # distinct message — fall through to a fresh submission exactly once
        # rather than surfacing a confusing "resume failed" error to the operator.
        if ($cpQuery.State -eq "Failed" -and $cpQuery.Error -match "Could not resume cached query") {
            Write-Host "    Cached job no longer available — submitting a fresh query..." -ForegroundColor DarkGray
            $cpQuery = Invoke-MATAuditLogQuery `
                -DisplayName "MAT-CopilotProbe-$(Get-Date -Format 'yyyyMMddHHmmss')" `
                -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
                -OperationFilters @("CopilotInteraction") `
                -PollSeconds 60
        }

        if ($cpQuery.State -eq "Pending") {
            $script:MAT_Global.PendingCopilotQueryId      = $cpQuery.QueryId
            $script:MAT_Global.PendingCopilotQueryVersion = $cpQuery.ApiVersion
            if ($cachedId -ne $cpQuery.QueryId) {
                # Only stamp a fresh submission time — resuming the same job keeps its original age.
                $script:MAT_Global.PendingCopilotQuerySubmittedAt = Get-Date
            }
        } else {
            $script:MAT_Global.PendingCopilotQueryId          = $null
            $script:MAT_Global.PendingCopilotQueryVersion     = $null
            $script:MAT_Global.PendingCopilotQuerySubmittedAt = $null
        }

        switch ($cpQuery.State) {
            "Completed" {
                if ($cpQuery.RecordCount -gt 0) {
                    $latest = ($cpQuery.Records | Sort-Object { [datetime]$_.createdDateTime } -Descending |
                               Select-Object -First 1).createdDateTime
                    Add-AuditRow "Copilot" "Copilot Interaction Logging" "Healthy" "High" `
                        "$($cpQuery.RecordCount) events in last 30 days (latest: $latest)" `
                        "CopilotInteraction events are actively captured via the Purview Audit Search Graph API. AI sessions are available for forensic investigation."
                } else {
                    Add-AuditRow "Copilot" "Copilot Interaction Logging" "Warning" "High" `
                        "0 events in last 30 days" `
                        "UAL is enabled but no Copilot events found. Expected if Copilot is not yet deployed. If licensed and in use, investigate the absence."
                }
            }
            "Pending" {
                Add-AuditRow "Copilot" "Copilot Interaction Logging" "Manual Check" "High" `
                    "Graph audit query still running (Job ID: $($cpQuery.QueryId))" `
                    "Purview Audit Search is an asynchronous background job and can take several minutes on larger tenants — this is expected, not a fault. Re-running Auditor mode will resume checking this same job rather than starting a new one. Job ID cached for up to 24h: GET /security/auditLog/queries/$($cpQuery.QueryId)/records"
            }
            "Failed" {
                if ($cpQuery.Error -match "403|Forbidden|Authorization_RequestDenied|401|Unauthorized") {
                    Add-AuditRow "Copilot" "Copilot Interaction Logging" "Manual Check" "High" `
                        "Graph query denied" `
                        "Requires the AuditLogsQuery.Read.All Graph scope (or a workload-scoped equivalent). Reconnect with [C] to re-consent, then re-run this mode."
                } else {
                    Add-AuditRow "Copilot" "Copilot Interaction Logging" "Error" "High" `
                        "$($cpQuery.Error)" "Purview Audit Search Graph API call failed. Verify AuditLogsQuery.Read.All scope and that Purview Audit is licensed for this tenant."
                }
            }
        }
    } else {
        Add-AuditRow "Copilot" "Copilot Interaction Logging" "CRITICAL" "High" `
            "UAL DISABLED — zero Copilot events captured" `
            "All AI activity is unrecorded while UAL is off. Enable UAL via Activator mode [5]."
    }

    # 6b. Purview Audit tier — uses SKU cache, no extra Graph call
    $allSkus = Get-MATSkuData
    if ($allSkus) {
        $hasPremium = $allSkus.ServicePlans | Where-Object {
            $_.ServicePlanName -eq "M365_ADVANCED_AUDITING" -and $_.ProvisioningStatus -eq "Success"
        }
        if ($hasPremium) {
            Add-AuditRow "Copilot" "Purview Audit Tier" "Healthy" "High" "Purview Audit Premium — 1-year" `
                "Copilot events retained 1 year. Premium unlocks MailItemsAccessed when Copilot accesses email — critical for AI-assisted BEC investigations."
        } else {
            Add-AuditRow "Copilot" "Purview Audit Tier" "Warning" "High" "Standard — 90-day retention" `
                "Copilot events purged after 90 days. IR investigations beyond 3 months lack AI evidence. License M365_ADVANCED_AUDITING to extend to 1 year."
        }
    } else {
        Add-AuditRow "Copilot" "Purview Audit Tier" "Error" "Medium" "SKU data unavailable" `
            "Verify Directory.Read.All Graph scope."
    }

    # 6c. Mailbox audit cross-check — reuses $mailboxAuditEnabled, no extra call
    Add-AuditRow "Copilot" "Copilot Email Access Logging" `
        $(if ($mailboxAuditEnabled) {"Healthy"} else {"CRITICAL"}) "High" `
        $(if ($mailboxAuditEnabled) {"Mailbox auditing enabled"} else {"Mailbox auditing DISABLED"}) `
        $(if ($mailboxAuditEnabled) {
            "Copilot email summarisation generates MailItemsAccessed events (requires Purview Audit Premium). Essential for AI-assisted exfiltration investigations."
        } else {
            "Copilot email access leaves no mailbox-level evidence. A threat actor using Copilot on a compromised account can harvest email content invisibly."
        })

    # ---- OUTPUT -----------------------------------------------------------------
    $criticalCount = ($auditResults | Where-Object { $_.Status -eq "CRITICAL" }).Count
    $warningCount  = ($auditResults | Where-Object { $_.Status -eq "Warning"  }).Count
    $copilotCount  = ($auditResults | Where-Object { $_.Category -eq "Copilot" }).Count

    $auditResults | Export-Csv -Path $outFile -NoTypeInformation
    Write-MATLog -OperationName "AuditorMode" -Details "Auditor_Report.csv: $($auditResults.Count) checks — Critical: $criticalCount, Warnings: $warningCount, Copilot: $copilotCount."

    # v1.6 — recap the actual findings, not just their counts, for anyone
    # running Auditor mode on its own rather than via Super Auditor's HTML report.
    Write-MATFindingsRecap -Data $auditResults -StatusProperty "Status" `
        -LabelProperty "Audit_Control" -DetailProperty "Current_Value"

    Write-Host "`n[✓] Audit Complete!" -ForegroundColor Green
    Write-Host "[+] Report  : $outFile" -ForegroundColor Cyan
    Write-Host "[+] Checks  : $($auditResults.Count) ($copilotCount Copilot)" -ForegroundColor White
    if ($criticalCount -gt 0) { Write-Host "[!] CRITICAL : $criticalCount" -ForegroundColor Red }
    if ($warningCount  -gt 0) { Write-Host "[!] Warnings : $warningCount"  -ForegroundColor Yellow }

    if (-not $Silent) { Pause }
}
