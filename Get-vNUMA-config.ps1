function Get-vNUMA-config{
<#
.SYNOPSIS
    Retrieve the vNUMA config for all running VMs from a host
.DESCRIPTION
    The function retrieves the vmware.log of all powered on VMs and greps for vNUMA relevant dictionary and log entries. The equivalent of the ASH one-liner:
    "vmdumper -l | cut -d \/ -f 2-5 | while read path; do egrep -oi "DICT.*(displayname.*|numa.*|cores.*|vcpu.*|memsize.*|affinity.*)= .*|numa:.*|numaHost:.*" "/$path/vmware.log"; echo -e; done"
    Todo: make everything into proper objects (get adv settings for options, parse numahost log output), clean up temp space
.NOTES
    Author:     Valentin
    GitHub:     https://github.com/vbondzio/sowasvonunsupported/blob/master/Get-vNUMA-config.ps1
    Help:       vmware.log transfer shamelessly stolen from http://www.lucd.info/2011/02/27/virtual-machine-logging/ 
.PARAMETER VM
    The virtual machine(s) for which you want to retrieve, the logs. Defaults to all VMs on the host if left unspecified
.EXAMPLE
    PS> Get-vNUMA-config -HostName $ESXihost
.EXAMPLE
    PS> Get-vNUMA-config -VMName $VM
#>
    
    param(
    [parameter(Mandatory=$false)][String]$HostName,
    [parameter(Mandatory=$false)][String]$VMName
    )
    
    if($HostName) {
        $ESXiHost = Get-View -ViewType HostSystem -Property Name,VM -Filter @{"Name"=$HostName}
        $vms = Get-View ((Get-View $ESXiHost).VM) -Property Name,Config.Flags,Config.Files.LogDirectory,Runtime.PowerState
    } elseif($VMName) {
        $vms = Get-View -ViewType VirtualMachine -Property Name,Config.Flags,Config.Files.LogDirectory,Runtime.PowerState -Filter @{"name"=$VMName}
    } else {
        $vms = Get-View -ViewType VirtualMachine -Property Name,Config.Flags,Config.Files.LogDirectory,Runtime.PowerState
    }

    $tmpPath = "c:\Windows\temp\"
    $grepPattern = "DICT.*(displayname.*|numa.*|cores.*|vcpu.*|memsize.*|affinity.*)= .*|numa:.*|numaHost:.*"

    foreach($VM in $vms | Sort-Object -Property Name){
        if($VM.Runtime.PowerState -eq "poweredOn" -and $VM.Config.Flags.enableLogging -eq $true ) {
            $logPath = $VM.Config.Files.LogDirectory
            $dsName = $logPath.Split(']')[0].Trim('[')
            $vmPath = $logPath.Split(']')[1].Trim(' ')
            $ds = Get-Datastore -Name $dsName
            $drvName = "MyDS" + (Get-Random)
            
            New-PSDrive -Location $ds -Name $drvName -PSProvider VimDatastore -Root '\' | Out-Null
            Copy-DatastoreItem -Item ($drvName + ":" + $vmPath + "\vmware.log") -Destination ($tmpPath + $VM.Name + "\") -Force:$true
            Remove-PSDrive -Name $drvName -Confirm:$false
            Get-Content -Path  ($tmpPath + $VM.Name + "\vmware.log") | Select-String -Pattern ($grepPattern) | ForEach-Object {
                (($_) -Split "I125:")[1]
            }

        }
    }
}
