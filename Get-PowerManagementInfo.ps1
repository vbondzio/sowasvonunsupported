function Get-PowerManagementInfo {
    <#
    .SYNOPSIS
        List relevant information for BIOS and ESXi host power management 
    .DESCRIPTION
        Checks all hosts under the vCenter or a specific one and gathers PCPU Usage and Utilization figures, approximate ratio per PCPU to identify non-ESXi controlled frequency scaling. Takes into account whether the BIOS presents (legacy) P-States, the ESXi policy and availability of SMT. It assumes a certain utilization minimum and will become less accurate the closer it is to that minimum. Realtim stats over the last hour are used for the calculation.
        # note: at least thats the goal, it might not right now
    .NOTES
        Author:     Valentin
        GitHub:     https://github.com/vbondzio/sowasvonunsupported/blob/master/Get-PowerManagementInfo.ps1
        Liability:  Absolutely none, might work, might not, no guarantees. 
    .PARAMETER EsxiHostName
        The host which will be checked. The function runs against all hosts in the vCenter if not specified. 
    .EXAMPLE
        PS> Get-PowerManagementInfo
    .EXAMPLE
        PS> Get-PowerManagementInfo -EsxiHostName "MyHost"
    #>

    param(
        [Parameter(Mandatory = $false)] [string]$EsxiHostName
    )

    if($EsxiHostName) {
        $esxiHosts = Get-View -ViewType HostSystem -Property Name,Config.Option,Hardware,Runtime -Filter @{"Name"="$EsxiHostName"}
    } else {
        $esxiHosts = Get-View -ViewType HostSystem -Property Name,Config.Option,Hardware,Runtime
    }
        
    if ($global:DefaultVIServers.RefCount -ne "1") {
        Write-Error -Message "More than one connection, exiting. Remove this check if you know what you're doing."
        Disconnect-VIServer -Confirm:$false
        Exit
    }

    # "debug" logging: Continue / SilentlyContinue
    $VerbosePreference = "SilentlyContinue"

    # export result table
    $currentFunction = (Get-PSCallStack)[0].FunctionName
    $runDateTime = (Get-Date).ToString('yyyy-MM-dd_HH-mm')
    $csvExportFilename = "${currentFunction}_export@${runDateTime}.csv"
    # make platform independent, maybe use PSTempDrive in PS 7.0
    $localFolder ="c:\tmp\"

    # check last XX minutes of Realtime samples
    # should be 60 and 3, if not I might have changed it for testing and not reverted, uhps 
    $numberOfMinutes = 60
    $numberOfSamples = $numberOfMinutes * 3

    
    $allResults = @()
    foreach ($esxiHost in $esxiHosts | Sort-Object -Property Name) {
        
        Write-Verbose "Host Start: $($esxiHost.Name)"

        $esxiHostName = $esxiHost.Name
        $esxiHostConnectionState = $esxiHost.Runtime.ConnectionState

        Write-Verbose "Connection: $esxiHostConnectionState"
        
        $cpuTopology = "N/A"
        $esxiPowerPolicy = "N/A"
        $esxiPowerAcpiP = "N/A"
        $esxiPowerAcpiC = "N/A"
        $biosPowerPolicySuspected = "N/A"
        $numberOfVmsPoweredOn = "N/A"
        $numberOfVcpusPoweredOn = "N/A"
        $hostUsage = "N/A"
        $hostUtil = "N/A"
        $hostCoreUtil = "N/A"
        $hwVendor = "N/A"
        $hwModel = "N/A"
        $hwBiosVersion = "N/A"
        $hwBiosDate = "N/A"
        
        # will not fail if host is disconnected funnily enough
        $vmsPoweredOn = Get-View -ViewType "VirtualMachine" -Property Name,Config.Hardware -Filter @{"Runtime.PowerState"="PoweredOn"} -SearchRoot $($esxiHost).MoRef
        $numberOfVmsPoweredOn = $vmsPoweredOn.count

        Write-Verbose "# VMs: $numberOfVmsPoweredOn"

        if ($esxiHostConnectionState -eq "connected"){
            
            # not sure I'm going to use that but it should probably be the upper limit for PCPU consideration for non HCI
            $numberOfVcpusPoweredOn = ($vmsPoweredOn.Config.Hardware.NumCPU | Measure-Object -Sum).Sum
            
            $pSockets = $esxiHost.Hardware.CpuInfo.NumCpuPackages
            $pCores = $esxiHost.Hardware.CpuInfo.NumCpuCores
            $pThreads = $esxiHost.Hardware.CpuInfo.NumCpuThreads
            $cpuTopology = "$pSockets/$pCores/$pThreads"
            $hwVendor = $esxiHost.Hardware.SystemInfo.Vendor
            $hwModel = $esxiHost.Hardware.SystemInfo.Model
            $hwBiosVersion = $esxiHost.Hardware.BiosInfo.BiosVersion
            $hwBiosDate = $esxiHost.Hardware.BiosInfo.ReleaseDate
            
            # get ESXi visible PM tech and make assumptions about BIOS policy
            $esxiPowerPolicy = $esxiHost.Hardware.CpuPowerManagementInfo.CurrentPolicy
            $esxiPowerAcpiP = ($esxiHost.Hardware.CpuPowerManagementInfo.HardwareSupport -like "*P-states*")
            $esxiPowerAcpiC = ($esxiHost.Hardware.CpuPowerManagementInfo.HardwareSupport -like "*C-states*")
            
            # todo: if this is ever extended, build the comments from simple blocks to avoid repetition and maybe create a report 
            if ($esxiPowerAcpiP -and $esxiPowerAcpiC){
                $biosPowerPolicySuspected = "Custom / Recommended"
                $biosPowerPolicyComment = "P and deep C-States are visible to ESXi. Make sure that all other non-OS visible settings are configured as they would in your target policy (e.g. BIOS Max. Performance). Note that visible P-States doesn't mean that ESXi is allowed to control all nor that the CPU isn't frequency scaled by other means."
            } elseif ($esxiPowerAcpiP) {
                $biosPowerPolicySuspected = "OS controlled"
                $biosPowerPolicyComment = "Only P-States are visible to ESXi, this is most likely a misunderstanding of configuring `"OS Control`". Make sure to present deep C-States when optimizing for maximum Turbo Boost / performance / manageability. Note that visible P-States doesn't mean that ESXi is allowed to control all nor that the CPU isn't frequency scaled by other means."
            } elseif ($esxiPowerAcpiC) {
                $biosPowerPolicySuspected = "Dynamic / Low"
                $biosPowerPolicyComment = "ESXi is presented deep C-States but not P-State control, that is usually the default for BIOS Low or Dynamic policies which also frequency scale the CPU via BIOS controlled P-States. Note that non-visible `"legacy`" P-States could also be due to `"Hardware-Controlled Performance States (HWP)`"."
            } else{
                $biosPowerPolicySuspected = "Max. Performance"
                $biosPowerPolicyComment = "No P nor deep C-States visible to ESXi, this is usually the default for BIOS Max / High Performance policies. Make sure to present deep C-States when optimizing for maximum Turbo Boost / performance / manageability. Note that non-visible `"legacy`" P-States could also be due to `"Hardware-Controlled Performance States (HWP)`". If the system is frequency scaled with this policy, the cause is HW (PSU redundancy, power capping, CPU or chassis temperature, BIOS bug etc."
            }

            Write-Verbose "Comment on suspected BIOS Policy: $biosPowerPolicyComment"

            $esxiHostObject = Get-VMHost -Name $esxiHost.Name
            $queryStats = 'cpu.utilization.average','cpu.usage.average','cpu.coreutilization.average'
            $perHostStats = Get-Stat -Entity $esxiHostObject -MaxSamples $numberOfSamples -Realtime -Stat $queryStats |
                Where-Object {$_.Instance -eq ""} |
                Select-Object -Property MetricId,Value | 
                Group-Object -Property MetricId 

            $hostUsage = ($perHostStats.Group | Where-Object {$_.MetricId -eq 'cpu.usage.average'} | Measure-Object -Property Value -Average).Average
            $hostUtil = ($perHostStats.Group | Where-Object {$_.MetricId -eq 'cpu.utilization.average'} | Measure-Object -Property Value -Average).Average
            $hostCoreUtil = ($perHostStats.Group | Where-Object {$_.MetricId -eq 'cpu.coreutilization.average'} | Measure-Object -Property Value -Average).Average
          
            Write-Verbose "$perHostStats"
        }

        $currentResults = [pscustomobject] @{
            "Host" = $esxiHostName
            "Vendor" = $hwVendor
            "Model" = $hwModel
            "BIOS ver." = $hwBiosVersion
            "BIOS date" = $hwBiosDate
            "Sockets/Cores/Threads" = $cpuTopology
            "ESXi Policy" = $esxiPowerPolicy
            "P-States" = $esxiPowerAcpiP
            "deep C-States" = $esxiPowerAcpiC
            "Suspected BIOS Policy" = $biosPowerPolicySuspected
            "Used" = [Math]::Round($hostUsage,1)
            "Util" = [Math]::Round($hostUtil,1)
            "CoreUtil" = [Math]::Round($hostCoreUtil,1)
            "#VMs" = $numberOfVmsPoweredOn
            "#vCPUs" = $numberOfVcpusPoweredOn            
        } 

        $allResults += $currentResults

        Write-Verbose "Host End: $esxiHostName"
    }        
    Write-Verbose "Loop End"
    
    if ($allResults) {
        $allResults | Format-Table -Property * -AutoSize
        #$allResults | Export-Csv -Path $localFolder$csvExportFilename -NoTypeInformation
        #Write-Output "Results of run written to: $localFolder$csvExportFilename"
    } else {
        Write-Output "Nothing to report (no hosts or other issue, change to verbose logging)."
    }
}

Get-PowerManagementInfo
