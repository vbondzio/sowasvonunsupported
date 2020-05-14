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
        The cluster which contains the VMs you want to run the KB script against. Runs against all clusters / hosts if not specified. Doesn't work with "VMname" parameter.
    .PARAMETER VMname
        The VM you want to run the KB script against. Runs against all clusters / hosts if not specified. Doesn't work with "ClusterName" parameter.
    .PARAMETER CsvFile
        The path to a single column, headered "VMNames", CSV file containing unique VM names.
    .PARAMETER Run
        Will copy and run the removal script, ommiting will just get VM / Windows info.
    .EXAMPLE
        PS> Remove-vNETdriver-wrapper
    .EXAMPLE
        PS> Remove-vNETdriver-wrapper -Run
    .EXAMPLE
        PS> Remove-vNETdriver-wrapper -ClusterName "MyCluster" -Run
    #>

    param(
        [Parameter(Mandatory = $false, ParameterSetName="Cluster")] [string]$ClusterName,
        [Parameter(Mandatory = $false, ParameterSetName="VM")] [string]$VMname,
        [Parameter(Mandatory = $false, ParameterSetName="CSV")] [string]$CsvFile,
        [Parameter(Mandatory = $false)] [switch]$Run
    )

    $WarningPreference = "SilentlyContinue"

    # "Read-Host -AsSecureString | ConvertFrom-SecureString". For testing, don't do that or replace it with proper credential management
    # $windowsAdminCred = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList "Administrator", $(ConvertTo-SecureString 01000000d08c9ddf0115d1118c7a00c04fc297eb0100000065a759ea933507458a7c8c815bfe5a7d00000000020000000000106600000001000020000000cb5698d93780e0b39116c9b907dce8e2d258267aa509ce441096d8cf385d6b9e000000000e8000000002000020000000cbfa1208bd65471062c80db18d8b2fe1cc97b4b59e4b64d623f0af3755e7314120000000b458f2f2f79ec02fefd841486f4bbe174c2475760ca2388bd402d8ad5af638f540000000a276c12692530f281fb01a9beeca272cb027e85b22af1c5bf690612fbfad148d590459dd679c30aec49b82022e17bcccfb7ea9a73d2fec0bb463efc87c99062b)
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
        $cluster = Get-View -ViewType ClusterComputeResource -Property Name,Host -Filter @{"Name"="$ClusterName"}
        $vms = Get-View ((Get-View $cluster.Host).VM) -Property Name,Summary.Vm,Runtime.PowerState,Config.GuestId,Guest
    } elseif ($VMname) {
        $vms = Get-VM -Name "$VMname" | Get-View
    } elseif ($CsvFile) {
        $csvVmNames = (Import-Csv -Path "$CsvFile").VMNames
        $vms = Get-VM -Name $csvVmNames | Get-View
    } else {
        $vms = Get-View -ViewType VirtualMachine -Property Name,Summary.Vm,Runtime.PowerState,Config.GuestId,Guest
    }

    $allResults = @()
    foreach ($vm in $vms | Where-Object {
            $_.Runtime.PowerState -eq "poweredOn" -and $_.Config.GuestId -like "windows*"
        } | Sort-Object -Property Name) {
            
        if (!$VMname -or !$CsvFile){
            $fullVmObject = Get-VM -Id $vm.Summary.Vm
        } else {
            $fullVmObject = $vm
        }

        $windowsVersion = "N/A"
        $psVersion = "N/A"
        $executionPolicy = "N/A"
        $fileCopied = "N/A"
        $scriptResult = "N/A"
        
        if ($debugStats) {
            Clear-Variable $debugStats
        }
                
        try {
            $debugStats = Invoke-VMScript -vm $fullVmObject -ScriptText "[System.Environment]::OSVersion.Version.ToString(); (Get-Host).Version.ToString(); Get-ExecutionPolicy" -GuestCredential $windowsAdminCred -ScriptType Powershell -ErrorAction Stop
        } catch {
            $fileCopied = "login failed"
        }

        if ($debugStats) {
            $debugStats = $debugStats.Split("`n")
            $windowsVersion = $debugStats[0]
            $psVersion = $debugStats[1]
            $executionPolicy = $debugStats[2]
        }

        if ($Run -and $debugStats) {
            
            try {
                Copy-VMGuestFile -VM $fullVmObject -LocalToGuest -Source $localScriptToUpload -Destination $guestRemoteFolder -GuestCredential $windowsAdminCred -ErrorAction Stop
                $fileCopied = $?
            } catch {
                $fileCopied = "file not copied"
            }

            # copy fail might have been file already uploaded, invoke anyhow            
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
    if (!$allResults) {
        Write-Host "No VM in scope (Guest type Windows and Powered on, in this vCenter / Cluster etc.)."
    } else {
        # $allResults
        $allResults | Export-Csv -Path $localFolder$csvExportFilename -NoTypeInformation
        Write-Host "Results of run written to: $localFolder$csvExportFilename"
    }
}
