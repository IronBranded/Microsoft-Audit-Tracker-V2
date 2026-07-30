# ================================================================================
#  MAT_GraphAudit.ps1  —  Microsoft Purview Audit Search via Microsoft Graph
#  Added in MAT v1.4, extended in v1.5
# ================================================================================
#  Wraps the Microsoft Graph "auditLogQuery" API — the Graph-native, asynchronous
#  replacement for the Exchange Online Search-UnifiedAuditLog cmdlet:
#
#    POST /security/auditLog/queries                submit a search
#    GET  /security/auditLog/queries/{id}            poll job status
#    GET  /security/auditLog/queries/{id}/records    page through results
#
#  Reference (v1.0, GA):
#  https://learn.microsoft.com/en-us/graph/api/security-auditcoreroot-post-auditlogqueries
#  Permission required: AuditLogsQuery.Read.All (or a workload-scoped variant,
#  e.g. AuditLogsQuery-Exchange.Read.All) — requested by Connect-MAT.
#
#  DESIGN NOTES (why this file exists instead of calling the Graph Beta SDK):
#
#   - The typed SDK cmdlets (New-MgBetaSecurityAuditLogQuery,
#     Get-MgBetaSecurityAuditLogQueryRecord, etc.) live in the large
#     Microsoft.Graph.Beta.Security module, which MAT does not otherwise need,
#     and have open SDK bugs as of mid-2026 (URI-format and auth-drop errors on
#     some builds — see msgraph-sdk-powershell issues #3084, #3199, #3323).
#     Calling the REST surface directly via Invoke-MgGraphRequest needs nothing
#     beyond Microsoft.Graph.Authentication, which MAT already requires — no new
#     module install for the operator.
#
#   - The API is a background job, not a synchronous call. Microsoft's own
#     guidance and independent testing (Invictus Incident Response /
#     Microsoft-Extractor-Suite, Practical365, office365itpros) show completion
#     times from under a minute to 35+ minutes depending on tenant size and
#     query breadth. Invoke-MATAuditLogQuery polls for a bounded, configurable
#     window and returns a "Pending" state rather than blocking an interactive
#     MAT session for the full job lifetime — a Pending result is normal
#     behaviour for this API, not a fault.
#
#   - Microsoft-Extractor-Suite's Get-UALGraph cmdlet — the tool MAT originally
#     drew inspiration from — defaults to the beta endpoint because both beta
#     and v1.0 have shown intermittent instability in the field, and exposes a
#     -SearchId parameter so a caller can resume checking an existing job
#     instead of starting a new one. This helper mirrors both: v1.0 by default
#     with automatic beta fallback on a non-permission failure, and an
#     -ExistingQueryId parameter (v1.5) for the same resume behaviour — see
#     Operations\Auditor.ps1 6a, which caches the job id in $script:MAT_Global
#     when a query is still Pending and checks it first on the next run.
# ================================================================================

