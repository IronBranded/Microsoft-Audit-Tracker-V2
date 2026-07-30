function Get-MATGroupDerivedRoles {
    <#
    .SYNOPSIS
    Resolves directory roles the operator holds via role-assignable GROUP
    membership (including an active PIM-for-Groups activation) rather than a
    direct role assignment.
    .DESCRIPTION
    Get-MgUserMemberOf only surfaces roles assigned directly to the user as
    #microsoft.graph.directoryRole objects. It does NOT resolve roles that
    reach the user through membership in a role-assignable group — which is
    exactly how PIM-for-Groups grants privileged access. Left unchecked, an
    operator whose Global Administrator access comes from an active
    PIM-for-Groups membership is reported as "Standard User" and incorrectly
    denied Activator mode (and under-reported everywhere else the detected
    role is used).

    This cross-references the operator's group memberships (already fetched
    by the caller) against the tenant's role assignments for a fixed list of
    roles MAT cares about, using only the RoleManagement.Read.Directory scope
    MAT already requests — no new consent needed. Role definition IDs are
    resolved by display name at runtime (one Get-MgRoleManagementDirectoryRoleDefinition
    -All call) rather than hardcoded template GUIDs, since only Global
    Administrator's template ID is independently verified elsewhere in this
    codebase (Protector.ps1) and guessing the other eight would be worse than
    not checking at all.

    Note on coverage: this catches ACTIVE membership in a role-assignable
    group, including an activated PIM-for-Groups assignment — memberOf only
    ever reflects active membership, never an eligible-but-not-activated one,
    which mirrors how MAT already treats un-activated PIM directory roles
    (see README PIM note). Nested group-in-group membership is not resolved
    (Get-MgUserMemberOf is non-transitive) — if that turns out to matter in
    practice, switching the caller to Get-MgUserTransitiveMemberOf would close
    that gap at the cost of a heavier call.
    .PARAMETER GroupIds
    Object IDs of groups from the operator's (non-transitive) memberOf result.
    .PARAMETER RoleNames
    Role display names to resolve and check, in priority order.
    .OUTPUTS
    String array of role display names the operator effectively holds via a group.
    #>
    param(
        [string[]]$GroupIds,
        [string[]]$RoleNames
    )

    $found = [System.Collections.Generic.List[string]]::new()
    if (-not $GroupIds -or $GroupIds.Count -eq 0) { return $found }

    $memberIds = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$GroupIds, [System.StringComparer]::OrdinalIgnoreCase
    )

    try {
        $allDefs = Invoke-MATGraphWithRetry -ScriptBlock {
            Get-MgRoleManagementDirectoryRoleDefinition -All -ErrorAction Stop
        }
    } catch {
        Write-Verbose "Get-MATGroupDerivedRoles: could not load role definitions — $($_.Exception.Message)"
        return $found
    }

    foreach ($roleName in $RoleNames) {
        $def = $allDefs | Where-Object { $_.DisplayName -eq $roleName } | Select-Object -First 1
        if (-not $def) { continue }

        try {
            $assignments = Invoke-MATGraphWithRetry -ScriptBlock {
                Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$($def.Id)'" -All -ErrorAction Stop
            }
        } catch {
            Write-Verbose "Get-MATGroupDerivedRoles: assignment lookup failed for '$roleName' — $($_.Exception.Message)"
            continue
        }

        $viaGroup = $assignments | Where-Object { $memberIds.Contains($_.PrincipalId) }
        if ($viaGroup) { $found.Add($roleName) }
    }

    return $found
}

