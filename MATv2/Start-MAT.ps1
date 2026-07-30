# ================================================================================
#  Microsoft Audit Tracker (MAT) - Entry Point
#  Version: 2.0
#  Description: Cloud Response & Auditing Utility for Microsoft 365 / Azure
#
#  Directory Layout (must match actual folder structure):
#
#    MicrosoftAuditTracker/
#    ├── Start-MAT.ps1              ← This file
#    ├── Core/
#    │   ├── MAT_State.ps1
#    │   ├── MAT_Logging.ps1
#    │   ├── MAT_Paths.ps1
#    │   ├── MAT_ConsoleUX.ps1
#    │   ├── MAT_GraphRetry.ps1
#    │   ├── MAT_Connection.ps1
#    │   └── MAT_GraphAudit.ps1
#    ├── Data/
#    │   └── LicenseMap.ps1
#    ├── UI/
#    │   └── MAT_UI_Engine.ps1
#    └── Operations/
#        ├── Diagnostic.ps1
#        ├── Auditor.ps1
#        ├── Protector.ps1
#        ├── Licensor.ps1
#        ├── Activator.ps1
#        └── SuperAuditor.ps1
#
#  v2.0 — MAT V2: first release as its own repository. Consolidates the v1.4
#  (Graph migration), v1.5 (hardening), and v1.6 (console UX) work into a
#  complete, self-consistent set of files — including SuperAuditor.ps1 and
#  MAT_UI_Engine.ps1, which previously only existed as patch instructions
#  layered on top of a base the repo didn't contain. Every fix below is now
#  built directly into its file rather than described as a diff to apply:
#    - PowerShell -> Microsoft Graph migration (Copilot Interaction Logging via
#      the Purview Audit Search API; UAL config, mailbox audit config, and
#      remote-domain checks confirmed to have no Graph equivalent and
#      deliberately kept on Exchange Online PowerShell — see README).
#    - AuditLogsQuery.Read.All scope; resume-query support for pending Graph
#      audit jobs (Core\MAT_GraphAudit.ps1).
#    - Throttling/backoff retry wrapper for Graph calls (Core\MAT_GraphRetry.ps1).
#    - PIM-for-Groups / role-assignable-group detection
#      (Get-MATGroupDerivedRoles, Core\MAT_Connection.ps1).
#    - Console UX: Write-Progress on every multi-second wait (module loading,
#      the Graph audit poll, Super Auditor's three-phase run), forced UTF-8
#      console encoding, keypress waits instead of fixed sleeps
#      (Core\MAT_ConsoleUX.ps1), and a findings recap (not just counts) after
#      Auditor/Protector/Licensor.
#    - SuperAuditor.ps1 stats rollup now counts every row (Manual Check/Error/
#      Info included via a remainder bucket) instead of under-counting the
#      executive summary total.
#
#  Full per-version history: see README "PowerShell -> Graph Migration Notes",
#  "v1.5 Hardening Pass", and "v1.6 Console UX Pass".
# ================================================================================

$ErrorActionPreference = "Stop"
Clear-Host

# UTF-8 console output so box-drawing/checkmark characters render correctly.
# Windows PowerShell 5.1's classic conhost.exe console defaults to the system
# codepage (frequently NOT UTF-8 on US/EU Windows installs) unless told
# otherwise, which turns "✓ ✗ ═" into "?" or garbled bytes. PS7+ terminals are
# typically UTF-8 already, so this is a safe no-op there. Wrapped in try/catch:
# some hosts (older conhost without a UTF-8 codepage installed, output
# redirected to a file/pipe, certain CI runners) will throw on this — in that
# narrow case the glyphs may still render oddly, but the tool continues rather
# than crashing over a cosmetic setting.
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch {
    Write-Verbose "Could not set UTF-8 console encoding — special characters may not render correctly on this host."
}

Write-Host "════════════════════════════════════════════════════════════════════════════" -ForegroundColor Blue
Write-Host "  Microsoft Audit Tracker (MAT) v2.0 - Initializing..." -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════════════════════════════════════" -ForegroundColor Blue

# $PSScriptRoot is empty when script content is pasted directly into a console session.
# Fall back to the invocation path so module resolution always works.
$scriptPath = if ($PSScriptRoot) {
    $PSScriptRoot
} else {
    Split-Path -Parent $MyInvocation.MyCommand.Path
}

