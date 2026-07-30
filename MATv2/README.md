# MICROSOFT-AUDIT-TRACKER (MAT)
Cloud Response & Auditing Utility

**Version: 2.0**.
**Creator: M. Decayette (IronBranded)**

> **MAT V2.** First release of this repository. Every file listed under
> "File Structure" below is complete and self-contained — nothing here depends
> on a patch note or an external diff. See "PowerShell → Graph Migration
> Notes", "v1.5 Hardening Pass", and "v1.6 Console UX Pass" for the full
> history of what changed and why on the way to this release.

---

## LEGAL DISCLAIMER & MANDATORY CONSENT

This tool is provided for professional security auditing and Incident Response purposes only.
Use of MAT **MUST** be conducted only after obtaining **explicit written consent** from the
Tenant Owners and Authorized Administrators.

The user is solely responsible for ensuring all activities comply with local laws,
organizational policies, and privacy regulations. The developer assumes no liability for
data loss, service interruption, or legal consequences resulting from use of this tool.

---

## TABLE OF CONTENTS

1. Tool Description & IR Relevance
2. File Structure
3. How to Use (Windows & macOS)
4. Privileged Identity Management (PIM) Note
5. Required Permissions — Per-Mode Matrix
6. Graph API Scopes
7. Operations Matrix
8. Defensive Stack Coverage
9. Copilot AI Audit Integration
10. Cloud IR Preparedness & Security Pillars
11. PowerShell → Graph Migration Notes
12. v1.5 Hardening Pass
13. v1.6 Console UX Pass
14. Outputs
15. References

---

## TOOL DESCRIPTION & IR RELEVANCE

Microsoft Audit Tracker (MAT) identifies the "Cloud Response & Forensic Footprint" capabilities
of a Microsoft 365 tenant and determines whether the current configuration is actually
capturing the evidence an IR team would need. It provides a unified view of audit logging
health, identity posture, defensive stack licensing, and AI governance — all in a single run
with no manual API queries.

---

## FILE STRUCTURE

```
MicrosoftAuditTracker/
├── Start-MAT.ps1                 ← Entry point
├── Core/
│   ├── MAT_State.ps1             ← Global state + SKU cache helper
│   ├── MAT_Logging.ps1           ← Operator audit trail (non-repudiation)
│   ├── MAT_Paths.ps1             ← Cross-platform report/log path resolution
│   ├── MAT_Connection.ps1        ← Authentication + session management
│   ├── MAT_GraphAudit.ps1        ← Purview Audit Search Graph API wrapper (v1.4)
│   ├── MAT_GraphRetry.ps1        ← Throttling/backoff wrapper for Graph calls (v1.5)
│   └── MAT_ConsoleUX.ps1         ← Keypress waits + console findings recap (v1.6)
├── Data/
│   └── LicenseMap.ps1            ← SKU + Defender service-plan reference data
│                                    Also owns $script:RequiredSolutions (v1.3)
├── UI/
│   └── MAT_UI_Engine.ps1         ← Console header and menu loop
└── Operations/
    ├── Auditor.ps1               ← Mode 1 — Forensic Health Check
    ├── Protector.ps1             ← Mode 2 — Identity & Posture Check
    ├── Licensor.ps1              ← Mode 3 — Defensive Stack & License Inventory
    ├── Activator.ps1             ← Mode 5 — UAL remediation
    ├── Diagnostic.ps1            ← [D] — Environment diagnostic check
    └── SuperAuditor.ps1          ← Mode 4 — Full-spectrum audit + HTML report
```

If any Core module is absent, MAT will print the expected path and exit.
`Start-MAT.ps1` resolves all module paths from its own directory (`$PSScriptRoot`).

---

## HOW TO USE

### Requirements

| Platform | PowerShell Version  |
|----------|---------------------|
| Windows  | 5.1 or 7+           |
| macOS    | 7+ (pwsh)           |

### Install required modules

