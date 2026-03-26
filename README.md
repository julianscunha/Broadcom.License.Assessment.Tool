# VMware Broadcom License Assessment Tool

Automated PowerShell-based assessment tool for VMware environments, designed to calculate licensing requirements under Broadcom's subscription model for **VMware Cloud Foundation (VCF)**, **vSphere Foundation (VVF)**, and **vSAN Add-on**.

Developed by [Juliano Cunha](https://github.com/julianscunha).

## Overview

This script connects to one or more vCenter environments, validates local prerequisites, inspects clusters and hosts, calculates licensing needs based on Broadcom public guidance, and generates both technical and executive-friendly outputs.

It is intended for consultants, partners, pre-sales engineers, architects, and administrators who need a repeatable way to assess environments and prepare licensing discussions or commercial proposals.

## Key Features

- Validates local prerequisites before assessment starts:
  - PowerShell version
  - VMware PowerCLI availability and version
  - execution policy suitability
  - session-only certificate handling when required
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
- Detects and flags environments that may require updated logic for **vSphere / vSAN 8.0 U3+**
- Optionally collects current license assignments and inventory details
- Highlights licensing risks in the current environment, including:
  - expired licenses
  - licenses approaching expiration
  - evaluation mode usage
  - objects without license assignment
- Produces multiple output formats:
  - console summary
  - log file
  - CSV
  - JSON
  - HTML
  - PDF (best-effort, depending on local conversion capability)
- Creates a more executive-style report suitable for customer-facing review

## Licensing Logic

The script follows Broadcom public guidance referenced in knowledge base articles related to VCF/VVF sizing and licensing calculations.

Core assumptions implemented in the script:

- Each physical CPU is counted with a **minimum of 16 cores**
- vSAN licensing is based on **raw physical claimed capacity**, not usable capacity
- Included vSAN entitlement depends on the selected subscription model:
  - **VCF**: 1 TiB per licensed core
  - **VVF**: 0.25 TiB per licensed core
- When environment data is inconsistent (for example, possible stale devices or storage health issues), the script attempts to keep the assessment usable and records warnings in the final report

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- VMware PowerCLI 13.3 or later
- Network connectivity to the target vCenter(s)
- Credentials with sufficient read permissions to collect inventory and licensing information

## Safety and Change Control

This tool is designed to avoid permanent changes.

- `ExecutionPolicy` adjustments are only made in **Process** scope
- certificate handling changes are session-scoped whenever possible
- no configuration changes are made to vCenter, ESXi, vSAN, or workloads
- temporary changes made by the script are tracked and included in the final report
- the script attempts to restore temporary session settings at the end of execution

## Basic Usage

```powershell
.\Invoke-BroadcomLicenseAssessment-GitHub.ps1
```

Example with optional switches:

```powershell
.\Invoke-BroadcomLicenseAssessment-GitHub.ps1 -TrustInvalidCertificates -DisconnectWhenDone -ExportPdf -CollectLicenseAssignments
```

## Optional Parameters

- `-OutputFolder`
  - Sets a custom output path
- `-ConfigFile`
  - Allows loading pre-defined environment input from a file
- `-ExportPdf`
  - Attempts PDF export in addition to HTML
- `-CollectLicenseAssignments`
  - Collects current licensing assignments and license inventory
- `-TrustInvalidCertificates`
  - Allows temporary handling of self-signed / untrusted certificates during the session
- `-DisconnectWhenDone`
  - Disconnects active PowerCLI sessions at the end
- `-SkipPrereqInstallHints`
  - Reduces prerequisite guidance prompts
- `-UseTranscript`
  - Enables PowerShell transcript logging when supported

## Execution Policy Behavior

You do **not** have to run `Set-ExecutionPolicy` manually before launching the script.

At the start of execution, the script checks whether the current session is allowed to run as expected. If not, it can prompt the user to apply:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
```

This is temporary and only affects the current PowerShell session.

## Interactive Flow

During execution, the script can prompt for:

1. friendly environment name
2. vCenter FQDN or IP
3. target licensing model (`VCF` or `VVF`)
4. whether to assess all clusters or a specific cluster
5. whether another environment should be added to the same run

## Generated Outputs

The script creates an output folder containing files such as:

- `assessment.log`
- `clusters.csv`
- `hosts.csv`
- `summary.csv`
- `license-assignments.csv` *(when collected)*
- `license-inventory.csv` *(when collected)*
- `assessment.json`
- `assessment-report.html`
- `assessment-report.pdf` *(if conversion succeeds)*

## Report Highlights

The HTML/PDF report is organized for easier executive consumption and typically includes:

- assessment summary
- environment-by-environment overview
- required VCF/VVF core quantities
- included vSAN entitlement
- raw vSAN capacity identified
- required vSAN Add-on quantities
- current license status overview
- possible unlicensed objects
- expiration risk indicators
- temporary runtime changes performed by the script
- technical notes and warnings

## Typical Use Cases

- pre-sales licensing assessments
- customer environment discovery
- migration planning to Broadcom subscriptions
- internal compliance reviews
- proposal preparation support

## Disclaimer

This project is **not officially affiliated with Broadcom or VMware**.
It is an independent community tool based on publicly available documentation and operational interpretation of those materials.

Always validate final commercial quantities with your own licensing team, distributor, or official Broadcom guidance before issuing a binding proposal.

## Contributing

Issues, suggestions, and pull requests are welcome.

If you improve support for additional scenarios, reports, or validation logic, contributions back to the project are encouraged.

## License

This project is released under the **MIT License**. See the [LICENSE](LICENSE) file for details.


## Example Output

- Public dashboard sample: [EXAMPLE-OUTPUT.html](./EXAMPLE-OUTPUT.html)
- Public markdown sample: [EXAMPLE-OUTPUT.md](./EXAMPLE-OUTPUT.md)
