#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/amperf.sh
# Prints avg. of core frequency per package in percent
# call with "all" to list all PCPUs instead of averaging per package, defaults to per socket

amperfSum=0
amperfCount=0

printf "%+8s  %+7s  %+6s\n" "Package" "PCPU" "AMPERF"

for package in $(vsish -e ls /hardware/cpuTopology/package/nodes/)
do 
	pcpurange=$(vsish -e get /hardware/cpuTopology/package/nodes/${package} | sed -n 's/   pcpus:\([0-9-]\+\)$/\1/p')
	pcpus=$(echo ${pcpurange} | sed 's/-/ /g')
	for pcpu in $(seq ${pcpus})
	do
		perf1=$(vsish -e get /power/pcpu/${pcpu}/perf)
		aperf1=$(echo "$perf1" | sed -n  's/^   APERF reading: \([0-9]\+\)$/\1/p')
		mperf1=$(echo "$perf1" | sed -n  's/^   MPERF reading: \([0-9]\+\)$/\1/p')
		
		perf2=$(vsish -e get /power/pcpu/${pcpu}/perf)
		aperf2=$(echo "$perf2"	| sed -n  's/^   APERF reading: \([0-9]\+\)$/\1/p')
		mperf2=$(echo "$perf2" | sed -n  's/^   MPERF reading: \([0-9]\+\)$/\1/p')

		amperfPct=$(printf %.2f\\n "$(( 100 * (${aperf2} - ${aperf1}) / (${mperf2} - ${mperf1}) ))")
		
		if [ "$1" == "all" ]
		then
			printf "%+8s  %+7s  %+6s\n" "${package}" "${pcpu}" "${amperfPct%.*}"
		else
			amperfSum=$(($amperfSum + ${amperfPct%.*}))
			amperfCount=$((amperfCount+1))
		fi
	done
	
	if [ "$1" != "all" ]
	then
		amperfPct=$(( $amperfSum / $amperfCount ))
		printf "%+8s  %+7s  %+6s\n" "${package}" "${pcpurange}" "${amperfPct%.*}"
	fi
done
