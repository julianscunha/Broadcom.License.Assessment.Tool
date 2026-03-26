#requires -Version 5.1
<#!
.SYNOPSIS
  Broadcom License Assessment Tool
.DESCRIPTION
  Interactive PowerShell assessment for VMware environments under Broadcom licensing.
  Developed by Juliano Cunha (https://github.com/julianscunha)
.NOTES
  Version: 1.0.0
#>
[CmdletBinding()]
param(
    [ValidateSet('VVF','VCF')]
    [string]$DefaultDeploymentType = 'VVF',
    [switch]$TrustInvalidCertificates,
    [switch]$CollectLicenseAssignments,
    [switch]$DisconnectWhenDone,
    [switch]$ExportPdf,
    [string]$OutputFolder = '.'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ToolName = 'BroadcomLicenseAssessmentTool'
$script:ToolVersion = '1.0.0'
$script:AuthorLine = 'Developed by Juliano Cunha (GitHub: julianscunha)'
$script:LogPath = Join-Path -Path $OutputFolder -ChildPath 'broadcom-assessment.log'
$script:SessionState = [ordered]@{
    ProcessExecutionPolicyChanged = $false
    PreviousPowerCLICertAction = $null
    CompanyName = ''
}

function Write-Log {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = ('[{0}] [{1}] {2}' -f $timestamp, $Level, $Message)
    Write-Host $line -ForegroundColor @{
        INFO='Cyan'; WARN='Yellow'; ERROR='Red'; OK='Green'
    }[$Level]
    Add-Content -Path $script:LogPath -Value $line
}

function Read-YesNo {
    param(
        [Parameter(Mandatory=$true)][string]$Prompt,
        [bool]$Default = $true
    )
    $suffix = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        $answer = Read-Host ("{0} {1}" -f $Prompt, $suffix)
        if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
        switch ($answer.Trim().ToLowerInvariant()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
        }
    }
}


function Restart-ScriptSessionIfRequested {
    param(
        [string]$Reason = 'A new PowerShell session is recommended to continue.'
    )
    Write-Log -Message $Reason -Level 'WARN'
    if (-not (Read-YesNo -Prompt 'Restart this script automatically in a new PowerShell session now?' -Default $true)) {
        throw 'A new session is required. Please run the script again.'
    }
    $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $PSCommandPath + '"'))
    foreach ($bound in $PSBoundParameters.GetEnumerator()) {
        if ($bound.Value -is [switch]) {
            if ($bound.Value.IsPresent) { $argList += ('-' + $bound.Key) }
        }
        elseif ($null -ne $bound.Value) {
            $argList += @(('-' + $bound.Key), ('"' + [string]$bound.Value + '"'))
        }
    }
    Start-Process -FilePath 'powershell.exe' -ArgumentList ($argList -join ' ')
    exit
}

