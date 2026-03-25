# =========================================
# Veeam AsBuilt Unified Tool
# Author: Juliano Cunha
# GitHub: https://github.com/julianscunha
# Repository: https://github.com/julianscunha/veeam-asbuilt-unified
# Description: Unified automation script to generate AsBuilt reports for
#              Veeam Backup & Replication (VBR) and
#              Veeam Backup for Microsoft 365 (VBM365)
# License: MIT
# =========================================

<#
.SYNOPSIS
Unified AsBuiltReport launcher for Veeam Backup & Replication (VBR) and
Veeam Backup for Microsoft 365 (VBM365 / VB365).

.DESCRIPTION
This script prepares the required PowerShell environment, validates the target
Veeam product selected by the user, installs/imports the required AsBuiltReport
modules, loads the correct Veeam PowerShell module, validates the detected
version, and generates the report.

.PARAMETER Product
Target Veeam product. Valid values: VBR, VBM365.
If omitted in interactive mode, the script prompts the user.

.PARAMETER Target
Target server name. Default: localhost.

.PARAMETER OutputPath
Output folder path. If omitted, a temporary folder is used.

.PARAMETER Silent
Runs without interactive confirmations where possible.

.PARAMETER Relaunched
Internal parameter used when the script relaunches itself in the required
PowerShell version.
#>

[CmdletBinding()]
param(
    [ValidateSet('VBR','VBM365')]
    [string]$Product,

    [string]$Target = 'localhost',

    [string]$OutputPath = '',

    [switch]$Silent,

    [int]$Relaunched = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ------------------------------
# LOG CONTROL
# ------------------------------
$logFile = Join-Path $env:TEMP 'AsBuiltReport_Veeam_Unified.log'

if ($Relaunched -eq 0) {
    if (Test-Path $logFile) {
        Remove-Item $logFile -Force
    }
    New-Item -ItemType File -Path $logFile -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('INFO','SUCCESS','WARNING','ERROR','DEBUG')]
        [string]$Level = 'INFO',

        [int]$Indent = 0
    )

    $prefix = ' ' * ($Indent * 2)
    $tag = switch ($Level) {
        'INFO'    { '[INFO]   ' }
        'SUCCESS' { '[OK]     ' }
        'WARNING' { '[WARN]   ' }
        'ERROR'   { '[ERROR]  ' }
        'DEBUG'   { '[DEBUG]  ' }
    }

    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $tag$prefix$Message"
    Write-Host $line
    $line | Out-File -FilePath $logFile -Append -Encoding utf8
}

function Stop-Script {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Log -Message $Message -Level ERROR
    if (-not $Silent) {
        Read-Host 'Press ENTER to exit' | Out-Null
    }
    exit 1
}

function Confirm-Action {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Silent) {
        return $true
    }

    $response = Read-Host "$Message (Y/N)"
    return $response -match '^[Yy]$'
}

function Ensure-Directory {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path $Path)) {
        if (Confirm-Action "Directory '$Path' does not exist. Create it") {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Log -Message "Directory created: $Path" -Level SUCCESS -Indent 1
        }
        else {
            Stop-Script -Message "Output directory does not exist: $Path"
        }
    }
}

function Ensure-Module {
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        Write-Log -Message "Installing module: $Name" -Level INFO -Indent 1
        Install-Module -Name $Name -Scope CurrentUser -Force -AllowClobber
    }

    Import-Module $Name -Force
    Write-Log -Message "Module loaded: $Name" -Level SUCCESS -Indent 1
}

function Ensure-Admin {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if (-not $isAdmin) {
        Stop-Script -Message 'This operation requires an elevated PowerShell session (Run as Administrator).'
    }

    Write-Log -Message 'Running with administrative privileges.' -Level SUCCESS -Indent 1
}

