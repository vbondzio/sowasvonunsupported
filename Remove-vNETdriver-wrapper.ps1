function Remove-vNETdriver-wrapper {
    <#
    .SYNOPSIS
        Runs RemoveOldVNetDriver.ps1 on all powered on Windows VMs and report back whether they have to be rebooted
    .DESCRIPTION
        Gets some basic VM information and tries to invoke the script from https://kb.vmware.com/s/article/78016 to disable the old vNet driver. Reports back which VMs have to be restarted
    .NOTES
        Author:     Valentin
        GitHub:     https://github.com/vbondzio/sowasvonunsupported/blob/master/Remove-vNETdriver-wrapper.ps1
        Liability:  Absolutely none, I didn't even fully test this for all possible returns.
    .PARAMETER ClusterName
        The cluster which contains the VMs you want to run the KB script against. Runs against all clusters / hosts if not specified. Doesn't support resourcepools (will only get VMs directly under the cluster).
    .PARAMETER VMname
        The VM you want to run the KB script against. Runs against all clusters / hosts if not specified. Doesn't work together with ClusterName parameter.
    .PARAMETER Run
        Will copy and run the removal script, ommiting will just get VM / Windows info
    .EXAMPLE
        PS> Remove-vNETdriver-wrapper
    .EXAMPLE
        PS> Remove-vNETdriver-wrapper -Run
    .EXAMPLE
        PS> Remove-vNETdriver-wrapper -ClusterName "MyCluster" -Run
    #>

    param(
        [Parameter(Mandatory = $false)] [string]$ClusterName,
        [Parameter(Mandatory = $false)] [string]$VMname,
        [Parameter(Mandatory = $false)] [switch]$Run
    )

    $windowsAdminCred = Get-Credential -Message "Enter Windows guest local admin credentials:"
    $guestRemoteFolder ="C:\Windows\Temp\"
    
    $scriptName = "RemoveOldVNetDriver.ps1"
    $scriptOriginalMd5sum = "7D3F050F4A0C19182625E0B7F8C1278E"
    $localFolder ="c:\tmp\"
    $localScriptToUpload = "$localFolder"+"$scriptName"

    $runDateTime = (Get-Date).ToString('yyyy-MM-dd_HH-mm')
    $csvExportFilename = "Remove-vNETdriver-wrapper_export@$runDateTime.csv"

    $scriptCurrentMd5sum = $(Get-FileHash $localScriptToUpload -Algorithm MD5).Hash

    if ($scriptCurrentMd5sum -ne $scriptOriginalMd5sum) {
        Write-Host "The MD5 checksum of: "$localScriptToUpload" ($scriptCurrentMd5sum), doesn't match the one this script was written for ($scriptOriginalMd5sum).`nExiting"
        Exit
    }

    if($ClusterName) {
        $cluster = Get-View -ViewType ClusterComputeResource -Property Name,ResourcePool -Filter @{"Name"="$ClusterName"}
        $vms = Get-View ((Get-View $cluster.ResourcePool).VM) -Property Name,Summary.Vm,Runtime.PowerState,Config.GuestId,Guest
    } elseif ($VMname) {
        $vms = Get-View -ViewType VirtualMachine -Property Name,Summary.Vm,Runtime.PowerState,Config.GuestId,Guest -Filter @{"Name"="$VMname"}
    } else {
        $vms = Get-View -ViewType VirtualMachine -Property Name,Summary.Vm,Runtime.PowerState,Config.GuestId,Guest
    }

    $allResults = @()
    foreach ($vm in $vms | Where-Object {
            $_.Runtime.PowerState -eq "poweredOn" -and $_.Config.GuestId -like "windows*"
        } | Sort-Object -Property Name) {
        
        $fullVmObject = Get-VM -Id $vm.Summary.Vm
        
        $windowsVersion = "N/A"
        $psVersion = "N/A"
        $executionPolicy = "N/A"
        $fileCopied = "N/A"
        $scriptResult = "N/A"

        $debugStats = Invoke-VMScript -vm $fullVmObject -ScriptText "[System.Environment]::OSVersion.Version.ToString(); (Get-Host).Version.ToString(); Get-ExecutionPolicy" -GuestCredential $windowsAdminCred -ScriptType Powershell
        
        if ($debugStats) {
            $debugStats = $debugStats.Split("`n")
            $windowsVersion = $debugStats[0]
            $psVersion = $debugStats[1]
            $executionPolicy = $debugStats[2]
        }

        if ($Run) {
            Copy-VMGuestFile -VM $fullVmObject -LocalToGuest -Source $localScriptToUpload -Destination $guestRemoteFolder -GuestCredential $windowsAdminCred
            $fileCopied = $?
            
            if ($?){
                $scriptOutput = Invoke-VMScript -vm $fullVmObject -ScriptText "powershell.exe -ExecutionPolicy Bypass -File $guestRemoteFolder$scriptName" -GuestCredential $windowsAdminCred -ScriptType Powershell

                Switch -Regex ($scriptOutput) { 
                    '.*you must reboot Windows to stop the driver from running.' {
                        $scriptResult = "needs reboot"
                    } 
                    '.*driver service is stopped and deleted.' {
                        $scriptResult = "removed"
                    } 
                    '.*no issue.' {
                        $scriptResult = "no issue"
                    } 
                    Default {
                        $scriptResult = $scriptOutput
                    } 
                } 
            }
        }

        $currentResults = [pscustomobject] @{
            "VM Name" = $vm.Name
            "VM IP" = $vm.Guest.IpAddress
            "Tools Version" = $vm.Guest.ToolsVersion
            "Guest Configured" = $vm.Config.GuestId
            "Guest Detected" = $vm.Guest.GuestId
            "Windows Version" = $windowsVersion
            "PowerShell Version" = $psVersion
            "Execution Policy" = $executionPolicy
            "File Copied" = $fileCopied
            "Script Result" = $scriptResult
        }
        $allResults += $currentResults
    }
    $allResults | Export-Csv -Path $localFolder$csvExportFilename -NoTypeInformation
}