function ConvertTo-SafeHtml {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function New-OutputFolder {
    if (-not (Test-Path -LiteralPath $OutputFolder)) {
        New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
    }
    if (Test-Path -LiteralPath $script:LogPath) {
        Remove-Item -LiteralPath $script:LogPath -Force
    }
    New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
}

function Show-Banner {
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ' Broadcom License Assessment Tool' -ForegroundColor Cyan
    Write-Host (' ' + $script:AuthorLine) -ForegroundColor Gray
    Write-Host (' Version ' + $script:ToolVersion) -ForegroundColor Gray
    Write-Host '============================================================' -ForegroundColor DarkCyan
    Write-Host ''
}

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-ExecutionPolicy {
    $effective = Get-ExecutionPolicy -List
    $machine = ($effective | Where-Object Scope -eq 'LocalMachine').ExecutionPolicy
    $user = ($effective | Where-Object Scope -eq 'CurrentUser').ExecutionPolicy
    $process = ($effective | Where-Object Scope -eq 'Process').ExecutionPolicy
    Write-Log -Message ("Prereq OK - Execution policy: Process={0}; CurrentUser={1}; LocalMachine={2}" -f $process, $user, $machine) -Level 'OK'

    $safePolicies = @('RemoteSigned','Unrestricted','Bypass')
    if ($safePolicies -contains $process -or $safePolicies -contains $user -or $safePolicies -contains $machine) {
        return
    }

    Write-Log -Message 'ExecutionPolicy may block script execution in this session.' -Level 'WARN'
    if (Read-YesNo -Prompt 'Apply temporary ExecutionPolicy Bypass in Process scope for this session only?' -Default $true) {
        Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
        $script:SessionState.ProcessExecutionPolicyChanged = $true
        Write-Log -Message 'Temporary Process-scope ExecutionPolicy set to Bypass.' -Level 'OK'
    }
    else {
        throw 'ExecutionPolicy not adjusted. Script cannot continue safely.'
    }
}

function Ensure-PowerCLI {
    $minimumVersion = [version]'13.3.0'
    $installed = Get-Module -ListAvailable -Name 'VMware.PowerCLI' | Sort-Object Version -Descending | Select-Object -First 1

    if (-not $installed -or $installed.Version -lt $minimumVersion) {
        if (-not $installed) {
            Write-Log -Message 'Prereq FAIL - VMware.PowerCLI module not installed.' -Level 'ERROR'
        }
        else {
            Write-Log -Message ("Prereq FAIL - VMware.PowerCLI {0} found, but 13.3+ is required." -f $installed.Version) -Level 'ERROR'
        }

        if (-not (Read-YesNo -Prompt 'Install or update VMware PowerCLI 13.3+ for CurrentUser now?' -Default $true)) {
            throw 'VMware PowerCLI is required. Run the script again after installation.'
        }

        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $nugetProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue
            if (-not $nugetProvider) {
                Write-Log -Message 'NuGet provider not found. Installing it now.' -Level 'INFO'
                Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
            }

            if (Get-Command Set-PSRepository -ErrorAction SilentlyContinue) {
                try {
                    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
                    Write-Log -Message 'PSGallery marked as Trusted for module installation.' -Level 'INFO'
                }
                catch {
                    Write-Log -Message ('Unable to mark PSGallery as Trusted automatically: ' + $_.Exception.Message) -Level 'WARN'
                }
            }

            if (-not (Get-Command Install-Module -ErrorAction SilentlyContinue)) {
                throw 'PowerShellGet / Install-Module is not available in this session.'
            }

            Write-Log -Message 'Installing VMware.PowerCLI in CurrentUser scope. This can take a few minutes.' -Level 'INFO'
            Write-Progress -Activity 'Installing VMware PowerCLI' -Status 'Preparing module installation' -PercentComplete 5
            Install-Module -Name VMware.PowerCLI -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
            Write-Progress -Activity 'Installing VMware PowerCLI' -Status 'Installation completed' -PercentComplete 100
            Start-Sleep -Milliseconds 300
            Write-Progress -Activity 'Installing VMware PowerCLI' -Completed
        }
        catch {
            Write-Progress -Activity 'Installing VMware PowerCLI' -Completed
            Write-Log -Message ('Failed to install VMware PowerCLI automatically: ' + $_.Exception.Message) -Level 'ERROR'
            throw 'PowerCLI installation failed. Re-run the script after resolving repository or internet access issues.'
        }

        $installed = Get-Module -ListAvailable -Name 'VMware.PowerCLI' | Sort-Object Version -Descending | Select-Object -First 1
        if (-not $installed -or $installed.Version -lt $minimumVersion) {
            Restart-ScriptSessionIfRequested -Reason 'VMware PowerCLI was installed or updated, but a fresh session is required to load it reliably.'
        }
    }

    # Configure CEIP and deprecation warnings in a hidden child session before importing in the current session.
    try {
        $cmd = "try { $env:VMWARE_CEIP_DISABLE='True'; Import-Module VMware.VimAutomation.Core -ErrorAction Stop | Out-Null; Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP `$false -Confirm:`$false | Out-Null; Set-PowerCLIConfiguration -Scope User -DisplayDeprecationWarnings `$false -Confirm:`$false | Out-Null } catch { }"
        $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-Command', $cmd) -WindowStyle Hidden -PassThru -Wait
    }
    catch { }

    $warningBak = $WarningPreference
    $infoBak = $InformationPreference
    $progressBak = $ProgressPreference
    try {
        $env:VMWARE_CEIP_DISABLE = 'True'
        $WarningPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'
        $ProgressPreference = 'SilentlyContinue'
        Import-Module VMware.VimAutomation.Core -DisableNameChecking -ErrorAction Stop -WarningAction SilentlyContinue 3>$null 4>$null 5>$null 6>$null | Out-Null
        Set-PowerCLIConfiguration -Scope User -ParticipateInCEIP:$false -DisplayDeprecationWarnings:$false -Confirm:$false | Out-Null
        Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP:$false -DisplayDeprecationWarnings:$false -InvalidCertificateAction Fail -Confirm:$false | Out-Null
    }
    finally {
        $WarningPreference = $warningBak
        $InformationPreference = $infoBak
        $ProgressPreference = $progressBak
    }

    $loaded = Get-Module -Name 'VMware.VimAutomation.Core'
    if (-not $loaded) {
        Restart-ScriptSessionIfRequested -Reason 'VMware PowerCLI is installed, but the current session did not load VMware.VimAutomation.Core reliably.'
    }

    Write-Log -Message ("Prereq OK - VMware.PowerCLI {0}" -f $installed.Version) -Level 'OK'
}

