# VMware Broadcom License Assessment Tool
# Author: Juliano Cunha (https://github.com/julianscunha)
# Repository: https://github.com/julianscunha
# Description: Automated assessment for VCF/VVF/vSAN licensing with dashboard-style executive reporting based on Broadcom public guidance
# License: MIT

[CmdletBinding()]
param(
    [string]$OutputFolder = (Join-Path -Path (Get-Location) -ChildPath ("Broadcom-License-Assessment-" + (Get-Date -Format 'yyyyMMdd-HHmmss'))),
    [string]$ConfigFile,
    [switch]$ExportPdf,
    [switch]$CollectLicenseAssignments,
    [switch]$TrustInvalidCertificates,
    [switch]$DisconnectWhenDone,
    [switch]$SkipPrereqInstallHints,
    [switch]$UseTranscript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region logging
$script:LogFile = $null
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:Infos = New-Object System.Collections.Generic.List[string]
$script:RuntimeChanges = New-Object System.Collections.Generic.List[object]
$script:OriginalExecutionPolicyProcess = $null
$script:OriginalInvalidCertificateAction = $null

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','DEBUG')] [string]$Level = 'INFO',
        [switch]$NoConsole
    )

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $line
    }

    if (-not $NoConsole) {
        switch ($Level) {
            'ERROR' { Write-Host $line -ForegroundColor Red }
            'WARN'  { Write-Host $line -ForegroundColor Yellow }
            'OK'    { Write-Host $line -ForegroundColor Green }
            'DEBUG' { Write-Host $line -ForegroundColor DarkGray }
            default { Write-Host $line -ForegroundColor Cyan }
        }
    }
}
#endregion logging

function Show-StartupBanner {
    $banner = @(
        '==============================================================',
        'Developed by Juliano Cunha (GitHub: julianscunha)',
        'Assessment de Licenciamento Broadcom / VMware',
        '=============================================================='
    )
    Write-Host ''
    foreach ($line in $banner) {
        Write-Host $line -ForegroundColor White
    }
    Write-Host ''
}

#region helpers
function New-OutputFolder {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
    return (Resolve-Path -LiteralPath $Path).Path
}

function Add-WarningItem {
    param([string]$Message)
    $script:Warnings.Add($Message) | Out-Null
    Write-Log -Level WARN -Message $Message
}

function Add-InfoItem {
    param([string]$Message)
    $script:Infos.Add($Message) | Out-Null
    Write-Log -Level INFO -Message $Message
}

function Get-SafeVersion {
    param($Version)
    try { return [version]$Version } catch { return [version]'0.0' }
}

