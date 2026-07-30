function Invoke-ActivatorMode {
    <#
    .SYNOPSIS
    Remediation Mode — Enable Unified Audit Logging
    .DESCRIPTION
    Enables UAL via Set-AdminAuditLogConfig.
    Requires Global Administrator or Compliance Administrator.

    v1.6: Both early-exit gates below now wait for a keypress instead of a
    fixed 2-second sleep.
    v1.4: No functional change. Set-AdminAuditLogConfig remains the only way to
    toggle UnifiedAuditLogIngestionEnabled — Microsoft Graph exposes no read or
    write surface for this tenant-level setting as of this release, so this mode
    still requires the ExchangeOnlineManagement session established by Connect-MAT.
    See README "PowerShell -> Graph Migration Notes".
    #>
    if (-not $script:MAT_Global.IsConnected) {
        Write-Host "[!] Connect first. Use [C] to connect." -ForegroundColor Red
        Wait-MATContinue; return
    }

    $allowedRoles = "Global Administrator|Compliance Administrator"
    if ($script:MAT_Global.UserRole -notmatch $allowedRoles) {
        Write-Host "[!] ACCESS DENIED." -ForegroundColor Red
        Write-Host "[!] Activator Mode requires one of:" -ForegroundColor Yellow
        Write-Host "      - Global Administrator" -ForegroundColor White
        Write-Host "      - Compliance Administrator" -ForegroundColor White
        Write-Host "[!] Detected role: $($script:MAT_Global.UserRole)" -ForegroundColor Yellow
        Write-Host "[!] If you hold a PIM-eligible role, activate it before connecting." -ForegroundColor Gray
        Wait-MATContinue; return
    }

    Write-Host "========================================================" -ForegroundColor Red
    Write-Host " WARNING: ACTIVATOR MODE"                                 -ForegroundColor Red
    Write-Host " This will ENABLE Unified Audit Logging for the tenant." -ForegroundColor Yellow
    Write-Host " This change is visible to all tenant administrators."    -ForegroundColor Yellow
    Write-Host "========================================================" -ForegroundColor Red

    $confirm = Read-Host "Type 'ENABLE-UAL' to proceed"
    if ($confirm -eq "ENABLE-UAL") {
        Write-Host "[*] Attempting to enable UAL..." -ForegroundColor Cyan
        try {
            Set-AdminAuditLogConfig -UnifiedAuditLogIngestionEnabled $true -ErrorAction Stop
            Write-Host "[+] Command sent successfully." -ForegroundColor Green
            Write-Host "[!] Note: changes may take up to 60 minutes to propagate." -ForegroundColor Yellow
            Write-MATLog -OperationName "ActivatorMode" -Details "Enabled Unified Audit Log. Operator role: $($script:MAT_Global.UserRole)"
        } catch {
            Write-Host "[!] Failed: $_" -ForegroundColor Red
            if ($_ -match "Enable-OrganizationCustomization") {
                Write-Host "Tip: Run Enable-OrganizationCustomization first, then retry." -ForegroundColor Gray
            }
            Write-MATLog -OperationName "ActivatorMode" -Details "Failed to enable UAL: $_" -Status "ERROR"
        }
    } else {
        Write-Host "[!] Cancelled." -ForegroundColor Yellow
        Write-MATLog -OperationName "ActivatorMode" -Details "UAL enablement cancelled by operator." -Status "INFO"
    }

    Write-Host "[*] Use Auditor Mode [1] to verify UAL status." -ForegroundColor Cyan
    Pause
}
