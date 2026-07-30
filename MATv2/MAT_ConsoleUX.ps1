# ================================================================================
#  MAT_ConsoleUX.ps1  —  Interactive console UX helpers
#  Added in MAT v1.6
# ================================================================================
#  Two small, focused helpers pulled out of the individual mode files so the
#  fix lives in one place instead of being copy-pasted at every call site:
#
#    Wait-MATContinue      — operator-controlled "press any key" wait, replacing
#                             fixed Start-Sleep delays that couldn't be skipped.
#    Write-MATFindingsRecap — prints the actual Critical/Warning findings to the
#                             console, not just a count, so a mode run outside
#                             Super Auditor still gives an at-a-glance triage view.
# ================================================================================

function Wait-MATContinue {
    <#
    .SYNOPSIS
    Waits for a keypress instead of a fixed delay.
    .DESCRIPTION
    Several spots in MAT (connection gates, access-denied paths, the menu's
    invalid-selection case) used a flat 2-3 second Start-Sleep so the operator
    had time to read a message before the screen moved on — dead time that
    couldn't be shortened even if you'd already read it, and pointless when
    nobody is at the keyboard.
    Falls back to a short fixed delay instead of blocking when the host isn't
    a real interactive console — RawUI.ReadKey throws in several real-world
    hosts (PowerShell ISE never implements it at all; redirected/piped output
    and some CI runners behave the same way) rather than hanging forever.
    .PARAMETER Message
    Prompt text shown before waiting.
    .PARAMETER FallbackSeconds
    Delay used instead of a keypress wait when the host isn't interactive
    (or ReadKey throws anyway despite looking interactive). Default 1.
    #>
    param(
        [string]$Message = "Press any key to continue...",
        [int]$FallbackSeconds = 1
    )

    $interactive = $Host.Name -ne "Default Host" -and
                   $Host.UI -and $Host.UI.RawUI -and
                   -not [Console]::IsInputRedirected

    if (-not $interactive) {
        Start-Sleep -Seconds $FallbackSeconds
        return
    }

    Write-Host $Message -ForegroundColor DarkGray -NoNewline
    try {
        [void]$Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        Write-Host ""
    } catch {
        # Host advertised RawUI but ReadKey still isn't supported (ISE is the
        # classic case) — degrade to the fixed fallback instead of leaving the
        # operator with no way to proceed.
        Write-Host ""
        Start-Sleep -Seconds $FallbackSeconds
    }
}

function Write-MATFindingsRecap {
    <#
    .SYNOPSIS
    Prints the actual Critical/Warning findings from a mode's results to the
    console, not just a count.
    .DESCRIPTION
    Auditor/Protector/Licensor each ended a run with a line like
    "CRITICAL: 3, Warnings: 5" but no list of which checks those were — finding
    out meant scrolling back through console output or opening the CSV. Only
    Super Auditor's HTML report had a "Key Findings" panel. This prints a short
    recap right where the operator is already looking, for anyone running a
    mode on its own.
    .PARAMETER Data
    The mode's result collection (e.g. $auditResults, $inventory, $defensiveResults).
    .PARAMETER StatusProperty
    Name of the property holding the status string for this mode (e.g. "Status", "State", "Health").
    .PARAMETER LabelProperty
    Property to show as the finding's short label (e.g. "Audit_Control", "Name", "Solution").
    .PARAMETER DetailProperty
    Optional property to show as a trailing detail, truncated to keep each line short.
    .PARAMETER CriticalValues
    Status value(s) that count as critical for this mode's vocabulary. Matched as a
    substring (like the rest of MAT's own status matching, e.g. SuperAuditor's -match
    "Warning|...") so compound values like "Warning (0% utilized)" still match "Warning".
    Pass an empty array to skip the critical section entirely.
    .PARAMETER WarningValues
    Same as CriticalValues, for the warning tier. Pass an empty array to skip.
    .PARAMETER MaxPerSection
    Cap on rows printed per severity before collapsing the rest into a "+N more" line,
    so a badly-misconfigured tenant doesn't scroll the console off-screen. Default 10.
    #>
    param(
        [Parameter(Mandatory = $true)][object[]]$Data,
        [Parameter(Mandatory = $true)][string]$StatusProperty,
        [Parameter(Mandatory = $true)][string]$LabelProperty,
        [string]$DetailProperty,
        [string[]]$CriticalValues = @("CRITICAL"),
        [string[]]$WarningValues  = @("Warning"),
        [int]$MaxPerSection = 10
    )

    function Get-MATMatchPattern ([string[]]$Values) {
        if (-not $Values -or $Values.Count -eq 0) { return $null }
        return ($Values | ForEach-Object { [regex]::Escape($_) }) -join "|"
    }

    function Write-MATFindingsSection ([object[]]$Rows, [string]$Title, [string]$Color, [string]$Prefix) {
        if (-not $Rows -or $Rows.Count -eq 0) { return }
        Write-Host "`n    $Title" -ForegroundColor $Color
        $shown = $Rows | Select-Object -First $MaxPerSection
        foreach ($row in $shown) {
            $label  = $row.$LabelProperty
            $detail = ""
            if ($DetailProperty -and $row.$DetailProperty) {
                $d = [string]$row.$DetailProperty
                if ($d.Length -gt 80) { $d = $d.Substring(0, 77) + "..." }
                $detail = " — $d"
            }
            Write-Host "      $Prefix $label$detail" -ForegroundColor $Color
        }
        $remaining = $Rows.Count - $shown.Count
        if ($remaining -gt 0) {
            Write-Host "      ... and $remaining more — see the CSV/HTML report for the full list" -ForegroundColor DarkGray
        }
    }

    $criticalPattern = Get-MATMatchPattern $CriticalValues
    $warningPattern  = Get-MATMatchPattern $WarningValues

    $criticalRows = if ($criticalPattern) { @($Data | Where-Object { $_.$StatusProperty -match $criticalPattern }) } else { @() }
    $warningRows  = if ($warningPattern)  { @($Data | Where-Object { $_.$StatusProperty -match $warningPattern  }) } else { @() }

    Write-MATFindingsSection -Rows $criticalRows -Title "CRITICAL FINDINGS:" -Color Red    -Prefix "✗"
    Write-MATFindingsSection -Rows $warningRows  -Title "WARNINGS:"          -Color Yellow -Prefix "!"
}