function Get-PowerShellFacts {
    $engineVersion = $PSVersionTable.PSVersion
    $edition = $PSVersionTable.PSEdition
    $exe = if ($PSVersionTable.PSVersion.Major -ge 6) { 'pwsh' } else { 'powershell' }
    [pscustomobject]@{
        Edition = $edition
        Version = $engineVersion.ToString()
        Executable = $exe
        ExecutionPolicyProcess = (Get-ExecutionPolicy -Scope Process)
        ExecutionPolicyCurrentUser = (Get-ExecutionPolicy -Scope CurrentUser)
        ExecutionPolicyLocalMachine = (Get-ExecutionPolicy -Scope LocalMachine)
        IsAdmin = ([bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
    }
}

function Get-PowerCLIFacts {
    $available = Get-Module -ListAvailable VMware.PowerCLI | Sort-Object Version -Descending | Select-Object -First 1
    $core = Get-Module -ListAvailable VMware.VimAutomation.Core | Sort-Object Version -Descending | Select-Object -First 1

    [pscustomobject]@{
        PowerCLIInstalled = [bool]$available
        PowerCLIVersion = if ($available) { $available.Version.ToString() } else { $null }
        VimAutomationCoreInstalled = [bool]$core
        VimAutomationCoreVersion = if ($core) { $core.Version.ToString() } else { $null }
        MeetsMinimum133 = if ($available) { ((Get-SafeVersion $available.Version) -ge (Get-SafeVersion '13.3')) } else { $false }
    }
}

function Test-ExecutionPolicyAcceptable {
    param([Parameter(Mandatory)]$PowerShellFacts)
    return [bool](
        $PowerShellFacts.ExecutionPolicyLocalMachine -in @('RemoteSigned','Bypass','Unrestricted') -or
        $PowerShellFacts.ExecutionPolicyCurrentUser -in @('RemoteSigned','Bypass','Unrestricted') -or
        $PowerShellFacts.ExecutionPolicyProcess -in @('Bypass','RemoteSigned','Unrestricted')
    )
}

function Invoke-ExecutionPolicyRemediation {
    param([Parameter(Mandatory)]$PowerShellFacts)

    if (Test-ExecutionPolicyAcceptable -PowerShellFacts $PowerShellFacts) {
        return [pscustomobject]@{ Changed = $false; Approved = $true; Scope = 'None'; PreviousValue = $PowerShellFacts.ExecutionPolicyProcess }
    }

    Write-Log -Level WARN -Message 'A política de execução atual pode impedir a importação/execução de módulos e scripts auxiliares.'
    Write-Host 'Para esta execução, o script pode aplicar temporariamente: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass' -ForegroundColor Yellow
    Write-Host 'Impacto: somente nesta janela/sessão do PowerShell; não altera GPO, vCenter, ESXi ou configurações permanentes do sistema.' -ForegroundColor Yellow
    $answer = (Read-Host 'Deseja aplicar essa alteração temporária agora? (S/N)').ToUpperInvariant()
    if ($answer -notin @('S','SIM','Y','YES')) {
        return [pscustomobject]@{ Changed = $false; Approved = $false; Scope = 'Process'; PreviousValue = $PowerShellFacts.ExecutionPolicyProcess }
    }

    $script:OriginalExecutionPolicyProcess = $PowerShellFacts.ExecutionPolicyProcess
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
    $script:RuntimeChanges.Add([pscustomobject]@{ Change = 'ExecutionPolicy'; Scope = 'Process'; PreviousValue = $script:OriginalExecutionPolicyProcess; NewValue = 'Bypass'; Reverted = $false }) | Out-Null
    Write-Log -Level OK -Message 'ExecutionPolicy ajustada temporariamente para Bypass no escopo Process.'

    return [pscustomobject]@{ Changed = $true; Approved = $true; Scope = 'Process'; PreviousValue = $script:OriginalExecutionPolicyProcess }
}

function Restore-ExecutionPolicyRemediation {
    if ($null -eq $script:OriginalExecutionPolicyProcess) { return }
    try {
        $target = if ([string]::IsNullOrWhiteSpace([string]$script:OriginalExecutionPolicyProcess) -or [string]$script:OriginalExecutionPolicyProcess -eq 'Undefined') { 'Undefined' } else { [string]$script:OriginalExecutionPolicyProcess }
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy $target -Force
        $change = $script:RuntimeChanges | Where-Object { $_.Change -eq 'ExecutionPolicy' } | Select-Object -First 1
        if ($change) { $change.Reverted = $true }
        Write-Log -Level OK -Message "ExecutionPolicy do escopo Process restaurada para '$target'."
    } catch {
        Add-WarningItem "Falha ao restaurar ExecutionPolicy do escopo Process: $($_.Exception.Message)"
    }
}

function Get-CurrentInvalidCertificateAction {
    try {
        $cfg = Get-PowerCLIConfiguration -Scope Session -ErrorAction Stop
        if ($cfg -and $cfg.PSObject.Properties.Name -contains 'InvalidCertificateAction') { return [string]$cfg.InvalidCertificateAction }
    } catch { }
    try {
        $cfg = Get-PowerCLIConfiguration -Scope User -ErrorAction Stop
        if ($cfg -and $cfg.PSObject.Properties.Name -contains 'InvalidCertificateAction') { return [string]$cfg.InvalidCertificateAction }
    } catch { }
    return $null
}

function Test-Prerequisites {
    $psFacts = Get-PowerShellFacts
    $cliFacts = Get-PowerCLIFacts

    $checks = New-Object System.Collections.Generic.List[object]

    $checks.Add([pscustomobject]@{ Check='PowerShell version'; Result = if ((Get-SafeVersion $psFacts.Version) -ge (Get-SafeVersion '5.1')) { 'PASS' } else { 'FAIL' }; Details = "$($psFacts.Edition) $($psFacts.Version)" }) | Out-Null
    $checks.Add([pscustomobject]@{ Check='Execution policy'; Result = if (Test-ExecutionPolicyAcceptable -PowerShellFacts $psFacts) { 'PASS' } else { 'WARN' }; Details = "Process=$($psFacts.ExecutionPolicyProcess); CurrentUser=$($psFacts.ExecutionPolicyCurrentUser); LocalMachine=$($psFacts.ExecutionPolicyLocalMachine)" }) | Out-Null
    $checks.Add([pscustomobject]@{ Check='Run as Administrator'; Result = if ($psFacts.IsAdmin) { 'PASS' } else { 'WARN' }; Details = if ($psFacts.IsAdmin) { 'Elevated session' } else { 'Some installs/config changes may require elevation' } }) | Out-Null
    $checks.Add([pscustomobject]@{ Check='VMware.PowerCLI'; Result = if ($cliFacts.PowerCLIInstalled) { if ($cliFacts.MeetsMinimum133) { 'PASS' } else { 'FAIL' } } else { 'FAIL' }; Details = if ($cliFacts.PowerCLIInstalled) { "Installed version $($cliFacts.PowerCLIVersion)" } else { 'Module not installed' } }) | Out-Null
    $checks.Add([pscustomobject]@{ Check='VMware.VimAutomation.Core'; Result = if ($cliFacts.VimAutomationCoreInstalled) { 'PASS' } else { 'FAIL' }; Details = if ($cliFacts.VimAutomationCoreInstalled) { "Installed version $($cliFacts.VimAutomationCoreVersion)" } else { 'Module not installed' } }) | Out-Null

    foreach ($check in $checks) {
        switch ($check.Result) {
            'PASS' { Write-Log -Level OK -Message ("Prereq OK - {0}: {1}" -f $check.Check, $check.Details) }
            'WARN' { Write-Log -Level WARN -Message ("Prereq warning - {0}: {1}" -f $check.Check, $check.Details) }
            'FAIL' { Write-Log -Level ERROR -Message ("Prereq fail - {0}: {1}" -f $check.Check, $check.Details) }
        }
    }

    if (-not $SkipPrereqInstallHints) {
        if (-not $cliFacts.PowerCLIInstalled) {
            Add-InfoItem 'Install VMware PowerCLI with: Install-Module VMware.PowerCLI -Scope CurrentUser -Force'
        } elseif (-not $cliFacts.MeetsMinimum133) {
            Add-InfoItem 'Update VMware PowerCLI to 13.3 or later. Official Broadcom guidance for KB 312202 requires PowerCLI 13.3 or greater.'
        }

        if (-not (Test-ExecutionPolicyAcceptable -PowerShellFacts $psFacts)) {
            Add-InfoItem 'For test/lab execution only, consider: Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass'
        }
    }

    return [pscustomobject]@{
        PowerShell = $psFacts
        PowerCLI = $cliFacts
        Checks = $checks
        HasBlockingIssue = [bool]($checks | Where-Object { $_.Result -eq 'FAIL' -and $_.Check -ne 'Execution policy' })
    }
}

function Ensure-PowerCLILoaded {
    Import-Module VMware.VimAutomation.Core -ErrorAction Stop
    try { Import-Module VMware.PowerCLI -ErrorAction Stop } catch { }
    try { Import-Module VMware.VimAutomation.Storage -ErrorAction SilentlyContinue } catch { }
}

function Set-CertificateHandling {
    if ($TrustInvalidCertificates) {
        try {
            $script:OriginalInvalidCertificateAction = Get-CurrentInvalidCertificateAction
            Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
            $script:RuntimeChanges.Add([pscustomobject]@{ Change = 'InvalidCertificateAction'; Scope = 'Session'; PreviousValue = $script:OriginalInvalidCertificateAction; NewValue = 'Ignore'; Reverted = $false }) | Out-Null
            Write-Log -Level OK -Message 'Configured PowerCLI InvalidCertificateAction=Ignore somente na sessão atual.'
        } catch {
            Add-WarningItem "Falha ao configurar InvalidCertificateAction=Ignore somente na sessão atual: $($_.Exception.Message)"
        }
    }
}

function Restore-CertificateHandling {
    $change = $script:RuntimeChanges | Where-Object { $_.Change -eq 'InvalidCertificateAction' } | Select-Object -First 1
    if (-not $change) { return }
    try {
        $target = if ([string]::IsNullOrWhiteSpace([string]$script:OriginalInvalidCertificateAction)) { 'Unset' } else { [string]$script:OriginalInvalidCertificateAction }
        if ($target -ne 'Unset') {
            Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction $target -Confirm:$false | Out-Null
        }
        $change.Reverted = $true
        Write-Log -Level OK -Message "InvalidCertificateAction da sessão restaurada para '$target'."
    } catch {
        Add-WarningItem "Falha ao restaurar InvalidCertificateAction da sessão: $($_.Exception.Message)"
    }
}

function Get-ReferenceMatrix {
    [pscustomobject]@{
        MinimumPowerCLIVersion = '13.3'
        MinimumCoresPerCpu = 16
        VCFvSanTiBPerCore = 1.0
        VVFvSanTiBPerCore = 0.25
        Kb312202 = 'https://knowledge.broadcom.com/external/article/312202/license-calculator-for-vmware-cloud-foun.html'
        Kb313548 = 'https://knowledge.broadcom.com/external/article/313548/counting-cores-for-vmware-cloud-foundati.html'
        Kb400416 = 'https://knowledge.broadcom.com/external/article/400416/licensing-script-in-kb-313548-fails-err.html'
        Notes = @(
            'VCF/VVF compute licensing uses total physical cores with a minimum of 16 cores per physical CPU.',
            'vSAN capacity licensing uses raw physical storage claimed by vSAN.',
            'VCF includes 1 TiB of vSAN entitlement per licensed core.',
            'VVF includes 0.25 TiB of vSAN entitlement per licensed core.',
            'For vCenter/vSAN 8.0 U3 and newer, use the updated KB 400416 script logic instead of the older direct claimed-capacity API path.'
        )
    }
}

function Get-MaskedValue {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'N/A' }
    if ($Value.Length -le 8) { return ('*' * $Value.Length) }
    return ('{0}...{1}' -f $Value.Substring(0,4), $Value.Substring($Value.Length-4,4))
}

function Convert-BytesToTiB {
    param([double]$Bytes)
    if ($Bytes -lt 0) { return -1 }
    return ($Bytes / 1TB)
}


function Convert-ToHtmlSafe {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return ($Text.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;'))
}
#endregion helpers

#region inventory and licensing
function Get-LicenseAssignmentSummary {
    param(
        [Parameter(Mandatory)] $Server,
        [switch]$CollectAssignments
    )

    $items = New-Object System.Collections.Generic.List[object]
    $inventory = New-Object System.Collections.Generic.List[object]
    $summary = [ordered]@{
        Server = $Server.Name
        TotalLicenseKeys = 0
        ExpiringIn30Days = 0
        ExpiringIn90Days = 0
        Expired = 0
        EvaluationLicenses = 0
        UnlicensedHosts = 0
        UnlicensedClusters = 0
        ObjectsWithoutLicense = 0
        Status = 'NotCollected'
    }

    if (-not $CollectAssignments) {
        return [pscustomobject]@{
            Assignments = $items
            Inventory = $inventory
            Summary = [pscustomobject]$summary
        }
    }

    try {
        $licenseManager = Get-View -Server $Server $Server.ExtensionData.Content.LicenseManager
        $assignmentManager = Get-View -Server $Server $licenseManager.LicenseAssignmentManager

        $licenseCollection = @()
        if ($licenseManager.PSObject.Properties.Name -contains 'Licenses') {
            $licenseCollection = @($licenseManager.Licenses)
        }

        foreach ($lic in $licenseCollection) {
            $expiration = $null
            foreach ($propName in @('ExpirationDate','expirationDate','Properties')) {
                if ($propName -eq 'Properties' -and $lic.PSObject.Properties.Name -contains 'Properties') {
                    foreach ($p in @($lic.Properties)) {
                        if ($p.Key -match 'expiration|expiry|expires') {
                            try { $expiration = [datetime]$p.Value } catch { }
                            if ($expiration) { break }
                        }
                    }
                } elseif ($lic.PSObject.Properties.Name -contains $propName) {
                    try { $expiration = [datetime]$lic.$propName } catch { }
                    if ($expiration) { break }
                }
            }

            $daysLeft = $null
            $status = 'Active'
            if ($expiration) {
                $daysLeft = [int][math]::Floor(($expiration - (Get-Date)).TotalDays)
                if ($daysLeft -lt 0) {
                    $status = 'Expired'
                    $summary.Expired++
                } elseif ($daysLeft -le 30) {
                    $status = 'ExpiringIn30Days'
                    $summary.ExpiringIn30Days++
                } elseif ($daysLeft -le 90) {
                    $status = 'ExpiringIn90Days'
                    $summary.ExpiringIn90Days++
                }
            }

            $isEvaluation = $false
            foreach ($field in @('EditionKey','Name','CostUnit')) {
                if ($lic.PSObject.Properties.Name -contains $field) {
                    $value = [string]$lic.$field
                    if ($value -match 'eval') { $isEvaluation = $true; break }
                }
            }
            if ($isEvaluation) { $summary.EvaluationLicenses++ }

            $inventory.Add([pscustomobject]@{
                Scope = 'Inventory'
                Name = $Server.Name
                EditionKey = if ($lic.PSObject.Properties.Name -contains 'EditionKey') { $lic.EditionKey } else { $null }
                LicenseName = if ($lic.PSObject.Properties.Name -contains 'Name') { $lic.Name } else { $null }
                LicenseKeyMasked = if ($lic.PSObject.Properties.Name -contains 'LicenseKey') { (Get-MaskedValue -Value $lic.LicenseKey) } else { 'N/A' }
                Total = if ($lic.PSObject.Properties.Name -contains 'Total') { $lic.Total } else { $null }
                Used = if ($lic.PSObject.Properties.Name -contains 'Used') { $lic.Used } else { $null }
                CostUnit = if ($lic.PSObject.Properties.Name -contains 'CostUnit') { $lic.CostUnit } else { $null }
                ExpirationDate = $expiration
                DaysToExpiration = $daysLeft
                Status = $status
                IsEvaluation = $isEvaluation
            }) | Out-Null
        }
        $summary.TotalLicenseKeys = @($inventory).Count

        foreach ($cluster in Get-Cluster -Server $Server) {
            try {
                $assigned = @($assignmentManager.QueryAssignedLicenses($cluster.ExtensionData.MoRef.Value))
                if ($assigned.Count -eq 0) {
                    $summary.UnlicensedClusters++
                    $items.Add([pscustomobject]@{
                        Scope = 'Cluster'
                        Name = $cluster.Name
                        EditionKey = 'UNASSIGNED'
                        LicenseName = 'No direct cluster license assignment found'
                        LicenseKeyMasked = 'N/A'
                        AssignmentStatus = 'UnlicensedOrInherited'
                    }) | Out-Null
                }
                foreach ($a in $assigned) {
                    $items.Add([pscustomobject]@{
                        Scope = 'Cluster'
                        Name = $cluster.Name
                        EditionKey = $a.AssignedLicense.EditionKey
                        LicenseName = $a.AssignedLicense.Name
                        LicenseKeyMasked = Get-MaskedValue -Value $a.AssignedLicense.LicenseKey
                        AssignmentStatus = 'Assigned'
                    }) | Out-Null
                }
            } catch {
                Add-WarningItem "Could not read assigned cluster license for $($cluster.Name) on $($Server.Name): $($_.Exception.Message)"
            }
        }

        foreach ($host in Get-VMHost -Server $Server) {
            try {
                $assigned = @($assignmentManager.QueryAssignedLicenses($host.ExtensionData.MoRef.Value))
                if ($assigned.Count -eq 0) {
                    $summary.UnlicensedHosts++
                    $items.Add([pscustomobject]@{
                        Scope = 'Host'
                        Name = $host.Name
                        EditionKey = 'UNASSIGNED'
                        LicenseName = 'No host license assignment found'
                        LicenseKeyMasked = 'N/A'
                        AssignmentStatus = 'Unlicensed'
                    }) | Out-Null
                }
                foreach ($a in $assigned) {
                    $items.Add([pscustomobject]@{
                        Scope = 'Host'
                        Name = $host.Name
                        EditionKey = $a.AssignedLicense.EditionKey
                        LicenseName = $a.AssignedLicense.Name
                        LicenseKeyMasked = Get-MaskedValue -Value $a.AssignedLicense.LicenseKey
                        AssignmentStatus = 'Assigned'
                    }) | Out-Null
                }
            } catch {
                Add-WarningItem "Could not read assigned host license for $($host.Name) on $($Server.Name): $($_.Exception.Message)"
            }
        }

        $summary.ObjectsWithoutLicense = $summary.UnlicensedHosts + $summary.UnlicensedClusters
        $summary.Status = if ($summary.ObjectsWithoutLicense -gt 0 -or $summary.Expired -gt 0) { 'ActionRequired' } elseif ($summary.ExpiringIn30Days -gt 0 -or $summary.ExpiringIn90Days -gt 0) { 'Attention' } else { 'Healthy' }
    } catch {
        Add-WarningItem "Could not query license assignments on $($Server.Name): $($_.Exception.Message)"
        $summary.Status = 'QueryFailed'
    }

    return [pscustomobject]@{
        Assignments = $items
        Inventory = $inventory
        Summary = [pscustomobject]$summary
    }
}

function Get-EnvironmentInput {
    param([int]$Index)

    Write-Host ''
    Write-Host ("=== Ambiente #{0} ===" -f $Index) -ForegroundColor White
    $name = Read-Host 'Nome amigável do ambiente/cliente'
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "Ambiente-$Index" }

    $server = Read-Host 'FQDN/IP do vCenter'
    $deployment = Read-Host 'Modelo alvo (VCF ou VVF)'
    while ($deployment -notin @('VCF','VVF')) {
        $deployment = (Read-Host 'Informe VCF ou VVF').ToUpperInvariant()
    }

    $clusterFilter = Read-Host 'Nome de cluster específico (Enter = todos)'

    [pscustomobject]@{
        Name = $name
        Server = $server
        DeploymentType = $deployment
        ClusterFilter = if ([string]::IsNullOrWhiteSpace($clusterFilter)) { $null } else { $clusterFilter }
    }
}

function Get-EnvironmentPlan {
    param([string]$ConfigFilePath)

    if ($ConfigFilePath) {
        $content = Get-Content -LiteralPath $ConfigFilePath -Raw | ConvertFrom-Json
        if ($content -is [System.Collections.IEnumerable]) { return @($content) }
        return @($content)
    }

    $plans = New-Object System.Collections.Generic.List[object]
    $index = 1
    do {
        $plans.Add((Get-EnvironmentInput -Index $index)) | Out-Null
        $index++
        $more = (Read-Host 'Há outro ambiente para avaliar? (S/N)').ToUpperInvariant()
    } while ($more -in @('S','SIM','Y','YES'))
    return $plans
}

function Connect-Environment {
    param([Parameter(Mandatory)]$Plan)

    Write-Log -Message "Conectando em $($Plan.Server) para o ambiente '$($Plan.Name)'..."
    try {
        $server = Connect-VIServer -Server $Plan.Server -ErrorAction Stop
        Write-Log -Level OK -Message "Conectado em $($server.Name) (versão $($server.Version))."
        return $server
    } catch {
        throw "Falha ao conectar em $($Plan.Server): $($_.Exception.Message)"
    }
}

function Get-ClusterScope {
    param(
        [Parameter(Mandatory)]$Server,
        [string]$ClusterFilter
    )

    $clusters = if ([string]::IsNullOrWhiteSpace($ClusterFilter)) {
        Get-Cluster -Server $Server | Sort-Object Name
    } else {
        Get-Cluster -Server $Server -Name $ClusterFilter | Sort-Object Name
    }

    return @($clusters)
}

function Get-VsanRawCapacityTiB {
    param(
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)]$Cluster
    )

    function QueryVcClusterHealthSummary {
        param([Parameter(Mandatory)]$ClusterRef)
        $healthSystem = Get-VsanView -Server $Server -Id 'VsanVcClusterHealthSystem-vsan-cluster-health-system'
        return $healthSystem.VsanQueryVcClusterHealthSummary($ClusterRef, $null, $null, $null, $null, $null, 'defaultView')
    }

    function GetDiskGroupCacheDisks {
        param([Parameter(Mandatory)][string]$HostName)
        try {
            $groups = Get-VsanDiskGroup -Server $Server -VMHost $HostName
            return @($groups | ForEach-Object { $_.ExtensionData.ssd.canonicalName })
        } catch {
            Add-WarningItem "Não foi possível obter cache disks do host $HostName no cluster $($Cluster.Name): $($_.Exception.Message)"
            return @()
        }
    }

    $clusterEntity = Get-Cluster -Server $Server -Name $Cluster.Name
    $clusterView = $clusterEntity.ExtensionData
    $isEsa = $false
    if ($null -ne $clusterEntity.VsanEsaEnabled) { $isEsa = [bool]$clusterEntity.VsanEsaEnabled }

    $healthSummary = QueryVcClusterHealthSummary -ClusterRef $clusterView.MoRef
    $physicalDiskHealth = $healthSummary.physicalDisksHealth
    if ($null -eq $physicalDiskHealth) {
        return [pscustomobject]@{
            Success = $true
            RawTiB = 0
            Mode = if ((Get-SafeVersion $Server.Version) -ge (Get-SafeVersion '8.0.3')) { 'KB400416' } else { 'KB313548' }
            Warning = $null
        }
    }

    $vmHosts = @(Get-Cluster -Server $Server -Name $Cluster.Name | Get-VMHost)
    foreach ($vmhost in $vmHosts) {
        if ($vmhost.ConnectionState -notin @('Connected','Maintenance')) {
            return [pscustomobject]@{
                Success = $false
                RawTiB = -1
                Mode = 'HEALTH-CHECK'
                Warning = "Host $($vmhost.Name) não está conectado."
            }
        }
    }

    $totalBytes = [double]0
    $hostNames = @($vmHosts | ForEach-Object { $_.Name })

    foreach ($hostPhysicalDiskHealth in $physicalDiskHealth) {
        $hostname = $hostPhysicalDiskHealth.hostname
        if ($hostNames -notcontains $hostname) { continue }
        if ($hostPhysicalDiskHealth.error) {
            return [pscustomobject]@{
                Success = $false
                RawTiB = -1
                Mode = 'HEALTH-CHECK'
                Warning = "vSAN health retornou erro ao coletar discos do host $hostname."
            }
        }

        $disks = $hostPhysicalDiskHealth.disks
        if ($null -eq $disks) { continue }
        $cacheDisks = @()
        if (-not $isEsa) { $cacheDisks = GetDiskGroupCacheDisks -HostName $hostname }

        foreach ($disk in $disks) {
            if (-not $isEsa) {
                $diskName = if ($disk.ScsiDisk -and $disk.ScsiDisk.canonicalName) { $disk.ScsiDisk.canonicalName } else { $disk.name }
                if ($cacheDisks -contains $diskName) { continue }
            }
            $capacity = $disk.ScsiDisk.capacity
            if ($null -eq $capacity) { continue }
            $totalBytes += ($capacity.block * $capacity.blockSize)
        }
    }

    $rawTiB = Convert-BytesToTiB -Bytes $totalBytes
    $mode = if ((Get-SafeVersion $Server.Version) -ge (Get-SafeVersion '8.0.3')) { 'KB400416' } else { 'KB313548-compatible' }
    return [pscustomobject]@{
        Success = $true
        RawTiB = $rawTiB
        Mode = $mode
        Warning = $null
    }
}