function Configure-PowerCLI {
    try {
        $script:SessionState.PreviousPowerCLICertAction = (Get-PowerCLIConfiguration -Scope Session -ErrorAction SilentlyContinue).InvalidCertificateAction
    } catch { }

    if ($TrustInvalidCertificates) {
        Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP:$false -DisplayDeprecationWarnings:$false -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
        Write-Log -Message 'PowerCLI session configured to ignore invalid certificates.' -Level 'WARN'
    }
    else {
        Set-PowerCLIConfiguration -Scope Session -ParticipateInCEIP:$false -DisplayDeprecationWarnings:$false -InvalidCertificateAction Fail -Confirm:$false | Out-Null
    }
}

function Connect-VIServerWithPrompt {
    param(
        [Parameter(Mandatory=$true)][string]$Server,
        [Parameter(Mandatory=$true)][pscredential]$Credential
    )

    try {
        Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop -WarningAction SilentlyContinue 3>$null 4>$null 5>$null 6>$null | Out-Null
        Write-Log -Message ('Connected to ' + $Server) -Level 'OK'
        return
    }
    catch {
        $msg = $_.Exception.Message
        $fqid = $_.FullyQualifiedErrorId
        $looksLikeCert = ($msg -match 'certificate' -or $msg -match 'SSL/TLS' -or $fqid -match 'Certificate')
        if (-not $looksLikeCert) {
            throw
        }

        Write-Log -Message ('Certificate validation failed while connecting to ' + $Server + '.') -Level 'WARN'
        if (-not (Read-YesNo -Prompt 'Ignore invalid certificate for this PowerCLI session and retry connection?' -Default $true)) {
            throw 'Connection aborted by user after certificate validation failure.'
        }

        Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
        Write-Log -Message 'Invalid certificate handling set to Ignore for this session after user confirmation.' -Level 'WARN'

        Connect-VIServer -Server $Server -Credential $Credential -ErrorAction Stop -WarningAction SilentlyContinue 3>$null 4>$null 5>$null 6>$null | Out-Null
        Write-Log -Message ('Connected to ' + $Server) -Level 'OK'
    }
}

function Get-EnvironmentVersionFlag {
    param([Parameter(Mandatory=$true)]$Cluster)
    $hosts = Get-VMHost -Location $Cluster | Select-Object -ExpandProperty Version
    $requiresUpdatedMethod = $false
    foreach ($hostVersion in $hosts) {
        if ($hostVersion -match '^8\.0\.3' -or $hostVersion -match '^8\.0 U3') {
            $requiresUpdatedMethod = $true
        }
    }
    return $requiresUpdatedMethod
}

