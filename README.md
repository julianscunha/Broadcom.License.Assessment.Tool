
# Broadcom License Assessment Tool

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![VMware](https://img.shields.io/badge/VMware-vSphere-green)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Status](https://img.shields.io/badge/Status-Active-brightgreen)
![Maintainer](https://img.shields.io/badge/Maintainer-julianscunha-black)

Interactive PowerShell tool for Broadcom / VMware license assessments.

It validates prerequisites, connects to one or more vCenter or ESXi endpoints, calculates VVF / VCF and vSAN Add-on requirements, collects license inventory by default, adds a heuristic VCF-versus-VVF suitability narrative to the exported report, and exports the result to HTML, JSON, CSV and, when supported by the local workstation, PDF.

## Features

- Comment-based help and `-Help` switch
- Interactive assessment of one or multiple environments
- Customer / company name stamped on the exported report
- PowerCLI bootstrap with install / update prompt
- Certificate handling with retry prompt
- `CollectLicenseAssignments` enabled by default
- Auto-disconnect from vCenter / ESXi at the end by default
- Risk score in the report and console summary
- Executive HTML report with dashboard cards, bars, executive summary, findings, recommendations, and VCF versus VVF suitability section
- Optional PDF export with multiple fallbacks
- JSON, CSV and log export

## Usage

```powershell
Get-Help .\BroadcomLicenseAssessmentTool.ps1 -Full
.\BroadcomLicenseAssessmentTool.ps1
.\BroadcomLicenseAssessmentTool.ps1 -CustomerName "ACME Corp" -DeploymentType VVF -ExportPdf
.\BroadcomLicenseAssessmentTool.ps1 -TrustInvalidCertificates
.\BroadcomLicenseAssessmentTool.ps1 -DisconnectWhenDone:$false
```

## Parameters

- `-Help`
- `-CustomerName <string>`
- `-DeploymentType <VVF|VCF>`
- `-TrustInvalidCertificates`
- `-DisconnectWhenDone <bool>` default `True`
- `-ExportPdf`
- `-CollectLicenseAssignments <bool>` default `True`

## PDF Export Behavior

When `-ExportPdf` is used, the script tries the following in order:

1. Microsoft Word COM automation
2. Microsoft Edge headless print-to-pdf
3. Google Chrome headless print-to-pdf
4. `wkhtmltopdf`

If none of them is available, the HTML report is still generated and the script logs a warning instead of failing the assessment.

## VCF vs VVF Suitability

The report contains a suitability section that compares VCF and VVF based on signals observable from the connected vCenter / ESXi environment, mainly compute sizing and raw vSAN footprint. This section is intentionally heuristic and does **not** prove usage of products or features that are not directly surfaced through the connected endpoint, such as NSX, SDDC Manager, HCX, Aria, or Tanzu.

## Output Files

Exported files are written to the `output` folder in the current working directory.

Typical file set:

- `ACME_Corp-Broadcom-License-Assessment.html`
- `ACME_Corp-Broadcom-License-Assessment.pdf`
- `ACME_Corp-Broadcom-License-Assessment.json`
- `ACME_Corp-Broadcom-License-Assessment-clusters.csv`
- `ACME_Corp-Broadcom-License-Assessment.log`

## Example Output

See:
- [EXAMPLE-OUTPUT.html](sandbox:/mnt/data/EXAMPLE-OUTPUT.html)
- [EXAMPLE-OUTPUT.md](sandbox:/mnt/data/EXAMPLE-OUTPUT.md)
