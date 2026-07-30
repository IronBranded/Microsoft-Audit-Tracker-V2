# ================================================================================
#  MAT_GraphRetry.ps1  —  Retry/backoff wrapper for Microsoft Graph calls
#  Added in MAT v1.5
# ================================================================================
#  None of MAT's Graph calls previously retried on throttling (HTTP 429) or
#  transient server errors (502/503/504) — a rate-limited or momentarily
#  unhealthy Graph endpoint just surfaced as an "Error" row in whichever mode
#  hit it. Super Auditor makes this worse by firing Auditor + Protector +
#  Licensor back to back, multiplying the number of calls in a short window.
#
#  Invoke-MATGraphWithRetry wraps a scriptblock, not a specific cmdlet, so the
#  existing call sites change minimally:
#
#    $sd = Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy -ErrorAction Stop
#  becomes
#    $sd = Invoke-MATGraphWithRetry -ScriptBlock {
#        Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy -ErrorAction Stop
#    }
#
#  The existing try/catch around each call is untouched — Invoke-MATGraphWithRetry
#  re-throws once retries are exhausted (or immediately for non-retryable errors),
#  so the surrounding catch block still runs exactly as before as the "give up"
#  path. Nothing about the existing error-handling contract changes.
# ================================================================================

function Invoke-MATGraphWithRetry {
    <#
    .SYNOPSIS
    Executes a scriptblock (typically a Graph SDK call) with retry/backoff on
    throttling (429) and transient server errors (502/503/504).
    .DESCRIPTION
    Honours the Retry-After header when Graph/Azure sends one; falls back to
    exponential backoff otherwise. Errors that are not throttling or a
    transient server error (auth failures, missing scopes, 404s, etc.) are
    re-thrown immediately on the first attempt — retrying those would just
    waste time and delay the real error reaching the caller's catch block.
    .PARAMETER ScriptBlock
    The call to execute, e.g. { Get-MgIdentityConditionalAccessPolicy -All -ErrorAction Stop }
    .PARAMETER MaxRetries
    Default 4.
    .PARAMETER BaseDelaySeconds
    Starting delay for exponential backoff when no Retry-After header is present. Default 2.
    .OUTPUTS
    Whatever ScriptBlock returns. Re-throws the last error if all retries are exhausted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [int]$MaxRetries = 4,
        [int]$BaseDelaySeconds = 2
    )

    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        } catch {
            $attempt++
            $ex         = $_.Exception
            $statusCode = $null
            try {
                if ($ex.Response -and $ex.Response.StatusCode) { $statusCode = [int]$ex.Response.StatusCode }
            } catch { }

            $isThrottle  = ($statusCode -eq 429) -or ($ex.Message -match "429|TooManyRequests|throttl")
            $isTransient = ($statusCode -in 502, 503, 504) -or
                           ($ex.Message -match "502|503|504|Gateway|Service Unavailable|Bad Gateway|timed out")

            if (-not ($isThrottle -or $isTransient) -or $attempt -gt $MaxRetries) {
                throw
            }

            $retryAfter = $null
            try {
                if ($ex.Response -and $ex.Response.Headers -and $ex.Response.Headers.RetryAfter -and
                    $ex.Response.Headers.RetryAfter.Delta) {
                    $retryAfter = $ex.Response.Headers.RetryAfter.Delta.Value.TotalSeconds
                }
            } catch { }

            $delay = if ($retryAfter -and $retryAfter -gt 0) {
                [math]::Ceiling($retryAfter)
            } else {
                $BaseDelaySeconds * [math]::Pow(2, $attempt - 1)
            }
            $kind = if ($isThrottle) { "throttled (429)" } else { "transient server error" }

            Write-Verbose "Invoke-MATGraphWithRetry: $kind on attempt $attempt/$MaxRetries — waiting ${delay}s"
            Write-Host "    [!] Graph call $kind — retry $attempt/$MaxRetries in ${delay}s..." -ForegroundColor DarkYellow
            Start-Sleep -Seconds $delay
        }
    }
}
