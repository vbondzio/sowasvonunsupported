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
        Will compare the ratio between sockets / evaluate sockets separately.
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
        $esxiHosts = Get-View -ViewType HostSystem -Property Name,Hardware,Runtime -Filter @{"Name"="$EsxiHostName"}
    } else {
        $esxiHosts = Get-View -ViewType HostSystem -Property Name,Hardware,Runtime
    }
        
    if ($global:DefaultVIServers.RefCount -ne "1") {
        Write-Error -Message "More than one connection, exiting. Remove the check if you know what you are doing."
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
    $numberOfMinutes = 15
    $numberOfSamples = $numberOfMinutes * 3

    # ignore avg. PCPU utilization < XX %
    $minPcpuUtilPct = 10

    ## maybe start with a target ratio and deduct based on circumstances
    # target used / util ratio, assuming no turbo boost
    # $targetRatio = 1
  
    $allResults = @()
    foreach ($esxiHost in $esxiHosts | Sort-Object -Property Name) {
        
        Write-Verbose "Host Start: $($esxiHost.Name)"

        $esxiHostName = $esxiHost.Name
        $esxiHostConnectionState = $esxiHost.Runtime.ConnectionState

        Write-Verbose "$esxiHostConnectionState"

        $actualRatio = "N/A"
        $freqScalingDetected = "N/A"

        $vmsPoweredOn = Get-View -ViewType "VirtualMachine" -Property Name,Config.Hardware -Filter @{"Runtime.PowerState"="PoweredOn"} -SearchRoot $($esxiHost).MoRef
        $numberOfVmsPoweredOn = $vmsPoweredOn.count

        if ($esxiHostConnectionState -eq "connected" -and $numberOfVmsPoweredOn -ge 1){
            # not sure I'm going to use that but it should probably be the upper limit for PCPU consideration for non HCI
            $numberOfVcpusPoweredOn = ($vmsPoweredOn.Config.Hardware.NumCPU | Measure-Object -Sum).Sum
            # maybe use $esxiHost.Hardware.CpuPkg and ThreadId instead of "manually" grouping the sockets
            $pSockets = $esxiHost.Hardware.CpuInfo.NumCpuPackages
            $pCores = $esxiHost.Hardware.CpuInfo.NumCpuCores
            $pThreads = $esxiHost.Hardware.CpuInfo.NumCpuThreads
           
            $queryStats = 'cpu.utilization.average','cpu.usage.average'
            $esxiHostObject = Get-VMHost -Name $esxiHost.Name
            
            $perPcpuStats = Get-Stat -Entity $esxiHostObject -MaxSamples $numberOfSamples -Realtime -Stat $queryStats |
             Select-Object MetricId,Value,Instance |
             Where-Object {$_.Instance -ne ""} | 
             Group-Object -Property Instance | ForEach-Object {
                $Usage = ($_.Group | Where-Object {$_.MetricId -eq 'cpu.usage.average'} | Measure-Object -Property Value -Average).Average
                $Util = ($_.Group | Where-Object {$_.MetricId -eq 'cpu.utilization.average'} | Measure-Object -Property Value -Average).Average
                New-Object PSObject -Property ([ordered]@{
                    PCPU = $_.Name
                    Usage = [Math]::Round($Usage,1)
                    Util = [Math]::Round($Util,1)
                    Ratio = [Math]::Round($Usage / $Util,2)
                }) 
            }
            
            # $perPcpuStats | Sort-Object {[int]$_.PCPU}
            #
            # TODO - pretty much half of the description ...
            #

            if ($PerSocket) {
                # just set the ratio of the affected socket(s), affected calc is the same
                Write-Error "Check back in a few days, not implemented yet"
                break
            } else {
                $hostStats = $perPcpuStats
            }

            # don't forget to check MaxFreqPct for custom ESXi policy
            if ($pCores / $pThreads -ne 1) {
                $smt = $true
                $targetRatio = 0.5
                # calculate htused based on 100 * cores < sum of util
            } else {
                $smt = $false
                $targetRatio = 0.8
            }

            $freqScalingDetected = $false
            $actualRatio = [Math]::Round(($hostStats | Where-Object {$_.Util -gt $minPcpuUtilPct} | Measure-Object -Property Ratio -Average).Average, 2)
            Write-Verbose "Used / Util Ratio: $actualRatio"
                        
            if ($actualRatio -eq 0) {
                $freqScalingDetected = "N/A, utilization < minPcpuUtilPct"
            } elseif ($actualRatio -lt $targetRatio) {
                $freqScalingDetected = $true
            }
        }
        $currentResults = [pscustomobject] @{
            "Host" = $esxiHostName
            "#VMs" = $numberOfVmsPoweredOn
            "Ratio" = $actualRatio
            "Down-Scaled" = $freqScalingDetected
        }
        if ($listAll -or $freqScalingDetected) {
            $allResults += $currentResults
        } 
        Write-Verbose "Host End: $esxiHostName"
    }        
    Write-Verbose "Loop End"
    if ($allResults) {
        $allResults | Format-Table -AutoSize
        $allResults | Export-Csv -Path $localFolder$csvExportFilename -NoTypeInformation
        Write-Host "Results of run written to: $localFolder$csvExportFilename"
    } else {
        Write-Verbose "Nothing ... "
    }
}
