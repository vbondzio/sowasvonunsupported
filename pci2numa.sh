#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/pstates_disabled_check.sh
# lists the NUMA node and connected PCI devices, | egrep "\[vm" for named vmk devices

# added in 6.7
version=$(vsish -e get /system/version | sed -n 's/   productVersion:\([0-9]\)\.\([0-9]\)\.\([0-9]\)$/\1\2\3/p')

if [ "$version" == "600" ] || [ "$version" == "650" ]
then
    echo "Needs ESXi 6.7 or newer"
	exit 0
fi

lspci=$(lspci)
for bus in $(vsish -e ls /hardware/pci/seg/0/bus/)
do
	for slot in $(vsish -e ls /hardware/pci/seg/0/bus/${bus}slot/)
	do
		for func in $(vsish -e ls /hardware/pci/seg/0/bus/${bus}slot/${slot}func/)
		do
			pciConfigHeader=$(vsish -e get /hardware/pci/seg/0/bus/${bus}slot/${slot}func/${func}pciConfigHeader)
			numaAssignedDevice=$(echo "${pciConfigHeader}" | sed -n 's/   Numa node:\([0-9]\+\)$/\1/p')
			if [ ${numaAssignedDevice} != "4294967295" ]
			then
				xbus=$(printf "%02x\n" ${bus%?})
				xslot=$(printf "%02x\n" ${slot%?})
				description=$(echo "${lspci}" | grep "0000:${xbus}:${xslot}.${func%?}" | cut -d " " -f 2-)
				echo ${numaAssignedDevice} - ${description}
			fi
		done
	done
done 
