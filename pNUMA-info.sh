#!/bin/sh
# totally not supported
# questions / bugs? email: vbondzio

htstate=$(vsish -e get /hardware/cpu/cpuInfo | sed -n 's/^   Hyperthreading state:Hyperthreading state: 3 -> \(.*\)$/\1/p');
packages=$(vsish -e get /hardware/cpu/cpuInfo | sed -n 's/^   Number of packages:\([0-9]\)$/\1/p');

echo -e "Hyperthreading: $htstate\nPackages: "$packages

vsish -e ls /memory/nodeList/ | sort -n | while read node
do
    pcpus=$(vsish -e ls /hardware/numa/${node}/pcpus/ | wc -l)
    
    if [[ "$htstate" == "enabled" ]]
    then
            cores=$(expr $pcpus / 2)
    else
            cores=$pcpus
    fi

    totalpages=$(vsish -e get /memory/nodeList/${node} | sed -n 's/^   Total (pages):\([0-9]\+\)$/\1/p')
    freepages=$(vsish -e get /memory/nodeList/${node} | sed -n 's/^   Free (pages):\([0-9]\+\)$/\1/p')

    echo -e "\nNUMA Node ${node}" \\n "PCPUs: "$pcpus \\n "Cores: $cores"  \\n "Total Mem: "$(expr ${totalpages} \* 4 / 1024 / 1024)" GB" \\n "Free Mem: "$(expr ${freepages} \*
done