# ================================================================================
# HELPER: Graceful exit with full session cleanup
# ================================================================================
function Exit-MAT {
    param([int]$Code = 0)
    Write-Host "`n[*] Cleaning up sessions before exit..." -ForegroundColor Yellow
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    if (Get-Module -Name Az.Accounts -ErrorAction SilentlyContinue) {
        Disconnect-AzAccount -Confirm:$false -ErrorAction SilentlyContinue
    }
    Write-Host "[+] Sessions cleared." -ForegroundColor Green
    Pause
    exit $Code
}

# ================================================================================
# 1. MODULE LOADING — subdirectory layout
#    Load order matters: State → Logging → Paths → ConsoleUX → GraphRetry →
#    Connection → GraphAudit → LicenseMap → UI → Operations. Core modules are
#    marked; a failure in any Core module aborts.
#
#    Format: @{ File = "filename.ps1"; Dir = "SubFolder" }
#    Dir is joined with $scriptPath to build the full path.
# ================================================================================
Write-Host "[*] Loading MAT modules..." -ForegroundColor Yellow

$coreModules = @(
    @{ File = "MAT_State.ps1";      Dir = "Core"       }
    @{ File = "MAT_Logging.ps1";    Dir = "Core"       }
    @{ File = "MAT_Paths.ps1";      Dir = "Core"       }
    @{ File = "MAT_ConsoleUX.ps1";  Dir = "Core"       }
    @{ File = "MAT_GraphRetry.ps1"; Dir = "Core"       }
    @{ File = "MAT_Connection.ps1"; Dir = "Core"       }
    @{ File = "MAT_GraphAudit.ps1"; Dir = "Core"       }
)

$otherModules = @(
    @{ File = "LicenseMap.ps1";     Dir = "Data"       }
    @{ File = "MAT_UI_Engine.ps1";  Dir = "UI"         }
    @{ File = "Diagnostic.ps1";     Dir = "Operations" }
    @{ File = "Auditor.ps1";        Dir = "Operations" }
    @{ File = "Protector.ps1";      Dir = "Operations" }
    @{ File = "Licensor.ps1";       Dir = "Operations" }
    @{ File = "Activator.ps1";      Dir = "Operations" }
    @{ File = "SuperAuditor.ps1";   Dir = "Operations" }
)

$allModules    = $coreModules + $otherModules
$coreFileNames = $coreModules | ForEach-Object { $_.File }

$loadedCount   = 0
$failedModules = @()
$moduleIndex   = 0

foreach ($mod in $allModules) {
    $moduleIndex++
    Write-Progress -Activity "Loading MAT modules" -Status "$($mod.Dir)\$($mod.File)" `
        -PercentComplete ([math]::Round(($moduleIndex / $allModules.Count) * 100))

    $modulePath = Join-Path (Join-Path $scriptPath $mod.Dir) $mod.File

    if (Test-Path $modulePath) {
        try {
            $prevEAP = $ErrorActionPreference
            . $modulePath
            $ErrorActionPreference = $prevEAP
            $loadedCount++
            Write-Host "  [✓] $($mod.Dir)\$($mod.File)" -ForegroundColor Green
        } catch {
            $ErrorActionPreference = $prevEAP
            $failedModules += $mod.File
            Write-Host "  [✗] FAILED: $($mod.Dir)\$($mod.File) — $_" -ForegroundColor Red
        }
    } else {
        $failedModules += $mod.File
        Write-Host "  [!] NOT FOUND: $($mod.Dir)\$($mod.File)" -ForegroundColor Red
        Write-Host "      Expected : $modulePath" -ForegroundColor DarkGray
    }
}

Write-Progress -Activity "Loading MAT modules" -Completed
Write-Host "`n[+] Loaded $loadedCount / $($allModules.Count) modules" -ForegroundColor Green

if ($failedModules.Count -gt 0) {
    Write-Host "[!] Failed to load $($failedModules.Count) module(s):" -ForegroundColor Red
    $failedModules | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }

    $coreFailures = $failedModules | Where-Object { $_ -in $coreFileNames }
    if ($coreFailures.Count -gt 0) {
        Write-Host "`n[!] CRITICAL: Core module(s) failed — MAT cannot continue." -ForegroundColor Red
        Write-Host "    Ensure the following folder structure exists next to Start-MAT.ps1:" -ForegroundColor Yellow
        Write-Host "      Core\MAT_State.ps1"      -ForegroundColor Gray
        Write-Host "      Core\MAT_Logging.ps1"    -ForegroundColor Gray
        Write-Host "      Core\MAT_Paths.ps1"      -ForegroundColor Gray
        Write-Host "      Core\MAT_ConsoleUX.ps1"  -ForegroundColor Gray
        Write-Host "      Core\MAT_GraphRetry.ps1" -ForegroundColor Gray
        Write-Host "      Core\MAT_Connection.ps1" -ForegroundColor Gray
        Write-Host "      Core\MAT_GraphAudit.ps1" -ForegroundColor Gray
        Write-Host "      Data\LicenseMap.ps1"     -ForegroundColor Gray
        Write-Host "      UI\MAT_UI_Engine.ps1"    -ForegroundColor Gray
        Write-Host "      Operations\Auditor.ps1"  -ForegroundColor Gray
        Write-Host "      (etc.)"                  -ForegroundColor Gray
        Exit-MAT -Code 1
    }
}