function Test-IsVsanCluster {
    param([Parameter(Mandatory)]$Cluster)
    try {
        if ($Cluster.ExtensionData.ConfigurationEx.VsanConfigInfo.Enabled) { return $true }
    } catch { }

    try {
        $hosts = @(Get-Cluster -Name $Cluster.Name | Get-VMHost)
        foreach ($h in $hosts) {
            if ($h.ExtensionData.Runtime.VsanRuntimeInfo.MembershipList) { return $true }
        }
    } catch { }
    return $false
}

function Get-EnvironmentAssessment {
    param(
        [Parameter(Mandatory)]$Server,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Reference
    )

    $clusters = Get-ClusterScope -Server $Server -ClusterFilter $Plan.ClusterFilter
    if (-not $clusters -or $clusters.Count -eq 0) {
        throw "Nenhum cluster encontrado para o filtro '$($Plan.ClusterFilter)' em $($Server.Name)."
    }

    $allClusterRows = New-Object System.Collections.Generic.List[object]
    $allHostRows = New-Object System.Collections.Generic.List[object]
    $versionRows = New-Object System.Collections.Generic.List[object]

    foreach ($cluster in $clusters) {
        Write-Log -Message "Analisando cluster $($cluster.Name)..."
        $hosts = @(Get-Cluster -Server $Server -Name $cluster.Name | Get-VMHost | Sort-Object Name)
        $isVsan = Test-IsVsanCluster -Cluster $cluster

        $clusterCoreTotal = 0
        $clusterEntitledTiB = 0.0
        foreach ($host in $hosts) {
            $sockets = [int]$host.ExtensionData.Hardware.CpuInfo.NumCpuPackages
            $totalCores = [int]$host.ExtensionData.Hardware.CpuInfo.NumCpuCores
            $coresPerSocket = if ($sockets -gt 0) { [int]($totalCores / $sockets) } else { 0 }
            $licCoresPerCpu = [Math]::Max($Reference.MinimumCoresPerCpu, $coresPerSocket)
            $licensedCores = $sockets * $licCoresPerCpu
            $entitledTiB = if ($Plan.DeploymentType -eq 'VCF') { $licensedCores * $Reference.VCFvSanTiBPerCore } else { $licensedCores * $Reference.VVFvSanTiBPerCore }

            $clusterCoreTotal += $licensedCores
            $clusterEntitledTiB += $entitledTiB

            $allHostRows.Add([pscustomobject]@{
                EnvironmentName = $Plan.Name
                vCenter = $Server.Name
                DeploymentType = $Plan.DeploymentType
                Cluster = $cluster.Name
                Host = $host.Name
                ESXiVersion = $host.Version
                ESXiBuild = $host.Build
                CpuSockets = $sockets
                CoresPerSocketActual = $coresPerSocket
                CoresPerSocketLicensed = $licCoresPerCpu
                LicensedCores = $licensedCores
                vSanEntitledTiB = [math]::Round($entitledTiB, 2)
                ClusterIsvSAN = $isVsan
            }) | Out-Null

            $versionRows.Add([pscustomobject]@{
                EnvironmentName = $Plan.Name
                vCenter = $Server.Name
                Cluster = $cluster.Name
                Host = $host.Name
                vCenterVersion = $Server.Version
                ESXiVersion = $host.Version
                ESXiBuild = $host.Build
            }) | Out-Null
        }

        $rawTiB = 0.0
        $capacityMode = 'N/A'
        $capacityStatus = 'NotApplicable'
        $capacityWarning = $null
        if ($isVsan) {
            $cap = Get-VsanRawCapacityTiB -Server $Server -Cluster $cluster
            $capacityMode = $cap.Mode
            $capacityStatus = if ($cap.Success) { 'Success' } else { 'Warning' }
            $capacityWarning = $cap.Warning
            if ($cap.Success) {
                $rawTiB = [math]::Ceiling($cap.RawTiB)
            } else {
                $rawTiB = 0
                Add-WarningItem "Cluster $($cluster.Name): $($cap.Warning)"
            }
        }

        $clusterAddOn = [math]::Max(0, $rawTiB - [math]::Floor($clusterEntitledTiB))
        $recommended = if ($isVsan -and $clusterAddOn -gt 0) { "$($Plan.DeploymentType) + vSAN Add-on" } else { $Plan.DeploymentType }

        $allClusterRows.Add([pscustomobject]@{
            EnvironmentName = $Plan.Name
            vCenter = $Server.Name
            DeploymentType = $Plan.DeploymentType
            Cluster = $cluster.Name
            HostCount = $hosts.Count
            vCenterVersion = $Server.Version
            vSANEnabled = $isVsan
            ComputeCoresRequired = $clusterCoreTotal
            vSanEntitledTiB = [math]::Round($clusterEntitledTiB, 2)
            vSanRawTiBRequired = $rawTiB
            vSanAddOnTiBRequired = $clusterAddOn
            CapacityCalculationMode = $capacityMode
            CapacityStatus = $capacityStatus
            CapacityWarning = $capacityWarning
            RecommendedTarget = $recommended
        }) | Out-Null
    }

    $licenseInfo = Get-LicenseAssignmentSummary -Server $Server -CollectAssignments:$CollectLicenseAssignments
    $licenseAssignments = @($licenseInfo.Assignments)
    $licenseInventory = @($licenseInfo.Inventory)
    $licenseSummary = $licenseInfo.Summary

    $envComputeTotal = [int](($allClusterRows | Measure-Object -Property ComputeCoresRequired -Sum).Sum)
    $envEntitled = [double](($allClusterRows | Measure-Object -Property vSanEntitledTiB -Sum).Sum)
    $envRawTiB = [double](($allClusterRows | Measure-Object -Property vSanRawTiBRequired -Sum).Sum)
    $envVsanAddOn = [math]::Max(0, [math]::Ceiling($envRawTiB - [math]::Floor($envEntitled)))

    $comparison = [pscustomobject]@{
        EnvironmentName = $Plan.Name
        vCenter = $Server.Name
        CurrentAssignmentsCount = @($licenseAssignments).Count
        RecommendedModel = if ($envVsanAddOn -gt 0) { "$($Plan.DeploymentType) + vSAN Add-on" } else { $Plan.DeploymentType }
        ComputeCoresRequired = $envComputeTotal
        vSanEntitledTiB = [math]::Round($envEntitled, 2)
        vSanRawTiBRequired = [math]::Round($envRawTiB, 2)
        vSanAddOnTiBRequired = $envVsanAddOn
        ReferenceRule = if ($Plan.DeploymentType -eq 'VCF') { '1 TiB/core of vSAN entitlement' } else { '0.25 TiB/core of vSAN entitlement' }
        CurrentLicenseStatus = $licenseSummary.Status
        CurrentLicenseKeys = $licenseSummary.TotalLicenseKeys
        LicensesExpiringIn30Days = $licenseSummary.ExpiringIn30Days
        LicensesExpiringIn90Days = $licenseSummary.ExpiringIn90Days
        ExpiredLicenses = $licenseSummary.Expired
        UnlicensedObjects = $licenseSummary.ObjectsWithoutLicense
    }

    [pscustomobject]@{
        Plan = $Plan
        Server = $Server.Name
        ServerVersion = $Server.Version
        Clusters = $allClusterRows
        Hosts = $allHostRows
        Versions = $versionRows
        LicenseAssignments = $licenseAssignments
        LicenseInventory = $licenseInventory
        LicenseSummary = $licenseSummary
        Comparison = $comparison
    }
}
#endregion inventory and licensing