function Connect-MAT {
    Write-Host "`n[*] PURGING PREVIOUS SESSIONS..." -ForegroundColor Yellow

    # Disconnect all services from the PREVIOUS session before resetting state.
    Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
    Disconnect-MgGraph -ErrorAction SilentlyContinue
    if (Get-Module -Name Az.Accounts -ErrorAction SilentlyContinue) {
        Disconnect-AzAccount -Confirm:$false -ErrorAction SilentlyContinue
    }

    Initialize-MATState
    Write-Host "[*] Initiating Clean Connection..." -ForegroundColor Cyan

    try {
        Write-Host "[-] Authenticating with Microsoft Graph..." -ForegroundColor Gray

        # AuditLogsQuery.Read.All (v1.4) — required by the Graph-based Copilot
        # Interaction Logging probe in Auditor mode (Core\MAT_GraphAudit.ps1).
        Connect-MgGraph -Scopes `
            "Directory.Read.All",
            "AuditLog.Read.All",
            "AuditLogsQuery.Read.All",
            "User.Read.All",
            "RoleManagement.Read.Directory",
            "Policy.Read.All",
            "Reports.Read.All" `
            -ErrorAction Stop

        $ctx = Get-MgContext
        if (-not $ctx) { throw "Graph context is null after successful authentication." }

        # ── TENANT NAME RESOLUTION ─────────────────────────────────────────────
        $tenantInfo = Invoke-MATGraphWithRetry -ScriptBlock {
            Get-MgOrganization -Property DisplayName, Id -ErrorAction Stop | Select-Object -First 1
        }

        if ($tenantInfo -and [string]::IsNullOrWhiteSpace($tenantInfo.DisplayName)) {
            Write-Verbose "DisplayName was null with -Property; retrying without -Property"
            $tenantInfo = Invoke-MATGraphWithRetry -ScriptBlock {
                Get-MgOrganization -ErrorAction Stop | Select-Object -First 1
            }
        }

        if (-not $tenantInfo) { throw "Get-MgOrganization returned no results." }

        $script:MAT_Global.Status      = "Connected"
        $script:MAT_Global.IsConnected = $true
        $script:MAT_Global.TenantId    = $tenantInfo.Id

        $script:MAT_Global.TenantName =
            if (-not [string]::IsNullOrWhiteSpace($tenantInfo.DisplayName)) {
                $tenantInfo.DisplayName.Trim()
            } elseif (-not [string]::IsNullOrWhiteSpace($tenantInfo.Id)) {
                "Tenant-$($tenantInfo.Id.Substring(0,8))"
            } else {
                "Unknown Tenant"
            }

        $script:MAT_Global.UserPrincipal = $ctx.Account

        Write-Host "[+] Connected to tenant : $($script:MAT_Global.TenantName)" -ForegroundColor Green
        Write-Host "[+] Authenticated as    : $($ctx.Account)" -ForegroundColor Green

        # Pre-warm SKU cache
        Write-Host "[-] Pre-caching license data..." -ForegroundColor Gray
        try {
            $script:MAT_Global.SkuCache     = Invoke-MATGraphWithRetry -ScriptBlock {
                Get-MgSubscribedSku -Property SkuPartNumber, SkuId, PrepaidUnits, ConsumedUnits, ServicePlans -ErrorAction Stop
            }
            $script:MAT_Global.SkuCacheTime = Get-Date
            Write-Host "[+] License cache ready ($($script:MAT_Global.SkuCache.Count) SKUs)" -ForegroundColor Green
        } catch {
            Write-Host "[!] SKU pre-cache failed — modes will fetch on-demand: $_" -ForegroundColor Yellow
        }

        # Exchange Online
        # Still required for Get-AdminAuditLogConfig, Get-OrganizationConfig, and
        # Get-RemoteDomain (used by Auditor/Activator modes) — none have a
        # Microsoft Graph equivalent as of this release. See README "PowerShell
        # -> Graph Migration Notes". Everything else that used to touch Exchange
        # Online in earlier MAT versions (the Copilot UAL probe) now runs on Graph.
        Write-Host "[-] Connecting to Exchange Online as $($ctx.Account)..." -ForegroundColor Gray
        try {
            Connect-ExchangeOnline -UserPrincipalName $ctx.Account -ShowProgress $false -ErrorAction Stop
            Write-Host "[+] Exchange Online connected" -ForegroundColor Green
        } catch {
            Write-Host "[!] Exchange Online connection failed: $_" -ForegroundColor Yellow
            Write-Host "[!] Auditor and Copilot telemetry checks will be limited." -ForegroundColor Yellow
        }

        # M365 RBAC detection
        Write-Host "[-] Analyzing M365 Permissions..." -ForegroundColor Gray
        try {
            $memberOf = Invoke-MATGraphWithRetry -ScriptBlock {
                Get-MgUserMemberOf -UserId $ctx.Account -All -ErrorAction Stop
            }
            $roles    = @()
            $groupIds = @()
            foreach ($r in $memberOf) {
                $odType = $r.AdditionalProperties["@odata.type"]
                if ($odType -eq "#microsoft.graph.directoryRole") {
                    $n = $r.AdditionalProperties["displayName"]
                    if (-not [string]::IsNullOrWhiteSpace($n)) { $roles += $n }
                } elseif ($odType -eq "#microsoft.graph.group") {
                    $groupIds += $r.Id
                }
            }

            # v1.5 — PIM-for-Groups / role-assignable-group gap. See
            # Get-MATGroupDerivedRoles above for the full explanation.
            $roleNamesOfInterest = @(
                "Global Administrator", "Privileged Role Administrator", "Security Administrator",
                "Compliance Administrator", "Compliance Data Administrator", "Exchange Administrator",
                "Reports Reader", "Global Reader", "Security Reader"
            )
            $groupRoles   = Get-MATGroupDerivedRoles -GroupIds $groupIds -RoleNames $roleNamesOfInterest
            $viaGroupOnly = @($groupRoles | Where-Object { $roles -notcontains $_ })
            if ($viaGroupOnly.Count -gt 0) {
                $roles += $viaGroupOnly
                Write-Host "[+] Role(s) detected via group membership: $($viaGroupOnly -join ', ')" -ForegroundColor Cyan
            }

            $m365Role = if     ($roles -contains "Global Administrator")          { "Global Administrator" }
                        elseif ($roles -contains "Privileged Role Administrator") { "Privileged Role Administrator" }
                        elseif ($roles -contains "Security Administrator")        { "Security Administrator" }
                        elseif ($roles -contains "Compliance Administrator")      { "Compliance Administrator" }
                        elseif ($roles -contains "Compliance Data Administrator") { "Compliance Data Administrator" }
                        elseif ($roles -contains "Exchange Administrator")        { "Exchange Administrator" }
                        elseif ($roles -contains "Reports Reader")                { "Reports Reader" }
                        elseif ($roles -contains "Global Reader")                 { "Global Reader" }
                        elseif ($roles -contains "Security Reader")               { "Security Reader" }
                        elseif ($roles.Count -gt 0)                               { $roles[0] }
                        else                                                      { "Standard User" }

            $script:MAT_Global.UserRole     = $m365Role
            $script:MAT_Global.RoleViaGroup = [bool]($viaGroupOnly -contains $m365Role)

            # UserRole itself is left as a clean role name (Activator's role check
            # and the fixed-width header box both key off it) — the "via group"
            # fact is exposed separately through RoleViaGroup instead of being
            # appended to the string.
            $roleNote = if ($script:MAT_Global.RoleViaGroup) { " (via group)" } else { "" }
            Write-Host "[+] M365 Role detected: $m365Role$roleNote" -ForegroundColor Cyan

        } catch {
            Write-Host "[!] M365 role detection error: $_" -ForegroundColor Yellow
            $script:MAT_Global.UserRole = "Detection Failed"
        }

        # Azure RBAC detection
        Write-Host "[-] Analyzing Azure Permissions..." -ForegroundColor Gray
        $azRole = "No Access"

        if (Get-Module -ListAvailable -Name Az.Accounts -ErrorAction SilentlyContinue) {
            try {
                $azConn = Connect-AzAccount -AccountId $ctx.Account -ErrorAction Stop
                if ($azConn) {
                    Write-Host "[+] Azure connected" -ForegroundColor Green
                    $assignments = Invoke-MATGraphWithRetry -ScriptBlock {
                        Get-AzRoleAssignment -SignInName $ctx.Account -ErrorAction Stop
                    }
                    if ($assignments) {
                        $azNames = $assignments.RoleDefinitionName | Select-Object -Unique
                        $azRole  = if     ($azNames -contains "Owner")                     { "Owner" }
                                   elseif ($azNames -contains "Contributor")               { "Contributor" }
                                   elseif ($azNames -contains "User Access Administrator") { "User Access Administrator" }
                                   elseif ($azNames -contains "Monitoring Contributor")    { "Monitoring Contributor" }
                                   elseif ($azNames -contains "Monitoring Reader")         { "Monitoring Reader" }
                                   elseif ($azNames -contains "Reader")                   { "Reader" }
                                   elseif ($azNames.Count -gt 0)                          { "Custom ($($azNames[0]))" }
                                   else                                                    { "No Assignments" }
                        Write-Host "[+] Azure Role: $azRole" -ForegroundColor Cyan

                        if ($azRole -eq "Reader") {
                            Write-Host "[!] Note: Entra ID diagnostic endpoint requires Monitoring Reader, not just Reader." -ForegroundColor Yellow
                        }
                    } else {
                        $azRole = "No Assignments"
                        Write-Host "[!] No Azure role assignments found" -ForegroundColor Yellow
                    }
                }
            } catch {
                Write-Host "[!] Azure detection error: $_" -ForegroundColor Yellow
                $azRole = "Auth Limited"
            }
        } else {
            Write-Host "[!] Az.Accounts not installed — Azure checks unavailable" -ForegroundColor Yellow
            $azRole = "Module Not Installed"
        }

        $script:MAT_Global.AzureStatus = $azRole

        Write-Host "`n[+] CONNECTION SUCCESSFUL" -ForegroundColor Green
        Write-Host "    Tenant  : $($script:MAT_Global.TenantName)" -ForegroundColor White
        Write-Host "    User    : $($script:MAT_Global.UserPrincipal)" -ForegroundColor White
        Write-Host "    M365    : $($script:MAT_Global.UserRole)" -ForegroundColor Cyan
        Write-Host "    Azure   : $($script:MAT_Global.AzureStatus)" -ForegroundColor Cyan

        Wait-MATContinue -Message "`nPress any key to continue to the menu..."

    } catch {
        Write-Host "`n[!] CONNECTION ERROR: $_" -ForegroundColor Red
        Write-Host "[!] Connection failed. Verify credentials and permissions." -ForegroundColor Yellow

        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue

        Initialize-MATState

        Pause
    }
}