# ================================================================================
# 2. DEPENDENCY CHECK — verify PS modules are installed AND importable
# ================================================================================
Write-Host "`n[*] Checking PowerShell module dependencies..." -ForegroundColor Yellow

$dependencies = @(
    @{ Name = "Microsoft.Graph.Authentication"; Required = $true;  Note = "Core Graph connectivity, incl. the auditLogQuery API used by Auditor mode" }
    @{ Name = "ExchangeOnlineManagement";       Required = $true;  Note = "UAL config, mailbox audit config, remote domain — no Graph equivalent yet" }
    @{ Name = "Az.Accounts";                    Required = $false; Note = "Optional: Azure RBAC detection" }
    @{ Name = "Az.Monitor";                     Required = $false; Note = "Optional: Entra ID diagnostic settings (requires Monitoring Reader Azure role)" }
)

$allPresent = $true
foreach ($dep in $dependencies) {
    $result = $null
    try { $result = Import-Module $dep.Name -PassThru -ErrorAction Stop } catch {}

    if ($result) {
        Write-Host "  [✓] $($dep.Name) v$($result.Version)" -ForegroundColor Green
    } elseif ($dep.Required) {
        Write-Host "  [✗] $($dep.Name) — MISSING or BROKEN (REQUIRED)" -ForegroundColor Red
        $allPresent = $false
    } else {
        Write-Host "  [!] $($dep.Name) — not installed ($($dep.Note))" -ForegroundColor Yellow
    }
}

if (-not $allPresent) {
    Write-Host "`n[!] Required modules are missing. Install them:" -ForegroundColor Red
    Write-Host "    Install-Module Microsoft.Graph.Authentication -Force" -ForegroundColor White
    Write-Host "    Install-Module ExchangeOnlineManagement -Force" -ForegroundColor White
    Write-Host "`n    Optional (recommended):" -ForegroundColor Yellow
    Write-Host "    Install-Module Az.Accounts -Force" -ForegroundColor White
    Write-Host "    Install-Module Az.Monitor  -Force" -ForegroundColor White
    Exit-MAT -Code 1
}

# ================================================================================
# 3. INITIALIZE GLOBAL STATE
# ================================================================================
Write-Host "`n[*] Initializing MAT state..." -ForegroundColor Yellow

if (Get-Command Initialize-MATState -ErrorAction SilentlyContinue) {
    Initialize-MATState
    Write-Host "[✓] State initialized" -ForegroundColor Green
} else {
    Write-Host "[✗] Initialize-MATState not found — core module failed to load." -ForegroundColor Red
    Exit-MAT -Code 1
}

# ================================================================================
# 4. LAUNCH UI
# ================================================================================
Write-Host "`n[*] Launching MAT Dashboard..." -ForegroundColor Yellow
Start-Sleep -Seconds 1

if (Get-Command Show-MATMenu -ErrorAction SilentlyContinue) {
    Show-MATMenu
} else {
    Write-Host "`n[!] FATAL: Show-MATMenu not found — UI engine failed to load." -ForegroundColor Red
    Exit-MAT -Code 1
}