#region reporting

function New-HtmlReport {
    param(
        [Parameter(Mandatory)]$AssessmentBundle,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Prereqs,
        [Parameter(Mandatory)]$Reference
    )

    function Format-Number {
        param($Value)
        if ($null -eq $Value) { return '0' }
        if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
            return ('{0:N2}' -f [double]$Value)
        }
        return ('{0:N0}' -f [double]$Value)
    }

    function New-ProgressBlock {
        param(
            [string]$Title,
            [double]$Value,
            [double]$Max,
            [string]$Suffix,
            [string]$Tone = 'blue',
            [string]$Hint = ''
        )
        if ($Max -le 0) { $Max = 1 }
        $pct = [math]::Round(([math]::Min($Value, $Max) / $Max) * 100, 0)
        return @"
<div class='metric-card'>
  <div class='metric-top'>
    <div class='metric-title'>$Title</div>
    <div class='metric-value'>$(Format-Number $Value) $Suffix</div>
  </div>
  <div class='bar-track'><div class='bar-fill tone-$Tone' style='width: $pct%;'></div></div>
  <div class='metric-hint'>$Hint</div>
</div>
"@
    }

    function New-StatCard {
        param([string]$Label,[string]$Value,[string]$Sub='')
        return @"
<div class='stat-card'>
  <div class='stat-label'>$Label</div>
  <div class='stat-value'>$Value</div>
  <div class='stat-sub'>$Sub</div>
</div>
"@
    }

    $allClusterRows = @($AssessmentBundle.Environments | ForEach-Object { $_.Clusters })
    $allHostRows = @($AssessmentBundle.Environments | ForEach-Object { $_.Hosts })
    $global = @($AssessmentBundle.GlobalSummary)[0]
    $maxCompute = [double]([math]::Max(1, (@($allClusterRows | Measure-Object -Property ComputeCoresRequired -Maximum).Maximum)))
    $maxRaw = [double]([math]::Max(1, (@($allClusterRows | Measure-Object -Property vSanRawTiBRequired -Maximum).Maximum)))
    $maxAddOn = [double]([math]::Max(1, (@($allClusterRows | Measure-Object -Property vSanAddOnTiBRequired -Maximum).Maximum)))

    $style = @"
