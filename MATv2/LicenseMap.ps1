# ================================================================================
# DATA: LicenseMap.ps1
# Description: Authoritative SKU and Defender service-plan mappings for MAT.
#              All modules reference $script:LicenseSkuMap, $script:LicenseDefenderMap,
#              $script:RequiredSolutions, and $script:CopilotServicePlans instead
#              of defining local copies.
# v1.3: Expanded DefenderMap — full Defender product/plan coverage including
#       Defender for Endpoint P1/P2, Defender for Office 365 P1/P2,
#       Defender for Identity (Entra ID P1/P2 paths), Defender for Cloud,
#       Defender for Cloud Apps, Defender XDR, Defender for IoT, Sentinel.
#       RequiredSolutions list promoted from Licensor.ps1 to here so it is
#       authoritative and shared (Licensor imports $script:RequiredSolutions).
# ================================================================================

$script:LicenseSkuMap = @{
    # ── Office 365 Enterprise ────────────────────────────────────────────────
    "STANDARDPACK"                    = "Office 365 E1"
    "ENTERPRISEPACK"                  = "Office 365 E3"
    "ENTERPRISEPREMIUM"               = "Office 365 E5"
    "ENTERPRISEWITHSCAL"              = "Office 365 E4 (Legacy)"
    "MIDSIZEPACK"                     = "Office 365 Midsize Business (Legacy)"
    # ── Microsoft 365 Enterprise ────────────────────────────────────────────
    "SPE_E3"                          = "Microsoft 365 E3"
    "SPE_E5"                          = "Microsoft 365 E5 (Full)"
    "SPE_F1"                          = "Microsoft 365 F1 (Legacy)"
    "M365_E3"                         = "Microsoft 365 E3"
    "M365_E5"                         = "Microsoft 365 E5"
    "M365_E5_SECURITY"                = "Microsoft 365 E5 Security"
    "M365_E5_COMPLIANCE"              = "Microsoft 365 E5 Compliance"
    "IDENTITY_THREAT_PROTECTION"      = "Microsoft 365 E5 Security (Legacy)"
    "THREAT_INTELLIGENCE"             = "Microsoft 365 E5 Security Add-on"
    # ── Microsoft 365 Business ───────────────────────────────────────────────
    "M365_BUSINESS_BASIC"             = "Microsoft 365 Business Basic"
    "M365_BUSINESS_STANDARD"          = "Microsoft 365 Business Standard"
    "M365_BUSINESS_PREMIUM"           = "Microsoft 365 Business Premium"
    "O365_BUSINESS"                   = "Office 365 Business"
    "O365_BUSINESS_ESSENTIALS"        = "Office 365 Business Essentials"
    "O365_BUSINESS_PREMIUM"           = "Office 365 Business Premium"
    "SPB"                             = "Microsoft 365 Business Premium"
    # ── Frontline ────────────────────────────────────────────────────────────
    "M365_F1"                         = "Microsoft 365 F1"
    "M365_F3"                         = "Microsoft 365 F3"
    "DESKLESSPACK"                    = "Office 365 F3"
    "M365_F5_SECURITY"                = "Microsoft 365 F5 Security"
    "M365_F5_COMPLIANCE"              = "Microsoft 365 F5 Compliance"
    "M365_F5_SECCOMP"                 = "Microsoft 365 F5 Security + Compliance"
    # ── Education ────────────────────────────────────────────────────────────
    "M365_A1"                         = "Microsoft 365 A1 (Legacy)"
    "A1_FOR_DEVICES"                  = "Microsoft 365 A1 for Devices"
    "M365_A3"                         = "Microsoft 365 A3"
    "M365EDU_A3"                      = "Microsoft 365 A3"
    "M365_A5"                         = "Microsoft 365 A5 (Full)"
    "M365EDU_A5"                      = "Microsoft 365 A5"
    "M365_A5_SECURITY"                = "Microsoft 365 A5 Security"
    "M365_A5_COMPLIANCE"              = "Microsoft 365 A5 Compliance"
    "STANDARDWOFFPACK_IW_STUDENT"     = "Office 365 A1 Student"
    "STANDARDWOFFPACK_IW_FACULTY"     = "Office 365 A1 Faculty"
    # ── Defender / Security Add-ons (SKU-level display names) ───────────────
    "ATP_ENTERPRISE_FACULTY"          = "Defender for Office 365 Plan 2 (Faculty)"
    "ATP_ENTERPRISE_STUDENT"          = "Defender for Office 365 Plan 2 (Student)"
    "AAD_PREMIUM"                     = "Azure AD Premium P1"
    "AAD_PREMIUM_P2"                  = "Azure AD Premium P2"
    # ── Enterprise Mobility + Security ───────────────────────────────────────
    "EMS"                             = "Enterprise Mobility + Security E3"
    "EMSPREMIUM"                      = "Enterprise Mobility + Security E5"
    # ── Microsoft 365 Copilot ────────────────────────────────────────────────
    "Microsoft_365_Copilot"           = "Microsoft 365 Copilot"
    "COPILOT_FOR_M365"                = "Microsoft 365 Copilot"
    "M365_COPILOT"                    = "Microsoft 365 Copilot"
    "COPILOT_FOR_MICROSOFT_365"       = "Microsoft 365 Copilot"
    # ── Government ───────────────────────────────────────────────────────────
    "ENTERPRISEPACK_GOV"              = "Office 365 E3 (GCC)"
    "ENTERPRISEPREMIUM_GOV"           = "Office 365 E5 (GCC)"
    "SPE_E3_GOV"                      = "Microsoft 365 E3 (GCC)"
    "SPE_E5_GOV"                      = "Microsoft 365 E5 (GCC)"
    "ENTERPRISEPACK_GOV_HI"           = "Office 365 E3 (GCC High)"
    "ENTERPRISEPREMIUM_GOV_HI"        = "Office 365 E5 (GCC High)"
    "DOD_ENTERPRISEPACK"              = "Office 365 E3 (DoD)"
    "DOD_ENTERPRISEPREMIUM"           = "Office 365 E5 (DoD)"
    # ── Misc ─────────────────────────────────────────────────────────────────
    "FLOW_FREE"                       = "Power Automate Free"
    "POWER_BI_STANDARD"               = "Power BI Pro"
    "POWER_BI_PREMIUM"                = "Power BI Premium"
    "PROJECTPROFESSIONAL"             = "Project Plan 3"
    "PROJECTPREMIUM"                  = "Project Plan 5"
    "VISIOCLIENT"                     = "Visio Plan 2"
}

