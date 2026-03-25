# VMware Broadcom License Assessment Tool

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![VMware](https://img.shields.io/badge/VMware-vSphere%208%2B-green)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Status](https://img.shields.io/badge/Status-Active-blue)
![Maintained](https://img.shields.io/badge/Maintained-Yes-brightgreen)
![Contributions](https://img.shields.io/badge/Contributions-Welcome-orange)
![GitHub](https://img.shields.io/badge/GitHub-julianscunha-black)

Automated PowerShell-based assessment tool for VMware environments, built to calculate licensing requirements under Broadcom's subscription model for **VMware Cloud Foundation (VCF)**, **VMware vSphere Foundation (VVF)**, and **vSAN Add-on**.

Developed by [Juliano Cunha](https://github.com/julianscunha).

## Overview

This tool connects to one or more vCenter environments, validates local prerequisites, inspects clusters and hosts, calculates licensing needs according to Broadcom public guidance, checks the current licensing state, and generates both technical artifacts and an executive dashboard report.

It is intended for consultants, partners, pre-sales engineers, architects, and administrators who need a repeatable way to assess environments and prepare licensing discussions or commercial proposals.

## What the tool does

- Validates local prerequisites before the assessment starts:
  - PowerShell version
  - VMware PowerCLI availability and version
  - execution policy suitability
  - temporary certificate handling when required
- Safely handles `ExecutionPolicy` in **Process** scope only, with user confirmation
- Supports **multiple environments / multiple vCenters** in a single run
- Calculates required licensing for:
  - **VCF core licenses**
  - **VVF core licenses**
  - **vSAN Add-on TiB**
- Applies Broadcom-aligned logic such as:
  - **minimum 16 cores per physical CPU**
  - **vSAN raw physical capacity** as the licensing basis
  - VCF entitlement of **1 TiB per core**
  - VVF entitlement of **0.25 TiB per core**
- Detects current licensing information when available:
  - license assignments
  - expired licenses
  - licenses expiring in 30/90 days
  - evaluation mode
  - unlicensed objects
- Generates a dashboard-style HTML report and can optionally convert it to PDF
- Exports JSON and CSV outputs for deeper technical analysis

## Dashboard-style reporting

The advanced HTML/PDF report includes:

- executive KPI cards
- visual capacity bars for compute, entitlement, raw vSAN, and additional add-on need
- cluster-by-cluster breakdown
- host-by-host breakdown
- explicit calculation walkthrough tables
- clear statement of the active rule set and formulas used
- warning and caveat section
- reference section with the Broadcom KBs used by the script

See the included examples:

- [Advanced markdown example](EXAMPLE-OUTPUT-ADVANCED.md)
- [Advanced HTML example](EXAMPLE-OUTPUT-ADVANCED.html)

## Licensing model implemented

The current rule set embedded in the script is based on Broadcom public guidance:

- **Compute cores per host** = physical CPU sockets × `max(actual cores per CPU, 16)`
- **Environment compute total** = sum of licensed cores across all hosts
- **VCF included vSAN entitlement** = compute cores × `1.00 TiB`
- **VVF included vSAN entitlement** = compute cores × `0.25 TiB`
- **vSAN Add-on required** = `max( ceil(raw vSAN TiB - floor(included entitlement TiB)), 0 )`

The tool also includes the updated path for **vSphere / vSAN 8.0 U3 and later**, where the older direct claimed-capacity API path is no longer valid.

## Requirements

- PowerShell 5.1 or later
- VMware PowerCLI 13.3 or later
- Network access to the target vCenter Server(s)
- Sufficient privileges in vCenter to read inventory, cluster, host, vSAN, and license information
- For PDF export:
  - Microsoft Edge or Google Chrome in headless mode, or
  - Microsoft Word COM automation as a fallback

## Typical usage

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Invoke-BroadcomLicenseAssessment-GitHub-Advanced.ps1 -TrustInvalidCertificates -CollectLicenseAssignments -DisconnectWhenDone -ExportPdf
```

You can also run without the temporary execution policy change if your system policy already allows local scripts.

## Output files

Typical output folder contents:

- `assessment-data.json`
- `clusters.csv`
- `hosts.csv`
- `license-assignments.csv`
- `license-inventory.csv`
- `assessment-report.html`
- `assessment-report.pdf` *(optional)*
- `execution.log`

## Safety and runtime behavior

- No permanent changes are made to the virtualized environment
- Session-only changes can be applied when needed, with user confirmation:
  - `ExecutionPolicy` in **Process** scope only
  - temporary PowerCLI invalid certificate handling
- The script attempts to restore temporary session settings at the end of the run
- Any temporary changes are listed in the final report

## Reference KBs

- Broadcom KB 312202 — License calculator for VCF, VVF and vSAN
- Broadcom KB 313548 — Counting cores for VCF/VVF and TiBs for vSAN
- Broadcom KB 400416 — Updated script path for vSphere / vSAN 8.0 U3

## Repository structure suggestion

```text
.
├── Invoke-BroadcomLicenseAssessment-GitHub-Advanced.ps1
├── README.md
├── LICENSE
├── EXAMPLE-OUTPUT-ADVANCED.md
└── EXAMPLE-OUTPUT-ADVANCED.html
```

## Disclaimer

This project is **not officially affiliated with Broadcom or VMware**. It is an independent community tool based on publicly available documentation and implementation best practices.

Always validate the final commercial position with an authorized partner or with Broadcom when required.

## Contributing

Contributions are welcome through issues and pull requests.