<style>
:root{--bg:#07111f;--panel:#ffffff;--ink:#0f172a;--muted:#64748b;--line:#d9e2ec;--blue:#2563eb;--blue2:#60a5fa;--indigo:#3730a3;--green:#16a34a;--amber:#d97706;--red:#dc2626;--slate:#1e293b;--paper:#f4f7fb;--soft:#eef5ff;}
@page { size:A4; margin:12mm; }
*{box-sizing:border-box;}
body{margin:0;font-family:Segoe UI,Arial,sans-serif;background:linear-gradient(180deg,#eaf1fb 0,#f7f9fc 220px,#f7f9fc 100%);color:var(--ink);font-size:12px;line-height:1.45;}
.container{max-width:1200px;margin:0 auto;padding:24px;}
.hero{background:radial-gradient(circle at top right,#1d4ed8 0,#0b1f48 48%,#081226 100%);color:#fff;border-radius:24px;padding:28px 30px;box-shadow:0 18px 48px rgba(8,18,38,.18);position:relative;overflow:hidden;}
.hero:after{content:'';position:absolute;right:-80px;top:-80px;width:240px;height:240px;border-radius:999px;background:rgba(255,255,255,.08);}
.hero .eyebrow{font-size:11px;text-transform:uppercase;letter-spacing:.8px;opacity:.9;}
.hero h1{margin:10px 0 8px 0;font-size:30px;line-height:1.1;max-width:780px;}
.hero p{margin:6px 0;max-width:840px;color:rgba(255,255,255,.9);}
.meta-row{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;margin-top:18px;}
.meta-box{background:rgba(255,255,255,.08);border:1px solid rgba(255,255,255,.12);border-radius:14px;padding:12px 14px;backdrop-filter: blur(6px);}
.meta-box .k{font-size:10px;text-transform:uppercase;opacity:.82;}
.meta-box .v{font-size:18px;font-weight:700;margin-top:4px;}
.section{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:22px;margin-top:18px;box-shadow:0 8px 28px rgba(15,23,42,.05);}
.section h2{margin:0 0 10px 0;font-size:20px;color:var(--slate);}
.section h3{margin:18px 0 10px 0;font-size:15px;color:var(--indigo);}
.lead{color:var(--muted);margin-top:0;margin-bottom:14px;}
.stats-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px;}
.stat-card{border:1px solid var(--line);border-radius:16px;padding:14px;background:linear-gradient(180deg,#fff,#f8fbff);}
.stat-label{font-size:11px;color:var(--muted);text-transform:uppercase;letter-spacing:.4px;}
.stat-value{font-size:26px;font-weight:800;color:var(--slate);margin-top:4px;}
.stat-sub{font-size:11px;color:var(--muted);margin-top:6px;}
.metric-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;}
.metric-card{border:1px solid var(--line);border-radius:16px;padding:14px;background:#fff;}
.metric-top{display:flex;justify-content:space-between;gap:10px;align-items:flex-end;}
.metric-title{font-weight:700;color:var(--slate);}
.metric-value{font-weight:800;color:var(--blue);}
.bar-track{height:12px;border-radius:999px;background:#edf2f7;overflow:hidden;margin-top:10px;border:1px solid #e2e8f0;}
.bar-fill{height:100%;border-radius:999px;}
.tone-blue{background:linear-gradient(90deg,#2563eb,#60a5fa);}
.tone-green{background:linear-gradient(90deg,#16a34a,#4ade80);}
.tone-amber{background:linear-gradient(90deg,#d97706,#fbbf24);}
.tone-red{background:linear-gradient(90deg,#dc2626,#fb7185);}
.metric-hint{font-size:11px;color:var(--muted);margin-top:8px;}
.callout{background:linear-gradient(180deg,#eff6ff,#f8fbff);border:1px solid #cfe0ff;border-left:6px solid var(--blue);border-radius:14px;padding:14px 16px;}
.badge-row{display:flex;gap:8px;flex-wrap:wrap;}
.badge{display:inline-flex;align-items:center;padding:5px 10px;border-radius:999px;border:1px solid #dbeafe;background:#eff6ff;color:#1e3a8a;font-size:11px;font-weight:700;}
.dual{display:grid;grid-template-columns:1.25fr .75fr;gap:14px;}
.calc-box{background:#fbfdff;border:1px dashed #cbd5e1;border-radius:14px;padding:14px;}
.formula{font-family:Consolas,Menlo,monospace;background:#0f172a;color:#e2e8f0;padding:10px 12px;border-radius:10px;display:block;margin:8px 0;font-size:11px;white-space:pre-wrap;}
table{width:100%;border-collapse:collapse;font-size:11px;margin:0 0 14px 0;}
th,td{border:1px solid var(--line);padding:7px 8px;vertical-align:top;}
th{background:#eff6ff;color:#1e293b;text-align:left;}
tr:nth-child(even) td{background:#fbfcfe;}
.small{font-size:11px;color:var(--muted);}
.list-clean{margin:8px 0 0 0;padding-left:18px;}
.list-clean li{margin:4px 0;}
.footer{text-align:center;color:var(--muted);font-size:11px;margin:20px 0 8px 0;}
.status-ok{color:var(--green);font-weight:700;}
.status-warn{color:var(--amber);font-weight:700;}
.status-fail{color:var(--red);font-weight:700;}
@media print{body{background:#fff;}.container{padding:0;max-width:none;}.section,.hero{box-shadow:none;}}
</style>
"@

    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $html = New-Object System.Collections.Generic.List[string]
    $html.Add('<html><head><meta charset="utf-8" />')
    $html.Add($style)
    $html.Add('</head><body><div class="container">')
    $html.Add('<div class="hero">')
    $html.Add('<div class="eyebrow'>Generated by Juliano Cunha (GitHub: julianscunha)</div>')
    $html.Add('<h1>Broadcom / VMware Licensing Executive Assessment</h1>')
    $html.Add('<p>Executive dashboard generated from collected vCenter inventory, licensing assignments, and Broadcom-aligned calculation rules.</p>')
    $html.Add('<p><strong>Developed by Juliano Cunha (GitHub: julianscunha)</strong></p>')
    $html.Add('<div class="meta-row">')
    $html.Add("<div class='meta-box'><div class='k'>Generated at</div><div class='v'>$generatedAt</div></div>")
    $html.Add("<div class='meta-box'><div class='k'>Environments</div><div class='v'>$($global.TotalEnvironments)</div></div>")
    $html.Add("<div class='meta-box'><div class='k'>Compute Required</div><div class='v'>$($global.TotalComputeCoresRequired) cores</div></div>")
    $html.Add("<div class='meta-box'><div class='k'>vSAN Add-on</div><div class='v'>$($global.TotalvSanAddOnTiBRequired) TiB</div></div>")
    $html.Add('</div></div>')

    $html.Add('<div class="section">')
    $html.Add('<h2>Executive summary</h2>')
    $html.Add('<p class="lead">High-level dashboard summarizing the recommended licensing position, current observed licensing status, and total vSAN raw capacity considered in the assessment.</p>')
    $html.Add('<div class="stats-grid">')
    $html.Add((New-StatCard -Label 'Compute cores required' -Value "$($global.TotalComputeCoresRequired)" -Sub 'Total licensed cores required across all environments'))
    $html.Add((New-StatCard -Label 'Included vSAN entitlement' -Value "$(Format-Number $global.TotalvSanEntitledTiB) TiB" -Sub 'Based on the selected target model and current Broadcom rules'))
    $html.Add((New-StatCard -Label 'Total vSAN raw measured' -Value "$(Format-Number $global.TotalvSanRawTiBRequired) TiB" -Sub 'Raw capacity claimed by vSAN clusters'))
    $html.Add((New-StatCard -Label 'Additional vSAN required' -Value "$($global.TotalvSanAddOnTiBRequired) TiB" -Sub 'Rounded additional TiB required above included entitlement'))
    $html.Add('</div>')
    $html.Add('<div style="height:12px"></div>')
    $html.Add('<div class="metric-grid">')
    $html.Add((New-ProgressBlock -Title 'Total compute requirement' -Value $global.TotalComputeCoresRequired -Max ([math]::Max(1,$global.TotalComputeCoresRequired)) -Suffix 'cores' -Tone 'blue' -Hint 'Sum of licensed cores across all assessed hosts.'))
    $html.Add((New-ProgressBlock -Title 'vSAN entitlement coverage' -Value $global.TotalvSanEntitledTiB -Max ([math]::Max($global.TotalvSanEntitledTiB,$global.TotalvSanRawTiBRequired,1)) -Suffix 'TiB' -Tone 'green' -Hint 'Included vSAN entitlement available from selected subscriptions.'))
    $html.Add((New-ProgressBlock -Title 'vSAN raw measured' -Value $global.TotalvSanRawTiBRequired -Max ([math]::Max($global.TotalvSanEntitledTiB,$global.TotalvSanRawTiBRequired,1)) -Suffix 'TiB' -Tone 'amber' -Hint 'Measured raw vSAN capacity claimed by the cluster(s).'))
    $html.Add((New-ProgressBlock -Title 'Additional vSAN Add-on' -Value $global.TotalvSanAddOnTiBRequired -Max ([math]::Max($global.TotalvSanRawTiBRequired,1)) -Suffix 'TiB' -Tone 'red' -Hint 'Additional TiB required after entitlement offset.'))
    $html.Add('</div>')
    $html.Add('<div style="height:12px"></div>')
    $html.Add('<div class="callout"><strong>Executive takeaway.</strong>')
    $html.Add('<ul class="list-clean">')
    $html.Add("<li>Total consolidated compute requirement: <strong>$($global.TotalComputeCoresRequired) cores</strong>.</li>")
    $html.Add("<li>Total included vSAN entitlement: <strong>$(Format-Number $global.TotalvSanEntitledTiB) TiB</strong>.</li>")
    $html.Add("<li>Total raw vSAN measured: <strong>$(Format-Number $global.TotalvSanRawTiBRequired) TiB</strong>.</li>")
    $html.Add("<li>Additional vSAN Add-on recommended: <strong>$($global.TotalvSanAddOnTiBRequired) TiB</strong>.</li>")
    $html.Add("<li>Objects currently detected without license: <strong>$($global.TotalObjectsWithoutLicense)</strong>.</li>")
    $html.Add('</ul></div></div>')

    $html.Add('<div class="section">')
    $html.Add('<h2>Calculation standard and methodology</h2>')
    $html.Add('<p class="lead">This report explicitly shows the active calculation model used by the script so the customer can understand how the final numbers were produced.</p>')
    $html.Add('<div class="dual">')
    $html.Add('<div class="calc-box">')
    $html.Add('<h3>Current rule set</h3><ul class="list-clean">')
    foreach ($n in $Reference.Notes) { $html.Add("<li>$(Convert-ToHtmlSafe -Text $n)</li>") }
    $html.Add('</ul>')
    $html.Add('<span class="formula">Compute cores per host = CPU sockets × max(actual cores per CPU, 16)</span>')
    $html.Add('<span class="formula">Environment compute total = Σ licensed cores for all hosts</span>')
    $html.Add('<span class="formula">VCF included vSAN entitlement = compute cores × 1.00 TiB</span>')
    $html.Add('<span class="formula">VVF included vSAN entitlement = compute cores × 0.25 TiB</span>')
    $html.Add('<span class="formula">vSAN Add-on required = max( ceiling(raw vSAN TiB − floor(included entitlement TiB)), 0 )</span>')
    $html.Add('</div>')
    $html.Add('<div class="calc-box">')
    $html.Add('<h3>Sources referenced</h3>')
    $html.Add("<ul class='list-clean'><li><a href='$($Reference.Kb312202)'>KB 312202</a></li><li><a href='$($Reference.Kb313548)'>KB 313548</a></li><li><a href='$($Reference.Kb400416)'>KB 400416</a></li></ul>")
    $html.Add('<p class="small">The script uses an embedded reference matrix based on Broadcom public guidance. It does not depend on live scraping from Broadcom at runtime.</p>')
    $html.Add('</div></div></div>')

    $html.Add('<div class="section">')
    $html.Add('<h2>Prerequisite validation</h2>')
    $html.Add('<p class="lead">Validation of the local session used to run the assessment, including PowerShell, PowerCLI, permissions, and temporary session changes.</p>')
    $html.Add((($Prereqs.Checks | ConvertTo-Html -Fragment) -join "`n"))
    $html.Add('</div>')

    foreach ($env in $AssessmentBundle.Environments) {
        $comparison = @($env.Comparison)[0]
        $licenseSummary = @($env.LicenseSummary)[0]
        $envMax = [double]([math]::Max(1, (@($env.Clusters | Measure-Object -Property ComputeCoresRequired -Maximum).Maximum)))
        $envMaxRaw = [double]([math]::Max(1, (@($env.Clusters | Measure-Object -Property vSanRawTiBRequired -Maximum).Maximum, @($env.Clusters | Measure-Object -Property vSanEntitledTiB -Maximum).Maximum | Measure-Object -Maximum).Maximum))

        $html.Add('<div class="section">')
        $html.Add("<div style='display:flex;justify-content:space-between;gap:12px;align-items:flex-start;flex-wrap:wrap;'><div><h2 style='margin-bottom:6px;'>Environment: $(Convert-ToHtmlSafe -Text $env.Plan.Name)</h2><div class='small'>vCenter: $(Convert-ToHtmlSafe -Text $env.Server) | Version: $(Convert-ToHtmlSafe -Text $env.ServerVersion)</div></div><div class='badge-row'><span class='badge'>Target model: $($env.Plan.DeploymentType)</span><span class='badge'>Compute: $($comparison.ComputeCoresRequired) cores</span><span class='badge'>vSAN Add-on: $($comparison.vSanAddOnTiBRequired) TiB</span></div></div>")
        $html.Add('<div style="height:12px"></div>')
        $html.Add('<div class="stats-grid">')
        $html.Add((New-StatCard -Label 'Recommended model' -Value "$($comparison.RecommendedModel)" -Sub 'Model inferred from measured compute and vSAN position'))
        $html.Add((New-StatCard -Label 'Included entitlement' -Value "$(Format-Number $comparison.vSanEntitledTiB) TiB" -Sub "$($comparison.ReferenceRule)"))
        $html.Add((New-StatCard -Label 'Raw vSAN measured' -Value "$(Format-Number $comparison.vSanRawTiBRequired) TiB" -Sub 'Rounded raw capacity used in the calculation'))
        $html.Add((New-StatCard -Label 'Unlicensed objects' -Value "$($comparison.UnlicensedObjects)" -Sub 'Objects detected without current license assignment'))
        $html.Add('</div>')
        $html.Add('<div style="height:12px"></div>')
        $html.Add('<div class="metric-grid">')
        foreach ($cluster in $env.Clusters) {
            $html.Add((New-ProgressBlock -Title ("$($cluster.Cluster) · Compute") -Value $cluster.ComputeCoresRequired -Max $envMax -Suffix 'cores' -Tone 'blue' -Hint ("Licensed compute after the 16-core-per-CPU rule.")))
        }
        foreach ($cluster in $env.Clusters) {
            $tone = if ($cluster.vSanAddOnTiBRequired -gt 0) { 'red' } elseif ($cluster.vSanRawTiBRequired -gt 0) { 'amber' } else { 'green' }
            $hint = if ($cluster.vSANEnabled) { "Raw $(Format-Number $cluster.vSanRawTiBRequired) TiB | Included $(Format-Number $cluster.vSanEntitledTiB) TiB | Add-on $($cluster.vSanAddOnTiBRequired) TiB" } else { 'No vSAN capacity collected for this cluster.' }
            $html.Add((New-ProgressBlock -Title ("$($cluster.Cluster) · vSAN") -Value $cluster.vSanRawTiBRequired -Max $envMaxRaw -Suffix 'TiB' -Tone $tone -Hint $hint))
        }
        $html.Add('</div>')
        $html.Add('<div style="height:12px"></div>')
        $html.Add('<div class="callout">')
        $html.Add("<strong>Recommended comparison.</strong> Preliminary recommendation of <strong>$($comparison.ComputeCoresRequired) cores</strong> for <strong>$($env.Plan.DeploymentType)</strong>, with <strong>$(Format-Number $comparison.vSanEntitledTiB) TiB</strong> included entitlement, <strong>$(Format-Number $comparison.vSanRawTiBRequired) TiB</strong> measured raw capacity, and <strong>$($comparison.vSanAddOnTiBRequired) TiB</strong> additional vSAN Add-on.")
        $html.Add('</div>')

        $html.Add('<h3>Calculation walkthrough</h3>')
        $walk = foreach ($cluster in $env.Clusters) {
            $clusterHosts = @($env.Hosts | Where-Object { $_.Cluster -eq $cluster.Cluster })
            $socketTotal = [int](($clusterHosts | Measure-Object -Property CpuSockets -Sum).Sum)
            $actualCores = if ($clusterHosts.Count -gt 0) { ($clusterHosts | Select-Object -First 1).CoresPerSocketActual } else { 0 }
            $licensedPerCpu = if ($clusterHosts.Count -gt 0) { ($clusterHosts | Select-Object -First 1).CoresPerSocketLicensed } else { 0 }
            [pscustomobject]@{
                Cluster = $cluster.Cluster
                Hosts = $cluster.HostCount
                TotalCpuSockets = $socketTotal
                ActualCoresPerCpu = $actualCores
                LicensedCoresPerCpu = $licensedPerCpu
                ComputeFormula = "0 sockets × 1 licensed cores" -f $socketTotal, $licensedPerCpu
                ComputeCoresRequired = $cluster.ComputeCoresRequired
                IncludedvSanTiB = $cluster.vSanEntitledTiB
                RawvSanTiB = $cluster.vSanRawTiBRequired
                vSanAddOnTiB = $cluster.vSanAddOnTiBRequired
                CapacityMode = $cluster.CapacityCalculationMode
                CapacityStatus = $cluster.CapacityStatus
            }
        }
        $html.Add((($walk | ConvertTo-Html -Fragment) -join "`n"))

        if ($licenseSummary) {
            $html.Add('<h3>Current licensing health</h3>')
            $html.Add((($env.LicenseSummary | ConvertTo-Html -Fragment) -join "`n"))
        }
        if (@($env.LicenseInventory).Count -gt 0) {
            $html.Add('<h3>License inventory</h3>')
            $html.Add((($env.LicenseInventory | ConvertTo-Html -Fragment) -join "`n"))
        }
        if (@($env.LicenseAssignments).Count -gt 0) {
            $html.Add('<h3>Current assignments and unlicensed objects</h3>')
            $html.Add((($env.LicenseAssignments | ConvertTo-Html -Fragment) -join "`n"))
        }
        $html.Add('<h3>Cluster-level summary</h3>')
        $html.Add((($env.Clusters | ConvertTo-Html -Fragment) -join "`n"))
        $html.Add('<h3>Host-level summary</h3>')
        $html.Add((($env.Hosts | ConvertTo-Html -Fragment) -join "`n"))
        $html.Add('</div>')
    }

    if (@($AssessmentBundle.RuntimeChanges).Count -gt 0) {
        $html.Add('<div class="section">')
        $html.Add('<h2>Temporary runtime changes</h2>')
        $html.Add('<p class="lead">All changes below are session-scoped, intended to avoid permanent impact to the workstation or the virtualized environment, and are restored when possible at the end of the run.</p>')
        $html.Add(((@($AssessmentBundle.RuntimeChanges) | ConvertTo-Html -Fragment) -join "`n"))
        $html.Add('</div>')
    }

    if ($script:Warnings.Count -gt 0) {
        $html.Add('<div class="section">')
        $html.Add('<h2>Warnings and caveats</h2><ul class="list-clean">')
        foreach ($w in $script:Warnings) { $html.Add("<li>$(Convert-ToHtmlSafe -Text $w)</li>") }
        $html.Add('</ul></div>')
    }

    $html.Add('<div class="section">')
    $html.Add('<h2>References used by the assessment</h2>')
    $html.Add('<ul class="list-clean">')
    foreach ($n in $Reference.Notes) { $html.Add("<li>$(Convert-ToHtmlSafe -Text $n)</li>") }
    $html.Add("<li><a href='$($Reference.Kb312202)'>KB 312202</a></li>")
    $html.Add("<li><a href='$($Reference.Kb313548)'>KB 313548</a></li>")
    $html.Add("<li><a href='$($Reference.Kb400416)'>KB 400416</a></li>")
    $html.Add('</ul></div>')
    $html.Add("<div class='footer'>Generated by Juliano Cunha (GitHub: julianscunha)</div>")
    $html.Add('</div></body></html>')

    $html -join "`n" | Set-Content -Path $Path -Encoding UTF8
}

function Convert-HtmlToPdf {
    param(
        [Parameter(Mandatory)][string]$HtmlPath,
        [Parameter(Mandatory)][string]$PdfPath
    )

    $edgeCandidates = @(
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
        "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe"
    ) | Where-Object { $_ -and (Test-Path $_) }

    if ($edgeCandidates.Count -gt 0) {
        $browser = $edgeCandidates[0]
        $uri = 'file:///' + ($HtmlPath -replace '\\','/')
        $args = @('--headless', '--disable-gpu', "--print-to-pdf=$PdfPath", $uri)
        $proc = Start-Process -FilePath $browser -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
        if (Test-Path -LiteralPath $PdfPath) { return $true }
        Add-WarningItem "Falha ao converter HTML em PDF com $browser (ExitCode $($proc.ExitCode))."
    }

    try {
        $word = New-Object -ComObject Word.Application
        $word.Visible = $false
        $doc = $word.Documents.Open($HtmlPath)
        $wdFormatPDF = 17
        $doc.SaveAs([ref]$PdfPath, [ref]$wdFormatPDF)
        $doc.Close()
        $word.Quit()
        if (Test-Path -LiteralPath $PdfPath) { return $true }
    } catch {
        Add-WarningItem "Não foi possível converter o relatório para PDF automaticamente: $($_.Exception.Message)"
    }

    return $false
}

function Save-Outputs {
    param(
        [Parameter(Mandatory)]$AssessmentBundle,
        [Parameter(Mandatory)][string]$Folder,
        [Parameter(Mandatory)]$Prereqs,
        [Parameter(Mandatory)]$Reference
    )

    $clustersCsv = Join-Path $Folder 'clusters.csv'
    $hostsCsv = Join-Path $Folder 'hosts.csv'
    $licensesCsv = Join-Path $Folder 'license-assignments.csv'
    $licenseInventoryCsv = Join-Path $Folder 'license-inventory.csv'
    $summaryCsv = Join-Path $Folder 'summary.csv'
    $jsonPath = Join-Path $Folder 'assessment.json'
    $htmlPath = Join-Path $Folder 'assessment-report.html'
    $pdfPath = Join-Path $Folder 'assessment-report.pdf'

    $allClusters = @($AssessmentBundle.Environments | ForEach-Object { $_.Clusters })
    $allHosts = @($AssessmentBundle.Environments | ForEach-Object { $_.Hosts })
    $allLicenses = @($AssessmentBundle.Environments | ForEach-Object { $_.LicenseAssignments })
    $allLicenseInventory = @($AssessmentBundle.Environments | ForEach-Object { $_.LicenseInventory })
    $allSummary = @($AssessmentBundle.Environments | ForEach-Object { $_.Comparison })

    $allClusters | Export-Csv -LiteralPath $clustersCsv -NoTypeInformation -Encoding UTF8
    $allHosts | Export-Csv -LiteralPath $hostsCsv -NoTypeInformation -Encoding UTF8
    $allSummary | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8
    if ($allLicenses.Count -gt 0) { $allLicenses | Export-Csv -LiteralPath $licensesCsv -NoTypeInformation -Encoding UTF8 }
    if ($allLicenseInventory.Count -gt 0) { $allLicenseInventory | Export-Csv -LiteralPath $licenseInventoryCsv -NoTypeInformation -Encoding UTF8 }

    $AssessmentBundle | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8
    New-HtmlReport -AssessmentBundle $AssessmentBundle -Path $htmlPath -Prereqs $Prereqs -Reference $Reference
    if ($ExportPdf) { [void](Convert-HtmlToPdf -HtmlPath $htmlPath -PdfPath $pdfPath) }

    return [pscustomobject]@{
        ClustersCsv = $clustersCsv
        HostsCsv = $hostsCsv
        LicensesCsv = if (Test-Path $licensesCsv) { $licensesCsv } else { $null }
        LicenseInventoryCsv = if (Test-Path $licenseInventoryCsv) { $licenseInventoryCsv } else { $null }
        SummaryCsv = $summaryCsv
        Json = $jsonPath
        Html = $htmlPath
        Pdf = if (Test-Path $pdfPath) { $pdfPath } else { $null }
        Log = $script:LogFile
    }
}
#endregion reporting

#region main
try {
    Show-StartupBanner
    $resolvedOutput = New-OutputFolder -Path $OutputFolder
    $script:LogFile = Join-Path $resolvedOutput 'assessment.log'
    Write-Log -Message 'Início da execução do assessment.'

    if ($UseTranscript) {
        try {
            Start-Transcript -Path (Join-Path $resolvedOutput 'transcript.txt') -Force | Out-Null
        } catch {
            Add-WarningItem "Não foi possível iniciar transcript: $($_.Exception.Message)"
        }
    }

    $reference = Get-ReferenceMatrix
    $prereqs = Test-Prerequisites
    if ($prereqs.HasBlockingIssue) {
        throw 'Existem pré-requisitos bloqueantes. Corrija os itens FAIL e execute novamente.'
    }

    if (-not (Test-ExecutionPolicyAcceptable -PowerShellFacts $prereqs.PowerShell)) {
        $policyRemediation = Invoke-ExecutionPolicyRemediation -PowerShellFacts $prereqs.PowerShell
        if (-not $policyRemediation.Approved) {
            throw 'Execução cancelada: a política de execução atual não está no padrão esperado e o ajuste temporário não foi autorizado.'
        }
        $prereqs = Test-Prerequisites
    }

    Ensure-PowerCLILoaded
    Set-CertificateHandling

    $plans = Get-EnvironmentPlan -ConfigFilePath $ConfigFile
    if (-not $plans -or $plans.Count -eq 0) {
        throw 'Nenhum ambiente informado.'
    }

    $environments = New-Object System.Collections.Generic.List[object]
    foreach ($plan in $plans) {
        $server = $null
        try {
            $server = Connect-Environment -Plan $plan
            $assessment = Get-EnvironmentAssessment -Server $server -Plan $plan -Reference $reference
            $environments.Add($assessment) | Out-Null
        } finally {
            if ($DisconnectWhenDone -and $server) {
                try { Disconnect-VIServer -Server $server -Confirm:$false | Out-Null } catch { }
            }
        }
    }

    $globalCompute = [int]((@($environments | ForEach-Object { $_.Comparison.ComputeCoresRequired }) | Measure-Object -Sum).Sum)
    $globalEntitled = [double]((@($environments | ForEach-Object { $_.Comparison.vSanEntitledTiB }) | Measure-Object -Sum).Sum)
    $globalRaw = [double]((@($environments | ForEach-Object { $_.Comparison.vSanRawTiBRequired }) | Measure-Object -Sum).Sum)
    $globalAddOn = [math]::Max(0, [math]::Ceiling($globalRaw - [math]::Floor($globalEntitled)))

    $bundle = [pscustomobject]@{
        GeneratedAt = (Get-Date).ToString('s')
        OutputFolder = $resolvedOutput
        GlobalSummary = @([pscustomobject]@{
            TotalEnvironments = $environments.Count
            TotalComputeCoresRequired = $globalCompute
            TotalvSanEntitledTiB = [math]::Round($globalEntitled, 2)
            TotalvSanRawTiBRequired = [math]::Round($globalRaw, 2)
            TotalvSanAddOnTiBRequired = $globalAddOn
            TotalExpiredLicenses = [int]((@($environments | ForEach-Object { $_.LicenseSummary.Expired }) | Measure-Object -Sum).Sum)
            TotalLicensesExpiringIn30Days = [int]((@($environments | ForEach-Object { $_.LicenseSummary.ExpiringIn30Days }) | Measure-Object -Sum).Sum)
            TotalLicensesExpiringIn90Days = [int]((@($environments | ForEach-Object { $_.LicenseSummary.ExpiringIn90Days }) | Measure-Object -Sum).Sum)
            TotalObjectsWithoutLicense = [int]((@($environments | ForEach-Object { $_.LicenseSummary.ObjectsWithoutLicense }) | Measure-Object -Sum).Sum)
        })
        Environments = $environments
        Warnings = $script:Warnings.ToArray()
        Infos = $script:Infos.ToArray()
        References = $reference
        RuntimeChanges = $script:RuntimeChanges.ToArray()
    }

    $outputs = Save-Outputs -AssessmentBundle $bundle -Folder $resolvedOutput -Prereqs $prereqs -Reference $reference

    Write-Host ''
    Write-Host '===== RESUMO FINAL =====' -ForegroundColor White
    $bundle.GlobalSummary | Format-Table -AutoSize
    Write-Host ''
    Write-Host 'Arquivos gerados:' -ForegroundColor White
    $outputs.PSObject.Properties | ForEach-Object {
        if ($_.Value) { Write-Host ("- {0}: {1}" -f $_.Name, $_.Value) }
    }
    Write-Host ''
    Write-Host 'Assessment concluído.' -ForegroundColor Green
}
catch {
    Write-Log -Level ERROR -Message $_.Exception.Message
    throw
}
finally {
    try { Restore-CertificateHandling } catch { }
    try { Restore-ExecutionPolicyRemediation } catch { }
    try {
        if ($UseTranscript) { Stop-Transcript | Out-Null }
    } catch { }
}
#endregion main
