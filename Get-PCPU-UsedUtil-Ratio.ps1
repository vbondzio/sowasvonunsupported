function Get-PCPU-UsedUtil-Ratio {
    <#
    .SYNOPSIS
        Checks the per PCPU Usage / Utilization difference and alert when frequency scaling is suspected.
    .DESCRIPTION
        Checks all hosts under the vCenter or a specific one and gathers PCPU Usage and Utilization figures, approximate ratio per PCPU to identify non-ESXi controlled frequency scaling. Takes into account whether the BIOS presents (legacy) P-States, the ESXi policy and availability of SMT. It assumes a certain utilization minimum and will become less accurate the closer it is to that minimum. Stats over the last 15 minutes are used for the calculation.
        # note: at least thats the goal, it might not right now
    .NOTES
        Author:     Valentin
        GitHub:     https://github.com/vbondzio/sowasvonunsupported/blob/master/Get-PCPU-UsedUtil-Ratio.ps1
        Liability:  Absolutely none, might work, might not, no guarantees. 
    .PARAMETER EsxiHostName
        The host in which all PCPU ratios will be checked. The function runs against hosts in the vCenter if not specified. 
    .PARAMETER PerSocket
        Will check each package separately and return the host as affect if at least one socket is below the target ratio. It is also more accurate as it takes minimum utilization for HT into account (not accurate if HT is forced on part of the package via affinities).
    .PARAMETER ListAll
        Will list all instead of just affected hosts.
    .EXAMPLE
        PS> Invoke-Rolling-Maintenance-Mode
    .EXAMPLE
        PS> Invoke-Rolling-Maintenance-Mode -PerSocket
    .EXAMPLE
        PS> Invoke-Rolling-Maintenance-Mode -EsxiHostName "MyHost"
    #>

    param(
        [Parameter(Mandatory = $false)] [string]$EsxiHostName,
        [Parameter(Mandatory = $false)] [switch]$PerSocket,
        [Parameter(Mandatory = $false)] [switch]$ListAll
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
    # should be 15 and 3, if not I might have changed it for testing and not reverted, uhps 
    $numberOfMinutes = 1
    $numberOfSamples = $numberOfMinutes * 1

    # ignore avg. PCPU utilization < XX %
    # can be reduced on lower utilized hosts but evaluation will become less accurate
    # should be 10, if not I might have changed it for testing and not reverted, uhps 
    # will be adjusted depending on ESXi Power Policy if in effect ... or maybe not, check back with Tim whether CPU Load Default translates to util, 60% for Balanced and 90 % for Low Power, seems a tad high
    $minPcpuUtilPctDefault = 10

    # target used / util ratio, assuming no turbo boost
    # should be 1, if not I might have changed it for testing and not reverted, uhps 
    $targetUsedUtilRatioDefault = 1
    
    $allResults = @()
    foreach ($esxiHost in $esxiHosts | Sort-Object -Property Name) {
        
        Write-Verbose "Host Start: $($esxiHost.Name)"

        $esxiHostName = $esxiHost.Name
        $esxiHostConnectionState = $esxiHost.Runtime.ConnectionState

        Write-Verbose "Connection: $esxiHostConnectionState"
        
        $actualUsedUtilRatio = "N/A"
        $freqScalingDetected = "N/A"
        $cpuTopology = "N/A"
        $esxiPowerPolicy = "N/A"
        $esxiPowerAcpiP = "N/A"
        $esxiPowerAcpiC = "N/A"
        $biosPowerPolicySuspected = "N/A"
        $numberOfVmsPoweredOn = "N/A"
        $numberOfVcpusPoweredOn = "N/A"
        $actualUsedUtilRatio = "N/A"
        $freqScalingDetected = "N/A"
        
        # will not fail if host is disconnected funnily enough
        $vmsPoweredOn = Get-View -ViewType "VirtualMachine" -Property Name,Config.Hardware -Filter @{"Runtime.PowerState"="PoweredOn"} -SearchRoot $($esxiHost).MoRef
        $numberOfVmsPoweredOn = $vmsPoweredOn.count

        $targetUsedUtilRatio = $targetUsedUtilRatioDefault

        Write-Verbose "# VMs: $numberOfVmsPoweredOn"
        
        # let's ignore powered on VMs and set it to 0 instead of 1
        if ($esxiHostConnectionState -eq "connected" -and $numberOfVmsPoweredOn -ge 0){
            
            # not sure I'm going to use that but it should probably be the upper limit for PCPU consideration for non HCI
            $numberOfVcpusPoweredOn = ($vmsPoweredOn.Config.Hardware.NumCPU | Measure-Object -Sum).Sum
            
            $pSockets = $esxiHost.Hardware.CpuInfo.NumCpuPackages
            $pCores = $esxiHost.Hardware.CpuInfo.NumCpuCores
            $pThreads = $esxiHost.Hardware.CpuInfo.NumCpuThreads
            $cpuTopology = "$pSockets/$pCores/$pThreads"
            
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

            # just if I'm ever bored, check the impact of having config.option in the original get-view properties since Custom policies are massively rare
            if ($esxiPowerPolicy -eq "Custom"){
                $esxiPowerOptions = $esxiHost.Config.Option | Where-Object {$_.Key -match "^Power*"}
                # TODO a bunch of stuff to max limit the ratio to MaxFreqPct and check MinFreqPct as the lowest watermark, maybe set minPcpuUtilPct to MaxCpuLoad ... WRT to that, I should do some sort of a modifier since MaxCpuLoad is used on a vastly smaller scale and I'm looking at at least 20 second samples ... so maybe divide by 20 at least? Na, that would move us to close to error margin territory... 
            }

            $minPcpuUtilPct = $minPcpuUtilPctDefault = 10

            if ($esxiPowerAcpiP) {
                switch ($esxiPowerPolicy) {
                    Balanced {
                        $esxiPowerMaxCpuLoad = 60
                    } 
                    Low {
                        $esxiPowerMaxCpuLoad = 90
                    } 
                    Custom {
                        # not even looking at min / max freq pct yet
                        If (($esxiPowerOptions | Where-Object {$_.Key -eq "Power.UsePStates"}).Value -eq 1){
                            $esxiPowerMaxCpuLoad = ($esxiPowerOptions | Where-Object {$_.Key -eq "Power.MaxCpuLoad"}).Value
                        }
                    } Default {
                        $esxiPowerMaxCpuLoad = 0
                    }                       
                }
            }

            # stats stuff, I'm pretty sure you need the full vmhost object here ... but it's late, TODO another time
            # let's get core util in case I have to throw most of the evaluation away
            $esxiHostObject = Get-VMHost -Name $esxiHost.Name
            $queryStats = 'cpu.utilization.average','cpu.usage.average','cpu.coreutilization.average'
            $perPcpuStats = Get-Stat -Entity $esxiHostObject -MaxSamples $numberOfSamples -Realtime -Stat $queryStats |
                Select-Object MetricId,Value,Instance |
                Where-Object {$_.Instance -ne ""} | 
                Group-Object -Property Instance | ForEach-Object {

                $localPcpu = $_.Name
                $Package = ($esxiHost.Hardware.CpuPkg | Where-Object {$_.ThreadId -contains $localPcpu}).Index
                $Usage = ($_.Group | Where-Object {$_.MetricId -eq 'cpu.usage.average'} | Measure-Object -Property Value -Average).Average
                $Util = ($_.Group | Where-Object {$_.MetricId -eq 'cpu.utilization.average'} | Measure-Object -Property Value -Average).Average
                $CoreUtil = ($_.Group | Where-Object {$_.MetricId -eq 'cpu.coreutilization.average'} | Measure-Object -Property Value -Average).Average
                
                New-Object PSObject -Property ([ordered]@{
                    PCPU = $_.Name
                    Package = $Package
                    Usage = $Usage
                    Util = $Util
                    CoreUtil = $CoreUtil
                    Ratio = $Usage / $Util
                }) 
            } | Sort-Object {[int]$_.PCPU}
            $perPcpuStats
            # let's already only consider the min util from here on, what if there is not a single PCPU above it?
            $perPcpuStats = $perPcpuStats | Where-Object {$_.Util -ge $minPcpuUtilPct} 
            
            if ($PerSocket -and $perPcpuStats) {
                $perPackageStats = $perPcpuStats | Group-Object -Property Package | ForEach-Object {

                    $Usage = ($_.Group.Usage | Measure-Object -Average).Average
                    # check for $minPcpuUtilPct here once host avg. is dropped in a later version
                    $Util = ($_.Group.Util | Measure-Object -Average).Average
                    $UtilSum = ($_.Group.Util | Measure-Object -Sum).Sum

                    New-Object PSObject -Property ([ordered]@{
                        Package = $_.Name
                        Usage = [Math]::Round($Usage,2)
                        Util = [Math]::Round($Util,2)
                        UtilSum = [Math]::Round($UtilSum,2)
                        Ratio = [Math]::Round($Usage / $Util,2)
                    }) 
                }
                # get only one Ratio from the socket with the lowest ratio
                $selectedPackageStats = $perPackageStats | Sort-Object -Property Ratio | Select-Object -First 1
                $actualUsedUtilRatio = $selectedPackageStats.Ratio

                # calculate a package util average, this might be slightly slightly too large as I'm assuming all dropped PCPUs < $minPcpuUtilPct
                $perPackageCores = $pCores / $pSockets
                $perPackageThreads = $pThreads / $pSockets
                $maxNonHtUtil = $perPackageCores * 100
                $maxHtUtil = $perPackageThreads * 100
                $numberOfBusyPcpus = ($perPcpuStats | Where-Object {$_.Packet -eq $selectedPackageStats.Packet}).count
                $sumUtilBusyPcpus = $selectedPackageStats.UtilSum
                # super advanced algorithms here ...
                $sumUtilFilteredPcpus = ($perPackageThreads - $numberOfBusyPcpus) * ($minPcpuUtilPct - 1)
                $packageUtil = [Math]::Round((($sumUtilBusyPcpus + $sumUtilFilteredPcpus) / $maxHtUtil) * 100,1)
                $packageUtil


            } else {
                $actualUsedUtilRatio = [Math]::Round(($perPcpuStats | Measure-Object -Property Ratio -Average).Average, 2)
            }
            Write-Verbose "Used / Util Ratio: $actualUsedUtilRatio"

            # check MaxFreqPct for custom ESXi policy once you figure out 
            if ($pCores / $pThreads -ne 1) { 
                if ($PerSocket -and $packageUtil -ge 50) {
                    $targetUsedUtilRatio =  [Math]::Round($targetUsedUtilRatio - (($packageUtil -50) /  100),2)
                    $targetUsedUtilRatio
                } elseif ($PerSocket -and $esxiPowerPolicy -eq "Balanced") {       
                    # TODO, implement some reduction due to ESXi PM
                    # let's just deduct a little in case we are running with balanced, more checks at some other point
                    $targetUsedUtilRatio = $targetUsedUtilRatio - 0.3
                }else {
                    # ultimately, checking for above 50% util only makes sense per socket ... unless I evaluate on a per core basis ...
                    # I should probably just rewrite everything to a per socket check, or per core? sigh ...
                    # use 1.9 instead of 2 but this is still a worst case scenario as a default ... i.e. the > minPcpuUtilPct PCPUs of host would have to be nearly 50% frequency scaled if HT isn't used at all
                    $targetUsedUtilRatio = $targetUsedUtilRatio / 1.9
                } 
                # should I worry about the order of targetUsedUtilRatio deductions? Only once we look at ESXi PP
            } elseif ($esxiPowerPolicy -eq "Balanced") {
                $targetUsedUtilRatio = $targetUsedUtilRatio - 0.3
            }

            # take 10% off the target ratio just in case?
            # $targetUsedUtilRatio = $targetUsedUtilRatio - ($targetUsedUtilRatio / 10)
            
            $freqScalingDetected = $false
        
            if ($actualUsedUtilRatio -eq 0) {
                $freqScalingDetected = "N/A (Util < minPcpuUtilPct: $minPcpuUtilPct)"
            } elseif ($actualUsedUtilRatio -lt $targetUsedUtilRatio) {
                $freqScalingDetected = $true
            }

            Write-Verbose "Freq. Scaled?: $freqScalingDetected"
        }

        $currentResults = [pscustomobject] @{
            "Host" = $esxiHostName
            "Sockets/Cores/Threads" = $cpuTopology
            "ESXi Policy" = $esxiPowerPolicy
            "P-States" = $esxiPowerAcpiP
            "deep C-States" = $esxiPowerAcpiC
            "Suspected BIOS Policy" = $biosPowerPolicySuspected
            # VMs an vCPUs of the whole host, even with -PerSocket
            "#VMs" = $numberOfVmsPoweredOn
            "#vCPUs" = $numberOfVcpusPoweredOn
            # lowest ratio of all sockets with -PerSocket
            "Ratio" = $actualUsedUtilRatio
            "Target Ratio" =  [Math]::Round($targetUsedUtilRatio, 2)
            "Down-Scaled" = $freqScalingDetected
        } 

        if ($listAll -or ($freqScalingDetected -NotLike "N/A*" -and $freqScalingDetected -ne $false)) {
            $allResults += $currentResults
        } 
        Write-Verbose "Host End: $esxiHostName"
    }        
    Write-Verbose "Loop End"
    if ($allResults) {
        $allResults | Format-Table -Property * -AutoSize
        #$allResults | Export-Csv -Path $localFolder$csvExportFilename -NoTypeInformation
        #Write-Host "Results of run written to: $localFolder$csvExportFilename"
    } else {
        Write-Output "No hosts with severe frequency scaling or enough load to make prediction found. Try running with `"-ListAll`"."
    }
}

Get-PCPU-UsedUtil-Ratio -ListAll
