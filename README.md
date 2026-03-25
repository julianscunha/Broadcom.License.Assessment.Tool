# VMware Broadcom License Assessment Tool

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![VMware](https://img.shields.io/badge/VMware-vSphere%207%2F8-green)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Status](https://img.shields.io/badge/Status-Active-blue)
![Contributions](https://img.shields.io/badge/Contributions-Welcome-orange)
![GitHub](https://img.shields.io/badge/GitHub-julianscunha-black)

Automated PowerShell-based assessment tool for VMware environments, designed to calculate licensing requirements under Broadcom's subscription model for **VMware Cloud Foundation (VCF)**, **VMware vSphere Foundation (VVF)**, and **vSAN Add-on**.

Developed by [Juliano Cunha](https://github.com/julianscunha).

## What this tool does

This script connects to one or more vCenter environments, validates local prerequisites, optionally bootstraps missing PowerCLI requirements in the **same PowerShell session**, collects inventory and licensing data, applies Broadcom-aligned licensing rules, and produces both technical and executive-style outputs.

It is intended for consultants, partners, architects, administrators, and pre-sales teams that need a repeatable way to assess environments and prepare licensing discussions or commercial proposals.

## Key capabilities

- Validates local prerequisites before the assessment starts:
  - PowerShell version
  - execution policy suitability
  - VMware PowerCLI presence and version
  - VMware.VimAutomation.Core availability
- Can **prompt to remediate prerequisites automatically** in the current session:
  - temporary `ExecutionPolicy` adjustment in **Process** scope only
  - temporary TLS 1.2 enablement for package download
  - temporary trust of `PSGallery` during installation
  - installation or update of `VMware.PowerCLI` in `CurrentUser` scope
- Supports **multiple environments / multiple vCenters** in one run
- Calculates required licensing for:
  - **VCF core licenses**
  - **VVF core licenses**
  - **vSAN Add-on TiB**
- Applies Broadcom-aligned logic such as:
  - **minimum 16 cores per physical CPU**
  - **vSAN raw physical claimed capacity** as the licensing basis
  - **VCF entitlement = 1 TiB per licensed core**
  - **VVF entitlement = 0.25 TiB per licensed core**
- Detects environments that may require the **updated 8.0 U3+ logic path**
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
  - HTML dashboard-style report
  - PDF (best effort, depending on local conversion capability)

## Broadcom guidance implemented

This tool is based on Broadcom public guidance, including:

- **KB 312202**: the calculator workflow requires **VMware PowerCLI 13.3 or later** and uses the CSV/script model for VCF/VVF simulations.
- **KB 313548**: VCF/VVF licensing is based on total physical CPU cores with a **minimum of 16 cores per physical CPU**, while vSAN licensing is based on **raw physical storage contributed to vSAN**.
- **KB 313548** also states that VCF includes **1 TiB of vSAN entitlement per licensed core** and VVF includes **0.25 TiB per licensed core**.
- **KB 400416** is the updated path for environments running **8.0 U3**, where the older claimed-capacity script path can fail.

## Safety and change control

The script is designed to avoid permanent changes to vCenter, ESXi, clusters, storage, or workloads.

Temporary and user-approved local changes may be made on the **machine running the script**:

- `ExecutionPolicy` changes are only applied in **Process** scope
- TLS protocol changes are **session-only**
- `PSGallery` trust is changed only temporarily and restored at the end
- `InvalidCertificateAction` for PowerCLI is set in **Session** scope only when requested

Persistent local changes can occur **only if you approve them**:

- installation or update of `VMware.PowerCLI` in `CurrentUser` scope
- installation of the `NuGet` package provider if missing

If PowerCLI needs a fresh PowerShell session after installation, the script can either try to relaunch itself or clearly instruct the user to run it again.

## Requirements

- Windows PowerShell 5.1+ or PowerShell 7+
- Network connectivity to the target vCenter(s)
- Credentials with sufficient read permissions to collect inventory and licensing information
- Internet access to the PowerShell Gallery if PowerCLI bootstrap is needed

## Basic usage

```powershell
.\BroadcomLicenseAssessmentTool.ps1
```

Example with optional switches:

```powershell
.\BroadcomLicenseAssessmentTool.ps1 -TrustInvalidCertificates -DisconnectWhenDone -ExportPdf -CollectLicenseAssignments
```

## Typical execution flow

1. The script shows the startup banner.
2. It validates PowerShell, execution policy, and PowerCLI prerequisites.
3. If the execution policy is not suitable, it asks whether it can apply `Bypass` in **Process** scope only.
4. If PowerCLI is missing or older than **13.3**, it asks whether it can bootstrap the requirements in the same session.
5. It connects to each vCenter, collects host, cluster, vSAN, and licensing data.
6. It applies the licensing formulas and builds a consolidated summary.
7. It writes log, CSV, JSON, HTML, and optional PDF outputs.
8. It restores temporary session changes.

## Licensing formulas used

### Compute licensing

For each host:

- Count physical CPUs (sockets)
- Count physical cores per CPU
- Apply the **16-core minimum per CPU**

Formula:

```text
Licensed cores per host = CPU sockets × max(actual cores per CPU, 16)
```

Cluster total:

```text
Cluster compute cores = sum(licensed cores per host)
```

### vSAN licensing

For each vSAN cluster:

- Measure **raw physical capacity** contributed by all hosts
- Convert to TiB

Formula:

```text
Required raw vSAN TiB = sum(raw contributed capacity across all hosts)
```

### Included vSAN entitlement

- **VCF**: `licensed cores × 1.0 TiB`
- **VVF**: `licensed cores × 0.25 TiB`

### vSAN Add-on requirement

```text
vSAN Add-on required = max(ceil(raw vSAN TiB) - floor(included entitlement TiB), 0)
```

## Output files

The tool can generate:

- `assessment.log`
- `clusters.csv`
- `hosts.csv`
- `licenses.csv`
- `license-inventory.csv`
- `summary.csv`
- `assessment.json`
- `assessment.html`
- `assessment.pdf` (best effort)

## Example output

See the advanced examples in:

- `EXAMPLE-OUTPUT-ADVANCED.html`
- `EXAMPLE-OUTPUT-ADVANCED.md`

## Notes

- When the environment reports inconsistent storage health, the script records warnings and keeps the assessment readable whenever possible.
- For 8.0 U3+ environments, the report highlights that the updated KB 400416 approach should be used.
- This project is not affiliated with Broadcom or VMware.

## Contributing

Contributions are welcome. Issues, pull requests, and improvement ideas are encouraged.

## License

MIT License. See the `LICENSE` file.
