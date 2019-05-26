#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/pshare_check.sh
# Calculates shareable memory that is currently LP backed

# we don't want errors by default, just in case this is run while a VM is power up / down etc.
exec 2> /dev/null

# alloc/pshare was introduced in 6.5, the identifier in vsi did change in 6.7 though
version=$(vsish -e get /system/version | sed -n 's/   productVersion:\([0-9]\)\.\([0-9]\)\.\([0-9]\)$/\1\2\3/p')

pshareString65="s/   Current count of guest large page mappings:\([0-9]\+\)$/\1/p"
pshareString67="s/   Current number of 2MB page mappings:\([0-9]\+\)$/\1/p"

case $version in
        "650")  pshareString=${pshareString65};;
        "670")  pshareString=${pshareString67};;
esac

printf "\n%+9s     %-40s\n" "Shareable" "VM Name"
echo -e "-----------------------------------------------------"
for vm in $(vsish -e ls /vm/)
        do vmid=$(echo ${vm} | cut -d / -f -1)
        currentLargePages=$(vsish -e get /memory/lpage/vmLPage/${vmid} | sed -n "${pshareString}")
        vmname=$(vsish -e get /vm/${vm}vmmGroupInfo | sed -n 's/   display name:\(.*\)$/\1/p')
        shareablePct=$(vsish -e get /vm/${vm}alloc/pshare | sed -n 's/^   pct shareable.*:\([0-9]\+\)$/\1/p')
        shareableMb=$(awk "BEGIN {print ${currentLargePages} * 2 * ${shareablePct} / 10000}")
        shareableMbTotal=$(awk "BEGIN {print ${shareableMbTotal} + ${shareableMb}}")
        printf "%9.0f MB  %-40s\n" "${shareableMb}" "${vmname}"
done
echo -e "-----------------------------------------------------"
printf "%9.0f MB  %-40s\n\n" "${shareableMbTotal}" "Total"