# ================================================================================
# DEFENDER MAP  — service plan name → canonical solution label
#
# Key design rules:
#   1. Exact-match keys take priority in Licensor's O(1) hot path.
#   2. Wildcard keys (containing *) fall to a secondary loop.
#   3. Canonical labels are the single source of truth — RequiredSolutions
#      (below) must match these values exactly (or via -like for Plan variants).
#   4. Where the same solution ships under multiple service-plan names (e.g.
#      Defender for Endpoint P1 via MDE_PLAN1 and via WINDEFATP), both keys
#      map to the identical canonical label so deduplication works correctly.
#   5. Defender for Identity surfaces via Entra ID P1/P2 service plans as
#      well as via discrete MDI plan names — all map to the same label.
#   6. Defender for Cloud (CSPM/CWP) and Defender for Cloud Apps are kept
#      as separate solutions even though they are sometimes bundled.
# ================================================================================
$script:LicenseDefenderMap = @{

    # ── Microsoft Sentinel ───────────────────────────────────────────────────
    "MICROSOFT_SENTINEL"                              = "Microsoft Sentinel"
    "AZURE_SENTINEL"                                  = "Microsoft Sentinel"
    "SENTINEL_STANDARD"                               = "Microsoft Sentinel"
    "SENTINEL_PLAN1"                                  = "Microsoft Sentinel"
    "*SENTINEL*"                                      = "Microsoft Sentinel"   # wildcard fallback

    # ── Defender for Endpoint Plan 1 ─────────────────────────────────────────
    # Included in Microsoft 365 Business Premium (WINDEFATP), M365 F1/F3,
    # and as a standalone add-on (MDE_PLAN1).
    "MDE_PLAN1"                                       = "Defender for Endpoint Plan 1"
    "WINDEFATP"                                       = "Defender for Endpoint Plan 1"
    "WINDOWS_DEFENDER_ATP_P1"                         = "Defender for Endpoint Plan 1"
    "MICROSOFTDEFENDERFORENDPOINT_P1"                 = "Defender for Endpoint Plan 1"

    # ── Defender for Endpoint Plan 2 ─────────────────────────────────────────
    # Included in M365 E5, M365 E5 Security, and as standalone.
    "MDE_PLAN2"                                       = "Defender for Endpoint Plan 2"
    "THREAT_PROTECTION"                               = "Defender for Endpoint Plan 2"
    "WINDOWS_DEFENDER_ADVANCED_THREAT_PROTECTION"     = "Defender for Endpoint Plan 2"
    "MDATP"                                           = "Defender for Endpoint Plan 2"
    "THREAT_PROTECTION_ENDPOINT"                      = "Defender for Endpoint Plan 2"
    "MICROSOFTDEFENDERFORENDPOINT"                    = "Defender for Endpoint Plan 2"

    # ── Defender for Office 365 Plan 1 ───────────────────────────────────────
    # Included in M365 Business Premium, M365 F3 (via MDOFFICEP1), O365 E3 add-on.
    "EXCHANGE_ADVANCED_THREAT_PROTECTION"             = "Defender for Office 365 Plan 1"
    "ATP_STANDARD"                                    = "Defender for Office 365 Plan 1"
    "MDOFFICEP1"                                      = "Defender for Office 365 Plan 1"
    "MDEFENDERFOROFFICE_P1"                           = "Defender for Office 365 Plan 1"
    "ANTIPHI_SERVICE_PLAN"                            = "Defender for Office 365 Plan 1"

    # ── Defender for Office 365 Plan 2 ───────────────────────────────────────
    # Included in M365 E5, O365 E5, and ATP_ENTERPRISE add-on.
    "ATP_ENTERPRISE"                                  = "Defender for Office 365 Plan 2"
    "ATP_ENTERPRISE_FACULTY"                          = "Defender for Office 365 Plan 2"
    "ATP_ENTERPRISE_STUDENT"                          = "Defender for Office 365 Plan 2"
    "MDEFENDERFOROFFICE_P2"                           = "Defender for Office 365 Plan 2"

    # ── Defender for Identity (Entra ID P1 path) ─────────────────────────────
    # Defender for Identity is licensed via Entra ID P1 (AAD_PREMIUM) within
    # EMS E3, M365 E3, and standalone AAD P1 SKUs. The discrete MDI service
    # plan name also maps here.
    "AAD_PREMIUM"                                     = "Defender for Identity (Entra P1)"
    "AZURE_ACTIVE_DIRECTORY_PLATFORM"                 = "Defender for Identity (Entra P1)"
    "MDI_PLAN1"                                       = "Defender for Identity (Entra P1)"

    # ── Defender for Identity (Entra ID P2 path) ─────────────────────────────
    # Entra ID P2 (AAD_PREMIUM_P2 / AAD_PREMIUM_V2) is required for Identity
    # Protection risk-based policies and PIM; it also satisfies the MDI licence.
    "AAD_PREMIUM_P2"                                  = "Defender for Identity (Entra P2)"
    "AAD_PREMIUM_V2"                                  = "Defender for Identity (Entra P2)"
    "AAD_IDENTITY_PROTECTION"                         = "Defender for Identity (Entra P2)"
    "M365_DEFENDER_IDENTITY"                          = "Defender for Identity (Entra P2)"
    "MDI_PLAN2"                                       = "Defender for Identity (Entra P2)"

    # ── Defender for Cloud (CSPM / Workload Protection) ──────────────────────
    # Azure Defender / Microsoft Defender for Cloud; appears as a service plan
    # in some E5 bundles and as a discrete plan in Azure subscriptions.
    "MICROSOFTDEFENDERFORCLOUD"                       = "Defender for Cloud"
    "AZURE_DEFENDER"                                  = "Defender for Cloud"
    "DEFENDER_FOR_CLOUD"                              = "Defender for Cloud"
    "MDE_SERVER"                                      = "Defender for Cloud"      # Defender for Servers P1/P2
    "MDE_SERVER_P2"                                   = "Defender for Cloud"
    "*DEFENDERFORCLOUD*"                              = "Defender for Cloud"      # wildcard fallback

    # ── Defender for Cloud Apps ───────────────────────────────────────────────
    # Standalone MCAS add-on or included in M365 E5 / E5 Security.
    "CLOUDAPPSECURITY"                                = "Defender for Cloud Apps"
    "MICROSOFT_CLOUD_APP_SECURITY"                    = "Defender for Cloud Apps"
    "MCAS"                                            = "Defender for Cloud Apps"
    "MDA_PREMIUM"                                     = "Defender for Cloud Apps"

    # ── Defender XDR (Microsoft 365 Defender) ────────────────────────────────
    # The unified XDR portal; licence entitlement surfaces via MTP / M365_DEFENDER.
    "MTP"                                             = "Defender XDR"
    "MICROSOFT_THREAT_PROTECTION"                     = "Defender XDR"
    "M365_DEFENDER"                                   = "Defender XDR"
    "M365_SECURITY_COMPLIANCE"                        = "Defender XDR"

    # ── Defender for IoT ─────────────────────────────────────────────────────
    "IOT_SECURITY"                                    = "Defender for IoT"
    "DEFENDER_IOT"                                    = "Defender for IoT"
    "MICROSOFTDEFENDERFORIOT"                         = "Defender for IoT"
    "*IOT*"                                           = "Defender for IoT"        # wildcard fallback
}

