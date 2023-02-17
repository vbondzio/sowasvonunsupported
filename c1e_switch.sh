#!/bin/sh
# https://github.com/vbondzio/sowasvonunsupported/blob/master/c1e_switch.sh
# disable or enable C1E via MSR, completely and utterly unsupported
# Intel CPUs post Nehalem only

# C1E enablement in the boot log doesn't really matter, maybe do something fancy at a later date
# c1eEnabledBootLog=$(gzip -dc /var/log/boot.gz | grep -c C1E\ feature\ enabled\ by\ the\ BIOS)
# echo -e "\nC1E enabled according to /var/log/boot.gz? - ${c1eEnabledBootLog}"

MSR_POWER_CTL=0x000001fc
MSR_POWER_CTL_C1E=0x00000002

powerControlMsr=$(vsish -e get /hardware/msr/pcpu/0/addr/${MSR_POWER_CTL})
switchedC1eMsr=$(printf "0x%x\n" "$((${powerControlMsr} ^ ${MSR_POWER_CTL_C1E}))") # XOR

checkAllPcpusForPowerControlMsrValue () {
    # the check is really just for debug / sanity checking, the MSR should be synced across cores in a package and checking both threads is probably unnecessary 

    powerControlMsrUnique=$(
        for allPcpus in $(vsish -e ls /hardware/cpu/cpuList/)
        do
            vsish -e get /hardware/msr/pcpu/${allPcpus}/addr/${MSR_POWER_CTL} 
        done | uniq | wc -l
    )
    
    if [ ${powerControlMsrUnique} != "1" ] 
    then
        echo -e "something is really wrong, call an adult!" >&2
        fi
}

checkC1eEnabled () {
    # according to the MSR value on PCPU0
    powerControlMsr=$(vsish -e get /hardware/msr/pcpu/0/addr/${MSR_POWER_CTL})
    c1eEnabledMsr=$(((${powerControlMsr} & ${MSR_POWER_CTL_C1E}) !=0)) # AND

    if [ "${c1eEnabledMsr}" == "1" ]
    then
        echo -e "C1E enabled" >&2
    else
        echo -e "C1E disabled" >&2
    fi
}

$(checkC1eEnabled)
$(checkAllPcpusForPowerControlMsrValue)

numPackages=$(sched-stats -t ncpus | sed -n 's/^[ \t]*\([0-9]\+\) packages$/\1/p')
numPcpus=$(sched-stats -t ncpus | sed -n 's/^[ \t]*\([0-9]\+\) PCPUs$/\1/p')

for firstPcpuEachPackage in $(seq 0 $((${numPcpus} / ${numPackages})) $((${numPcpus} - 1)))
do
    echo -e "writing ${switchedC1eMsr} to PCPU ${firstPcpuEachPackage} at ${MSR_POWER_CTL}"
    vsish -e set /hardware/msr/pcpu/${firstPcpuEachPackage}/addr/${MSR_POWER_CTL} ${switchedC1eMsr}
done

$(checkAllPcpusForPowerControlMsrValue)
$(checkC1eEnabled)
