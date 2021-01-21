#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/pNUMA-info.sh
# no idea why you would be using this instead of sched-stats -t ncpus / numa-pnode

htstate=$(vsish -e get /hardware/cpu/cpuInfo | sed -n 's/^   Hyperthreading state:.* \([a-z]\+\)$/\1/p')
packages=$(vsish -e get /hardware/cpu/cpuInfo | sed -n 's/^   Number of packages:\([0-9]\)$/\1/p')
nodes=$(sched-stats -t ncpus | sed -n 's/\([0-9]\+\) NUMA nodes$/\1/p')
echo -e "Hyperthreading: $htstate\nPackages: $packages\nNodes: $nodes"
for node in $(vsish -e ls /memory/nodeList/ | sort -n)
do
	pcpus=$(vsish -e ls /hardware/numa/${node}/pcpus/ | wc -l)
	if [[ "$htstate" == "enabled" ]]
	then
		cores=$(( $pcpus / 2 ))
	else
		cores=$pcpus
	fi
	totalpages=$(vsish -e get /memory/nodeList/${node} | sed -n 's/^   Total (pages):\([0-9]\+\)$/\1/p')
	freepages=$(vsish -e get /memory/nodeList/${node} | sed -n 's/^   Free (pages):\([0-9]\+\)$/\1/p')
	echo -e "\nNUMA Node ${node}" \\n "PCPUs: "$pcpus \\n "Cores: $cores"  \\n "Total Mem: "$(( ${totalpages} * 4 / 1024 / 1024 ))" GB" \\n "Free Mem: "$(( ${freepages} * 4 / 1024 / 1024 ))" GB"
done
