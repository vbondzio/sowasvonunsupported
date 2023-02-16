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

numPackages=$(sched-stats -t ncpus | sed -n 's/^[ \t]*\([0-9]\+\) packages$/\1/p')
numCores=$(sched-stats -t ncpus | sed -n 's/^[ \t]*\([0-9]\+\) cores$/\1/p')
numThreads=$(sched-stats -t ncpus | sed -n 's/^[ \t]*\([0-9]\+\) PCPUs$/\1/p')

checkAllCoresForPowerControlMsrValue () {
    # the all core check is really just for debug / sanity checking, the MSR should be synced across cores in a package
    echo -e "\nChecking the value of MSR_POWER_CTL (${MSR_POWER_CTL}) for all ${numCores} cores:" >&2
    for powerControlMsrOfCore in $(seq 0 2 $((${numThreads} - 1)))
    do
        echo -e "PCPU ${powerControlMsrOfCore} - $(vsish -e get /hardware/msr/pcpu/${powerControlMsrOfCore}/addr/${MSR_POWER_CTL})" >&2
    done
}

checkC1eEnabled () {
    # according to the MSR value on PCPU0
    powerControlMsr=$(vsish -e get /hardware/msr/pcpu/0/addr/${MSR_POWER_CTL})
    c1eEnabledMsr=$(((${powerControlMsr} & ${MSR_POWER_CTL_C1E}) !=0)) # AND
    
    if [ "${c1eEnabledMsr}" == "1" ]
    then
        echo -e "\nC1E enabled" >&2 
    else
        echo -e "\nC1E disabled" >&2
    fi
}

$(checkC1eEnabled)
$(checkAllCoresForPowerControlMsrValue)

for lastPcpuEachPackage in $(seq $((${numThreads} / ${numPackages} - 1)) $((${numThreads} / ${numPackages})) ${numThreads})
do
    echo -e "\nwriting ${switchedC1eMsr} to PCPU ${lastPcpuEachPackage}"
    vsish -e set /hardware/msr/pcpu/${lastPcpuEachPackage}/addr/${MSR_POWER_CTL} ${switchedC1eMsr}
done

$(checkAllCoresForPowerControlMsrValue)
$(checkC1eEnabled)
