function Get-MATDownloadsPath {
    if ($IsWindows -or (-not $IsWindows -and -not $IsMacOS -and -not $IsLinux)) {
        $basePath = [Environment]::GetFolderPath("UserProfile")
    } else {
        $basePath = $env:HOME
    }

    if ([string]::IsNullOrWhiteSpace($basePath)) {
        $basePath = $PWD.Path
    }

    return Join-Path $basePath "Downloads"
}

function Get-SafeTenantName {
    param([string]$TenantName)
    if ([string]::IsNullOrWhiteSpace($TenantName)) { return "Unknown_Tenant" }
    return ($TenantName -replace '[\\/:*?"<>|]', '_').Trim()
}

function Get-MATReportPath {
    param([string]$TenantName)
    $root       = Get-MATDownloadsPath
    $matRoot    = Join-Path $root "MAT_Reports"
    $safeTenant = Get-SafeTenantName $TenantName
    $dateFolder = (Get-Date).ToString("yyyy-MM-dd")
    $finalPath  = Join-Path (Join-Path $matRoot $safeTenant) $dateFolder

    if (-not (Test-Path $finalPath)) {
        New-Item -Path $finalPath -ItemType Directory -Force | Out-Null
    }
    return $finalPath
}

function Get-MATLogPath {
    $root    = Get-MATDownloadsPath
    $logRoot = Join-Path (Join-Path $root "MAT_Reports") "MAT_Operational_Logs"

    if (-not (Test-Path $logRoot)) {
        New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
    }
    return $logRoot
}