```powershell
Install-Module Microsoft.Graph.Authentication -Force
Install-Module ExchangeOnlineManagement -Force   # still needed — see "PowerShell -> Graph Migration Notes"
Install-Module Az.Accounts -Force                # Optional — Azure RBAC + diagnostic checks
Install-Module Az.Monitor  -Force                # Optional — Entra ID diagnostic settings
```

Note: `Microsoft.Graph.Beta.Security` is **not** required. MAT's Graph-based audit search
(`Core\MAT_GraphAudit.ps1`) calls the REST endpoint directly via `Invoke-MgGraphRequest`
from `Microsoft.Graph.Authentication`, rather than depending on the beta SDK cmdlets.

### Windows

```powershell
# Open PowerShell as Administrator
cd C:\Path\To\MicrosoftAuditTracker
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process -Force
.\Start-MAT.ps1
```

### macOS / Linux

```bash
cd /path/to/MicrosoftAuditTracker
pwsh ./Start-MAT.ps1
```

---

## PRIVILEGED IDENTITY MANAGEMENT (PIM) NOTE

MAT detects **currently active** M365 role assignments via `Get-MgUserMemberOf`.
PIM-eligible roles that have **not been activated** for the current session are invisible
to this call and will display as "Standard User" in the MAT header.

**Before running MAT**, activate any required PIM role in the Entra admin center:
`Identity Governance → Privileged Identity Management → My roles → Activate`

Roles that require activation before specific modes will work correctly:
- Global Administrator or Compliance Administrator → required for Activator mode [5]
- Security Administrator or higher → recommended for full Auditor/Protector coverage

---

## REQUIRED PERMISSIONS — PER-MODE MATRIX

### Mode 1 — Auditor (read-only)

| Layer         | Minimum permission |
|---------------|--------------------|
| M365 Role     | Security Reader (or Global Reader, Compliance Admin, Security Admin, Global Admin) |
| Exchange Role | View-Only Audit Reports; View-Only Configuration |
| Azure Role    | **Monitoring Reader** — required for Entra ID diagnostic endpoint. Generic "Reader" is NOT sufficient for `/providers/Microsoft.aadiam/diagnosticSettings`. Reader on subscription is sufficient for Azure Activity Log check. |
| Graph Scopes  | `AuditLog.Read.All`, `AuditLogsQuery.Read.All`, `Directory.Read.All` |

### Mode 2 — Protector (read-only)

| Layer        | Minimum permission |
|--------------|--------------------|
| M365 Role    | Security Reader |
| Exchange     | None required |
| Azure        | None required |
| Graph Scopes | `Directory.Read.All`, `Policy.Read.All` — CA policy queries will always fail without `Policy.Read.All`, regardless of M365 admin role |

### Mode 3 — Licensor (read-only)

| Layer        | Minimum permission |
|--------------|--------------------|
| M365 Role    | Global Reader or Security Reader |
| Exchange     | None required |
| Azure        | None required |
| Graph Scopes | `Directory.Read.All`, `Reports.Read.All` (for Copilot usage summary) |

### Mode 4 — Super Auditor (read-only)

Union of Modes 1, 2, and 3. Recommended minimum: **Security Administrator** or
**Compliance Administrator** with **Monitoring Reader** on Azure.

### Mode 5 — Activator (write — tenant-level change)

| Layer        | Requirement |
|--------------|-------------|
| M365 Role    | **Global Administrator** OR **Compliance Administrator** — both hold the Exchange "Audit Logs" management role required by `Set-AdminAuditLogConfig`. Security Administrator does NOT have this right. |
| Exchange     | Audit Logs management role (held automatically by GA and Compliance Admin) |
| Azure        | None required |

---

## GRAPH API SCOPES

All scopes are requested at connection time. Re-connect with [C] if a scope is missing.

