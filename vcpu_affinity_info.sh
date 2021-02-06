#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/vcpu_affinity_info.sh
# Lists running VM ID, sched group, numa client and vcpu affinity information

# we don't want errors in case some vsi node is halfway gone
exec 2> /dev/null

for vm in $(vsish -e ls /vm/)
do 
	cartel=$(vsish -e get /vm/${vm}vmxCartelID)
	group=$(vsish -e get /sched/Vcpus/${cartel}/groupID | sed 's/[ \t]*$//')
		
	vcpulead=$(vsish -e get /sched/groups/${group}/vcpuLeaderID | sed 's/[ \t]*$//')
	vmname=$(vsish -e get /world/${vcpulead}/name | cut -d : -f 2-)
	grpaff=$(vsish -e get /sched/groups/${group}/cpuAffinity | sed -n '/^   .*$/p')
	latSens=$(vsish -e get /sched/groups/${group}/latencySensitivity | sed -n 's/\(.*\) latency-sensitivity$/\1/p')
	echo -e "CID=${cartel%%/}\tGID=${group}\tLWID=${vcpulead}\tName=${vmname%%/}"
	echo -e "\nGroup CPU Affinity:\n${grpaff}"
	echo -e "\nLatency Sensitivity:\n   ${latSens}"
	for nc in $(vsish -e ls /sched/groups/${group}/numaClients)
	do
		ncaff=$(vsish -e get /sched/groups/${group}/numaClients/${nc}clientAffinity)
		nchn=$(vsish -e get /sched/groups/${group}/numaClients/${nc}home)
		echo -e "\nNUMA client ${nc%%/}:\n   affinity: ${ncaff}\n   home: ${nchn}"
	done
	echo -e
	printf "%+12s  %+5s  %+5s  %+12s  %+12s  %+9s  %+5s\n" "vcpuId" "vcpu#" "pcpu#" "affinityMode" "softAffinity" "Affinity" "ExAff"
	for vcpu in $(vsish -e ls /sched/cpuClients/${vcpulead}/Vcpus)
	do
		vcpuname=$(vsish -e get /sched/Vcpus/${vcpu}/worldName | sed -n 's/^vmx-vcpu-\([0-9]\+\):.*$/\1/p')
		pcpu=$(vsish -e get /sched/Vcpus/${vcpu}/stats/summaryStats | sed -n 's/^   PCPU:pcpu \([0-9]\+\)/\1/p')
		amode=$(vsish -e get /sched/Vcpus/${vcpu}/stats/summaryStats | sed -n 's/^   .*affinityMode: \([0-9].*$\)/\1/p')
		affinity=$(vsish -e get /sched/Vcpus/${vcpu}/stats/affinity)
		saffinity=$(vsish -e get /sched/Vcpus/${vcpu}/stats/softAffinity)
		xaffinity=$(vsish -re get /sched/Vcpus/${vcpu}/exclusiveAffinity)
		if [ $xaffinity != "0xffffffff" ]
		then
			exaff="yes"
		else
			exaff="no"			
		fi
		printf "%+12s  %+5s  %+5s  %+12s  %+12s  %+9s  %+5s\n" "${vcpu}" "${vcpuname}" "${pcpu}" "${amode}" "${saffinity}" "${affinity}" "${exaff}"
	done
	echo -e "\n"
done