# ================================================================================
# REQUIRED SOLUTIONS — canonical labels that MUST appear in every Defensive Stack
# report. Licensor.ps1 imports $script:RequiredSolutions and injects placeholder
# rows for any solution not found in the tenant's service plans.
#
# Labels must match DefenderMap values exactly (or prefix-match via -like "$sol*").
# ================================================================================
$script:RequiredSolutions = @(
    "Microsoft Sentinel"
    "Defender for Endpoint Plan 1"
    "Defender for Endpoint Plan 2"
    "Defender for Office 365 Plan 1"
    "Defender for Office 365 Plan 2"
    "Defender for Identity (Entra P1)"
    "Defender for Identity (Entra P2)"
    "Defender for Cloud"
    "Defender for Cloud Apps"
    "Defender XDR"
    "Defender for IoT"
)

$script:CopilotServicePlans = @(
    "Copilot_for_M365",
    "Microsoft_365_Copilot",
    "M365_COPILOT",
    "COPILOT_FOR_MICROSOFT_365"
)

Write-Verbose "LicenseMap loaded: $($script:LicenseSkuMap.Count) SKUs, $($script:LicenseDefenderMap.Count) Defender plans, $($script:CopilotServicePlans.Count) Copilot service plans, $($script:RequiredSolutions.Count) required solutions"
