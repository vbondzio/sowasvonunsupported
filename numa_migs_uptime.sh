#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/numa_migs_uptime.sh
# numa migrations over absolute uptime, also includes locality swap which is missing in "sched-stats -t numa-migration"
# really more of a hint since absolute migrations since invocation tells you nothing over long periods of time
# use numa_migs_diff.sh for checking recent / ongoing migrations

# we don't want errors in case some vsi node is halfway gone
exec 2> /dev/null

for vm in $(vsish -e ls /vm/)
do
	cartel=$(vsish -e get /vm/${vm}vmxCartelID)
	group=$(vsish -e get /sched/Vcpus/${cartel}/groupID | sed 's/[ \t]*$//')

	vcpulead=$(vsish -e get /sched/groups/${group}/vcpuLeaderID | sed 's/[ \t]*$//')
	vmname=$(vsish -e get /world/${vcpulead}/name | cut -d : -f 2-)
	uptime=$(vsish -e get /sched/Vcpus/${vcpulead}/stats/stateTimes | sed -n 's/^   uptime:\([0-9]\+\).\{6\} usec $/\1/p')
	
	echo -e "CID=${cartel%%/}\tGID=${group}\tLWID=${vcpulead}\tName=${vmname%%/}\tUptime(hours)=$(( ${uptime} / 3600 ))\n"

	printf "%+9s %+9s %-40s\n" "absolute" "per hour" "type"
	echo -e "--------------------------------------------"
	
	migrationTotal=0
	for migrations in $(vsish -e get /sched/groups/${group}/stats/numaStats/stats | egrep "balanceMig|loadSwap|localitySwap|loadMigration|localityMigration|longTermFairnessMig")
	do
		migrationType=$(echo ${migrations} | cut -d : -f 1)
		migrationAmount=$(echo ${migrations} | cut -d : -f 2)
		printf "%+9s %+9s %-40s\n" "${migrationAmount}" "$(( ${migrationAmount} / (${uptime} / 3600) ))" "${migrationType}"
		migrationTotal=$(( ${migrationTotal} + ${migrationAmount} ))
	done
	
	echo -e "--------------------------------------------"
	printf "%+9s %+9s %-40s\n\n\n" "${migrationTotal}" "$(( ${migrationTotal} / (${uptime} / 3600) ))" "Total"
done