function Invoke-MATAuditLogQuery {
    <#
    .SYNOPSIS
    Runs a Microsoft Purview Audit Search via the Microsoft Graph auditLogQuery API.
    .DESCRIPTION
    Submits an audit log query (or resumes an existing one — see -ExistingQueryId),
    polls for completion within a bounded window, and returns whatever records are
    available. Because the API is an asynchronous background job, a "Pending"
    result after the poll window is expected — it does NOT mean the query failed,
    only that the job outlived the interactive wait.
    .PARAMETER DisplayName
    Friendly name for the query job, visible in the Purview portal's audit job list.
    Ignored when -ExistingQueryId is supplied.
    .PARAMETER StartDate
    Start of the search range (local time — converted to UTC internally).
    Ignored when -ExistingQueryId is supplied.
    .PARAMETER EndDate
    End of the search range (local time — converted to UTC internally).
    Ignored when -ExistingQueryId is supplied.
    .PARAMETER RecordTypeFilters
    Optional. One or more microsoft.graph.security.auditLogRecordType values
    (e.g. "exchangeAdmin", "azureActiveDirectory"). Ignored when -ExistingQueryId
    is supplied.
    .PARAMETER OperationFilters
    Optional. One or more operation/activity names (e.g. "CopilotInteraction",
    "MailItemsAccessed"). MAT's Copilot probe filters on this rather than
    RecordType. Ignored when -ExistingQueryId is supplied.
    .PARAMETER PollSeconds
    Total time to wait for job completion before returning a Pending result.
    Default 60s — enough for small tenants / narrow queries without stalling an
    interactive console session. Increase for a background/unattended run.
    .PARAMETER PollIntervalSeconds
    Delay between status polls. Default 5s.
    .PARAMETER ApiVersion
    "v1.0" (default, GA) or "beta". On a non-permission failure against the
    requested version, the function automatically retries once against the
    other endpoint before giving up. Ignored when -ExistingQueryId is supplied
    (use -ExistingApiVersion instead, so the correct endpoint is polled).
    .PARAMETER ExistingQueryId
    (v1.5) Resume an already-submitted query instead of creating a new one —
    skips straight to polling/fetching. Use this with the job id returned by a
    previous "Pending" result so a re-run doesn't pile up duplicate audit jobs.
    .PARAMETER ExistingApiVersion
    (v1.5) Which endpoint the existing query id was submitted against — must
    match, since v1.0 and beta are handled as separate resources.
    .OUTPUTS
    PSCustomObject with:
      State       — "Completed" | "Pending" | "Failed"
      QueryId     — the Graph auditLogQuery id (cache this to resume later)
      ApiVersion  — which endpoint ("v1.0"/"beta") the QueryId lives on — pass
                    this back in as -ExistingApiVersion when resuming
      Records     — array of auditLogRecord objects (empty unless Completed)
      RecordCount — Records.Count
      Error       — populated only when State = "Failed"
    .EXAMPLE
    Invoke-MATAuditLogQuery -DisplayName "Copilot probe" `
        -StartDate (Get-Date).AddDays(-30) -EndDate (Get-Date) `
        -OperationFilters @("CopilotInteraction")
    .EXAMPLE
    Invoke-MATAuditLogQuery -ExistingQueryId $cachedId -ExistingApiVersion "v1.0"
    #>
    [CmdletBinding(DefaultParameterSetName = "New")]
    param(
        [Parameter(Mandatory = $true, ParameterSetName = "New")][string]$DisplayName,
        [Parameter(Mandatory = $true, ParameterSetName = "New")][datetime]$StartDate,
        [Parameter(Mandatory = $true, ParameterSetName = "New")][datetime]$EndDate,
        [Parameter(ParameterSetName = "New")][string[]]$RecordTypeFilters,
        [Parameter(ParameterSetName = "New")][string[]]$OperationFilters,
        [Parameter(ParameterSetName = "New")][ValidateSet("v1.0", "beta")][string]$ApiVersion = "v1.0",

        [Parameter(Mandatory = $true, ParameterSetName = "Resume")][string]$ExistingQueryId,
        [Parameter(ParameterSetName = "Resume")][ValidateSet("v1.0", "beta")][string]$ExistingApiVersion = "v1.0",

        [int]$PollSeconds = 60,
        [int]$PollIntervalSeconds = 5
    )

    function New-MATAuditQueryBody {
        $b = @{
            "@odata.type"       = "#microsoft.graph.security.auditLogQuery"
            displayName         = $DisplayName
            filterStartDateTime = $StartDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
            filterEndDateTime   = $EndDate.ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        }
        if ($RecordTypeFilters) { $b.recordTypeFilters = @($RecordTypeFilters) }
        if ($OperationFilters)  { $b.operationFilters  = @($OperationFilters)  }
        return $b
    }

    function Submit-MATAuditQuery ([string]$Version) {
        $uri  = "https://graph.microsoft.com/$Version/security/auditLog/queries"
        $body = New-MATAuditQueryBody | ConvertTo-Json -Depth 5
        # Retries transient failures on THIS endpoint before the caller falls
        # back to the other endpoint — see the fallback block below.
        Invoke-MATGraphWithRetry -MaxRetries 2 -ScriptBlock {
            Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType "application/json" -ErrorAction Stop
        }
    }

    $queryId     = $null
    $usedVersion = $null
    $status      = $null

    if ($PSCmdlet.ParameterSetName -eq "Resume") {
        # ── RESUME an existing job ─────────────────────────────────────────
        Write-Verbose "Invoke-MATAuditLogQuery: resuming $ExistingQueryId on $ExistingApiVersion"
        $queryId     = $ExistingQueryId
        $usedVersion = $ExistingApiVersion
        $resumeUri   = "https://graph.microsoft.com/$usedVersion/security/auditLog/queries/$queryId"
        try {
            $poll   = Invoke-MATGraphWithRetry -ScriptBlock { Invoke-MgGraphRequest -Method GET -Uri $resumeUri -ErrorAction Stop }
            $status = $poll.status
        } catch {
            # The cached job may have expired, been purged, or belong to a
            # different tenant/session — fall back to a caller-driven retry
            # rather than a hard failure. The caller (Auditor.ps1) is expected
            # to clear its cached id and submit a fresh query on this signal.
            return [PSCustomObject]@{
                State = "Failed"; QueryId = $queryId; ApiVersion = $usedVersion
                Records = @(); RecordCount = 0
                Error = "Could not resume cached query — it may have expired. Original error: $($_.Exception.Message)"
            }
        }
    } else {
        # ── SUBMIT a new job (with one automatic endpoint fallback) ────────
        $usedVersion = $ApiVersion
        try {
            Write-Verbose "Invoke-MATAuditLogQuery: submitting on $ApiVersion"
            $job = Submit-MATAuditQuery -Version $ApiVersion
        } catch {
            $msg               = $_.Exception.Message
            $isPermissionError = $msg -match "403|Forbidden|Authorization_RequestDenied|InsufficientPermissions|401|Unauthorized"

            if ($isPermissionError) {
                # Retrying against the other endpoint will not fix a missing scope — surface it directly.
                return [PSCustomObject]@{
                    State = "Failed"; QueryId = $null; ApiVersion = $ApiVersion
                    Records = @(); RecordCount = 0; Error = $msg
                }
            }

            # Non-permission failure (timeout, 5xx, endpoint instability) — field notes from
            # Microsoft-Extractor-Suite report both beta and v1.0 have had outages; try the
            # other endpoint once before giving up.
            $fallback = if ($ApiVersion -eq "v1.0") { "beta" } else { "v1.0" }
            Write-Verbose "Invoke-MATAuditLogQuery: $ApiVersion submit failed ($msg) — retrying on $fallback"
            try {
                $job         = Submit-MATAuditQuery -Version $fallback
                $usedVersion = $fallback
            } catch {
                return [PSCustomObject]@{
                    State = "Failed"; QueryId = $null; ApiVersion = $ApiVersion
                    Records = @(); RecordCount = 0
                    Error = "Both $ApiVersion and $fallback endpoints failed. Last error: $($_.Exception.Message)"
                }
            }
        }

        $queryId = $job.id
        if (-not $queryId) {
            return [PSCustomObject]@{
                State = "Failed"; QueryId = $null; ApiVersion = $usedVersion
                Records = @(); RecordCount = 0; Error = "Graph did not return a query id."
            }
        }
        $status = $job.status
    }

    # ── POLL (bounded) ──────────────────────────────────────────────────────
    $baseUri = "https://graph.microsoft.com/$usedVersion/security/auditLog/queries/$queryId"
    $elapsed = 0

    while ($status -in @("notStarted", "running") -and $elapsed -lt $PollSeconds) {
        Start-Sleep -Seconds $PollIntervalSeconds
        $elapsed += $PollIntervalSeconds
        # v1.6 — this loop can run for up to $PollSeconds with nothing else
        # printed; Write-Progress gives the operator a live status instead of
        # a silent-looking hang.
        Write-Progress -Activity "Waiting on Microsoft Graph audit search" `
            -Status "Job $queryId — status: $status ($elapsed/$PollSeconds sec elapsed)" `
            -PercentComplete ([math]::Round(($elapsed / $PollSeconds) * 100))
        try {
            $poll   = Invoke-MgGraphRequest -Method GET -Uri $baseUri -ErrorAction Stop
            $status = $poll.status
        } catch {
            Write-Verbose "Invoke-MATAuditLogQuery: poll failed, retrying — $($_.Exception.Message)"
        }
    }
    Write-Progress -Activity "Waiting on Microsoft Graph audit search" -Completed

    # ── RESOLVE ─────────────────────────────────────────────────────────────
    switch ($status) {
        "succeeded" {
            $records = [System.Collections.Generic.List[object]]::new()
            $recUri  = "$baseUri/records"
            do {
                try {
                    $page = Invoke-MATGraphWithRetry -ScriptBlock { Invoke-MgGraphRequest -Method GET -Uri $recUri -ErrorAction Stop }
                } catch {
                    Write-Verbose "Invoke-MATAuditLogQuery: record page fetch failed — $($_.Exception.Message)"
                    break
                }
                if ($page.value) { $records.AddRange(@($page.value)) }
                $recUri = $page.'@odata.nextLink'
            } while ($recUri)

            return [PSCustomObject]@{
                State = "Completed"; QueryId = $queryId; ApiVersion = $usedVersion
                Records = $records.ToArray(); RecordCount = $records.Count
            }
        }
        "failed" {
            return [PSCustomObject]@{
                State = "Failed"; QueryId = $queryId; ApiVersion = $usedVersion
                Records = @(); RecordCount = 0
                Error = "Graph reported query status 'failed' (job $queryId)."
            }
        }
        default {
            # notStarted / running after the bounded wait — expected behaviour for a
            # background job, not an error. Hand back the job id (and which endpoint
            # it lives on) so the caller can resume it via -ExistingQueryId next time.
            return [PSCustomObject]@{
                State = "Pending"; QueryId = $queryId; ApiVersion = $usedVersion
                Records = @(); RecordCount = 0
            }
        }
    }
}
