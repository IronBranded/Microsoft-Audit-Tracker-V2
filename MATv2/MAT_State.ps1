function Initialize-MATState {
    <#
    .SYNOPSIS
    Initializes or resets the global MAT state object.
    .DESCRIPTION
    Called at startup, before new connections, and on connection failure.
    SkuCache / SkuCacheTime are reset here so a new tenant connection
    always fetches a fresh license catalog.

    v1.5: Added RoleViaGroup (role-assignable-group / PIM-for-Groups
    detection) and the PendingCopilotQuery* fields (resume support for the
    async Graph audit search job in Auditor mode). All new fields default to
    "no role via group" / "no pending job" so existing behaviour is unchanged
    until a connection actually populates them.
    #>
    $script:MAT_Global = @{
        Status        = "Disconnected"
        IsConnected   = $false
        TenantName    = "DISCONNECTED"
        TenantId      = $null
        UserPrincipal = "None"
        UserRole      = "Not Authenticated"
        RoleViaGroup  = $false     # v1.5 — true if UserRole was resolved via a role-assignable group / PIM-for-Groups rather than a direct assignment
        AzureStatus   = "Not Checked"
        SkuCache      = $null      # Populated by Connect-MAT; reused by all audit modes
        SkuCacheTime  = $null      # DateTime stamp used to enforce 60-min cache TTL

        # v1.5 — cache for resuming a still-running Purview Audit Search job
        # (Auditor mode 6a) instead of submitting a brand-new one on the next run.
        PendingCopilotQueryId          = $null
        PendingCopilotQueryVersion     = $null
        PendingCopilotQuerySubmittedAt = $null
    }
    Write-Verbose "MAT Global State initialized/reset"
}

function Get-MATConnectionStatus {
    return $script:MAT_Global.IsConnected
}

function Get-MATTenantInfo {
    return @{
        TenantName    = $script:MAT_Global.TenantName
        TenantId      = $script:MAT_Global.TenantId
        UserPrincipal = $script:MAT_Global.UserPrincipal
        M365Role      = $script:MAT_Global.UserRole
        RoleViaGroup  = $script:MAT_Global.RoleViaGroup
        AzureRole     = $script:MAT_Global.AzureStatus
        Status        = $script:MAT_Global.Status
    }
}

function Get-MATSkuData {
    <#
    .SYNOPSIS
    Returns tenant SKU data from cache, refreshing if stale or absent.
    .DESCRIPTION
    All audit modes call this helper instead of Get-MgSubscribedSku directly.
    Cache is valid for 60 minutes. On a refresh failure the stale cache is
    returned so in-progress audits are not interrupted by a transient Graph error.

    v1.5: The refresh call now goes through Invoke-MATGraphWithRetry — this is
    the single most shared Graph call in MAT (Auditor, Protector, and Licensor
    all read from this cache), so it is the highest-leverage place to add
    throttling/backoff handling.
    .OUTPUTS
    Array of MgSubscribedSku objects, or $null if data has never been fetched.
    #>
    $ageMin = if ($script:MAT_Global.SkuCacheTime) {
        ((Get-Date) - $script:MAT_Global.SkuCacheTime).TotalMinutes
    } else { 999 }

    if ($script:MAT_Global.SkuCache -and $ageMin -lt 60) {
        Write-Verbose "Get-MATSkuData: cache hit (age: $([math]::Round($ageMin,1)) min)"
        return $script:MAT_Global.SkuCache
    }

    try {
        Write-Verbose "Get-MATSkuData: refreshing from Graph"
        $skus = Invoke-MATGraphWithRetry -ScriptBlock {
            Get-MgSubscribedSku -Property SkuPartNumber, SkuId, PrepaidUnits, ConsumedUnits, ServicePlans -ErrorAction Stop
        }
        $script:MAT_Global.SkuCache     = $skus
        $script:MAT_Global.SkuCacheTime = Get-Date
        return $skus
    } catch {
        Write-Host "[!] SKU cache refresh failed: $($_.Exception.Message)" -ForegroundColor Yellow
        if ($script:MAT_Global.SkuCache) {
            Write-Host "[!] Returning stale SKU cache." -ForegroundColor Yellow
            return $script:MAT_Global.SkuCache
        }
        return $null
    }
}
