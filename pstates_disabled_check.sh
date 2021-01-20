#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/pstates_disabled_check.sh
# Checks whether the HW is disabling any P-States, preventing ESXi from using them. Exits if ESXi can't control P-States in the first place.

hwSupport=$(vsish -e get /power/hardwareSupport | sed -n 's/   CPU power management:\(ACPI P-states.*\)$/\1/p')
if [ -z "$hwSupport" ]; then
    echo "No P-States presented to ESXi"; exit 0
fi

for pcpu in $(vsish -e ls /power/pcpu/)
do 
	for pstate in $(vsish -e ls /power/pcpu/${pcpu}pstate/)
	do 
		avail=$(vsish -e get /power/pcpu/${pcpu}pstate/${pstate} | sed -n  's/^   Available: \([0-1]\)$/\1/p')
		if [ $avail == "0" ]
		then
			echo "${pstate%%/}"
		fi
	done
done | sort -n | uniq -c | awk '{ print "P"$2" is disabled on "$1" PCPUs" }'
