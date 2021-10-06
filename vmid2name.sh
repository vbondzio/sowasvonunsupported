#!/bin/sh
exec 2> /dev/null

for vm in $(vsish -e ls /vm/)
do
    cartel=$(vsish -e get /vm/${vm}vmxCartelID)
    group=$(vsish -e get /sched/Vcpus/${cartel}/groupID | sed 's/[ \t]*$//')
    vcpulead=$(vsish -e get /sched/groups/${group}/vcpuLeaderID | sed 's/[ \t]*$//')
    vmname=$(vsish -e get /world/${vcpulead}/name | cut -d : -f 2-)
    echo -e "CID: ${cartel}\tGID: ${group}\tvcpuLeaderID: ${vcpulead}\tName: ${vmname%%/}"
done
