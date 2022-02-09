#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/vmid2name.sh
# lists most of the ids you might need to "identify" a certain VM
# we don't want errors by default because some vsi nodes might already be partially destroyed
exec 2> /dev/null

printf "%+12s %+12s %+12s %+12s    %-42s %-42s\n" "WID" "CID" "GID" "LWID" "displayName" "workDir"
# https://stackoverflow.com/questions/38861895/how-to-repeat-a-dash-hyphen-in-shell
printf -- '-%.0s' $(seq 160); echo ""
for vm in $(vsish -e ls /vm/ | sort -n)
do
	cartel=$(vsish -e get /vm/${vm}vmxCartelID)
	group=$(vsish -e get /sched/Vcpus/${cartel}/groupID | sed 's/[ \t]*$//')
	vcpulead=$(vsish -e get /sched/groups/${group}/vcpuLeaderID | sed 's/[ \t]*$//')
	vmname=$(vsish -e get /world/${vcpulead}/name | cut -d : -f 2-)
	dir=$(vsish -e get /userworld/cartel/${cartel}/cmdline | grep -o /vmfs/volumes.* | cut -d / -f 4-5)
	printf "%+12s %+12s %+12s %+12s    %-42s %-42s\n" ${vm%%/} ${cartel} ${group} ${vcpulead} "${vmname%%/}" "${dir}"
done
