# Broadcom License Assessment Tool

Enterprise PowerShell assessment tool for Broadcom / VMware licensing.

It connects to one or more vCenter / ESXi endpoints, calculates required compute cores, estimates bundled raw vSAN entitlement, evaluates vSAN Add-on exposure, optionally collects visible license inventory, and produces executive-ready HTML, JSON, CSV, LOG, and optional PDF outputs.

## Main capabilities

- Interactive prerequisite validation
- PowerCLI bootstrap and module installation flow
- Certificate retry prompt for lab or internal PKI environments
- Multi-environment assessment in a single run
- Executive HTML report with Gartner-style layout
- Risk score, decision guidance, and business interpretation
- Financial comparison between **VVF** and **VCF**
- Optional rough commercial estimate using operator-supplied unit prices
- License inventory table when exposed by the connected endpoint
- Final disconnect from active VIServer sessions

## Parameters

- `-CustomerName <string>` customer or company name displayed in outputs
- `-DeploymentType <VVF|VCF>` default model used for the connected environment prompt
- `-TrustInvalidCertificates` ignore invalid certificates automatically for the current session
- `-DisconnectWhenDone <bool>` default `True`
- `-ExportPdf` export PDF when local prerequisites are available
- `-CollectLicenseAssignments <bool>` default `True`
- `-EstimatedCurrency <string>` currency label used in all estimate fields. Use **one currency consistently** across all estimate parameters, for example `BRL`, `USD`, or `EUR`
- `-EstimatedPricePerCore <decimal>` fallback per-core unit price used for both VVF and VCF when model-specific core prices are not supplied
- `-EstimatedPricePerCoreVVF <decimal>` optional VVF-specific per-core unit price
- `-EstimatedPricePerCoreVCF <decimal>` optional VCF-specific per-core unit price
- `-EstimatedPricePerTiBAddon <decimal>` vSAN Add-on per-TiB unit price

## Financial comparison logic

The report calculates a rough commercial comparison using the provided pricing inputs:

- **VVF included raw vSAN entitlement** = `RequiredComputeCores * 0.25 TiB`
- **VCF included raw vSAN entitlement** = `RequiredComputeCores * 1.0 TiB`
- **Required vSAN Add-on TiB** = `max(raw vSAN TiB - included entitlement, 0)`, rounded up to whole TiB
- **Estimated total cost** = `Core cost + Add-on cost`

This comparison is intended for proposal shaping, not as an official price quote.

## Example commands

```powershell
Get-Help .\BroadcomLicenseAssessmentTool.ps1 -Full

.\BroadcomLicenseAssessmentTool.ps1 `
  -CustomerName "Comerc" `
  -EstimatedCurrency BRL `
  -EstimatedPricePerCoreVVF 125 `
  -EstimatedPricePerCoreVCF 165 `
  -EstimatedPricePerTiBAddon 450 `
  -ExportPdf
```

## Output files

The script writes files to `output` under the current working directory:

- `Customer-Broadcom-License-Assessment.html`
- `Customer-Broadcom-License-Assessment.json`
- `Customer-Broadcom-License-Assessment-clusters.csv`
- `Customer-Broadcom-License-Assessment.log`
- `Customer-Broadcom-License-Assessment.pdf` when PDF export succeeds

## Notes

- License inventory depends on what the connected endpoint exposes and what the credential is authorized to read
- Financial results are heuristic and depend entirely on the operator-supplied pricing inputs
- The feature-fit recommendation between VVF and VCF is advisory, not contractual