function Get-VsanRawCapacityTiB {
    param([Parameter(Mandatory=$true)]$Cluster)
    $capacityTiB = 0
    $method = 'Get-VsanSpaceUsage'
    try {
        $usage = Get-VsanSpaceUsage -Cluster $Cluster -ErrorAction Stop
        if ($usage -and $usage.CapacityGB) {
            $capacityTiB = [math]::Round(([double]$usage.CapacityGB / 1024), 2)
            return [pscustomobject]@{ TiB = $capacityTiB; Method = $method; Notes = '' }
        }
    }
    catch {
        $method = 'ESXCLI fallback'
    }

    $sumMB = 0
    $notes = 'Fallback method used. Capacity Tier disks summed via ESXCLI.'
    foreach ($vmhost in Get-VMHost -Location $Cluster) {
        $esxcli = Get-EsxCli -VMHost $vmhost -V2
        $storageItems = $esxcli.vsan.storage.list.Invoke()
        foreach ($item in $storageItems) {
            if ($item.IsCapacityTier -eq $true) {
                $deviceInfo = $esxcli.storage.core.device.list.Invoke(@{device=$item.Device})
                if ($deviceInfo -and $deviceInfo.Size) {
                    $sumMB += [double]$deviceInfo.Size
                }
            }
        }
    }
    if ($sumMB -gt 0) {
        $capacityTiB = [math]::Round(($sumMB / 1024 / 1024), 2)
    }
    return [pscustomobject]@{ TiB = $capacityTiB; Method = $method; Notes = $notes }
}

function Get-LicenseAssignmentsSummary {
    param([Parameter(Mandatory=$true)]$Server)
    $items = @()
    try {
        $licenseManager = Get-View -Id 'LicenseManager-LicenseManager'
        foreach ($lic in $licenseManager.Licenses) {
            $properties = @{}
            foreach ($pair in $lic.Properties) {
                $properties[$pair.Key] = $pair.Value
            }
            $expiration = $null
            if ($properties.ContainsKey('expirationDate')) {
                [datetime]::TryParse($properties['expirationDate'], [ref]$expiration) | Out-Null
            }
            $status = 'Valid'
            if ($expiration) {
                if ($expiration -lt (Get-Date)) { $status = 'Expired' }
                elseif ($expiration -le (Get-Date).AddDays(30)) { $status = 'Expiring<=30d' }
                elseif ($expiration -le (Get-Date).AddDays(90)) { $status = 'Expiring<=90d' }
            }
            if ($properties.ContainsKey('editionKey') -and $properties['editionKey'] -match 'eval') {
                $status = 'Evaluation'
            }
            $items += [pscustomobject]@{
                Name = $lic.Name
                LicenseKey = $lic.LicenseKey
                CostUnit = $lic.CostUnit
                Total = $lic.Total
                Used = $lic.Used
                ExpirationDate = $expiration
                Status = $status
                Server = $Server
            }
        }
    }
    catch {
        Write-Log -Message ('License inventory could not be fully collected: ' + $_.Exception.Message) -Level 'WARN'
    }
    return $items
}

function New-ClusterAssessment {
    param(
        [Parameter(Mandatory=$true)]$Server,
        [Parameter(Mandatory=$true)]$Cluster,
        [Parameter(Mandatory=$true)][string]$DeploymentType,
        [switch]$CollectLicenses
    )

    $vmhosts = Get-VMHost -Location $Cluster | Sort-Object Name
    $hostRows = @()
    $totalAdjustedCores = 0
    foreach ($vmhost in $vmhosts) {
        $cpuPackages = [int]$vmhost.NumCpu
        $coresPerPackage = [int]$vmhost.ExtensionData.Hardware.CpuInfo.NumCpuCores / [math]::Max($cpuPackages,1)
        $actualCores = $cpuPackages * $coresPerPackage
        $adjustedCores = [math]::Max($actualCores, (16 * $cpuPackages))
        $includedVsanTiB = if ($DeploymentType -eq 'VCF') { $adjustedCores * 1.0 } else { $adjustedCores * 0.25 }
        $totalAdjustedCores += $adjustedCores
        $hostRows += [pscustomobject]@{
            Cluster = $Cluster.Name
            VMHost = $vmhost.Name
            NumCpuSockets = $cpuPackages
            NumCpuCoresPerSocket = $coresPerPackage
            ActualCoreCount = $actualCores
            FoundationLicenseCoreCount = $adjustedCores
            IncludedVsanTiB = [math]::Round($includedVsanTiB,2)
            HostVersion = $vmhost.Version
        }
    }

    $vsanRaw = Get-VsanRawCapacityTiB -Cluster $Cluster
    $includedClusterTiB = if ($DeploymentType -eq 'VCF') { $totalAdjustedCores * 1.0 } else { $totalAdjustedCores * 0.25 }
    $requiredAddOnTiB = [math]::Max([math]::Ceiling($vsanRaw.TiB - [math]::Floor($includedClusterTiB)), 0)

    $licenseData = @()
    if ($CollectLicenses) {
        $licenseData = Get-LicenseAssignmentsSummary -Server $Server
    }

    return [pscustomobject]@{
        Server = $Server
        Cluster = $Cluster.Name
        DeploymentType = $DeploymentType
        Hosts = $hostRows
        TotalRequiredComputeLicenses = $totalAdjustedCores
        IncludedEntitlementTiB = [math]::Round($includedClusterTiB,2)
        RawVsanTiB = [math]::Round($vsanRaw.TiB,2)
        RequiredVsanAddOnTiB = [int]$requiredAddOnTiB
        VsanMethod = $vsanRaw.Method
        VsanNotes = $vsanRaw.Notes
        RequiresUpdatedMethod = Get-EnvironmentVersionFlag -Cluster $Cluster
        LicenseInventory = $licenseData
    }
}