| Scope | Required for |
|-------|-------------|
| `Directory.Read.All` | Tenant info, SKU/license queries, user lookups |
| `AuditLog.Read.All` | Directory/sign-in audit log access |
| `AuditLogsQuery.Read.All` | **(v1.4)** Purview Audit Search API — Copilot Interaction Logging check in Auditor mode |
| `User.Read.All` | Group/role membership queries |
| `RoleManagement.Read.Directory` | Role assignment detection + PIM eligibility queries |
| `Policy.Read.All` | CA policies and Security Defaults — **not** covered by Directory.Read.All |
| `Reports.Read.All` | Copilot usage summary endpoint — held by Reports Reader, Security Reader, Global Reader, Compliance Admin, Global Admin |

---

## OPERATIONS MATRIX

```
[1] AUDITOR MODE    Forensic Health Check
                    UAL status and retention (threshold-evaluated, not just displayed)
                    Entra ID diagnostic logging (category validation, not just existence)
                    Azure Activity Log export (current subscription)
                    Mailbox auditing and retention
                    External auto-forwarding policy (BEC exfiltration gate)
                    Copilot AI telemetry (Graph-based UAL capture, Purview tier,
                                           email access logging)

[2] PROTECTOR MODE  Identity & Posture Check
                    Security Defaults status
                    Conditional Access policies (Enabled / Disabled / Report-only)
                    CA policy MFA grant coverage (BuiltInControls:mfa + AuthenticationStrength)
                    MFA enforcement correlation (Security Defaults + CA cross-check)
                    Legacy authentication block detection
                    PIM standing Global Administrator access
                    Security service plan inventory (HashSet O(1) lookups)
                    Copilot data governance (MIP licensing + MFA enforcement correlation)

[3] LICENSOR MODE   Defensive Stack & License Inventory
                    Full Defender product coverage (11 required solutions):
                      Microsoft Sentinel
                      Defender for Endpoint Plan 1 / Plan 2
                      Defender for Office 365 Plan 1 / Plan 2
                      Defender for Identity (Entra P1 path)
                      Defender for Identity (Entra P2 path)
                      Defender for Cloud (CSPM / Workload Protection)
                      Defender for Cloud Apps
                      Defender XDR
                      Defender for IoT
                    Full SKU inventory with over-consumption detection
                    Copilot license analysis (seat utilization, expiry warnings, usage summary)

[4] SUPER AUDITOR   Runs Modes 1 + 2 + 3 sequentially
                    Generates executive HTML report with:
                    - Key Findings panel (critical items at a glance)
                    - Collapsible sections with chevron toggle
                    - Sticky top navigation (jump to any section)
                    - Row-level severity highlighting (critical/warning tints)
                    - Zebra row striping
                    - Section 5: Consolidated Copilot AI Audit

[5] ACTIVATOR MODE  Remediation — Enable Unified Audit Logging
                    Requires Global Administrator OR Compliance Administrator
                    Requires 'ENABLE-UAL' confirmation string
                    All actions logged to operator audit trail
```

---

## DEFENSIVE STACK COVERAGE (Mode 3 / Section 3)

The table below lists every product MAT reports on, the service-plan names it detects,
and the typical licence source.

| Product | Key Service Plan(s) | Typical Licence Source |
|---------|---------------------|------------------------|
| Microsoft Sentinel | `MICROSOFT_SENTINEL`, `AZURE_SENTINEL` | Azure subscription add-on |
| Defender for Endpoint Plan 1 | `MDE_PLAN1`, `WINDEFATP` | M365 Business Premium, M365 F1/F3, standalone |
| Defender for Endpoint Plan 2 | `MDE_PLAN2`, `THREAT_PROTECTION`, `MDATP` | M365 E5, M365 E5 Security, standalone |
| Defender for Office 365 Plan 1 | `EXCHANGE_ADVANCED_THREAT_PROTECTION`, `MDOFFICEP1` | M365 Business Premium, M365 F3, standalone |
| Defender for Office 365 Plan 2 | `ATP_ENTERPRISE`, `MDEFENDERFOROFFICE_P2` | M365 E5, O365 E5, standalone |
| Defender for Identity (Entra P1) | `AAD_PREMIUM`, `MDI_PLAN1` | EMS E3, M365 E3, standalone AAD P1 |
| Defender for Identity (Entra P2) | `AAD_PREMIUM_P2`, `AAD_IDENTITY_PROTECTION` | EMS E5, M365 E5, standalone AAD P2 |
| Defender for Cloud | `MICROSOFTDEFENDERFORCLOUD`, `MDE_SERVER` | Azure subscription add-on |
| Defender for Cloud Apps | `CLOUDAPPSECURITY`, `MCAS` | M365 E5, M365 E5 Security, standalone |
| Defender XDR | `MTP`, `M365_DEFENDER` | M365 E5, M365 E5 Security |
| Defender for IoT | `IOT_SECURITY`, `DEFENDER_IOT` | Azure subscription add-on |

