function Invoke-Rolling-Maintenance-Mode {
    <#
    .SYNOPSIS
        Will cycle all hosts through enter and exit maintenance mode, vMotioning all (vMotionable) VMs at least once.
    .DESCRIPTION
        Cycles all hosts in one or all clusters (default) into maintenance mode and out of it. By default, it will skip the remaining hosts in a cluster if enter maintenance mode fails / times out. It also "trails" every maintenance mode with a sleep for e.g. memory reclamation and migrations to settle. This is for 6.5 and newer and doesn't have versioning for earlier releases.
    .NOTES
        Author:     Valentin
        GitHub:     https://github.com/vbondzio/sowasvonunsupported/blob/master/Invoke-Rolling-Maintenance-Mode.ps1
        Liability:  Absolutely none, I didn't fully test this and its far from complete.
    .PARAMETER ClusterName
        The cluster in which all hosts will be MM cycled. Runs against all clusters / hosts in the vCenter if not specified. 
    .PARAMETER Continue
        Will not skip the cluster if one of the host doesn't successfully enter maintenance mode.
    .EXAMPLE
        PS> Invoke-Rolling-Maintenance-Mode
    .EXAMPLE
        PS> Invoke-Rolling-Maintenance-Mode -Continue
    .EXAMPLE
        PS> Invoke-Rolling-Maintenance-Mode -ClusterName "MyCluster"
    #>

    param(
        [Parameter(Mandatory = $false)] [string]$ClusterName,
        [Parameter(Mandatory = $false)] [switch]$Continue
    )

    if($ClusterName) {
        $clusters = Get-View -ViewType ClusterComputeResource -Property Name,Host,Configuration -Filter @{"Name"="$ClusterName"}
    } else {
        $clusters = Get-View -ViewType ClusterComputeResource -Property Name,Host,Configuration
    }
    
    if ($global:DefaultVIServers.RefCount -ne "1") {
        Write-Error -Message "More than one connection, exiting. Remove the check if you know what you are doing."
        Disconnect-VIServer -Confirm:$false
        Exit
    }

    # "debug" logging: Continue, SilentlyContinue
    $VerbosePreference = "Continue"
    # ensureObjectAccessibility, evacuateAllData, noAction
    $vsanDataMigrationDefault = "ensureObjectAccessibility"
    $mModeTimeoutSeconds = 600
    $mModeIntervalDelaySeconds = 300

    $localFolder ="c:\tmp\"
    $runDateTime = (Get-Date).ToString('yyyy-MM-dd_HH-mm')
    $csvExportFilename = "Invoke-Rolling-Maintenance-Mode_export@$runDateTime.csv"

    $allResults = @()
    foreach ($cluster in $clusters | Sort-Object -Property Name) {

        Write-Verbose "Cluster Start: $($cluster.Name)"

        # I won't take EnableVmBehaviorOverrides into account
        $clusterName = $cluster.Name
        $DrsEnabled = $cluster.Configuration.DrsConfig.Enabled
        $DrsLevel = $cluster.Configuration.DrsConfig.DefaultVmBehavior
        $vmotionRate = $cluster.Configuration.DrsConfig.VmotionRate
        # flatten for csv export
        $DrsOptions = $cluster.Configuration.DrsConfig.Option.ForEach({ '{0}={1}' -f $_.Key, $_.Value }) -join ' ' 

        $esxiHosts = Get-View $cluster.Host -Property Name,Runtime,Summary
       
        $esxiHostName = "N/A"
        $esxiHostPowerState = "N/A"
        $esxiHostConnectionState = "N/A"
        $esxiHostMaintenanceMode = "N/A"
        $esxiHostMQuarantineMode = "N/A"
        $esxiCycledMaintenanceMode = "N/A"

        foreach ($esxiHost in $esxiHosts | Sort-Object -Property Name) {
            
            Write-Verbose "Host Start: $($esxiHost.Name)"

            $esxiHostName = $esxiHost.Name
            $esxiHostPowerState = $esxiHost.Runtime.PowerState
            $esxiHostConnectionState = $esxiHost.Runtime.ConnectionState
            $esxiHostMaintenanceMode = $esxiHost.Runtime.InMaintenanceMode
            # should check for 6.5
            $esxiHostMQuarantineMode = $esxiHost.Runtime.InQuarantineMode
            
            $vmsNotMigrated = "N/A"
            $esxiCycledMaintenanceMode = "N/A"
            $breakLater = $false

            if ($esxiHostPowerState -eq "poweredOn" -and $esxiHostConnectionState -eq "connected" -and $DrsEnabled -eq $true -and $DrsLevel -eq "fullyAutomated" -and $esxiHostMaintenanceMode -eq $false -and $esxiHostMQuarantineMode -eq $false){

                $mModeSpec = New-Object VMware.Vim.HostMaintenanceSpec
                $mModeSpec.VsanMode = New-Object VMware.Vim.VsanHostDecommissionMode
                $mModeSpec.VsanMode.ObjectAction = [VMware.Vim.VsanHostDecommissionModeObjectAction]::$vsanDataMigrationDefault
                $timeout = $mModeTimeoutSeconds   
                $evacuatePoweredOffVms = $false

                $error.clear()
                try {
                    $esxiHost.EnterMaintenanceMode($timeout,$evacuatePoweredOffVms,$mModeSpec)
                } catch {
                    $vmsNotMigrated = (Get-View -ViewType "VirtualMachine" -Property Name -Filter @{"Runtime.PowerState"="PoweredOn"} -SearchRoot $(Get-View -ViewType "HostSystem" -Filter @{"Name"="$esxiHostName"} -Property Name).MoRef).Name
                    
                    Write-Verbose "Host MM failed: $esxiHostName"
                    
                    if (!$Continue) {
                        Write-Error -Message "$esxiHostName failed to enter maintenance mode, skipping remaining cluster."
                        $breakLater = $true
                    } else {
                        Write-Verbose "Host MM failed, continue: $esxiHostName"
                        Start-Sleep -Seconds $mModeIntervalDelaySeconds
                    }
                } 
                if (!$error) {
                    $esxiHost.ExitMaintenanceMode($timeout)
                    Start-Sleep -Seconds $mModeIntervalDelaySeconds
                    $esxiCycledMaintenanceMode = (Get-Date).ToString('yyyy-MM-dd:HH-mm-ss')

                    Write-Verbose "Host Cycled: $esxiHostName"
                } 
            }

            $currentResults = [pscustomobject] @{
                "Cluster" = $clusterName
                "DRS Enabled" = $DrsEnabled
                "DRS Level" = $DrsLevel
                "vMotion Rate" = $vmotionRate
                "Adv. Options" = $DrsOptions
                "Host" = $esxiHostName
                "Power" = $esxiHostPowerState
                "Connection" = $esxiHostConnectionState
                "VMs left" =  $vmsNotMigrated
                "Completed" = $esxiCycledMaintenanceMode
            }
            $allResults += $currentResults
            if ($breakLater) {
                Write-Verbose "Host Break: $esxiHostName"
                Break
            }
            Write-Verbose "Host End: $esxiHostName"
        }
        Write-Verbose "Cluster End: $clusterName"
    }        
    $allResults | Format-Table -AutoSize
    $allResults | Export-Csv -Path $localFolder$csvExportFilename -NoTypeInformation
    Write-Host "Results of run written to: $localFolder$csvExportFilename"
}
