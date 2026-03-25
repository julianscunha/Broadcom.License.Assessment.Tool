# Veeam AsBuilt Unified

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)](https://github.com/julianscunha/veeam-asbuilt-unified)
[![Veeam](https://img.shields.io/badge/Veeam-VBR%20%7C%20VBM365-00B336)](https://github.com/julianscunha/veeam-asbuilt-unified)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](./LICENSE)
[![Maintained by Juliano Cunha](https://img.shields.io/badge/Maintained%20by-julianscunha-black)](https://github.com/julianscunha)

Unified PowerShell script to generate AsBuilt reports for:

- **VBR** — Veeam Backup & Replication
- **VBM365** — Veeam Backup for Microsoft 365

The script does **not auto-detect the product** by design. The user must explicitly choose whether the execution is for **VBR** or **VBM365**, and the script then follows the correct workflow for that product.

## Why this project exists

Veeam environments often require different PowerShell runtimes, modules, and connection methods depending on the product being documented. This script standardizes that process and adds:

- structured logging
- prerequisite validation
- controlled PowerShell relaunch when required
- automated AsBuilt module installation/import
- version validation before report generation

## Supported products

### VBR

Workflow for **Veeam Backup & Replication** using:

- `AsBuiltReport.Veeam.VBR`
- `Veeam.Backup.PowerShell.dll`
- `Connect-VBRServer`
- `Get-VBRBackupServerInfo`

### VBM365

Workflow for **Veeam Backup for Microsoft 365** using:

- `AsBuiltReport.Veeam.VB365`
- `Veeam.Archiver.PowerShell.dll`
- `Connect-VBOService`
- `Get-VBOServer`

## Requirements

### General

- Internet access to install required PowerShell modules from PSGallery, unless already installed.
- Permission to run PowerShell scripts.
- Local access to the target Veeam server or management console components.

### VBR requirements

- PowerShell **7 or later** for this script workflow.
- Veeam Backup & Replication installed.
- `Veeam.Backup.PowerShell.dll` present under the default VBR console path.
- Supported baseline in this script: **VBR 12+**.
- VBR 13+ is allowed, but logged as a warning because upstream module support may evolve.

### VBM365 requirements

- **Windows PowerShell 5.1**.
- Run the shell **as Administrator**.
- Veeam Backup for Microsoft 365 installed.
- `Veeam.Archiver.PowerShell.dll` present under the default VBM365 path.
- Supported baseline in this script: **VBM365 6+**.

## Features

- Explicit user selection between **VBR** and **VBM365**.
- Separate logic paths per product.
- Automatic installation of required AsBuilt dependencies.
- Structured UTF-8 log file.
- Log overwrite on fresh execution.
- Log preservation during internal PowerShell relaunch.
- Version validation before report generation.
- Optional silent mode for automation.

## Script behavior

When launched without `-Product`, the script prompts the user to choose:

- `1` for **VBR**
- `2` for **VBM365**

After that, it:

1. validates the PowerShell version for the chosen product
2. relaunches in the correct shell if needed
3. validates required modules and DLLs
4. connects to the selected Veeam product
5. validates the installed version
6. generates the AsBuilt report

## Usage

### Interactive mode

```powershell
.\veeam-asbuilt-unified.ps1
```

The script will ask which product to use.

### Explicit product selection

#### VBR

```powershell
.\veeam-asbuilt-unified.ps1 -Product VBR -Target localhost -OutputPath C:\Reports\VBR
```

#### VBM365

```powershell
.\veeam-asbuilt-unified.ps1 -Product VBM365 -Target localhost -OutputPath C:\Reports\VBM365
```

### Silent mode

#### VBR

```powershell
.\veeam-asbuilt-unified.ps1 -Product VBR -Target localhost -OutputPath C:\Reports\VBR -Silent
```

#### VBM365

```powershell
.\veeam-asbuilt-unified.ps1 -Product VBM365 -Target localhost -OutputPath C:\Reports\VBM365 -Silent
```

## Parameters

| Parameter | Description |
|---|---|
| `-Product` | Required in automation. Valid values: `VBR`, `VBM365` |
| `-Target` | Target server name. Default: `localhost` |
| `-OutputPath` | Directory where reports are generated |
| `-Silent` | Suppresses prompts and assumes yes for operational confirmations |
| `-Relaunched` | Internal parameter used by the script during shell relaunch |

## Log file

Default log location:

```text
%TEMP%\AsBuiltReport_Veeam_Unified.log
```

The log is overwritten at each fresh execution and preserved when the script internally relaunches itself in another PowerShell version.

## Output

Depending on the AsBuilt module behavior and installed dependencies, the script generates:

- **Word** report
- **HTML** report

under the selected output directory.

## Notes

- This script intentionally asks the user which product should be documented instead of trying to infer the product automatically.
- That behavior avoids ambiguous execution on servers where multiple Veeam products may coexist.
- Default DLL paths are based on standard installations. Adjust the script if your installation path differs.

## Recommended repository structure

```text
.
├── README.md
├── LICENSE
└── veeam-asbuilt-unified.ps1
```

## License

MIT

## Author

**Juliano Cunha**

GitHub: [`julianscunha`](https://github.com/julianscunha)
