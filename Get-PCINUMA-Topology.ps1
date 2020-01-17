function Get-PCINUMA-Topology {
    <#
    .SYNOPSIS
        Retrieve the NUMA topology of PCI devices from a given ESXi host
    .DESCRIPTION
        The function retrieves PCI information including the devices NUMA location from an ESXi host. It needs 6.7 and a recent-ish version of PowerCLI.
        Note that this funcion sources a GitHub hosted "join" function.
    .NOTES
        Author:     Valentin
        GitHub:     https://github.com/vbondzio/sowasvonunsupported/blob/master/Get-PCINUMA-Topology.ps1 
    .PARAMETER HostName
        The host you want to connect and retreive the topology information for.
    .PARAMETER All
        By default, Get-PCINUMA-Topology will only return PCI devices with a VMkernel Name (vmnic / vmhba etc.), specifying "-All" will return all PCI devices that are associated to a NUMA node
    .EXAMPLE
        PS> Get-vNUMA-config -HostName $ESXihost
    .EXAMPLE
        PS> Get-vNUMA-config -HostName $ESXihost -All
    #>

    param(
        [Parameter(Mandatory = $true)] [string]$HostName,
        [Parameter(Mandatory = $false)] [switch]$All
    )

    $user = "root"
    $password = 'foobar'

    # bail if powershell / cli / esxi isn't on the required build
    # todo: powershell, I guess 4?
    # $powerShellVersion = $Host.Version
    # PowerCLI has to be 10.1.0:
    # https://vdc-download.vmware.com/vmwb-repository/dcr-public/84d0d3d0-b960-4e39-888c-e67a01af23fe/e6519fe3-ac1d-4b9e-85c0-178160b23593/vmware-powercli-101-release-notes.html
    # "VMware PowerCLI has been updated to support the new API features in VMware vSphere 6.7.
    # let's hope we don't use double digit minor numbers ... could also check if I wasn't lazy ...
    $powerCliVersion = (Get-Module -Name VMware.PowerCLI | Select-Object -Property Version).Version
    $ourPowerCliVersion = [string]($powerCliVersion).Major + [string]($powerCliVersion).Minor
    $minPowerCliVersion = 101
    if ([int]$ourPowerCliVersion -lt $minPowerCliVersion) {
        Write-Error -Message "PowerCLI version must support 6.7 API (10.1.0.8403314). Current Version: $powerCliVersion"
        break
    }

    # right now only works against a host, not via vCenter (PR 2486858)
    Connect-VIServer -Server $HostName -User $user -Password $password | Out-Null

    $esxiVersion = ($global:DefaultVIServers).Version
    $hostOrvCenter = ($global:DefaultVIServers).ProductLine
    $numberOfConnections = ($global:DefaultVIServers).count

    if ($esxiVersion -ne "6.7.0" -or $hostOrvCenter -ne "embeddedEsx" -or $numberOfConnections -ne "1") {
        Write-Error -Message "Not connected _directly_ and _only_ to an 6.7+ ESXi host"
        Disconnect-VIServer -Server $esxiHostFqdn -Confirm:$false
        break
    }

    $vmHost = Get-VMHost
    $hostEsxcli = Get-EsxCli -V2 -VMHost $vmHost
    $hostInfo = ($vmHost | Get-View -Property Name,Hardware.NumaInfo)
    # https://code.vmware.com/apis/358/vsphere/doc/vim.host.NumaNode.html 
    $hostNumaInfo = $hostInfo.Hardware.NumaInfo.NumaNode
    $hostPciInfo = $hostEsxcli.Hardware.pci.list.Invoke()

    # keep an eye on https://github.com/PowerShell/PowerShell/issues/5909#issuecomment-461192202, until then the below should be fine since it is https and immutable for a specific change
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/iRon7/Join-Object/83a2f33b2d205e70d4840269a11c1b02c8b4ba24/Join-Object.ps1' | Invoke-Expression
    # needs expression for fall-back, see:
    # https://github.com/iRon7/Join-Object/issues/10#issuecomment-572556965
    # should really just build a custom object given the little amount of data
    # in my defense, my older approach joined a ton more 
    $pciAndNumaTable = $hostNumaInfo | InnerJoin-Object $hostPciInfo { $Left.PciId -contains $Right.Address } `
        | Select-Object DeviceName,VendorName,VMkernelName,Address,
    @{ N = "VID"; E = { [string]::Format("{0:x}",$_.VendorId) } },
    @{ N = "DID"; E = { [string]::Format("{0:x}",$_.DeviceId) } },
    @{ N = "SVID"; E = { [string]::Format("{0:x}",$_.SubVendorId) } },
    @{ N = "SDID"; E = { [string]::Format("{0:x}",$_.SubDeviceId) } },
    @{ N = "NUMA Node"; E = { $_.TypeId } }

    if ($All) {
        $pciAndNumaTable | Sort-Object -Property "NUMA Node","Address" | Format-Table -AutoSize
    } else {
        $pciAndNumaTable | Where-Object { $_.VMkernelName -like "vm*" } | Sort-Object -Property "NUMA Node","Address" | Format-Table -AutoSize
    }
}
Get-PCINUMA-Topology