function New-ExecutiveHtml {
    param(
        [Parameter(Mandatory=$true)]$Assessments,
        [Parameter(Mandatory=$true)][string]$Path,
        [bool]$Internal = $false,
        [string]$LogoUrl = ''
    )

    $totalCores = ($Assessments | Measure-Object -Property TotalRequiredComputeLicenses -Sum).Sum
    $totalIncluded = [math]::Round((($Assessments | Measure-Object -Property IncludedEntitlementTiB -Sum).Sum),2)
    $totalRaw = [math]::Round((($Assessments | Measure-Object -Property RawVsanTiB -Sum).Sum),2)
    $totalAddon = ($Assessments | Measure-Object -Property RequiredVsanAddOnTiB -Sum).Sum
    $maxScale = [math]::Max([math]::Max([math]::Max([double]$totalRaw, [double]$totalIncluded), [double]$totalAddon), 1)

    $html = New-Object System.Collections.Generic.List[string]
    $null = $html.Add('<!doctype html>')
    $null = $html.Add('<html><head><meta charset="utf-8"><title>Broadcom License Assessment</title>')
    $null = $html.Add('<style>')
    $null = $html.Add('body{font-family:Segoe UI,Arial,sans-serif;background:#f5f7fb;color:#0f172a;margin:0;padding:24px;} @media (prefers-color-scheme: dark){body{background:#06111f;color:#e5e7eb}.card,.section{background:#0b1730;color:#e5e7eb;box-shadow:none} th{background:#0f1f3c;color:#cbd5e1} td{border-bottom:1px solid #22314f}.sub,.footer{color:#9ca3af}.track{background:#1e293b}}')
    $null = $html.Add('.wrap{max-width:1200px;margin:0 auto;} .hero{background:#0b1220;color:#fff;border-radius:18px;padding:28px 32px;margin-bottom:22px;}')
    $null = $html.Add('.hero h1{margin:0 0 10px;font-size:32px;} .hero p{margin:6px 0;color:#cbd5e1;} .eyebrow{letter-spacing:.1em;text-transform:uppercase;font-size:12px;color:#93c5fd;}')
    $null = $html.Add('.logo-wrap{display:inline-block;background:rgba(255,255,255,.96);padding:10px 16px;border-radius:12px;margin-bottom:14px;} .logo{max-height:70px;max-width:280px;} .grid{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-bottom:22px;}')
    $null = $html.Add('.card{background:#fff;border-radius:16px;padding:18px;box-shadow:0 10px 30px rgba(15,23,42,.08);} .kpi{font-size:30px;font-weight:700;margin-top:8px;} .sub{color:#475569;font-size:13px;}')
    $null = $html.Add('.section{background:#fff;border-radius:16px;padding:20px;box-shadow:0 10px 30px rgba(15,23,42,.08);margin-bottom:20px;} .section h2{margin:0 0 14px;font-size:22px;}')
    $null = $html.Add('.bars{display:grid;gap:10px;} .barlabel{display:flex;justify-content:space-between;font-size:13px;margin-bottom:4px;} .track{height:12px;background:#e2e8f0;border-radius:999px;overflow:hidden;} .fill{height:12px;border-radius:999px;}')
    $null = $html.Add('table{width:100%;border-collapse:collapse;font-size:13px;} th,td{padding:10px 8px;border-bottom:1px solid #e2e8f0;text-align:left;} th{color:#334155;background:#f8fafc;}')
    $null = $html.Add('.badge{display:inline-block;background:#eff6ff;color:#1d4ed8;padding:4px 8px;border-radius:999px;font-size:12px;margin-right:6px;} .warn{color:#92400e;background:#fef3c7;}')
    $null = $html.Add('.footer{font-size:12px;color:#64748b;text-align:center;margin-top:18px;} .formula{font-family:Consolas,monospace;background:#0f172a;color:#e2e8f0;border-radius:12px;padding:12px;overflow:auto;}')
    $null = $html.Add('@media(max-width:1000px){.grid{grid-template-columns:repeat(2,1fr);}} @media(max-width:700px){.grid{grid-template-columns:1fr;}}')
    $null = $html.Add('</style></head><body><div class="wrap">')
    $null = $html.Add('<div class="hero">')
    if ($Internal -and $LogoUrl) {
        $null = $html.Add('<div class="logo-wrap"><img class="logo" src="' + (ConvertTo-SafeHtml $LogoUrl) + '" alt="Triple S Cloud Solutions logo"></div>')
        $null = $html.Add('<div class="eyebrow">Generated for internal use</div>')
    } else {
        $null = $html.Add('<div class="eyebrow">Generated by Triple S Cloud Solutions</div>')
    }
    $null = $html.Add('<h1>Broadcom / VMware License Assessment</h1>')
    $null = $html.Add('<p>Developed by Juliano Cunha (GitHub: julianscunha)</p>')
    $null = $html.Add('<p>Customer / Company: ' + (ConvertTo-SafeHtml $script:SessionState.CompanyName) + '</p>')
    $null = $html.Add('<p>Assessment date: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + '</p>')
    $null = $html.Add('</div>')
    $null = $html.Add('<div class="grid">')
    foreach ($pair in @(
        @{T='Required compute';V=("{0} cores" -f $totalCores);S='Broadcom minimum 16 cores per CPU applied'},
        @{T='Included vSAN';V=("{0} TiB" -f $totalIncluded);S='VCF = 1 TiB/core, VVF = 0.25 TiB/core'},
        @{T='Measured raw vSAN';V=("{0} TiB" -f $totalRaw);S='Raw physical capacity claimed by vSAN'},
        @{T='Required vSAN Add-on';V=("{0} TiB" -f $totalAddon);S='Rounded up when above entitlement'}
    )) {
        $null = $html.Add('<div class="card"><div class="sub">' + $pair.T + '</div><div class="kpi">' + $pair.V + '</div><div class="sub">' + $pair.S + '</div></div>')
    }
    $null = $html.Add('</div>')
    $null = $html.Add('<div class="section"><h2>Current standard and formulas</h2>')
    $null = $html.Add('<div class="formula">')
    $null = $html.Add('Adjusted host cores = max(actual host cores, 16 x physical CPU count)<br>')
    $null = $html.Add('Included vSAN entitlement = adjusted cores x 1.0 (VCF) or adjusted cores x 0.25 (VVF)<br>')
    $null = $html.Add('Required vSAN Add-on = max(ceil(raw vSAN TiB - floor(included entitlement TiB)), 0)<br>')
    $null = $html.Add('For vSphere / vSAN 8.0 U3+, Broadcom documents an updated claimed-capacity method.</div></div>')
    $null = $html.Add('<div class="section"><h2>Consumption dashboard</h2><div class="bars">')
    $barData = @(
        @{N='Required compute (cores)'; V=[double]$totalCores; C='#2563eb'},
        @{N='Included vSAN entitlement (TiB)'; V=[double]$totalIncluded; C='#059669'},
        @{N='Measured raw vSAN (TiB)'; V=[double]$totalRaw; C='#7c3aed'},
        @{N='Required vSAN Add-on (TiB)'; V=[double]$totalAddon; C='#ea580c'}
    )
    foreach ($b in $barData) {
        $width = [math]::Round(($b.V / $maxScale) * 100, 2)
        $null = $html.Add('<div><div class="barlabel"><span>' + $b.N + '</span><span>' + $b.V + '</span></div><div class="track"><div class="fill" style="width:' + $width + '%;background:' + $b.C + '"></div></div></div>')
    }
    $null = $html.Add('</div></div>')
    $null = $html.Add('<div class="section"><h2>Detailed calculations by cluster</h2><table><thead><tr><th>Server</th><th>Cluster</th><th>Model</th><th>Required compute</th><th>Included vSAN</th><th>Raw vSAN</th><th>Required Add-on</th><th>Method</th></tr></thead><tbody>')
    foreach ($a in $Assessments) {
        $methodBadge = '<span class="badge">' + (ConvertTo-SafeHtml $a.VsanMethod) + '</span>'
        if ($a.RequiresUpdatedMethod) { $methodBadge += '<span class="badge warn">8.0 U3+ path</span>' }
        $null = $html.Add('<tr><td>' + (ConvertTo-SafeHtml $a.Server) + '</td><td>' + (ConvertTo-SafeHtml $a.Cluster) + '</td><td>' + (ConvertTo-SafeHtml $a.DeploymentType) + '</td><td>' + $a.TotalRequiredComputeLicenses + ' cores</td><td>' + $a.IncludedEntitlementTiB + ' TiB</td><td>' + $a.RawVsanTiB + ' TiB</td><td>' + $a.RequiredVsanAddOnTiB + ' TiB</td><td>' + $methodBadge + '</td></tr>')
    }
    $null = $html.Add('</tbody></table></div>')
    $null = $html.Add('<div class="section"><h2>Host inventory excerpt</h2><table><thead><tr><th>Cluster</th><th>Host</th><th>CPU sockets</th><th>Cores per socket</th><th>Actual cores</th><th>Adjusted cores</th><th>Included vSAN</th><th>Version</th></tr></thead><tbody>')
    foreach ($a in $Assessments) {
        foreach ($h in $a.Hosts) {
            $null = $html.Add('<tr><td>' + (ConvertTo-SafeHtml $h.Cluster) + '</td><td>' + (ConvertTo-SafeHtml $h.VMHost) + '</td><td>' + $h.NumCpuSockets + '</td><td>' + $h.NumCpuCoresPerSocket + '</td><td>' + $h.ActualCoreCount + '</td><td>' + $h.FoundationLicenseCoreCount + '</td><td>' + $h.IncludedVsanTiB + ' TiB</td><td>' + (ConvertTo-SafeHtml $h.HostVersion) + '</td></tr>')
        }
    }
    $null = $html.Add('</tbody></table></div>')
    $null = $html.Add('<div class="footer">This report is based on collected environment data and Broadcom licensing guidelines. Final commercial positioning should be validated by an authorized partner.</div>')
    $null = $html.Add('</div></body></html>')
    [IO.File]::WriteAllText($Path, ($html -join [Environment]::NewLine), [Text.Encoding]::UTF8)
}

function Export-PdfIfPossible {
    param([string]$HtmlPath)
    if (-not $ExportPdf) { return }
    $pdfPath = [IO.Path]::ChangeExtension($HtmlPath, '.pdf')
    try {
        $word = New-Object -ComObject Word.Application
        $word.Visible = $false
        $doc = $word.Documents.Open($HtmlPath)
        $doc.SaveAs([ref]$pdfPath, [ref]17)
        $doc.Close()
        $word.Quit()
        Write-Log -Message ('PDF exported to ' + $pdfPath) -Level 'OK'
    }
    catch {
        Write-Log -Message 'PDF export skipped. Microsoft Word COM automation is unavailable in this session.' -Level 'WARN'
    }
}

function Restore-SessionChanges {
    try {
        if ($null -ne $script:SessionState.PreviousPowerCLICertAction -and $script:SessionState.PreviousPowerCLICertAction -ne '') {
            Set-PowerCLIConfiguration -Scope Session -InvalidCertificateAction $script:SessionState.PreviousPowerCLICertAction -Confirm:$false | Out-Null
        }
    } catch { }
    if ($script:SessionState.ProcessExecutionPolicyChanged) {
        try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Undefined -Force } catch { }
    }
    try {
        if ($DisconnectWhenDone) {
            Get-VIServer -ErrorAction SilentlyContinue | Disconnect-VIServer -Confirm:$false | Out-Null
            Write-Log -Message 'Disconnected from all VIServers.' -Level 'OK'
        }
    } catch { }
}

