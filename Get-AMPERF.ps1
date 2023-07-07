function Get-AMPERF {
    <#
    .SYNOPSIS
        Gets the frequency (Aperf/Mperf, percentage relative to nominal frequency) of each PCPU for a specific host, all host in a cluster or all hosts of the connected vCenter.
    .DESCRIPTION
        Gathers aperf and mperf values per PCPU over two data points, converts to pct relative to NF, the sample length is however long it takes to get the data, around 1-10 seconds. Uses Williams Get-EsxtopAPI to be able to get esxtop data via vCenter.
    .NOTES
        Author:     Valentin
        GitHub:     https://github.com/vbondzio/sowasvonunsupported/blob/master/Get-AMPERF.ps1
        Liability:  Absolutely none, might work, might not, no guarantees. 
    .PARAMETER EsxiHostName
        The host for which to gather the PCPUs frequency. The function runs against all hosts in the vCenter if not specified.
    .PARAMETER ClusterName
        The cluster for which to gather the PCPUs frequency of all hosts. The function runs against all hosts in the vCenter if not specified.         
    .EXAMPLE
        PS> Get-AMPERF
    .EXAMPLE
        PS> Get-AMPERF -EsxiHostName "MyHost"
    .EXAMPLE
        PS> Get-AMPERF -ClusterName "MyCluster"
    #>

    param(
        [Parameter(Mandatory = $false)] [string]$EsxiHostName,
        [Parameter(Mandatory = $false)] [string]$ClusterName
    )

    # Get-EsxtopAPI expects a full VMHost object, will look into that another day
    if($EsxiHostName) {
        $esxiHosts = Get-VMHost -Name $EsxiHostName
    } elseif($ClusterName) {
        $esxiHosts = Get-Cluster -Name $ClusterName | Get-VMHost
    } else {
        $esxiHosts = Get-VMHost
    }
        
    if ($global:DefaultVIServers.RefCount -ne "1") {
        Write-Error -Message "More than one connection, exiting. Remove this check if you know what you're doing."
        Disconnect-VIServer -Confirm:$false
        Exit
    }

    # export result table
    $currentFunction = (Get-PSCallStack)[0].FunctionName
    $runDateTime = (Get-Date).ToString('yyyy-MM-dd_HH-mm')
    $csvExportFilename = "${currentFunction}_export@${runDateTime}.csv"
    # make platform independent, maybe use PSTempDrive in PS 7.0
    $localFolder ="c:\tmp\"

    $allResults = @()    
    foreach ($esxiHost in $esxiHosts | Sort-Object -Property Name) {
        
        $esxtopSnapshot0 = Get-EsxtopPowerMetrics -EsxiHostName $esxiHost
        $esxtopSnapshot1 = Get-EsxtopPowerMetrics -EsxiHostName $esxiHost

        foreach ($pCPU in $esxtopSnapshot1.PCPU) {

            $aperf_t0 = ($esxtopSnapshot0 | Where-Object {$_.PCPU -eq "$pCPU"}).Aperf
            $aperf_t1 = ($esxtopSnapshot1 | Where-Object {$_.PCPU -eq "$pCPU"}).Aperf
            $mperf_t0 = ($esxtopSnapshot0 | Where-Object {$_.PCPU -eq "$pCPU"}).Mperf
            $mperf_t1 = ($esxtopSnapshot1 | Where-Object {$_.PCPU -eq "$pCPU"}).Mperf

            $amperfPct = (100 * ($aperf_t1 - $aperf_t0) / ($mperf_t1 - $mperf_t0))

            $currentResults = [pscustomobject] @{
                    "Host" = $esxiHost
                    "PCPU" = $pCPU
                    "A/MPERF%" = $amperfPct
            }
            $allResults += $currentResults
        }
        # I didn't see an impact on the host but better safe than sorry: https://williamlam.com/2013/01/retrieving-esxtop-performance-data.html
        $esxiHost | Get-EsxtopAPI -simpleCommand FreeStats | Out-Null
    }

    if ($allResults) {
        $allResults | Format-Table -Property * -AutoSize
        #$allResults | Export-Csv -Path $localFolder$csvExportFilename -NoTypeInformation
        #Write-Output "Results of run written to: $localFolder$csvExportFilename"
    } else {
        Write-Output "Nothing to report (no hosts or other issue)."
    }
}

Function Get-EsxtopPowerMetrics {
    <#
    .SYNOPSIS
        Helper function for Get-AMPERF
    .DESCRIPTION
        Gathers raw aperf and mperf values for all PCPUs of a host. Uses Williams Get-EsxtopAPI.
    .NOTES
        Author:     Valentin
        GitHub:     https://github.com/vbondzio/sowasvonunsupported/blob/master/Get-AMPERF.ps1
    .PARAMETER EsxiHostName
        The host for which to gather the raw AMPERF data.
    .EXAMPLE
        PS> Get-EsxtopPowerMetrics -EsxiHostName "MyHost"

    #>
    param(
        [Parameter(Mandatory = $true)] [string]$EsxiHostName
    )

    $esxtopFull = Get-VMHost -Name $EsxiHostName | Get-EsxtopAPI -simpleCommand FetchStats
    # don't ask me why that findstr is necessary, edit: ugh ...
    $esxtopMatch = $esxtopFull -split "`n" | Select-String "LCPUPower.[0-9]+"

    $allPCPUs = @()
    foreach ($line in $esxtopMatch.line){
        $currentPCPU = [pscustomobject] @{
           "PCPU" = $line.split("|")[2]
            "aperf" = $line.split("|")[3]
            "mperf" = $line.split("|")[4]
        }
        $allPCPUs += $currentPCPU
    }   
    $allPCPUs
}


function Get-EsxtopAPI {
    <#    
    .SYNOPSIS
        Using the vSphere API in vCenter Server to collect ESXTOP & vscsiStats metrics
    .NOTES
        Author:  William Lam
        Site:    www.williamlam.com
        Reference: http://www.williamlam.com/2017/02/using-the-vsphere-api-in-vcenter-server-to-collect-esxtop-vscsistats-metrics.html
    .PARAMETER Vmhost
        ESXi host
    .EXAMPLE
        PS> Get-VMHost -Name "esxi-1" | Get-EsxtopAPI
    #>

    param(
    [Parameter(
        Position=0,
        Mandatory=$true,
        ValueFromPipeline=$true,
        ValueFromPipelineByPropertyName=$true)
    ]
    [VMware.VimAutomation.ViCore.Impl.V1.Inventory.InventoryItemImpl]$VMHost,
    # VB: added parameter, using FetchStats and FreeStats
    [Parameter(
        Mandatory=$true)
    ]
    [string]$simpleCommand
    )

    $serviceManager = Get-View ($global:DefaultVIServer.ExtensionData.Content.serviceManager) -property "" -ErrorAction SilentlyContinue

    $locationString = "vmware.host." + $VMHost.Name
    $services = $serviceManager.QueryServiceList($null,$locationString)
    foreach ($service in $services) {
        if($service.serviceName -eq "Esxtop") {
            $serviceView = Get-View $services.Service -Property "entity"
            # VB: added parameter, using FetchStats and FreeStats
            $serviceView.ExecuteSimpleCommand("$simpleCommand") 
            break
        }
    }
}
