
<#
.SYNOPSIS
Broadcom License Assessment Tool

.DESCRIPTION
Interactive PowerShell assessment tool for VMware / Broadcom licensing.
It validates prerequisites, connects to one or more vCenter / ESXi endpoints,
collects cluster, host, vSAN and license information, calculates VVF / VCF and
vSAN Add-on requirements, and exports the results to HTML / JSON / CSV / PDF.

.PARAMETER Help
Shows detailed help and exits.

.PARAMETER CustomerName
Customer or company name to stamp on reports and exported file names.

.PARAMETER DeploymentType
Licensing model to calculate. Accepted values: VVF or VCF. Default: VVF.

.PARAMETER TrustInvalidCertificates
Automatically ignore invalid certificates for the current PowerCLI session.

.PARAMETER DisconnectWhenDone
Disconnect all connected VIServers at the end of the run. Default: $true.

.PARAMETER ExportPdf
Attempt to export the generated HTML report to PDF.

.PARAMETER CollectLicenseAssignments
Collect current assigned license information for hosts and clusters. Default: $true.

.EXAMPLE
.\BroadcomLicenseAssessmentTool.ps1 -Help

.EXAMPLE
.\BroadcomLicenseAssessmentTool.ps1 -CustomerName "ACME Corp" -DeploymentType VVF -ExportPdf

.EXAMPLE
Get-Help .\BroadcomLicenseAssessmentTool.ps1 -Full
#>

