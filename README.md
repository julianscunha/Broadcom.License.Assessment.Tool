# Broadcom License Assessment Tool

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![VMware](https://img.shields.io/badge/VMware-vSphere-green)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Status](https://img.shields.io/badge/Status-Active-brightgreen)
![Maintainer](https://img.shields.io/badge/Maintainer-julianscunha-black)

Interactive PowerShell tool for Broadcom / VMware license assessments.

It validates prerequisites, connects to one or more vCenter or ESXi endpoints, calculates VVF / VCF and vSAN Add-on requirements, and exports the result to HTML, JSON, CSV and, when supported by the local workstation, PDF.

## Features

- Comment-based help and `-Help` switch
- Interactive assessment of one or multiple environments
- Customer / company name stamped on the exported report
- PowerCLI bootstrap with install / update prompt
- Certificate handling with retry prompt
- vSAN raw capacity calculation
- Executive HTML report with dashboard cards and bars
- Optional PDF export with multiple fallbacks
- JSON, CSV and log export

## Usage

```powershell
Get-Help .\BroadcomLicenseAssessmentTool.ps1 -Full
.\BroadcomLicenseAssessmentTool.ps1
.\BroadcomLicenseAssessmentTool.ps1 -CustomerName "ACME Corp" -DeploymentType VVF -ExportPdf
.\BroadcomLicenseAssessmentTool.ps1 -TrustInvalidCertificates -DisconnectWhenDone
```

## Optional Parameters

- `-Help`
- `-CustomerName <string>`
- `-DeploymentType <VVF|VCF>`
- `-TrustInvalidCertificates`
- `-DisconnectWhenDone`
- `-ExportPdf`
- `-CollectLicenseAssignments`

## PDF Export Behavior

When `-ExportPdf` is used, the script tries the following in order:

1. Microsoft Word COM automation
2. Microsoft Edge headless print-to-pdf
3. Google Chrome headless print-to-pdf
4. `wkhtmltopdf`

If none of them is available, the HTML report is still generated and the script logs a warning instead of failing the assessment.

## Output Files

Exported files are written to the `output` folder in the current working directory.

The customer name is used in the file name whenever possible, for example:

- `ACME_Corp-Broadcom-License-Assessment.html`
- `ACME_Corp-Broadcom-License-Assessment.json`
- `ACME_Corp-Broadcom-License-Assessment-clusters.csv`
- `ACME_Corp-Broadcom-License-Assessment.log`

## Example Output

See:
- `EXAMPLE-OUTPUT.html`
- `EXAMPLE-OUTPUT.md`

## Notes

- Requires PowerShell 5.1 or later.
- Requires VMware PowerCLI 13.3 or later.
- The script does not make permanent changes to vCenter or ESXi.
- Temporary session changes may be applied to the local PowerShell session when the user confirms them.
