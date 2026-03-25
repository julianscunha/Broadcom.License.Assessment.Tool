# VMware Broadcom License Assessment Tool
# Author: Juliano Cunha (https://github.com/julianscunha)
# Repository: https://github.com/julianscunha
# Description: Automated assessment for VCF/VVF/vSAN licensing based on Broadcom public guidance
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

    $allClusterRows = @($AssessmentBundle.Environments | ForEach-Object { $_.Clusters })
    $allHostRows = @($AssessmentBundle.Environments | ForEach-Object { $_.Hosts })
    $allLicenseRows = @($AssessmentBundle.Environments | ForEach-Object { $_.LicenseAssignments })
    $allLicenseInventoryRows = @($AssessmentBundle.Environments | ForEach-Object { $_.LicenseInventory })
    $allComparisonRows = @($AssessmentBundle.Environments | ForEach-Object { $_.Comparison })
    $global = @($AssessmentBundle.GlobalSummary)[0]

    $style = @"
<style>
:root{
  --brand:#0b3d91;
  --brand-dark:#082a63;
  --brand-soft:#eef4ff;
  --accent:#1f6feb;
  --text:#1b2430;
  --muted:#667085;
  --border:#d7dfeb;
  --ok:#027a48;
  --warn:#b54708;
  --fail:#b42318;
  --page:#f5f7fb;
  --white:#ffffff;
}
@page { size: A4; margin: 18mm 12mm 18mm 12mm; }
* { box-sizing:border-box; }
body {
  font-family: Segoe UI, Arial, sans-serif;
  color: var(--text);
  margin: 0;
  background: var(--page);
  font-size: 12px;
  line-height: 1.45;
}
.container { max-width: 1180px; margin: 0 auto; padding: 24px; }
.cover {
  background: linear-gradient(135deg, var(--brand-dark), var(--brand));
  color: #fff;
  border-radius: 18px;
  padding: 28px 30px;
  box-shadow: 0 12px 30px rgba(8,42,99,.18);
  margin-bottom: 18px;
}
.cover-top { font-size: 12px; letter-spacing: .4px; opacity: .95; text-transform: uppercase; }
.cover h1 { margin: 8px 0 10px 0; font-size: 30px; line-height: 1.15; }
.cover p { margin: 6px 0; font-size: 13px; }
.meta-strip {
  display:flex; gap:18px; flex-wrap:wrap; margin-top: 16px; padding-top: 14px;
  border-top: 1px solid rgba(255,255,255,.18);
}
.meta-item strong { display:block; font-size:11px; opacity:.82; text-transform:uppercase; }
.meta-item span { font-size:14px; }
.section {
  background: var(--white);
  border: 1px solid var(--border);
  border-radius: 16px;
  padding: 20px 22px;
  margin-bottom: 18px;
  box-shadow: 0 4px 18px rgba(15,23,42,.04);
}
.section h2 {
  margin: 0 0 12px 0;
  color: var(--brand);
  font-size: 20px;
}
.section h3 {
  margin: 18px 0 10px 0;
  color: var(--brand-dark);
  font-size: 15px;
}
.lead {
  color: var(--muted);
  margin-top: 0;
  margin-bottom: 14px;
}
.kpi-grid {
  display:grid;
  grid-template-columns: repeat(4, minmax(0,1fr));
  gap: 12px;
  margin: 14px 0 8px 0;
}
.kpi {
  border: 1px solid var(--border);
  border-radius: 14px;
  padding: 14px;
  background: linear-gradient(180deg, #ffffff, #f9fbff);
}
.kpi .label { color: var(--muted); font-size: 11px; text-transform: uppercase; letter-spacing: .3px; }
.kpi .value { color: var(--brand-dark); font-size: 24px; font-weight: 700; margin-top: 4px; }
.kpi .sub { color: var(--muted); font-size: 11px; margin-top: 4px; }
.callout {
  background: var(--brand-soft);
  border-left: 5px solid var(--accent);
  border-radius: 10px;
  padding: 12px 14px;
  margin-top: 12px;
}
.summary-list { margin: 10px 0 0 0; padding-left: 18px; }
.summary-list li { margin: 4px 0; }
.env-header {
  display:flex; justify-content:space-between; gap:12px; align-items:flex-start; flex-wrap:wrap;
  margin-bottom: 8px;
}
.badge {
  display:inline-block;
  background: var(--brand-soft);
  color: var(--brand-dark);
  border: 1px solid #c9d8fb;
  border-radius: 999px;
  padding: 4px 10px;
  font-size: 11px;
  font-weight: 600;
  margin-right: 6px;
}
table { border-collapse: collapse; width: 100%; margin: 0 0 14px 0; font-size: 11px; }
th, td { border: 1px solid var(--border); padding: 7px 8px; vertical-align: top; }
th {
  background: #eef4ff;
  color: var(--brand-dark);
  text-align: left;
  font-weight: 700;
}
tr:nth-child(even) td { background: #fbfcfe; }
.ok { color: var(--ok); font-weight: bold; }
.warn { color: var(--warn); font-weight: bold; }
.fail { color: var(--fail); font-weight: bold; }
.small { font-size: 11px; color: var(--muted); }
.footer {
  margin-top: 18px;
  color: var(--muted);
  font-size: 11px;
  text-align: center;
}
hr.soft { border: 0; border-top: 1px solid var(--border); margin: 18px 0; }
ul.clean { margin: 8px 0 0 0; padding-left: 18px; }
@media print {
  body { background: #fff; }
  .container { max-width:none; padding: 0; }
  .section, .cover { box-shadow:none; }
}
</style>
"@

    $generatedAt = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $html = @()
    $html += '<html><head><meta charset="utf-8" />'
    $html += $style
    $html += '</head><body><div class="container">'
    $html += '<div class="cover">'
    $html += '<div class="cover-top">Generated by Juliano Cunha (GitHub: julianscunha)</div>'
    $html += '<h1>Assessment Executivo de Licenciamento Broadcom / VMware</h1>'
    $html += '<p>Relatório consolidado para apoio à análise técnica, validação comercial e preparação de proposta.</p>'
    $html += '<p><strong>Developed by Juliano Cunha (GitHub: julianscunha)</strong></p>'
    $html += '<div class="meta-strip">'
    $html += ("<div class='meta-item'><strong>Data de geração</strong><span>{0}</span></div>" -f $generatedAt)
    $html += ("<div class='meta-item'><strong>Ambientes avaliados</strong><span>{0}</span></div>" -f $global.TotalEnvironments)
    $html += ("<div class='meta-item'><strong>Compute total</strong><span>{0} cores</span></div>" -f $global.TotalComputeCoresRequired)
    $html += ("<div class='meta-item'><strong>vSAN Add-on total</strong><span>{0} TiB</span></div>" -f $global.TotalvSanAddOnTiBRequired)
    $html += '</div></div>'

    $html += '<div class="section">'
    $html += '<h2>Resumo executivo</h2>'
    $html += '<p class="lead">Este relatório apresenta o consolidado do assessment, o entendimento de licenciamento recomendado e os principais pontos de atenção do ambiente atual.</p>'
    $html += '<div class="kpi-grid">'
    $html += ("<div class='kpi'><div class='label'>Ambientes avaliados</div><div class='value'>{0}</div><div class='sub'>Consolidação total</div></div>" -f $global.TotalEnvironments)
    $html += ("<div class='kpi'><div class='label'>VVF / VCF Compute</div><div class='value'>{0}</div><div class='sub'>Cores requeridos</div></div>" -f $global.TotalComputeCoresRequired)
    $html += ("<div class='kpi'><div class='label'>vSAN raw apurado</div><div class='value'>{0}</div><div class='sub'>TiB totais</div></div>" -f $global.TotalvSanRawTiBRequired)
    $html += ("<div class='kpi'><div class='label'>vSAN Add-on</div><div class='value'>{0}</div><div class='sub'>TiB adicionais</div></div>" -f $global.TotalvSanAddOnTiBRequired)
    $html += '</div>'
    $html += '<div class="callout">'
    $html += '<strong>Leitura recomendada para proposta:</strong>'
    $html += '<ul class="summary-list">'
    $html += ("<li>Total consolidado de compute requerido: <strong>{0} cores</strong>.</li>" -f $global.TotalComputeCoresRequired)
    $html += ("<li>Total consolidado de entitlement vSAN: <strong>{0} TiB</strong>.</li>" -f $global.TotalvSanEntitledTiB)
    $html += ("<li>Total consolidado de capacidade vSAN raw apurada: <strong>{0} TiB</strong>.</li>" -f $global.TotalvSanRawTiBRequired)
    $html += ("<li>Total consolidado de vSAN Add-on sugerido: <strong>{0} TiB</strong>.</li>" -f $global.TotalvSanAddOnTiBRequired)
    $html += ("<li>Objetos sem licença identificados: <strong>{0}</strong>.</li>" -f $global.TotalObjectsWithoutLicense)
    $html += '</ul></div>'
    $html += '<p class="small">Observação: o dimensionamento final para proposta deve ser confirmado pela equipe técnico-comercial com base nas políticas vigentes da Broadcom e nas evidências coletadas neste assessment.</p>'
    $html += '</div>'

    $html += '<div class="section">'
    $html += '<h2>Checagem de pré-requisitos</h2>'
    $html += '<p class="lead">Validação da estação/sessão utilizada para execução do assessment, incluindo PowerShell, PowerCLI, privilégios e requisitos temporários de sessão.</p>'
    $html += (($Prereqs.Checks | ConvertTo-Html -Fragment) -join "`n")
    $html += '</div>'

    foreach ($env in $AssessmentBundle.Environments) {
        $comparison = @($env.Comparison)[0]
        $licenseSummary = @($env.LicenseSummary)[0]

        $html += '<div class="section">'
        $html += '<div class="env-header">'
        $html += ("<div><h2 style='margin-bottom:4px;'>Ambiente: {0}</h2><div class='small'>vCenter: {1} | Versão: {2}</div></div>" -f (Convert-ToHtmlSafe -Text $env.Plan.Name), (Convert-ToHtmlSafe -Text $env.Server), (Convert-ToHtmlSafe -Text $env.ServerVersion))
        $html += ("<div><span class='badge'>Modelo alvo: {0}</span><span class='badge'>Compute: {1} cores</span><span class='badge'>vSAN Add-on: {2} TiB</span></div>" -f $env.Plan.DeploymentType, $comparison.ComputeCoresRequired, $comparison.vSanAddOnTiBRequired)
        $html += '</div>'

        $html += '<div class="callout">'
        $html += ("<strong>Conclusão executiva do ambiente {0}:</strong> " -f (Convert-ToHtmlSafe -Text $env.Plan.Name))
        $html += ("Recomendação preliminar de <strong>{0} cores</strong> para o modelo <strong>{1}</strong>, com entitlement de vSAN em <strong>{2} TiB</strong>, capacidade raw apurada de <strong>{3} TiB</strong> e necessidade adicional de <strong>{4} TiB</strong> de vSAN Add-on." -f $comparison.ComputeCoresRequired, $env.Plan.DeploymentType, $comparison.vSanEntitledTiB, $comparison.vSanRawTiBRequired, $comparison.vSanAddOnTiBRequired)
        $html += '</div>'

        if ($licenseSummary) {
            $html += '<h3>Saúde do licenciamento atual</h3>'
            $html += '<p class="lead">Visão resumida das licenças atuais, incluindo expiração, evaluation e objetos sem licença.</p>'
            $html += (($env.LicenseSummary | ConvertTo-Html -Fragment) -join "`n")
        }
        if (@($env.LicenseInventory).Count -gt 0) {
            $html += '<h3>Inventário de licenças disponíveis</h3>'
            $html += '<p class="lead">Inventário retornado pelo ambiente no momento da coleta, utilizado como referência complementar para a análise.</p>'
            $html += (($env.LicenseInventory | ConvertTo-Html -Fragment) -join "`n")
        }
        if (@($env.LicenseAssignments).Count -gt 0) {
            $html += '<h3>Licenças atualmente atribuídas / objetos sem licença</h3>'
            $html += (($env.LicenseAssignments | ConvertTo-Html -Fragment) -join "`n")
        }

        $html += '<h3>Resumo por cluster</h3>'
        $html += (($env.Clusters | ConvertTo-Html -Fragment) -join "`n")
        $html += '<h3>Resumo por host</h3>'
        $html += (($env.Hosts | ConvertTo-Html -Fragment) -join "`n")
        $html += '<h3>Comparação recomendada</h3>'
        $html += '<p class="lead">Comparativo entre o cenário apurado e a referência de licenciamento implementada no script.</p>'
        $html += (($env.Comparison | ConvertTo-Html -Fragment) -join "`n")
        $html += '</div>'
    }

    if (@($AssessmentBundle.RuntimeChanges).Count -gt 0) {
        $html += '<div class="section">'
        $html += '<h2>Alterações temporárias realizadas durante a execução</h2>'
        $html += '<p class="lead">Todas as alterações abaixo foram tratadas em escopo de sessão/processo, sem impacto permanente no ambiente virtualizado, e o script tenta restaurá-las ao final.</p>'
        $html += ((@($AssessmentBundle.RuntimeChanges) | ConvertTo-Html -Fragment) -join "`n")
        $html += '</div>'
    }

    if ($script:Warnings.Count -gt 0) {
        $html += '<div class="section">'
        $html += '<h2>Alertas e ressalvas</h2><ul class="clean">'
        foreach ($w in $script:Warnings) { $html += ("<li>{0}</li>" -f (Convert-ToHtmlSafe -Text $w)) }
        $html += '</ul></div>'
    }

    $html += '<div class="section">'
    $html += '<h2>Referências aplicadas no assessment</h2>'
    $html += '<p class="lead">Base metodológica utilizada pelo script para cálculo, validações e interpretação do resultado.</p>'
    $html += '<ul class="clean">'
    foreach ($n in $Reference.Notes) { $html += ("<li>{0}</li>" -f (Convert-ToHtmlSafe -Text $n)) }
    $html += ("<li><a href='{0}'>KB 312202</a></li>" -f $Reference.Kb312202)
    $html += ("<li><a href='{0}'>KB 313548</a></li>" -f $Reference.Kb313548)
    $html += ("<li><a href='{0}'>KB 400416</a></li>" -f $Reference.Kb400416)
    $html += '</ul>'
    $html += '<p class="small">A comparação com o catálogo público da Broadcom foi tratada no script como matriz de referência estática baseada nessas KBs, sem scraping online em tempo real.</p>'
    $html += '</div>'

    $html += '<div class="footer">Generated by Juliano Cunha (GitHub: julianscunha) | Assessment Executivo de Licenciamento Broadcom / VMware</div>'
    $html += '</div></body></html>'
    Set-Content -LiteralPath $Path -Value ($html -join "`n") -Encoding UTF8
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