function Start-Assessment {
    New-OutputFolder
    Show-Banner
    Write-Log -Message 'Starting assessment.'
    Write-Log -Message ("Prereq OK - PowerShell version: {0}" -f $PSVersionTable.PSVersion) -Level 'OK'
    if (Test-IsAdministrator) { Write-Log -Message 'Prereq OK - Run as Administrator: Elevated session' -Level 'OK' }
    else { Write-Log -Message 'Prereq WARN - Script is not elevated. Some installation tasks may fail.' -Level 'WARN' }

    Ensure-ExecutionPolicy
    Ensure-PowerCLI
    Configure-PowerCLI

    $companyName = Read-Host 'Customer / Company name for the report'
    if ([string]::IsNullOrWhiteSpace($companyName)) { $companyName = 'Not informed' }
    $script:SessionState.CompanyName = $companyName

    $results = New-Object System.Collections.Generic.List[object]
    do {
        $server = Read-Host 'Enter vCenter Server / ESXi endpoint'
        if ([string]::IsNullOrWhiteSpace($server)) { throw 'Server cannot be empty.' }
        $deployment = Read-Host ('Deployment type for this environment [VVF/VCF] (default ' + $DefaultDeploymentType + ')')
        if ([string]::IsNullOrWhiteSpace($deployment)) { $deployment = $DefaultDeploymentType }
        $deployment = $deployment.ToUpperInvariant()
        if ($deployment -notin @('VVF','VCF')) { throw 'Deployment type must be VVF or VCF.' }

        $credential = Get-Credential -Message ('Credentials for ' + $server)
        Connect-VIServerWithPrompt -Server $server -Credential $credential

        $clusters = Get-Cluster | Sort-Object Name
        if (-not $clusters) { throw 'No clusters found in the connected environment.' }
        foreach ($cluster in $clusters) {
            Write-Log -Message ('Assessing cluster ' + $cluster.Name + ' on ' + $server)
            $results.Add((New-ClusterAssessment -Server $server -Cluster $cluster -DeploymentType $deployment -CollectLicenses:$CollectLicenseAssignments))
        }
    } while (Read-YesNo -Prompt 'Assess another environment in the same run?' -Default $false)

    $safeCompany = ($script:SessionState.CompanyName -replace '[^A-Za-z0-9._-]+','-').Trim('-')
    if ([string]::IsNullOrWhiteSpace($safeCompany)) { $safeCompany = 'customer' }
    $jsonPath = Join-Path $OutputFolder ($safeCompany + '-broadcom-assessment.json')
    $csvPath = Join-Path $OutputFolder ($safeCompany + '-broadcom-assessment.csv')
    $htmlPath = Join-Path $OutputFolder ($safeCompany + '-broadcom-assessment.html')

    $results | ConvertTo-Json -Depth 8 | Set-Content -Path $jsonPath -Encoding UTF8
    $results | Select-Object Server,Cluster,DeploymentType,TotalRequiredComputeLicenses,IncludedEntitlementTiB,RawVsanTiB,RequiredVsanAddOnTiB,VsanMethod,RequiresUpdatedMethod | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8
    New-ExecutiveHtml -Assessments $results -Path $htmlPath -Internal:$false
    Export-PdfIfPossible -HtmlPath $htmlPath

    $totalCores = ($results | Measure-Object -Property TotalRequiredComputeLicenses -Sum).Sum
    $totalAddon = ($results | Measure-Object -Property RequiredVsanAddOnTiB -Sum).Sum
    Write-Log -Message ('Summary: compute=' + $totalCores + ' cores; vSAN Add-on=' + $totalAddon + ' TiB') -Level 'OK'
    Write-Log -Message ('Artifacts generated in ' + (Resolve-Path $OutputFolder).Path) -Level 'OK'
}

try {
    Start-Assessment
}
catch {
    Write-Log -Message $_.Exception.Message -Level 'ERROR'
    throw
}
finally {
    Restore-SessionChanges
}
