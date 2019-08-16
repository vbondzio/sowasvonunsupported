#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/memstats_wrapper.sh
# memstats but replaces vmId with displayName, limited to max characters in vm-stats name column, breaks for other reports due to different length

# todo:
# proper argument handling
# variable padding for other reports

report="vm-stats"
selection="name:b:schedGrp:parSchedGroup:min:max:memSize:max:consumed:ballooned:swapped:touched:active:zipped:shared:zero"
trim="/  \+name/,/ \+Total/p"

# http://stackoverflow.com/questions/1648055/preserving-leading-white-space-while-readingwriting-a-file-line-by-line-in-bas
memstats -r ${report} -s ${selection} -u mb 2> /dev/null | sed -n "${trim}" | while IFS='' read -r line
    do cartel=$(echo ${line} | sed -n 's/^.*vm\.\([0-9]\+\) .*$/\1/p');
    if [ "$cartel" ]
        then
        vmmlead=$(vsish -e get /userworld/cartel/${cartel}/vmmLeader)
        leadname=$(vsish -e get /world/${vmmlead}/name)
        # http://ideatrash.net/2011/01/bash-string-padding-with-sed.html
        # fix the fitting at some point to something not as ugly
        vmname=$(echo ${leadname} | cut -c 6-20 | sed -e :a -e 's/^.\{1,14\}$/ &/;ta')
        line=$(echo "$line" | sed "s/^.*vm\.[0-9]\+/$vmname/g")
    fi
echo "$line"
done
