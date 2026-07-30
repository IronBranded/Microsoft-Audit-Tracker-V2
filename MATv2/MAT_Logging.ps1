function Write-MATLog {
    param (
        [Parameter(Mandatory=$true)]
        [string]$OperationName,

        [Parameter(Mandatory=$true)]
        [string]$Details,

        [ValidateSet("SUCCESS","ERROR","WARNING","INFO")]
        [string]$Status = "SUCCESS"
    )

    $logDir = Get-MATLogPath
    $tenant = if (-not [string]::IsNullOrWhiteSpace($script:MAT_Global.TenantName)) {
        $script:MAT_Global.TenantName
    } else { "UNKNOWN_TENANT" }

    # Strip characters illegal in Windows/Linux/macOS file paths
    $safeTenant = $tenant -replace '[\\/:*?"<>|]', '_'

    $timestamp = (Get-Date).ToString("yyyy-MM-dd")
    $fileName  = "${timestamp}_${safeTenant}_${OperationName}_OA.txt"
    $fullPath  = Join-Path $logDir $fileName

    $logEntry = @"
================================================================================
TIMESTAMP   : $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
OPERATOR    : $(try { whoami } catch { $env:USERNAME })
AZURE USER  : $($script:MAT_Global.UserPrincipal)
OPERATION   : $OperationName
TENANT      : $tenant
STATUS      : $Status
DETAILS     : $Details
================================================================================

"@
    Add-Content -Path $fullPath -Value $logEntry
}
