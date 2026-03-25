# Broadcom License Assessment Tool

![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue)
![VMware](https://img.shields.io/badge/VMware-vSphere%208%2B-green)
![License](https://img.shields.io/badge/License-MIT-yellow)
![Status](https://img.shields.io/badge/Status-Active-blue)
![Maintained](https://img.shields.io/badge/Maintained-Yes-brightgreen)
![Contributions](https://img.shields.io/badge/Contributions-Welcome-orange)

Automated PowerShell-based assessment tool for VMware environments, built to calculate licensing requirements under the Broadcom model for VCF, VVF, and vSAN.

Developed by [Juliano Cunha](https://github.com/julianscunha)

## Features

- Checks PowerShell, PowerCLI, execution policy, and session prerequisites
- Prompts to remediate blocking prerequisites in the same session
- Supports one or more vCenter environments in the same run
- Calculates:
  - VCF and VVF core requirements
  - Included vSAN entitlement
  - Additional vSAN Add-on requirements
- Collects current license assignments when requested
- Generates console, CSV, JSON, HTML, and optional PDF outputs
- Produces an executive dashboard-style report with formulas and per-environment calculation walkthrough

## Broadcom calculation model used

- Minimum **16 cores per physical CPU**
- **VCF** includes **1.00 TiB** of vSAN entitlement per licensed core
- **VVF** includes **0.25 TiB** of vSAN entitlement per licensed core
- vSAN Add-on is based on **raw physical capacity claimed by vSAN**
- For vSphere/vSAN **8.0 U3 and newer**, the report references the updated guidance path for claimed-capacity handling

## Usage

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\BroadcomLicenseAssessmentTool.ps1
```

Optional switches:

```powershell
.\BroadcomLicenseAssessmentTool.ps1 -TrustInvalidCertificates -CollectLicenseAssignments -ExportPdf -DisconnectWhenDone
```

## Output files

The script writes results into a timestamped output folder and typically produces:

- `broadcom-assessment-summary.json`
- `broadcom-assessment-environments.csv`
- `broadcom-assessment-license-assignments.csv`
- `broadcom-assessment-report.html`
- `broadcom-assessment-report.pdf` when PDF conversion is available

## Example output

See `EXAMPLE-OUTPUT-ADVANCED.md` and `EXAMPLE-OUTPUT-ADVANCED.html` for a sample dashboard-style report.

## Notes

- No permanent change is intended for vCenter or ESXi
- Session-only changes such as `ExecutionPolicy` or invalid-certificate handling are restored when possible
- The script is not officially affiliated with Broadcom or VMware

## License

MIT