[CmdletBinding()]
param(
    [Alias('h','?')]
    [switch]$Help,
    [string]$CustomerName,
    [ValidateSet('VVF','VCF')]
    [string]$DeploymentType = 'VVF',
    [switch]$TrustInvalidCertificates,
    [bool]$DisconnectWhenDone = $true,
    [switch]$ExportPdf,
    [bool]$CollectLicenseAssignments = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolName = 'Broadcom License Assessment Tool'
$script:Version = '1.2.0'
$script:BrandMode = 'Public'
$script:GeneratedBy = 'Juliano Cunha (GitHub: julianscunha)'
$script:StartTime = Get-Date
$script:LogLines = New-Object System.Collections.Generic.List[string]
$script:ConnectedServers = New-Object System.Collections.Generic.List[object]
$script:SessionTweaks = [ordered]@{
    ExecutionPolicyBypassApplied = $false
    InvalidCertificateIgnoreApplied = $false
    CeipDisabledAttempted = $false
}
$script:OriginalPreferences = [ordered]@{
    WarningPreference = $WarningPreference
    InformationPreference = $InformationPreference
    ProgressPreference = $ProgressPreference
}
$script:OutputRoot = Join-Path -Path (Get-Location) -ChildPath 'output'

function Show-Usage {
@"
$($script:ToolName) v$($script:Version)

Usage:
  .\BroadcomLicenseAssessmentTool.ps1 [options]

Options:
  -Help                         Show this help text and exit
  -CustomerName <string>        Customer / company name shown in the report
  -DeploymentType <VVF|VCF>     Licensing model to calculate (default: VVF)
  -TrustInvalidCertificates     Ignore invalid certificates automatically
  -DisconnectWhenDone <bool>    Disconnect VIServers at the end (default: True)
  -ExportPdf                    Try to export the HTML report to PDF
  -CollectLicenseAssignments    Collect current assigned licenses (default: True)

Examples:
  .\BroadcomLicenseAssessmentTool.ps1
  .\BroadcomLicenseAssessmentTool.ps1 -CustomerName "ACME Corp" -DeploymentType VVF -ExportPdf
  Get-Help .\BroadcomLicenseAssessmentTool.ps1 -Full
"@ | Write-Host
}

if ($Help) {
    Show-Usage
    return
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','OK','WARN','ERROR')][string]$Level = 'INFO',
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[{0}] [{1}] {2}" -f $timestamp, $Level, $Message
    $script:LogLines.Add($line) | Out-Null
    Write-Host $line -ForegroundColor $Color
}

function Show-Banner {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host $script:ToolName -ForegroundColor Cyan
    Write-Host ("Developed by {0}" -f $script:GeneratedBy) -ForegroundColor Gray
    Write-Host ("Version {0}" -f $script:Version) -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Read-YesNo {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [bool]$DefaultYes = $true
    )
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host "$Prompt $suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer -match '^(y|yes)$'
}

function Get-SafeFileName {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return 'UnnamedCustomer' }
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $chars = $Text.ToCharArray() | ForEach-Object { if ($invalid -contains $_) { '_' } else { $_ } }
    $safe = -join $chars
    $safe = $safe -replace '\s+', '_'
    if ([string]::IsNullOrWhiteSpace($safe)) { return 'UnnamedCustomer' }
    return $safe
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Ensure-ExecutionPolicy {
    $policies = Get-ExecutionPolicy -List
    $summary = ($policies | Where-Object { $_.Scope -in 'Process','CurrentUser','LocalMachine' } | ForEach-Object { '{0}={1}' -f $_.Scope,$_.ExecutionPolicy }) -join '; '
    Write-Log "Prereq OK - Execution policy: $summary" 'OK' 'Green'
    if ($policies.Process -eq 'Restricted') {
        if (Read-YesNo -Prompt 'Process execution policy is Restricted. Apply temporary Bypass for this session?' -DefaultYes $true) {
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
            $script:SessionTweaks.ExecutionPolicyBypassApplied = $true
            Write-Log 'Applied temporary Process execution policy Bypass.' 'WARN' 'Yellow'
        } else {
            throw 'Execution policy blocks the current session.'
        }
    }
}

function Ensure-PowerCLI {
    $loaded = Get-Module -ListAvailable VMware.PowerCLI | Sort-Object Version -Descending | Select-Object -First 1
    if ($loaded -and $loaded.Version -ge [version]'13.3.0') {
        Write-Log ("Prereq OK - VMware.PowerCLI {0}" -f $loaded.Version) 'OK' 'Green'
        return $loaded.Version
    }

    Write-Log 'Prereq FAIL - VMware.PowerCLI 13.3+ not found.' 'ERROR' 'Red'
    if (-not (Read-YesNo -Prompt 'Install or update VMware PowerCLI 13.3+ for CurrentUser now?' -DefaultYes $true)) {
        throw 'VMware.PowerCLI 13.3+ is required.'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    try {
        Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue | Out-Null
    } catch {}

    $ProgressPreference = 'Continue'
    Write-Progress -Activity 'Installing VMware.PowerCLI' -Status 'Preparing installation' -PercentComplete 5
    Install-Module -Name VMware.PowerCLI -Scope CurrentUser -AllowClobber -Force -ErrorAction Stop
    Write-Progress -Activity 'Installing VMware.PowerCLI' -Status 'Importing module' -PercentComplete 80

    $env:VMWARE_CEIP_DISABLE = 'true'
    Import-Module VMware.PowerCLI -DisableNameChecking -Scope Global -ErrorAction Stop | Out-Null
    try {
        Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
        Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false | Out-Null
        Set-PowerCLIConfiguration -Scope Session -DisplayDeprecationWarnings:$false -Confirm:$false | Out-Null
        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Fail -Confirm:$false | Out-Null
        $script:SessionTweaks.CeipDisabledAttempted = $true
    } catch {}
    Write-Progress -Activity 'Installing VMware.PowerCLI' -Completed

    $loaded = Get-Module -ListAvailable VMware.PowerCLI | Sort-Object Version -Descending | Select-Object -First 1
    if (-not $loaded) { throw 'VMware.PowerCLI installation did not complete successfully.' }
    Write-Log ("Prereq OK - VMware.PowerCLI {0}" -f $loaded.Version) 'OK' 'Green'
    return $loaded.Version
}

function Initialize-PowerCLIQuiet {
    $env:VMWARE_CEIP_DISABLE = 'true'
    $WarningPreference = 'SilentlyContinue'
    $InformationPreference = 'SilentlyContinue'
    Import-Module VMware.PowerCLI -DisableNameChecking -Scope Global -ErrorAction Stop | Out-Null
    try {
        Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP $false -Confirm:$false | Out-Null
        Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP $false -Confirm:$false | Out-Null
        Set-PowerCLIConfiguration -Scope Session -DisplayDeprecationWarnings:$false -Confirm:$false | Out-Null
        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Fail -Confirm:$false | Out-Null
        $script:SessionTweaks.CeipDisabledAttempted = $true
    } catch {}
}

function Connect-ToVIServer {
    param(
        [Parameter(Mandatory=$true)][string]$Server,
        [Parameter(Mandatory=$true)][pscredential]$Credential
    )

    try {
        if ($TrustInvalidCertificates) {
            Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $script:SessionTweaks.InvalidCertificateIgnoreApplied = $true
        }
        return Connect-VIServer -Server $Server -Credential $Credential -WarningAction SilentlyContinue -ErrorAction Stop
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'certificate|SSL|TLS|trust' -or $_.FullyQualifiedErrorId -match 'Certificate|ViSecurityNegotiationException') {
            Write-Log "Certificate validation failed while connecting to $Server." 'WARN' 'Yellow'
            if (Read-YesNo -Prompt 'Ignore invalid certificate for this PowerCLI session and retry connection?' -DefaultYes $true) {
                Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
                $script:SessionTweaks.InvalidCertificateIgnoreApplied = $true
                Write-Log 'Invalid certificate handling set to Ignore for this session after user confirmation.' 'WARN' 'Yellow'
                return Connect-VIServer -Server $Server -Credential $Credential -WarningAction SilentlyContinue -ErrorAction Stop
            }
            throw 'Connection aborted because certificate validation was not accepted.'
        }
        throw
    }
}

function Convert-BytesToTiB {
    param([double]$Bytes)
    if ($Bytes -le 0) { return 0 }
    return [math]::Round($Bytes / 1TB, 2)
}

function Get-VsanRawCapacityTiB {
    param([Parameter(Mandatory=$true)]$Cluster)
    $totalBytes = 0.0
    $clusterName = $Cluster.Name

    try {
        $spaceUsage = Get-VsanSpaceUsage -Cluster $Cluster -ErrorAction Stop
        if ($spaceUsage -and $spaceUsage.CapacityGB) {
            return [math]::Round(([double]$spaceUsage.CapacityGB / 1024), 2)
        }
    } catch {
        Write-Log "Get-VsanSpaceUsage failed for cluster $clusterName. Falling back to vSAN disk inventory." 'WARN' 'Yellow'
    }

    foreach ($vmhost in (Get-VMHost -Location $Cluster -ErrorAction Stop)) {
        try {
            $storageInfo = Get-VsanDisk -VMHost $vmhost -ErrorAction Stop
            foreach ($disk in $storageInfo) {
                if ($disk.IsCapacityFlash -or $disk.IsCapacityTier -or ($disk.DiskType -match 'capacity')) {
                    if ($disk.Capacity) { $totalBytes += [double]$disk.Capacity }
                    elseif ($disk.CapacityGB) { $totalBytes += ([double]$disk.CapacityGB * 1GB) }
                }
            }
        } catch {
            Write-Log ("Could not inventory vSAN disks on host {0}: {1}" -f $vmhost.Name, $_.Exception.Message) 'WARN' 'Yellow'
        }
    }

    return Convert-BytesToTiB -Bytes $totalBytes
}

function Get-LicenseAssignments {
    param(
        [Parameter(Mandatory=$true)]$Server,
        [bool]$Enabled = $true
    )
    $result = [ordered]@{
        AssignmentRows = @()
        Summary = [ordered]@{
            TotalLicenses = 0
            Expired = 0
            Expiring30 = 0
            Expiring90 = 0
            Evaluation = 0
            UnlicensedObjects = 0
        }
    }

    if (-not $Enabled) { return $result }

    try {
        $licenseManager = Get-View -Id 'LicenseManager-licenseManager' -Server $Server -ErrorAction Stop
        $licenses = @($licenseManager.Licenses)
        $result.Summary.TotalLicenses = $licenses.Count

        foreach ($lic in $licenses) {
            $exp = $null
            $edition = $null
            $isEval = $false
            if ($lic.Properties) {
                foreach ($prop in $lic.Properties) {
                    if ($prop.Key -match 'expirationDate|expiration') { $exp = $prop.Value }
                    if ($prop.Key -match 'editionKey|productName') { $edition = $prop.Value }
                    if ($prop.Key -match 'evaluation') { $isEval = $prop.Value -match 'true' }
                }
            }

            $expDate = $null
            if ($exp) { [void][datetime]::TryParse($exp, [ref]$expDate) }
            if ($expDate) {
                $days = ($expDate - (Get-Date)).TotalDays
                if ($days -lt 0) { $result.Summary.Expired++ }
                elseif ($days -le 30) { $result.Summary.Expiring30++ }
                elseif ($days -le 90) { $result.Summary.Expiring90++ }
            }
            if ($isEval) { $result.Summary.Evaluation++ }

            $result.AssignmentRows += [pscustomobject]@{
                Server = $Server.Name
                LicenseKey = $lic.LicenseKey
                Name = $lic.Name
                Edition = $edition
                Total = $lic.Total
                Used = $lic.Used
                CostUnit = $lic.CostUnit
                Expires = if ($expDate) { $expDate.ToString('yyyy-MM-dd') } else { '' }
                Evaluation = $isEval
            }
        }
    } catch {
        Write-Log ("License inventory failed on server {0}: {1}" -f $Server.Name, $_.Exception.Message) 'WARN' 'Yellow'
    }

    return $result
}

function New-ClusterAssessment {
    param(
        [Parameter(Mandatory=$true)]$Server,
        [Parameter(Mandatory=$true)]$Cluster,
        [Parameter(Mandatory=$true)][string]$DeploymentModel
    )

    $hostRows = New-Object System.Collections.Generic.List[object]
    $clusterName = $Cluster.Name
    $totalCoresRequired = 0

    foreach ($vmhost in (Get-VMHost -Location $Cluster -ErrorAction Stop | Sort-Object Name)) {
        $numSockets = [int]$vmhost.NumCpu
        $numCoresPerSocket = [int]($vmhost.ExtensionData.Hardware.CpuInfo.NumCpuCores / [math]::Max($vmhost.NumCpu,1))
        $adjustedCoresPerSocket = [math]::Max($numCoresPerSocket, 16)
        $requiredCores = $numSockets * $adjustedCoresPerSocket
        $totalCoresRequired += $requiredCores

        $hostRows.Add([pscustomobject]@{
            Server = $Server.Name
            Cluster = $clusterName
            VMHost = $vmhost.Name
            CpuSockets = $numSockets
            CoresPerSocketActual = $numCoresPerSocket
            CoresPerSocketBillable = $adjustedCoresPerSocket
            RequiredCores = $requiredCores
            Version = $vmhost.Version
            Build = $vmhost.Build
        }) | Out-Null
    }

    $entitlementTiB = if ($DeploymentModel -eq 'VCF') { [math]::Round($totalCoresRequired * 1.0, 2) } else { [math]::Round($totalCoresRequired * 0.25, 2) }
    $rawVsanTiB = Get-VsanRawCapacityTiB -Cluster $Cluster
    $requiredAddonTiB = [math]::Ceiling([math]::Max(($rawVsanTiB - $entitlementTiB), 0))

    return [pscustomobject]@{
        Server = $Server.Name
        Cluster = $clusterName
        DeploymentType = $DeploymentModel
        HostCount = $hostRows.Count
        RequiredComputeCores = $totalCoresRequired
        IncludedEntitlementTiB = $entitlementTiB
        RawVsanTiB = $rawVsanTiB
        RequiredVsanAddonTiB = $requiredAddonTiB
        HostRows = @($hostRows)
    }
}

function Get-EnvironmentAssessment {
    param(
        [Parameter(Mandatory=$true)]$Server,
        [Parameter(Mandatory=$true)][string]$DeploymentModel
    )

    $clusterAssessments = New-Object System.Collections.Generic.List[object]
    foreach ($cluster in (Get-Cluster -Server $Server -ErrorAction Stop | Sort-Object Name)) {
        Write-Log ("Assessing cluster {0} on {1}" -f $cluster.Name, $Server.Name) 'INFO' 'Cyan'
        $clusterAssessments.Add((New-ClusterAssessment -Server $Server -Cluster $cluster -DeploymentModel $DeploymentModel)) | Out-Null
    }

    return [pscustomobject]@{
        Server = $Server.Name
        DeploymentType = $DeploymentModel
        Clusters = @($clusterAssessments)
        Summary = [pscustomobject]@{
            ClusterCount = $clusterAssessments.Count
            RequiredComputeCores = (@($clusterAssessments) | Measure-Object -Property RequiredComputeCores -Sum).Sum
            IncludedEntitlementTiB = (@($clusterAssessments) | Measure-Object -Property IncludedEntitlementTiB -Sum).Sum
            RawVsanTiB = (@($clusterAssessments) | Measure-Object -Property RawVsanTiB -Sum).Sum
            RequiredVsanAddonTiB = (@($clusterAssessments) | Measure-Object -Property RequiredVsanAddonTiB -Sum).Sum
        }
    }
}

function Get-RiskScore {
    param([Parameter(Mandatory=$true)]$Assessment)
    $score = 5
    $reasons = New-Object System.Collections.Generic.List[string]

    if ([double]$Assessment.Summary.RequiredVsanAddonTiB -gt 0) {
        $score += 35
        $reasons.Add('Additional vSAN licensing is required beyond included entitlement.') | Out-Null
    }
    if ($Assessment.LicenseAssignments.Count -gt 0) {
        $expired = @($Assessment.LicenseAssignments | Where-Object { $_.Expires -and ([datetime]$_.Expires -lt (Get-Date)) }).Count
        $exp30 = @($Assessment.LicenseAssignments | Where-Object { $_.Expires -and ([datetime]$_.Expires -ge (Get-Date)) -and ([datetime]$_.Expires -le (Get-Date).AddDays(30)) }).Count
        $eval = @($Assessment.LicenseAssignments | Where-Object { $_.Evaluation -eq $true }).Count
        if ($expired -gt 0) { $score += 35; $reasons.Add("$expired license record(s) appear expired.") | Out-Null }
        if ($exp30 -gt 0) { $score += 15; $reasons.Add("$exp30 license record(s) expire within 30 days.") | Out-Null }
        if ($eval -gt 0) { $score += 10; $reasons.Add("$eval license record(s) appear to be evaluation-based.") | Out-Null }
    }
    if ($Assessment.EnvironmentCount -ge 3) {
        $score += 5
        $reasons.Add('Multiple environments increase operational complexity.') | Out-Null
    }

    if ($score -gt 100) { $score = 100 }
    $level = if ($score -ge 70) { 'High' } elseif ($score -ge 35) { 'Medium' } else { 'Low' }

    return [pscustomobject]@{
        Score = $score
        Level = $level
        Reasons = @($reasons)
    }
}

function Get-SuitabilityNarrative {
    param([Parameter(Mandatory=$true)]$Assessment)

    $raw = [double]$Assessment.Summary.RawVsanTiB
    $vcfIncluded = [double]$Assessment.Summary.RequiredComputeCores
    $vvfIncluded = [double]$Assessment.Summary.RequiredComputeCores * 0.25

    $pref = 'VVF'
    $reason = 'Observed signals from vCenter suggest a simpler virtualization-centered environment.'
    $tradeoff = 'VVF keeps the stack simpler, but it offers lower included raw vSAN entitlement than VCF.'
    $gains = New-Object System.Collections.Generic.List[string]
    $losses = New-Object System.Collections.Generic.List[string]

    if ($raw -gt $vvfIncluded) {
        $pref = 'VCF'
        $reason = 'The observed raw vSAN footprint is materially higher than the entitlement included with VVF, which may make VCF more suitable where broader private-cloud capabilities or larger included entitlement are desired.'
        $tradeoff = 'VCF generally aligns better with storage-heavy environments and full private-cloud ambitions, while VVF remains better aligned to simpler vSphere-first scenarios.'
    }

    $gains.Add('Higher included raw vSAN entitlement per licensed core in VCF (1.0 TiB/core) versus VVF (0.25 TiB/core).') | Out-Null
    $gains.Add('VCF can be more appropriate when the environment strategy includes broader private-cloud capabilities beyond core virtualization.') | Out-Null
    $losses.Add('VVF may require more separate vSAN Add-on capacity in storage-heavy environments.') | Out-Null
    $losses.Add('This assessment does not directly inspect NSX, SDDC Manager, HCX, Aria, or Tanzu usage, so the recommendation is heuristic and based only on signals visible from the connected vCenter / ESXi environment.') | Out-Null

    return [pscustomobject]@{
        PreferredModel = $pref
        Reason = $reason
        Tradeoff = $tradeoff
        GainsWithVCF = @($gains)
        ConsiderationsWithVVF = @($losses)
    }
}

function New-ExecutiveHtml {
    param(
        [Parameter(Mandatory=$true)]$Assessment,
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][bool]$Internal
    )

    $safeCustomer = if ($Assessment.CustomerName) { $Assessment.CustomerName } else { 'Not informed' }
    $titleTag = if ($Internal) { 'GENERATED BY TRIPLE S CLOUD SOLUTIONS' } else { 'BROADCOM / VMWARE LICENSE ASSESSMENT' }
    $accent = if ($Internal) { '#f28b25' } else { '#2563eb' }
    $summary = $Assessment.Summary
    $risk = $Assessment.RiskScore
    $suitability = $Assessment.Suitability
    $deficitTiB = [math]::Max(($summary.RawVsanTiB - $summary.IncludedEntitlementTiB), 0)

    $executiveSummary = if ($deficitTiB -gt 0) {
        "The assessed environment requires additional vSAN licensing beyond the included entitlement. Compute licensing is estimated at $($summary.RequiredComputeCores) cores and additional vSAN Add-on is estimated at $([math]::Round($summary.RequiredVsanAddonTiB,0)) TiB."
    } else {
        "The assessed environment appears covered by the included vSAN entitlement for the selected licensing model. Compute licensing is estimated at $($summary.RequiredComputeCores) cores and no additional vSAN Add-on is currently indicated."
    }

    $recommendation = if ($suitability.PreferredModel -eq 'VCF') {
        "Based on the observed storage profile and the resulting entitlement gap under VVF, VCF should be evaluated as the preferred direction for the commercial proposal."
    } else {
        "Based on the observed virtualization-focused profile from vCenter, VVF appears to be the more direct fit unless the customer is actively pursuing broader private-cloud capabilities."
    }

    $maxBar = [math]::Max(
        [math]::Max([double]$summary.RequiredComputeCores, [double]$summary.IncludedEntitlementTiB),
        [math]::Max([double]$summary.RawVsanTiB, [double]$summary.RequiredVsanAddonTiB)
    )
    if ($maxBar -le 0) { $maxBar = 1 }

    $clusterRows = foreach ($cluster in $Assessment.Environments.Clusters) {
        $calcRule = if ($cluster.DeploymentType -eq 'VCF') { 'VCF includes 1.0 TiB per licensed core.' } else { 'VVF includes 0.25 TiB per licensed core.' }
        "<tr><td>$($cluster.Server)</td><td>$($cluster.Cluster)</td><td>$($cluster.HostCount)</td><td>$($cluster.RequiredComputeCores)</td><td>$([math]::Round($cluster.IncludedEntitlementTiB,2))</td><td>$([math]::Round($cluster.RawVsanTiB,2))</td><td>$([math]::Round($cluster.RequiredVsanAddonTiB,0))</td><td>$calcRule</td></tr>"
    } -join [Environment]::NewLine

    $licenseSummaryRows = if ($Assessment.LicenseAssignments.Count -gt 0) {
        (foreach ($row in $Assessment.LicenseAssignments) {
            "<tr><td>$($row.Server)</td><td>$($row.Name)</td><td>$($row.Edition)</td><td>$($row.Total)</td><td>$($row.Used)</td><td>$($row.CostUnit)</td><td>$($row.Expires)</td><td>$($row.Evaluation)</td></tr>"
        }) -join [Environment]::NewLine
    } else {
        '<tr><td colspan="8">License assignment collection was disabled or no inventory was returned by the connected environment.</td></tr>'
    }

    $riskReasons = if ($risk.Reasons.Count -gt 0) { ('<ul><li>' + (($risk.Reasons -join '</li><li>')) + '</li></ul>') } else { '<p class="note">No material licensing risk signal was observed from the available data.</p>' }
    $vcfGains = '<ul><li>' + (($suitability.GainsWithVCF -join '</li><li>')) + '</li></ul>'
    $vvfConsiderations = '<ul><li>' + (($suitability.ConsiderationsWithVVF -join '</li><li>')) + '</li></ul>'

    $logoBlock = ''
    if ($Internal) {
        $logoBlock = '<div class="logo-box"><img src="https://triples.com.br/wp-content/uploads/2022/11/cropped-logo-triples-1.png" alt="Triple S" /></div>'
    }

    $html = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width,initial-scale=1" />
<title>Broadcom License Assessment - $safeCustomer</title>
<style>
:root {
  --bg: #f4f7fb;
  --card: #ffffff;
  --text: #0f172a;
  --muted: #475569;
  --line: #dbe3ef;
  --header1: #f8fbff;
  --header2: #eef4ff;
  --accent: $accent;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #08111f;
    --card: #0f1b2d;
    --text: #f8fafc;
    --muted: #cbd5e1;
    --line: #20304b;
    --header1: #143052;
    --header2: #1e3f6d;
    --accent: #7dd3fc;
  }
}
body { font-family: Segoe UI, Arial, sans-serif; margin:0; background:var(--bg); color:var(--text); }
.wrap { max-width: 1180px; margin: 24px auto; padding: 0 18px; }
.hero { background: linear-gradient(135deg, var(--header1), var(--header2)); border:1px solid var(--line); border-radius: 22px; padding: 36px; display:flex; gap:24px; align-items:center; box-shadow: 0 8px 28px rgba(15,23,42,.08); }
.logo-box { background: rgba(255,255,255,0.98); padding: 10px 16px; border-radius: 12px; min-width: 180px; display:flex; align-items:center; justify-content:center; }
.logo-box img { max-width: 160px; height:auto; display:block; }
.eyebrow { font-size: 12px; font-weight: 700; letter-spacing: .12em; color: var(--accent); margin-bottom: 10px; }
h1 { margin: 0 0 10px 0; font-size: 26px; line-height: 1.2; }
.sub { color: var(--muted); font-size: 18px; margin: 0 0 8px 0; }
.small { color: var(--muted); font-size: 14px; }
.grid { display:grid; grid-template-columns: repeat(4,minmax(0,1fr)); gap:16px; margin-top: 22px; }
.card { background: var(--card); border:1px solid var(--line); border-radius: 18px; padding: 18px; box-shadow: 0 8px 28px rgba(15,23,42,.05); }
.kpi-label { font-size: 13px; color: var(--muted); margin-bottom: 6px; }
.kpi-value { font-size: 30px; font-weight: 700; }
.section { margin-top: 20px; }
h2 { font-size: 18px; margin: 0 0 12px 0; }
table { width:100%; border-collapse: collapse; }
th,td { border-bottom:1px solid var(--line); padding:10px 8px; text-align:left; font-size:14px; vertical-align: top; }
th { font-size: 12px; color: var(--muted); text-transform: uppercase; letter-spacing: .06em; }
.bar { height: 12px; border-radius: 999px; background: rgba(148,163,184,.25); overflow: hidden; margin-top: 8px; }
.bar > span { display:block; height:100%; background: linear-gradient(90deg, var(--accent), #22c55e); border-radius: 999px; }
.note { color: var(--muted); font-size: 13px; }
.two-col { display:grid; grid-template-columns: 1.2fr .8fr; gap: 16px; }
.tag { display:inline-block; border-radius: 999px; padding: 4px 10px; border:1px solid var(--line); color: var(--muted); margin-right:6px; font-size: 12px; }
.footer { margin: 18px 0 32px; color: var(--muted); font-size: 12px; text-align:right; }
.score { font-size: 34px; font-weight: 700; color: var(--accent); }
@media (max-width: 980px) { .grid, .two-col { grid-template-columns: 1fr; } .hero { flex-direction:column; align-items:flex-start; } }
</style>
</head>
<body>
<div class="wrap">
  <div class="hero">
    $logoBlock
    <div>
      <div class="eyebrow">$titleTag</div>
      <h1>Broadcom / VMware License Assessment</h1>
      <div class="sub">Customer: $safeCustomer</div>
      <div class="small">Generated on $($Assessment.GeneratedOn) | Tool version $($script:Version)</div>
    </div>
  </div>

  <div class="grid">
    <div class="card"><div class="kpi-label">Required Compute Cores</div><div class="kpi-value">$($summary.RequiredComputeCores)</div></div>
    <div class="card"><div class="kpi-label">Included vSAN Entitlement (TiB)</div><div class="kpi-value">$([math]::Round($summary.IncludedEntitlementTiB,2))</div></div>
    <div class="card"><div class="kpi-label">Measured Raw vSAN (TiB)</div><div class="kpi-value">$([math]::Round($summary.RawVsanTiB,2))</div></div>
    <div class="card"><div class="kpi-label">Required vSAN Add-on (TiB)</div><div class="kpi-value">$([math]::Round($summary.RequiredVsanAddonTiB,0))</div></div>
  </div>

  <div class="card section">
    <h2>Executive Summary</h2>
    <p>$executiveSummary</p>
  </div>

  <div class="two-col section">
    <div class="card">
      <h2>Key Findings</h2>
      <ul>
        <li>Total required compute: $($summary.RequiredComputeCores) cores</li>
        <li>Included entitlement: $([math]::Round($summary.IncludedEntitlementTiB,2)) TiB</li>
        <li>Measured raw vSAN: $([math]::Round($summary.RawVsanTiB,2)) TiB</li>
        <li>Additional required: $([math]::Round($summary.RequiredVsanAddonTiB,0)) TiB</li>
        <li>Preferred commercial direction: $($suitability.PreferredModel)</li>
      </ul>
    </div>
    <div class="card">
      <h2>Risk Score</h2>
      <div class="score">$($risk.Score) / 100</div>
      <p><strong>Risk level:</strong> $($risk.Level)</p>
      $riskReasons
    </div>
  </div>

  <div class="card section">
    <h2>Recommendations</h2>
    <p>$recommendation</p>
  </div>

  <div class="two-col section">
    <div class="card">
      <h2>Dashboard</h2>
      <div class="kpi-label">Compute required</div>
      <div class="bar"><span style="width:$([math]::Round(([double]$summary.RequiredComputeCores / $maxBar) * 100, 2))%"></span></div>
      <div class="kpi-label">Included entitlement TiB</div>
      <div class="bar"><span style="width:$([math]::Round(([double]$summary.IncludedEntitlementTiB / $maxBar) * 100, 2))%"></span></div>
      <div class="kpi-label">Measured raw vSAN TiB</div>
      <div class="bar"><span style="width:$([math]::Round(([double]$summary.RawVsanTiB / $maxBar) * 100, 2))%"></span></div>
      <div class="kpi-label">Required vSAN Add-on TiB</div>
      <div class="bar"><span style="width:$([math]::Round(([double]$summary.RequiredVsanAddonTiB / $maxBar) * 100, 2))%"></span></div>
      <p class="note">Calculation standard: minimum 16 licensable cores per physical CPU. VCF includes 1.0 TiB raw vSAN per core. VVF includes 0.25 TiB raw vSAN per core. Additional vSAN Add-on = max(raw vSAN TiB - included entitlement TiB, 0).</p>
    </div>
    <div class="card">
      <h2>VCF vs VVF Suitability</h2>
      <p><strong>Suggested direction:</strong> $($suitability.PreferredModel)</p>
      <p>$($suitability.Reason)</p>
      <p class="note">$($suitability.Tradeoff)</p>
      <h3>Potential gains with VCF</h3>
      $vcfGains
      <h3>Considerations with VVF</h3>
      $vvfConsiderations
    </div>
  </div>

  <div class="card section">
    <h2>Assessment Metadata</h2>
    <p><span class="tag">Customer</span> $safeCustomer</p>
    <p><span class="tag">Deployment type</span> $($Assessment.DeploymentType)</p>
    <p><span class="tag">Environments</span> $($Assessment.EnvironmentCount)</p>
    <p><span class="tag">Generated by</span> $($Assessment.GeneratedBy)</p>
    <p><span class="tag">PowerCLI</span> $($Assessment.PowerCLIVersion)</p>
    <p><span class="tag">License inventory</span> $($Assessment.LicenseAssignments.Count) row(s)</p>
  </div>

  <div class="card section">
    <h2>Cluster Calculations</h2>
    <table>
      <thead>
        <tr><th>Server</th><th>Cluster</th><th>Hosts</th><th>Required cores</th><th>Included TiB</th><th>Raw vSAN TiB</th><th>Required Add-on TiB</th><th>Applied rule</th></tr>
      </thead>
      <tbody>
        $clusterRows
      </tbody>
    </table>
  </div>

  <div class="card section">
    <h2>Current License Inventory</h2>
    <table>
      <thead>
        <tr><th>Server</th><th>Name</th><th>Edition</th><th>Total</th><th>Used</th><th>Cost unit</th><th>Expires</th><th>Evaluation</th></tr>
      </thead>
      <tbody>
        $licenseSummaryRows
      </tbody>
    </table>
    <p class="note">The VCF versus VVF suitability section is heuristic. It does not directly inspect NSX, SDDC Manager, HCX, Aria, or Tanzu usage from the environment unless those signals are surfaced through the connected vCenter / ESXi view.</p>
  </div>

  <div class="footer">Generated by $($Assessment.GeneratedBy)</div>
</div>
</body>
</html>
"@

    Set-Content -Path $Path -Value $html -Encoding UTF8
}

function Export-PdfFromHtml {
    param(
        [Parameter(Mandatory=$true)][string]$HtmlPath,
        [Parameter(Mandatory=$true)][string]$PdfPath
    )

    try {
        $word = New-Object -ComObject Word.Application -ErrorAction Stop
        $word.Visible = $false
        $doc = $word.Documents.Open($HtmlPath)
        $wdFormatPDF = 17
        $doc.SaveAs([ref]$PdfPath, [ref]$wdFormatPDF)
        $doc.Close()
        $word.Quit()
        Write-Log "PDF exported with Microsoft Word: $PdfPath" 'OK' 'Green'
        return $true
    } catch {}

    $edgePath = Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe'
    if (-not (Test-Path $edgePath)) { $edgePath = Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe' }
    if (Test-Path $edgePath) {
        try {
            $uri = 'file:///' + ($HtmlPath -replace '\\','/')
            & $edgePath --headless --disable-gpu --print-to-pdf="$PdfPath" "$uri" | Out-Null
            if (Test-Path $PdfPath) {
                Write-Log "PDF exported with Microsoft Edge headless: $PdfPath" 'OK' 'Green'
                return $true
            }
        } catch {}
    }

    $chromePath = Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'
    if (Test-Path $chromePath) {
        try {
            $uri = 'file:///' + ($HtmlPath -replace '\\','/')
            & $chromePath --headless --disable-gpu --print-to-pdf="$PdfPath" "$uri" | Out-Null
            if (Test-Path $PdfPath) {
                Write-Log "PDF exported with Google Chrome headless: $PdfPath" 'OK' 'Green'
                return $true
            }
        } catch {}
    }

    $wk = Get-Command wkhtmltopdf -ErrorAction SilentlyContinue
    if ($wk) {
        try {
            & $wk.Source $HtmlPath $PdfPath | Out-Null
            if (Test-Path $PdfPath) {
                Write-Log "PDF exported with wkhtmltopdf: $PdfPath" 'OK' 'Green'
                return $true
            }
        } catch {}
    }

    Write-Log 'PDF export skipped. Word COM, Edge/Chrome headless, and wkhtmltopdf were unavailable in this session.' 'WARN' 'Yellow'
    return $false
}

function New-OutputBundle {
    param(
        [Parameter(Mandatory=$true)]$Assessment,
        [switch]$Internal
    )

    Ensure-Directory -Path $script:OutputRoot
    $safeCustomer = Get-SafeFileName -Text $Assessment.CustomerName
    $prefix = "$safeCustomer-Broadcom-License-Assessment"

    $jsonPath = Join-Path $script:OutputRoot "$prefix.json"
    $csvPath = Join-Path $script:OutputRoot "$prefix-clusters.csv"
    $htmlPath = Join-Path $script:OutputRoot "$prefix.html"
    $pdfPath = Join-Path $script:OutputRoot "$prefix.pdf"
    $logPath = Join-Path $script:OutputRoot "$prefix.log"

    $Assessment | ConvertTo-Json -Depth 10 | Set-Content -Path $jsonPath -Encoding UTF8
    $Assessment.Environments.Clusters | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    New-ExecutiveHtml -Assessment $Assessment -Path $htmlPath -Internal:$Internal
    $script:LogLines | Set-Content -Path $logPath -Encoding UTF8

    if ($ExportPdf) {
        [void](Export-PdfFromHtml -HtmlPath $htmlPath -PdfPath $pdfPath)
    }

    return [pscustomobject]@{
        Json = $jsonPath
        Csv = $csvPath
        Html = $htmlPath
        Pdf = if (Test-Path $pdfPath) { $pdfPath } else { '' }
        Log = $logPath
    }
}

function Restore-Session {
    try {
        if ($DisconnectWhenDone -and $script:ConnectedServers.Count -gt 0) {
            Disconnect-VIServer -Server $script:ConnectedServers -Confirm:$false | Out-Null
            Write-Log 'Disconnected active VIServer sessions.' 'OK' 'Green'
        }
    } catch {}
    try {
        $WarningPreference = $script:OriginalPreferences.WarningPreference
        $InformationPreference = $script:OriginalPreferences.InformationPreference
        $ProgressPreference = $script:OriginalPreferences.ProgressPreference
    } catch {}
}

Show-Banner
Write-Log 'Starting assessment.' 'INFO' 'Cyan'
Write-Log ("Prereq OK - PowerShell version: {0}" -f $PSVersionTable.PSVersion.ToString()) 'OK' 'Green'
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Log ("Prereq OK - Run as Administrator: {0}" -f $(if ($isElevated) { 'Elevated session' } else { 'Standard session' })) 'OK' 'Green'

Ensure-ExecutionPolicy
[void](Ensure-PowerCLI)
Initialize-PowerCLIQuiet

if ([string]::IsNullOrWhiteSpace($CustomerName)) {
    $CustomerName = Read-Host 'Customer / Company name for the report'
    if ([string]::IsNullOrWhiteSpace($CustomerName)) { $CustomerName = 'Not informed' }
}

$environments = New-Object System.Collections.Generic.List[object]
$allLicenseRows = New-Object System.Collections.Generic.List[object]

try {
    do {
        $serverName = Read-Host 'Enter vCenter Server / ESXi endpoint'
        if ([string]::IsNullOrWhiteSpace($serverName)) { throw 'Server / endpoint cannot be empty.' }

        $envDeployment = Read-Host ("Deployment type for this environment [VVF/VCF] (default {0})" -f $DeploymentType)
        if ([string]::IsNullOrWhiteSpace($envDeployment)) { $envDeployment = $DeploymentType }
        $envDeployment = $envDeployment.ToUpperInvariant()
        if ($envDeployment -notin @('VVF','VCF')) { throw 'Deployment type must be VVF or VCF.' }

        $cred = Get-Credential -Message ("Enter credentials for {0}" -f $serverName)
        $server = Connect-ToVIServer -Server $serverName -Credential $cred
        $script:ConnectedServers.Add($server) | Out-Null
        Write-Log ("Connected to {0}" -f $server.Name) 'OK' 'Green'

        $environmentAssessment = Get-EnvironmentAssessment -Server $server -DeploymentModel $envDeployment
        $environments.Add($environmentAssessment) | Out-Null

        $licenseInventory = Get-LicenseAssignments -Server $server -Enabled:$CollectLicenseAssignments
        foreach ($row in $licenseInventory.AssignmentRows) {
            $allLicenseRows.Add($row) | Out-Null
        }

        $more = Read-YesNo -Prompt 'Assess another environment in the same run?' -DefaultYes $false
    } while ($more)

    $flatClusters = @($environments | ForEach-Object { $_.Clusters } | ForEach-Object { $_ })
    $summary = [pscustomobject]@{
        RequiredComputeCores = (@($flatClusters) | Measure-Object -Property RequiredComputeCores -Sum).Sum
        IncludedEntitlementTiB = (@($flatClusters) | Measure-Object -Property IncludedEntitlementTiB -Sum).Sum
        RawVsanTiB = (@($flatClusters) | Measure-Object -Property RawVsanTiB -Sum).Sum
        RequiredVsanAddonTiB = (@($flatClusters) | Measure-Object -Property RequiredVsanAddonTiB -Sum).Sum
    }

    $assessment = [pscustomobject]@{
        CustomerName = $CustomerName
        GeneratedOn = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        GeneratedBy = $script:GeneratedBy
        EnvironmentCount = $environments.Count
        DeploymentType = if ($environments.Count -eq 1) { $environments[0].DeploymentType } else { 'Mixed' }
        PowerCLIVersion = (Get-Module VMware.PowerCLI | Select-Object -First 1).Version.ToString()
        Summary = $summary
        Environments = [pscustomobject]@{
            Servers = @($environments)
            Clusters = $flatClusters
        }
        LicenseAssignments = @($allLicenseRows)
        SessionTweaks = $script:SessionTweaks
    }
    $assessment | Add-Member -NotePropertyName RiskScore -NotePropertyValue (Get-RiskScore -Assessment $assessment)
    $assessment | Add-Member -NotePropertyName Suitability -NotePropertyValue (Get-SuitabilityNarrative -Assessment $assessment)

    $bundle = New-OutputBundle -Assessment $assessment -Internal:$false

    $expired = @($allLicenseRows | Where-Object { $_.Expires -and ([datetime]$_.Expires -lt (Get-Date)) }).Count
    $exp30 = @($allLicenseRows | Where-Object { $_.Expires -and ([datetime]$_.Expires -ge (Get-Date)) -and ([datetime]$_.Expires -le (Get-Date).AddDays(30)) }).Count
    $eval = @($allLicenseRows | Where-Object { $_.Evaluation -eq $true }).Count

    Write-Host ''
    Write-Host 'Console Summary:' -ForegroundColor Cyan
    Write-Host ("  Customer:                  {0}" -f $CustomerName)
    Write-Host ("  Environment count:         {0}" -f $assessment.EnvironmentCount)
    Write-Host ("  Required compute:          {0} cores" -f $summary.RequiredComputeCores)
    Write-Host ("  Included entitlement:      {0} TiB" -f ([math]::Round($summary.IncludedEntitlementTiB,2)))
    Write-Host ("  Measured raw vSAN:         {0} TiB" -f ([math]::Round($summary.RawVsanTiB,2)))
    Write-Host ("  Required vSAN add-on:      {0} TiB" -f ([math]::Round($summary.RequiredVsanAddonTiB,0)))
    Write-Host ("  Risk score:                {0}/100 ({1})" -f $assessment.RiskScore.Score, $assessment.RiskScore.Level)
    Write-Host ("  Suggested direction:       {0}" -f $assessment.Suitability.PreferredModel)
    Write-Host ("  License records collected: {0}" -f $allLicenseRows.Count)
    Write-Host ("  Expired licenses:          {0}" -f $expired)
    Write-Host ("  Expiring within 30 days:   {0}" -f $exp30)
    Write-Host ("  Evaluation licenses:       {0}" -f $eval)
    Write-Host ''
    Write-Host ("  Suitability note: {0}" -f $assessment.Suitability.Reason) -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Exported files:' -ForegroundColor Cyan
    Write-Host ("  HTML: {0}" -f $bundle.Html)
    if ($bundle.Pdf) { Write-Host ("  PDF:  {0}" -f $bundle.Pdf) }
    Write-Host ("  JSON: {0}" -f $bundle.Json)
    Write-Host ("  CSV:  {0}" -f $bundle.Csv)
    Write-Host ("  LOG:  {0}" -f $bundle.Log)
}
finally {
    Restore-Session
}
