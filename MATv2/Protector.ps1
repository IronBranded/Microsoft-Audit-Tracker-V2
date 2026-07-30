function Invoke-ProtectorMode {
    <#
    .SYNOPSIS
    Security Posture Audit Mode
    .DESCRIPTION
    Checks: Security Defaults, CA policies (state-aware + MFA grant coverage),
    MFA/CA correlation, legacy authentication block, PIM standing GA access,
    security service plan inventory, Copilot data governance (MIP + MFA).
    v1.6: Connection-gate wait replaced with a keypress instead of a fixed
    sleep; console now recaps actual Critical/Warning findings, not just counts.
    v1.5: Graph calls now retry on throttling/transient errors via
    Invoke-MATGraphWithRetry (Core\MAT_GraphRetry.ps1) — Super Auditor fires
    Auditor + Protector + Licensor back to back, so a rate-limited tenant
    previously showed up here as scattered "Error/Failed" rows.
    v1.2: HashSet for O(1) plan lookups; SKU cache; legacy auth + PIM checks;
    MFA grant coverage per policy; warning count surfaced in console.
    #>
    param([switch]$Silent)

    if (-not $script:MAT_Global.IsConnected) {
        Write-Host "`n[!] Connection Required. Use [C] to connect first." -ForegroundColor Red
        Wait-MATContinue; return
    }

    Write-Host "`n[*] Running Protector Mode..." -ForegroundColor Cyan
    Write-Host "[*] Tenant : $($script:MAT_Global.TenantName)"    -ForegroundColor White
    Write-Host "[*] User   : $($script:MAT_Global.UserPrincipal)" -ForegroundColor White
    Write-Host ""

    $reportPath = Get-MATReportPath -TenantName $script:MAT_Global.TenantName
    $outFile    = Join-Path $reportPath "Protector_Inventory.csv"
    $inventory  = [System.Collections.Generic.List[PSObject]]::new()

    $secDefaultsEnabled = $false
    $enabledCACount     = 0
    $mfaCACount         = 0
    $caps               = $null

    # ---- 1. SECURITY DEFAULTS --------------------------------------------------
    Write-Host "[-] Checking Security Defaults..." -ForegroundColor Gray
    try {
        $sd = Invoke-MATGraphWithRetry -ScriptBlock { Get-MgPolicyIdentitySecurityDefaultEnforcementPolicy -ErrorAction Stop }
        $secDefaultsEnabled = [bool]$sd.IsEnabled
        $sdState = if ($secDefaultsEnabled) { "Enabled" } else { "Disabled" }
        $inventory.Add([PSCustomObject]@{
            Type        = "Security Policy"
            Name        = "Security Defaults"
            State       = $sdState
            Description = "Baseline identity protections (MFA for all users, legacy auth block). Automatically disabled when Conditional Access is in use."
        })
        Write-Host "[✓] Security Defaults: $sdState" -ForegroundColor $(if ($secDefaultsEnabled) {"Green"} else {"Yellow"})
    } catch {
        Write-Host "[!] Security Defaults query failed: $($_.Exception.Message)" -ForegroundColor Yellow
        $inventory.Add([PSCustomObject]@{
            Type="Security Policy"; Name="Security Defaults"; State="Error/Failed"
            Description="Query failed. Requires Policy.Read.All Graph scope."
        })
    }

    # ---- 2. CONDITIONAL ACCESS --------------------------------------------------
    Write-Host "[-] Checking Conditional Access Policies..." -ForegroundColor Gray
    try {
        $caps = Invoke-MATGraphWithRetry -ScriptBlock { Get-MgIdentityConditionalAccessPolicy -ErrorAction Stop }
        if ($caps -and $caps.Count -gt 0) {
            $enabledCACount  = ($caps | Where-Object { $_.State -eq "enabled" }).Count
            $reportOnlyCount = ($caps | Where-Object { $_.State -eq "enabledForReportingButNotEnforced" }).Count
            $disabledCount   = ($caps | Where-Object { $_.State -eq "disabled" }).Count

            foreach ($p in $caps) {
                $caState = switch ($p.State) {
                    "enabled"                           { "Enabled" }
                    "disabled"                          { "Disabled" }
                    "enabledForReportingButNotEnforced" { "Warning" }
                    default                             { $p.State }
                }
                $inventory.Add([PSCustomObject]@{
                    Type  = "Conditional Access"
                    Name  = $p.DisplayName
                    State = $caState
                    Description = switch ($p.State) {
                        "enabled"                           { "Enforced." }
                        "disabled"                          { "Disabled — provides no protection." }
                        "enabledForReportingButNotEnforced" { "Report-only — logs but does NOT enforce." }
                        default                             { $p.State }
                    }
                })
            }

            # Count policies that explicitly require MFA
            $mfaCACount = ($caps | Where-Object {
                $_.State -eq "enabled" -and (
                    ($_.GrantControls.BuiltInControls -contains "mfa") -or
                    ($null -ne $_.GrantControls.AuthenticationStrength)
                )
            }).Count

            $inventory.Add([PSCustomObject]@{
                Type  = "Conditional Access"
                Name  = "CA Policy Summary"
                State = if ($enabledCACount -gt 0) {"Healthy"} else {"CRITICAL"}
                Description = "Total: $($caps.Count) | Enforced: $enabledCACount | MFA-granting: $mfaCACount | Report-only: $reportOnlyCount | Disabled: $disabledCount"
            })
            Write-Host "[✓] CA: $($caps.Count) policies ($enabledCACount enforced, $mfaCACount MFA-granting, $reportOnlyCount report-only)" -ForegroundColor Green
        } else {
            Write-Host "[!] No Conditional Access policies found" -ForegroundColor Yellow
            $inventory.Add([PSCustomObject]@{
                Type="Conditional Access"; Name="None"; State="No Policies Found"
                Description="No CA policies configured in this tenant."
            })
        }
    } catch {
        Write-Host "[!] CA query failed: $($_.Exception.Message)" -ForegroundColor Yellow
        $inventory.Add([PSCustomObject]@{
            Type="Conditional Access"; Name="Error"; State="Failed to query"
            Description="Requires Policy.Read.All Graph scope."
        })
    }

    # Correlation: no MFA enforcement at all
    if (-not $secDefaultsEnabled -and $enabledCACount -eq 0) {
        $inventory.Add([PSCustomObject]@{
            Type="Correlation Finding"; Name="MFA Enforcement Gap"; State="CRITICAL"
            Description="Security Defaults disabled AND no CA policies enforced. Tenant has NO MFA requirement. Any valid credential grants unrestricted M365 access."
        })
    } elseif (-not $secDefaultsEnabled -and $mfaCACount -eq 0 -and $enabledCACount -gt 0) {
        $inventory.Add([PSCustomObject]@{
            Type="Correlation Finding"; Name="MFA Grant Coverage Gap"; State="Warning"
            Description="CA policies are enforced but none explicitly require MFA (BuiltInControls:mfa or AuthenticationStrength). Policies may restrict access without requiring MFA. Verify at least one policy enforces MFA for all users."
        })
    }

    # ---- 3. LEGACY AUTHENTICATION BLOCK ----------------------------------------
    Write-Host "[-] Checking Legacy Authentication Block..." -ForegroundColor Gray
    if ($null -ne $caps) {
        $legacyBlock = $caps | Where-Object {
            $_.State -eq "enabled" -and
            ($_.Conditions.ClientAppTypes -contains "exchangeActiveSync" -or
             $_.Conditions.ClientAppTypes -contains "other") -and
            $_.GrantControls.BuiltInControls -contains "block"
        }
        if ($legacyBlock -and $legacyBlock.Count -gt 0) {
            $inventory.Add([PSCustomObject]@{
                Type="Security Policy"; Name="Legacy Authentication Block"; State="Healthy"
                Description="$($legacyBlock.Count) enabled CA policy/policies block legacy auth (EAS/other). Password-spray via legacy protocols is mitigated."
            })
        } else {
            $inventory.Add([PSCustomObject]@{
                Type="Security Policy"; Name="Legacy Authentication Block"; State="Warning"
                Description="No enabled CA policy blocks legacy authentication (exchangeActiveSync/other). Legacy auth bypasses MFA entirely and is the primary password-spray vector. Create a CA policy to block legacy auth for all users."
            })
        }
    } else {
        $inventory.Add([PSCustomObject]@{
            Type="Security Policy"; Name="Legacy Authentication Block"; State="Manual Check"
            Description="CA data unavailable — legacy auth status cannot be determined."
        })
    }

    # ---- 4. PIM STANDING GA ACCESS --------------------------------------------
    Write-Host "[-] Checking PIM / Standing GA Access..." -ForegroundColor Gray
    $gaTemplateId = "62e90394-69f5-4237-9190-012177145e10"
    try {
        $activeGA   = Invoke-MATGraphWithRetry -ScriptBlock {
            Get-MgRoleManagementDirectoryRoleAssignment -Filter "roleDefinitionId eq '$gaTemplateId'" -All -ErrorAction Stop
        }
        $eligibleGA = Invoke-MATGraphWithRetry -ScriptBlock {
            Get-MgRoleManagementDirectoryRoleEligibilitySchedule -Filter "roleDefinitionId eq '$gaTemplateId'" -All -ErrorAction Stop
        }

        $activeCount   = @($activeGA).Count
        $eligibleCount = @($eligibleGA).Count

        if ($activeCount -gt 0 -and $eligibleCount -eq 0) {
            $inventory.Add([PSCustomObject]@{
                Type="Security Policy"; Name="PIM — Global Administrator"; State="Warning"
                Description="$activeCount standing (permanent) GA assignment(s). No PIM eligibility configured for the GA role. Standing GA access widens the blast radius of a credential compromise. Convert to PIM-eligible assignments."
            })
        } elseif ($eligibleCount -gt 0) {
            $inventory.Add([PSCustomObject]@{
                Type="Security Policy"; Name="PIM — Global Administrator"; State="Healthy"
                Description="$eligibleCount PIM-eligible GA assignment(s). No standing GA access detected. Privileged access requires explicit time-bound activation with justification."
            })
        } else {
            $inventory.Add([PSCustomObject]@{
                Type="Security Policy"; Name="PIM — Global Administrator"; State="Manual Check"
                Description="No GA assignments found in active or eligibility schedules. Verify GA configuration in Entra ID."
            })
        }
    } catch {
        Write-Host "[!] PIM check failed: $($_.Exception.Message)" -ForegroundColor Yellow
        $inventory.Add([PSCustomObject]@{
            Type="Security Policy"; Name="PIM — Global Administrator"; State="Manual Check"
            Description="PIM query failed. Requires RoleManagement.Read.Directory scope. Error: $($_.Exception.Message)"
        })
    }

    # ---- 5. SECURITY SERVICE PLAN INVENTORY ------------------------------------
    Write-Host "[-] Inventorying Security Service Plans..." -ForegroundColor Gray

    $allSkus = Get-MATSkuData
    $activePlansSet = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    if ($allSkus) {
        foreach ($sku in $allSkus) {
            foreach ($plan in $sku.ServicePlans) {
                if ($plan.ProvisioningStatus -eq "Success") {
                    [void]$activePlansSet.Add($plan.ServicePlanName)
                }
            }
        }
    }

    $planMap = @{
        "AAD_PREMIUM"                         = "Entra ID P1"
        "AAD_PREMIUM_P2"                      = "Entra ID P2"
        "AAD_PREMIUM_V2"                      = "Entra ID P2"
        "M365_ADVANCED_AUDITING"              = "Purview Audit (Premium)"
        "THREAT_PROTECTION"                   = "Defender for Endpoint P2"
        "THREAT_PROTECTION_ENDPOINT"          = "Defender for Endpoint P2"
        "MDE_PLAN2"                           = "Defender for Endpoint P2"
        "ATP_ENTERPRISE"                      = "Defender for Office 365 P2"
        "MFA_PREMIUM"                         = "Azure AD MFA"
        "CLOUDAPPSECURITY"                    = "Defender for Cloud Apps"
        "MICROSOFT_CLOUD_APP_SECURITY"        = "Defender for Cloud Apps"
        "AZURE_ACTIVE_DIRECTORY_PLATFORM"     = "Defender for Identity"
        "AAD_IDENTITY_PROTECTION"             = "Azure AD Identity Protection"
        "INFORMATION_PROTECTION_COMPLIANCE"   = "Information Protection & Compliance"
        "M365_LIGHTHOUSE"                     = "Microsoft 365 Lighthouse"
    }

    Write-Host "[✓] $($activePlansSet.Count) unique active service plans" -ForegroundColor Green
    $foundCount = 0
    foreach ($planID in $planMap.Keys) {
        $found = $activePlansSet.Contains($planID)
        $inventory.Add([PSCustomObject]@{
            Type        = "Service Plan"
            Name        = $planMap[$planID]
            State       = if ($found) {"Licensed"} else {"Not Found"}
            Description = "Security service — plan ID: $planID"
        })
        if ($found) { $foundCount++ }
    }
    Write-Host "[✓] $foundCount / $($planMap.Count) key security plans found" -ForegroundColor Cyan

    # ---- 6. COPILOT DATA GOVERNANCE --------------------------------------------
    Write-Host "[-] Checking Copilot Data Governance Controls..." -ForegroundColor Gray

    # 6a. Sensitivity label licensing (MIP)
    $mipPlans   = @("INFORMATION_PROTECTION_COMPLIANCE","AIP_PREMIUM_P1","AIP_PREMIUM_P2","RMS_S_PREMIUM","RMS_S_PREMIUM2")
    $hasMipPlan = $mipPlans | Where-Object { $activePlansSet.Contains($_) } | Select-Object -First 1

    $inventory.Add([PSCustomObject]@{
        Type  = "Copilot"
        Name  = "Sensitivity Label Licensing (MIP)"
        State = if ($hasMipPlan) {"Licensed"} else {"Not Found"}
        Description = if ($hasMipPlan) {
            "MIP licensed ($hasMipPlan). Labels can govern what Copilot accesses and surfaces. Verify labels are published in Microsoft Purview."
        } else {
            "No MIP service plan found. Copilot has no content-level access controls and may surface unclassified or over-shared data."
        }
    })

    # 6b. Copilot + MFA enforcement correlation
    $cpSvcPlans = @("Copilot_for_M365","Microsoft_365_Copilot","M365_COPILOT","COPILOT_FOR_MICROSOFT_365")
    $cpSkuIds   = @("Microsoft_365_Copilot","COPILOT_FOR_M365","M365_COPILOT","COPILOT_FOR_MICROSOFT_365")
    $cpDeployed = ($cpSvcPlans | Where-Object { $activePlansSet.Contains($_) }).Count -gt 0 -or
                  ($allSkus -and ($allSkus | Where-Object { $_.SkuPartNumber -in $cpSkuIds }))

    if ($cpDeployed) {
        if (-not $secDefaultsEnabled -and $enabledCACount -eq 0) {
            $inventory.Add([PSCustomObject]@{
                Type="Copilot"; Name="Copilot + MFA Enforcement Gap"; State="CRITICAL"
                Description="Copilot is licensed but NO MFA enforcement is active. A single compromised credential grants full Copilot access — email summarisation, SharePoint file search, Teams retrieval — with no additional barrier."
            })
        } else {
            $mfaSrc = if ($secDefaultsEnabled) { "Security Defaults" } else {
                "$mfaCACount MFA-granting CA $(if ($mfaCACount -eq 1){'policy'}else{'policies'})"
            }
            $inventory.Add([PSCustomObject]@{
                Type="Copilot"; Name="Copilot + MFA Enforcement"; State="Healthy"
                Description="Copilot is licensed and MFA is enforced via $mfaSrc. Credential compromise alone is insufficient to gain Copilot access."
            })
        }
    } else {
        $inventory.Add([PSCustomObject]@{
            Type="Copilot"; Name="Copilot Deployment"; State="Not Licensed"
            Description="Microsoft 365 Copilot not detected in this tenant. Data governance checks are informational."
        })
    }

    # ---- OUTPUT ----------------------------------------------------------------
    $inventory | Export-Csv -Path $outFile -NoTypeInformation

    $criticalCount = ($inventory | Where-Object { $_.State -eq "CRITICAL" }).Count
    $warningCount  = ($inventory | Where-Object { $_.State -eq "Warning"  }).Count
    $copilotItems  = ($inventory | Where-Object { $_.Type  -eq "Copilot"  }).Count

    Write-MATLog -OperationName "ProtectorMode" -Details "Protector_Inventory.csv: $($inventory.Count) items — Critical: $criticalCount, Warnings: $warningCount, Copilot: $copilotItems."

    # v1.6 — recap the actual findings, not just their counts.
    Write-MATFindingsRecap -Data $inventory -StatusProperty "State" `
        -LabelProperty "Name" -DetailProperty "Description"

    Write-Host "`n[✓] Protector Mode Complete!" -ForegroundColor Green
    Write-Host "[+] Report : $outFile" -ForegroundColor Cyan
    Write-Host "[+] Items  : $($inventory.Count) ($copilotItems Copilot)" -ForegroundColor White
    if ($criticalCount -gt 0) { Write-Host "[!] CRITICAL : $criticalCount" -ForegroundColor Red }
    if ($warningCount  -gt 0) { Write-Host "[!] Warnings : $warningCount"  -ForegroundColor Yellow }

    if (-not $Silent) { Pause }
}