Not-licensed placeholder rows are injected for any product absent from the tenant's
service plans, so the report always shows a complete security posture picture.

---

## COPILOT AI AUDIT INTEGRATION

Copilot audit checks are embedded directly into each mode rather than a separate option,
so every standard audit run automatically includes AI governance visibility.

| Mode | Copilot checks |
|------|----------------|
| Auditor [1] | UAL `CopilotInteraction` event capture (30-day probe, **now via the Graph Purview Audit Search API**); Purview Audit tier (Standard 90d vs Premium 1yr); Mailbox audit cross-check for Copilot email access logging |
| Protector [2] | MIP sensitivity label licensing; Copilot + MFA enforcement correlation (CRITICAL if Copilot licensed with zero MFA enforcement) |
| Licensor [3] | Copilot SKU and bundled service plan detection; seat utilization and expiry warnings; Copilot usage summary via Graph Reports API |
| Super Auditor [4] | HTML Section 5 consolidates all Copilot findings from the three modes into one panel |

**Why these checks matter:** A threat actor using a compromised account with Copilot access
can summarise inboxes, search SharePoint, and retrieve Teams messages at scale — silently,
if UAL is off or if Copilot email access logging (MailItemsAccessed) is not captured.

---

## CLOUD DFIR PREPAREDNESS & SECURITY PILLARS

### Unified Audit Log (UAL)
Verifies UAL ingestion is enabled. Without it, there is zero visibility into M365 file,
email, and admin activity. Retention is evaluated against a 90-day threshold — not just
displayed as a raw value.

### Entra ID Diagnostic Logging
Checks whether `SignInLogs` and `AuditLogs` categories are both enabled in a diagnostic
setting on the Entra ID endpoint. Existence of a setting is insufficient — the tool validates
the categories. Requires Az.Monitor and Monitoring Reader Azure role.

### Azure Activity Log Export
Validates whether the current subscription has a diagnostic setting exporting activity logs
beyond the 90-day default. Scoped to the active subscription context.

### Mailbox Auditing
Confirms org-level mailbox auditing is enabled. Retention is threshold-evaluated.
Cross-referenced with external auto-forwarding to present a complete BEC picture.

### External Auto-Forwarding
Checks `Get-RemoteDomain -Identity Default` for `AutoForwardEnabled`. If allowed at org
level, BEC actors can silently forward all mail to an external attacker-controlled inbox.

### Conditional Access & MFA Enforcement
CA policies are inspected for actual state (enforced / report-only / disabled), not just
counted. A separate MFA grant coverage count identifies how many enforced policies
explicitly require MFA via `BuiltInControls` or `AuthenticationStrength`.

### Legacy Authentication Block
Inspects CA policies for blocks on `exchangeActiveSync` and `other` client types.
Legacy auth bypasses MFA and is the entry point for password spray attacks.

### PIM Standing Access
Detects permanent Global Administrator assignments with no PIM eligibility schedule,
flagging tenants where GA access is always-on rather than time-bound.

---

## POWERSHELL → GRAPH MIGRATION NOTES (v1.4)