function Restart-InPowerShell7 {
    $pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
    if (-not (Test-Path $pwsh)) {
        Stop-Script -Message 'PowerShell 7 was not found at the default path.'
    }

    $argList = @(
        '-NoExit'
        '-File'
        ('"{0}"' -f $PSCommandPath)
        '-Product'
        $Product
        '-Target'
        ('"{0}"' -f $Target)
        '-OutputPath'
        ('"{0}"' -f $OutputPath)
        '-Relaunched'
        '1'
    )

    if ($Silent) {
        $argList += '-Silent'
    }

    $argString = $argList -join ' '
    Write-Log -Message 'Relaunching in PowerShell 7.' -Indent 1
    Start-Process -FilePath $pwsh -ArgumentList $argString
    exit 0
}

function Restart-InWindowsPowerShell {
    $powershellExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path $powershellExe)) {
        Stop-Script -Message 'Windows PowerShell 5.1 was not found at the default path.'
    }

    $argList = @(
        '-NoExit'
        '-File'
        ('"{0}"' -f $PSCommandPath)
        '-Product'
        $Product
        '-Target'
        ('"{0}"' -f $Target)
        '-OutputPath'
        ('"{0}"' -f $OutputPath)
        '-Relaunched'
        '1'
    )

    if ($Silent) {
        $argList += '-Silent'
    }

    $argString = $argList -join ' '
    Write-Log -Message 'Relaunching in Windows PowerShell 5.1.' -Indent 1
    Start-Process -FilePath $powershellExe -ArgumentList $argString
    exit 0
}

function Get-VbrVersion {
    $info = Get-VBRBackupServerInfo
    Write-Log -Message 'VBR server information returned:' -Level DEBUG -Indent 1
    Write-Log -Message ($info | Format-Table | Out-String).TrimEnd() -Level DEBUG -Indent 2

    $version = $info.Build
    if (-not $version) {
        throw 'Build field was not returned by Get-VBRBackupServerInfo.'
    }

    return [version]$version
}

function Get-Vbm365Version {
    $server = Get-VBOServer
    Write-Log -Message 'VBM365 server information returned:' -Level DEBUG -Indent 1
    Write-Log -Message ($server | Format-Table | Out-String).TrimEnd() -Level DEBUG -Indent 2

    $rawVersion = $null
    if ($server.PSObject.Properties.Name -contains 'Version') {
        $rawVersion = $server.Version
    }
    if (-not $rawVersion -and $server.PSObject.Properties.Name -contains 'Build') {
        $rawVersion = $server.Build
    }

    if (-not $rawVersion) {
        $serialized = $server | Out-String
        if ($serialized -match '\d+\.\d+\.\d+(\.\d+)?') {
            $rawVersion = $matches[0]
        }
    }

    if (-not $rawVersion) {
        throw 'No version/build information was returned by Get-VBOServer.'
    }

    return [version]$rawVersion
}

# ------------------------------
# START
# ------------------------------
Write-Log -Message '===== START ====='

if (-not $Product) {
    if ($Silent) {
        Stop-Script -Message 'Parameter -Product is required when using -Silent. Valid values: VBR or VBM365.'
    }

    Write-Host ''
    Write-Host 'Select the Veeam product to document:'
    Write-Host '  1 - VBR (Veeam Backup & Replication)'
    Write-Host '  2 - VBM365 (Veeam Backup for Microsoft 365)'
    $selection = Read-Host 'Option'

    switch ($selection) {
        '1' { $Product = 'VBR' }
        '2' { $Product = 'VBM365' }
        default { Stop-Script -Message 'Invalid product selection.' }
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $env:TEMP ('AsBuiltReport_{0}' -f $Product)
}

Write-Log -Message 'Execution context'
Write-Log -Message "Selected product: $Product" -Indent 1
Write-Log -Message "Target: $Target" -Indent 1
Write-Log -Message "Output path: $OutputPath" -Indent 1
Write-Log -Message "Relaunched: $Relaunched" -Indent 1
Write-Log -Message "Silent mode: $Silent" -Indent 1

$psMajor = $PSVersionTable.PSVersion.Major
Write-Log -Message 'PowerShell validation'
Write-Log -Message ("Detected version: {0}" -f $PSVersionTable.PSVersion.ToString()) -Indent 1

Write-Log -Message 'PowerShell Gallery prerequisites'
try {
    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force | Out-Null
        Write-Log -Message 'NuGet provider installed.' -Level SUCCESS -Indent 1
    }
    else {
        Write-Log -Message 'NuGet provider already available.' -Level SUCCESS -Indent 1
    }

    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        Write-Log -Message 'PSGallery marked as Trusted.' -Level SUCCESS -Indent 1
    }
    catch {
        Write-Log -Message 'Could not update PSGallery trust policy. Continuing.' -Level WARNING -Indent 1
    }
}
catch {
    Stop-Script -Message "Failed to prepare PowerShell Gallery prerequisites: $_"
}

