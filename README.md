
# Broadcom License Assessment Tool

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![VMware](https://img.shields.io/badge/VMware-vSphere-green)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Status](https://img.shields.io/badge/Status-Enterprise--Ready-brightgreen)

Interactive PowerShell assessment tool for Broadcom / VMware licensing with executive-ready reporting.

## What it does

- Validates PowerShell / PowerCLI prerequisites
- Connects to one or more vCenter / ESXi endpoints
- Calculates required licensable compute cores
- Calculates bundled vSAN entitlement for VVF or VCF
- Measures visible raw vSAN footprint
- Calculates required vSAN Add-on capacity
- Optionally collects license inventory from the endpoint
- Produces Gartner-style HTML output for executive / sales review
- Exports JSON, CSV, LOG, and optional PDF

## Key enterprise features

- Interactive certificate handling
- Customer name stamping in output files
- Risk score for executive consumption
- Heuristic VVF vs VCF recommendation
- Optional commercial estimate inputs:
  - `-EstimatedPricePerCore`
  - `-EstimatedPricePerTiBAddon`
- Clean final log output
- Automatic disconnect at the end by default

## Parameters

- `-Help`
- `-CustomerName <string>`
- `-DeploymentType <VVF|VCF>`
- `-TrustInvalidCertificates`
- `-DisconnectWhenDone <bool>`
- `-ExportPdf`
- `-CollectLicenseAssignments <bool>`
- `-EstimatedPricePerCore <decimal>`
- `-EstimatedPricePerTiBAddon <decimal>`

## Example usage

```powershell
Get-Help .\BroadcomLicenseAssessmentTool.ps1 -Full

.\BroadcomLicenseAssessmentTool.ps1 `
  -CustomerName "ACME Corp" `
  -DeploymentType VVF `
  -ExportPdf

.\BroadcomLicenseAssessmentTool.ps1 `
  -CustomerName "ACME Corp" `
  -DeploymentType VCF `
  -EstimatedPricePerCore 125 `
  -EstimatedPricePerTiBAddon 450
```

## Output

The tool writes files to the `output` folder in the current working directory:

- `Customer-Broadcom-License-Assessment.html`
- `Customer-Broadcom-License-Assessment.json`
- `Customer-Broadcom-License-Assessment-clusters.csv`
- `Customer-Broadcom-License-Assessment.log`
- `Customer-Broadcom-License-Assessment.pdf` when PDF export succeeds

## VCF vs VVF note

The recommendation is heuristic. It uses signals visible from the connected endpoint, primarily:

- licensable compute cores
- bundled vSAN entitlement
- visible raw vSAN footprint
- optional license inventory exposure

It does **not** claim authoritative feature detection for products not directly surfaced by the endpoint.

## Example output files

- `EXAMPLE-OUTPUT.html`
- `EXAMPLE-OUTPUT.md`
- `EXAMPLE-OUTPUT-Internal.html`
- `EXAMPLE-OUTPUT-Internal.md`