This pass went through every PowerShell call in MAT and moved it to Microsoft Graph
wherever Graph actually supports the operation, using
[Microsoft-Extractor-Suite](https://microsoft-365-extractor-suite.readthedocs.io/) and
current Microsoft Learn documentation as reference. MAT already used the Microsoft Graph
PowerShell SDK for the large majority of its checks (Conditional Access, Security Defaults,
PIM/role assignments, SKU/license data, tenant info) — this pass focused on the handful of
calls that still went through Exchange Online PowerShell.

### ✅ Migrated to Microsoft Graph in v1.4

| Check | Was | Now |
|-------|-----|-----|
| Copilot Interaction Logging (Auditor 6a) | `Search-UnifiedAuditLog -RecordType CopilotInteraction` | Microsoft Graph **Purview Audit Search API** (`POST/GET /security/auditLog/queries`) via `Invoke-MATAuditLogQuery` in `Core\MAT_GraphAudit.ps1` |

Microsoft's own guidance now directs new automation to this Graph API instead of
`Search-UnifiedAuditLog`, and Microsoft-Extractor-Suite's `Get-UALGraph` made the identical
move. The API graduated from beta to **v1.0 (GA)** in 2026, but it is asynchronous — a query
is submitted as a background job, not answered synchronously — so `Invoke-MATAuditLogQuery`
polls for a bounded window (default 60s) and reports `Manual Check` with the job ID if the
job is still running when the window closes, rather than blocking the console for the
10–35+ minutes a large-tenant job can take.

### ⛔ Still on Exchange Online PowerShell — no Graph equivalent exists yet

| Check | Cmdlet | Why it hasn't moved |
|-------|--------|----------------------|
| UAL ingestion status/retention (Auditor 1, Activator) | `Get-AdminAuditLogConfig` / `Set-AdminAuditLogConfig` | No Graph endpoint exposes `UnifiedAuditLogIngestionEnabled` or `AdminAuditLogAgeLimit`. Confirmed against the current Microsoft Purview "Search the audit log" documentation. |
| Org-level mailbox audit config (Auditor 4) | `Get-OrganizationConfig` | Microsoft's new Graph "admin/exchange" API (public preview, 2026) covers `OrganizationConfig` **MailTips** settings, `Mailbox` properties, and `MailboxFolderPermission` — but not `AuditDisabled` / `AuditLogAgeLimit`. |
| External auto-forwarding policy (Auditor 5) | `Get-RemoteDomain` | Mail-flow / remote-domain configuration has no Graph surface in v1.0 or beta. |

MAT keeps the `ExchangeOnlineManagement` session in `Connect-MAT` specifically for these
three checks. If Microsoft extends Graph coverage to any of them, the corresponding block
in `Operations\Auditor.ps1` / `Operations\Activator.ps1` is the only place that needs to
change — each is isolated behind its own `try/catch` and clearly commented.

### Deliberately left on Az.\* modules — out of Graph's scope by design

`Get-AzDiagnosticSetting`, `Get-AzContext`, `Get-AzRoleAssignment`, and `Connect-AzAccount`
(Entra ID diagnostic settings, Azure Activity Log export, Azure RBAC) are **Azure Resource
Manager** concepts, not Microsoft 365/Entra data — Microsoft Graph does not cover ARM
resources, so these correctly stay on the `Az` modules. This isn't legacy debt; it's the
right tool for that data.

### Why `Invoke-MgGraphRequest` instead of the Beta SDK cmdlets

The typed cmdlets for this API (`New-MgBetaSecurityAuditLogQuery`,
`Get-MgBetaSecurityAuditLogQueryRecord`) live in `Microsoft.Graph.Beta.Security`, a module
MAT would otherwise have no reason to depend on, and have open SDK issues as of mid-2026
(URI-format and auth-token errors on some builds — see msgraph-sdk-powershell issues #3084,
#3199, #3323). `Core\MAT_GraphAudit.ps1` calls the REST endpoints directly with
`Invoke-MgGraphRequest`, which ships in `Microsoft.Graph.Authentication` — a dependency MAT
already had. This mirrors the pattern MAT already used for the Copilot usage summary in
Licensor mode (`Invoke-MgGraphRequest` against `reports/getMicrosoft365CopilotUsageSummary`).

---

## v1.5 HARDENING PASS

A follow-up pass covering four issues surfaced while reviewing the v1.4 migration —
one correctness gap in role detection, two resilience gaps, and one reporting gap.

### 1. PIM-for-Groups / role-assignable-group detection gap (Core\MAT_Connection.ps1)

`Get-MgUserMemberOf` only returns roles assigned **directly** to the signed-in user
as `#microsoft.graph.directoryRole` objects. It does not resolve roles that reach
the user through membership in a **role-assignable group** — which is exactly the
mechanism PIM-for-Groups uses. An operator whose Global Administrator access came
from an active PIM-for-Groups membership was reported as `Standard User` and
incorrectly denied Activator mode.

`Get-MATGroupDerivedRoles` (new) cross-references the operator's group memberships
against the tenant's role assignments for the same nine roles MAT already
prioritises, using only the `RoleManagement.Read.Directory` scope MAT already
requests — no new consent needed. Role definition IDs are resolved by display name
at runtime (`Get-MgRoleManagementDirectoryRoleDefinition`) rather than hardcoded,
since only Global Administrator's template ID was independently verified elsewhere
in this codebase (Protector.ps1's PIM check) and guessing the other eight would be
worse than not checking at all.

A new `$script:MAT_Global.RoleViaGroup` flag records whether the detected role came
from a group rather than a direct assignment; `UserRole` itself is left as a clean
role name so it keeps working everywhere it already did (Activator's regex-based
gate, the fixed-width header box). Note: this closes the *role-assignable group*
gap specifically — it still relies on `memberOf` (non-transitive), so a role
reached through a **nested** group-in-a-group is not resolved. `Get-MgUserMemberOf`
also only ever reflects *active* membership, so this correctly stays silent for an
eligible-but-not-yet-activated PIM-for-Groups assignment, matching how MAT already
treats un-activated PIM directory roles.

### 2. No explicit throttling/retry handling anywhere (Core\MAT_GraphRetry.ps1 — new)

The Microsoft Graph PowerShell SDK has some baseline retry handling of its own for
429 responses, but MAT itself had no explicit, tunable, or visible retry strategy —
and that SDK-level handling doesn't necessarily cover transient 502/503/504 server
errors or the raw `Invoke-MgGraphRequest` calls MAT makes for the audit-search and
Copilot-usage endpoints. Super Auditor's back-to-back Auditor + Protector +
Licensor run multiplies the chance of hitting a rate limit, and a throttled call
previously just surfaced as an "Error" row. `Invoke-MATGraphWithRetry` wraps a
scriptblock, honours the `Retry-After` header when present, falls back to
exponential backoff otherwise, and prints what it's doing so the operator isn't
staring at a silent pause. Non-retryable errors (missing scope, 404, etc.) are
re-thrown immediately rather than wasting time retrying something that won't
change. Applied to: the shared SKU fetch (`Get-MATSkuData` — used by all three
audit modes), the connection-time Graph and Azure RBAC calls, the audit-search
submit/poll/record calls, and Protector's and Licensor's Graph calls. The existing
`try`/`catch` around each call is untouched — the retry wrapper re-throws once
exhausted, so the original catch block still runs as the "give up" path.
Reference: [Microsoft Graph throttling guidance](https://learn.microsoft.com/en-us/graph/throttling).

### 3. No way to resume a pending audit query (Core\MAT_GraphAudit.ps1)

Re-running Auditor mode after a "Pending" Copilot Interaction Logging result used
to submit a brand-new Graph audit job every time rather than checking the one
already running. `Invoke-MATAuditLogQuery` gained `-ExistingQueryId` /
`-ExistingApiVersion` (mirroring Microsoft-Extractor-Suite's `-SearchId`
parameter); Auditor mode caches the job id and submission time in
`$script:MAT_Global.PendingCopilotQuery*` and checks that job first (for up to
24h) before submitting a new one. If the cached job has expired or was purged,
Auditor mode transparently falls back to a fresh submission.

### 4. SuperAuditor stats rollup didn't count every row (Operations\SuperAuditor.ps1)

The executive summary's Critical / Warning / Healthy counts never included
`Manual Check`, `Error`, or `Info` rows — so `criticalCount + warningCount +
healthyCount` could be less than `totalChecks` whenever any check couldn't run
automatically. This was a minor cosmetic gap before v1.4, but the new Pending
state from an async Graph audit job reports as `Manual Check`, making the gap
show up more often on larger tenants.

**v2.0 note:** originally shipped as a standalone patch, since this file's full
HTML/CSS template hadn't yet been independently re-verified end-to-end. It has
since been confirmed and is now built directly into `SuperAuditor.ps1` — the
new bucket is computed as a remainder immediately after `$healthyCount` rather
than a fourth set of `-match` filters (shorter, and mathematically guaranteed
to make the total add up regardless of which exact status strings any mode
uses now or in the future):

```powershell
$manualCount = $totalChecks - $criticalCount - $warningCount - $healthyCount
if ($manualCount -lt 0) { $manualCount = 0 }   # defensive guard, should not trigger
```

...and a fourth span in the stats card, reusing the report's existing blue
`Info/Manual` colour so no new CSS class was needed:

```html
<span class="bx" style="color:#58a6ff">Manual Review: $manualCount</span>
```

---

## v1.6 CONSOLE UX PASS

A pass focused specifically on the interactive console experience rather than
backend correctness — four issues, all fixed the same way: additively, without
touching the layout or wording of anything already on screen.

### 1. Silent multi-second waits (Write-Progress)

Nothing in MAT used PowerShell's native `Write-Progress` anywhere. Most
noticeable in two places: the async Graph audit-search poll
(`Core\MAT_GraphAudit.ps1`) can sit for up to 60 seconds with nothing printed
between status checks, and Super Auditor's three-phase Auditor → Protector →
Licensor run gave no sense of which phase was active or how much was left.
Both now show a live `Write-Progress` bar — module loading in `Start-MAT.ps1`
got the same treatment, since it's a similar "several seconds, several steps"
wait.

### 2. Unicode rendering risk on classic Windows PowerShell 5.1

The console output leans on `✓ ✗ ═ ─` throughout, but nothing forced a
UTF-8-capable output encoding. The classic `conhost.exe` console behind
Windows PowerShell 5.1 — an explicitly supported platform per this README —
defaults to the system codepage, which is frequently *not* UTF-8 on US/EU
Windows installs, turning those characters into `?` or garbled bytes.
`Start-MAT.ps1` now sets `[Console]::OutputEncoding` and `$OutputEncoding` to
UTF-8 at the very top, before the first character is printed. This is wrapped
in `try`/`catch`: a small number of hosts (very old conhost builds without a
UTF-8 codepage installed, output redirected to a file/pipe, some CI runners)
will throw on this, and in that narrow case the glyphs may still render
oddly — but the tool continues rather than failing over a cosmetic setting.
A full fallback to ASCII-safe equivalents (`[OK]`/`[X]` instead of `✓`/`✗`)
across every file would close that last gap too, but given how many files use
these characters, that's a much larger, more invasive change than this pass
was scoped for; the encoding fix resolves the common case.

### 3. Counts without a recap (Write-MATFindingsRecap)

Auditor, Protector, and Licensor each ended with a line like "CRITICAL: 3,
Warnings: 5" — a count, not a list. Finding out *which* checks those were
meant scrolling back through console output or opening the CSV. Only Super
Auditor's HTML report had a "Key Findings" panel; run any mode on its own and
you didn't get one. New `Write-MATFindingsRecap` (`Core\MAT_ConsoleUX.ps1`)
prints the actual failing rows — capped at 10 per severity with a "+N more"
line so a badly-misconfigured tenant can't scroll the console off-screen —
right where the operator is already looking. Wired into Auditor, Protector,
and both of Licensor's result sets (Defensive Stack and License Inventory,
which use different status vocabularies, so each call passes its own
critical/warning value list).

### 4. Unskippable forced delays (Wait-MATContinue)

Several spots — the connection-required gate in every mode, Activator's
access-denied gate, the menu's invalid-selection case, the post-connect
summary — used a flat `Start-Sleep` of 2-3 seconds that couldn't be shortened
even after you'd already read the message. New `Wait-MATContinue`
(`Core\MAT_ConsoleUX.ps1`) waits for a keypress instead, so the pause lasts
exactly as long as the operator needs. It falls back to a short fixed delay
rather than blocking when the host isn't a real interactive console
(`[Console]::IsInputRedirected`, non-standard `$Host.Name`) or when
`RawUI.ReadKey()` throws despite looking interactive — a real compatibility
gap in some hosts (PowerShell ISE never implements `ReadKey()` at all).
While going through these, one genuinely redundant wait was also removed
outright: `Connect-MAT`'s error path had a 3-second `Start-Sleep` immediately
followed by the existing `Pause` call — pure dead time with no purpose, since
`Pause` was already going to wait for the operator right after it.
Menu selection itself is unchanged — still `Read-Host`, not single-keypress
navigation. That's a separate, genuinely open design question (real
compatibility trade-offs across PowerShell hosts) rather than a clear-cut fix
like the four above, so it wasn't included here.

---

## OUTPUTS

| File | Created by |
|------|-----------|
| `Auditor_Report.csv` | Auditor mode [1] and Super Auditor [4] |
| `Protector_Inventory.csv` | Protector mode [2] and Super Auditor [4] |
| `Defensive_Stack.csv` | Licensor mode [3] and Super Auditor [4] |
| `Licenses_Inventory.csv` | Licensor mode [3] and Super Auditor [4] |
| `MAT_Executive_Report_*.html` | Super Auditor [4] only |
| `MAT_Operational_Logs/*_OA.txt` | Every mode run (non-repudiation audit trail) |

---

## REFERENCES

- Microsoft SKU & Service Plan Reference:
  https://learn.microsoft.com/en-us/entra/identity/users/licensing-service-plan-reference

- Microsoft Incident Response — M365 Forensic Artifacts:
  https://go.microsoft.com/fwlink/?linkid=2257423

- Microsoft 365 License Matrix:
  https://m365maps.com/matrix.htm

- Purview Audit (Copilot — CopilotInteraction record type):
  https://learn.microsoft.com/en-us/purview/audit-copilot

- Purview Audit Premium (M365_ADVANCED_AUDITING):
  https://learn.microsoft.com/en-us/purview/audit-premium

- Create auditLogQuery (Microsoft Graph v1.0 — Purview Audit Search API):
  https://learn.microsoft.com/en-us/graph/api/security-auditcoreroot-post-auditlogqueries

- Search the audit log (current status of Get/Set-AdminAuditLogConfig and
  Search-UnifiedAuditLog vs. the Graph Audit Search API):
  https://learn.microsoft.com/en-us/purview/audit-search

- Microsoft-Extractor-Suite — Unified Audit Log via Graph API (`Get-UALGraph`),
  the tool this migration pass drew direct inspiration from:
  https://microsoft-365-extractor-suite.readthedocs.io/en/stable/functionality/M365/UnifiedAuditLogGraph.html

- Microsoft Graph throttling guidance (Retry-After / backoff — v1.5 retry helper):
  https://learn.microsoft.com/en-us/graph/throttling

- Privileged Identity Management (PIM) for Groups — how active vs. eligible group
  membership works, referenced by the v1.5 role-detection fix:
  https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/concept-pim-for-groups

- Monitoring Reader role (required for Entra diagnostic endpoint):
  https://learn.microsoft.com/en-us/azure/azure-monitor/roles-permissions-security

- PIM role activation:
  https://learn.microsoft.com/en-us/entra/id-governance/privileged-identity-management/pim-how-to-activate-role

- Defender for Identity licensing requirements:
  https://learn.microsoft.com/en-us/defender-for-identity/deploy/prerequisites

- Microsoft Defender for Cloud pricing / plans:
  https://azure.microsoft.com/en-us/pricing/details/defender-for-cloud/