Ensure-Directory -Path $OutputPath

switch ($Product) {
    'VBR' {
        Write-Log -Message 'Preparing VBR workflow'

        if ($psMajor -lt 7) {
            Write-Log -Message 'VBR requires PowerShell 7+ in this script.' -Level WARNING -Indent 1
            if (Confirm-Action 'Relaunch in PowerShell 7 now') {
                Restart-InPowerShell7
            }
            else {
                Stop-Script -Message 'Execution cancelled because PowerShell 7 is required for the VBR workflow.'
            }
        }

        $vbrRoot = 'C:\Program Files\Veeam\Backup and Replication'
        $vbrDll = Join-Path $vbrRoot 'Console\Veeam.Backup.PowerShell.dll'

        if (-not (Test-Path $vbrDll)) {
            Stop-Script -Message "VBR PowerShell DLL not found: $vbrDll"
        }

        Write-Log -Message 'Loading AsBuilt modules for VBR'
        foreach ($module in @(
            'AsBuiltReport.Core',
            'PScribo',
            'PScriboCharts',
            'PSGraph',
            'Diagrammer.Core',
            'AsBuiltReport.Veeam.VBR'
        )) {
            Ensure-Module -Name $module
        }

        Write-Log -Message 'Loading VBR PowerShell module'
        try {
            Import-Module $vbrDll -Force
            Write-Log -Message 'VBR PowerShell DLL loaded successfully.' -Level SUCCESS -Indent 1
        }
        catch {
            Stop-Script -Message "Failed to load VBR PowerShell DLL: $_"
        }

        if (-not (Get-Command Get-VBRServer -ErrorAction SilentlyContinue)) {
            Stop-Script -Message 'Get-VBRServer is not available after loading the VBR module.'
        }
        Write-Log -Message 'VBR cmdlets available.' -Level SUCCESS -Indent 1

        Write-Log -Message 'Connecting to VBR server'
        try {
            Connect-VBRServer -Server $Target | Out-Null
            Write-Log -Message 'Connected successfully.' -Level SUCCESS -Indent 1
        }
        catch {
            Stop-Script -Message "Failed to connect to VBR server '$Target': $_"
        }

        Write-Log -Message 'Validating VBR version'
        try {
            $vbrVersion = Get-VbrVersion
            Write-Log -Message ("Detected VBR version: {0}" -f $vbrVersion.ToString()) -Level SUCCESS -Indent 1

            if ($vbrVersion.Major -lt 12) {
                Stop-Script -Message "Unsupported VBR version detected: $vbrVersion. Minimum supported version is 12."
            }

            if ($vbrVersion.Major -ge 13) {
                Write-Log -Message 'VBR 13+ detected. This may not be officially validated by the upstream AsBuilt module yet.' -Level WARNING -Indent 1
                if (-not $Silent -and -not (Confirm-Action 'Continue anyway')) {
                    Stop-Script -Message 'Execution cancelled by user due to VBR version warning.'
                }
            }
        }
        catch {
            Stop-Script -Message "Failed to determine VBR version: $_"
        }

        Write-Log -Message 'Generating VBR report'
        try {
            New-AsBuiltReport `
                -Report 'Veeam.VBR' `
                -Target $Target `
                -OutputPath $OutputPath `
                -Format 'Word','HTML'

            Write-Log -Message 'VBR report generated successfully.' -Level SUCCESS -Indent 1
        }
        catch {
            Stop-Script -Message "Failed to generate VBR report: $_"
        }
    }

    'VBM365' {
        Write-Log -Message 'Preparing VBM365 workflow'

        if ($psMajor -ne 5) {
            Write-Log -Message 'VBM365 requires Windows PowerShell 5.1 in this script.' -Level WARNING -Indent 1
            if (Confirm-Action 'Relaunch in Windows PowerShell 5.1 now') {
                Restart-InWindowsPowerShell
            }
            else {
                Stop-Script -Message 'Execution cancelled because Windows PowerShell 5.1 is required for the VBM365 workflow.'
            }
        }

        Ensure-Admin

        $vbmRoot = 'C:\Program Files\Veeam\Backup365'
        $vbmDll = Join-Path $vbmRoot 'Veeam.Archiver.PowerShell.dll'

        if (-not (Test-Path $vbmDll)) {
            Stop-Script -Message "VBM365 PowerShell DLL not found: $vbmDll"
        }

        Write-Log -Message 'Loading AsBuilt modules for VBM365'
        foreach ($module in @(
            'AsBuiltReport.Core',
            'PScribo',
            'PScriboCharts',
            'PSGraph',
            'Diagrammer.Core',
            'AsBuiltReport.Veeam.VB365'
        )) {
            Ensure-Module -Name $module
        }

        Write-Log -Message 'Loading VBM365 PowerShell module'
        try {
            Import-Module $vbmDll -Force
            Write-Log -Message 'VBM365 PowerShell DLL loaded successfully.' -Level SUCCESS -Indent 1
        }
        catch {
            Stop-Script -Message "Failed to load VBM365 PowerShell DLL: $_"
        }

        if (-not (Get-Command Get-VBOOrganization -ErrorAction SilentlyContinue)) {
            Stop-Script -Message 'Get-VBOOrganization is not available after loading the VBM365 module.'
        }
        Write-Log -Message 'VBM365 cmdlets available.' -Level SUCCESS -Indent 1

        Write-Log -Message 'Connecting to VBM365 service'
        try {
            Connect-VBOService -Server $Target | Out-Null
            Write-Log -Message 'Connected successfully.' -Level SUCCESS -Indent 1
        }
        catch {
            Stop-Script -Message "Failed to connect to VBM365 service '$Target': $_"
        }

        Write-Log -Message 'Validating VBM365 version'
        try {
            $vbmVersion = Get-Vbm365Version
            Write-Log -Message ("Detected VBM365 version: {0}" -f $vbmVersion.ToString()) -Level SUCCESS -Indent 1

            if ($vbmVersion.Major -lt 6) {
                Stop-Script -Message "Unsupported VBM365 version detected: $vbmVersion. Minimum supported version is 6."
            }
        }
        catch {
            Stop-Script -Message "Failed to determine VBM365 version: $_"
        }

        Write-Log -Message 'Generating VBM365 report'
        try {
            New-AsBuiltReport `
                -Report 'Veeam.VB365' `
                -Target $Target `
                -OutputFolderPath $OutputPath `
                -Format 'Word','HTML'

            Write-Log -Message 'VBM365 report generated successfully.' -Level SUCCESS -Indent 1
        }
        catch {
            Stop-Script -Message "Failed to generate VBM365 report: $_"
        }
    }
}

Write-Log -Message '===== END ====='
if (-not $Silent) {
    Read-Host 'Press ENTER to exit' | Out-Null
}
exit 0
