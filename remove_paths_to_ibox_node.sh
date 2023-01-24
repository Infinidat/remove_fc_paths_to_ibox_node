#!/bin/bash

# A tool to eliminate FC paths from this host to a specific node of a specific IBOX. 
# Author: Ishraq Ahmed, INFINIDAT Technical Advisor

# Help function
show_usage()
{
echo "Eliminate FC paths to a given InfiniBox node"
echo
echo "Usage: $0 -n <1|2|3> -s <serial> [-h]"
echo "options:"
echo "n    InfiniBox node - 1, 2 or 3."
echo "s    InfiniBox serial number"
echo "h    print this help"
echo
}

_node=0
_serial=0

if [ $# -eq 0 ]; then
    show_usage
    exit
fi

while getopts "hn:s:" option; do
    case $option in 
        h) show_usage; 
           exit
           ;;
        n) _node=$OPTARG 
           ;;
        s) _serial=$OPTARG
           ;;
	\?) echo "Error: Invalid option"; show_usage; 
           exit
           ;;
    esac
done

if ! [[ $_node =~ ^[1|2|3]$ ]]; then
    echo "Error: Need InfiniBox node number 1|2|3"
    exit
fi
if ! [[ $_serial =~ ^[0-9]+$ ]]; then
    echo "Error: Invalid InfiniBox serial number $_serial"
    exit
fi
if [ $_serial -eq 0 ]; then
    echo "Error: Need InfiniBox serial number!"
    exit
fi
echo "Invoked command: $0 -n $_node -s $_serial"

# Our goal is to find the correct H:C:T:L values (Host:Controller:Target:Lun)
# for the paths pointing to all the sd devices from a specific IBOX node.
# One the sdX devices are found, we delete them from multipath and kernel.
# H = host hba 0, 1, etc
# C = always 0.
# T = scsi_target_id 
# L = All the LUNs on from this target (since we are not looking for specific vol)

# Build regex of INFINIDAT InfiniBox Target WWPN
_regex=$(printf "0x5742b0f0%06x%d[1-8]" $_serial $_node)
# echo "WWPN RegEx = $_regex"

# Loop over the HBAs and build a list of HCTs that match IBOX Target WWPN
hct_list=""
for hba in $(ls /sys/class/fc_host 2>/dev/null)
do 
    hbaindex=$(echo $hba | cut -c5-)
    #echo "Working on /sys/class/fc_host/$hba"
    cd /sys/class/fc_remote_ports
    tmpfile=$(mktemp --suffix ".rport-$hbaindex.infi")
    find . -iname "rport-${hbaindex}:*" \
        -exec bash -c '_st=$(cat $1/scsi_target_id); _pn=$(cat $1/port_name); echo $_st" "$_pn ' bash {} \; > $tmpfile
    # echo "Output written to $tmpfile"
    while read line
    do
        _target=$(echo $line | cut -f 1 -d " ")
        _wwpn=$(echo $line | cut -f 2 -d " ")
        if [[ "$line" =~ $_regex ]]; then
            # echo "${hct_list}"
            hct="${hbaindex}:0:${_target}"
            # echo "H:C:T = ${hct} Matching IBOX $_serial Node-$_node Target port $_wwpn"
            hct_list+=" ${hct}"
        fi
    done < $tmpfile
done
echo "List of HCTs to delete:"
echo $hct_list

# run through the HCTs and find all the sd devices
# Store list in a temp file for later use if needed.
tmpfile=$(mktemp --suffix ".sd_list.infi")
cd /sys/block
for hct in $hct_list
do
    #echo $hct
    esc_hct=$(echo $hct | sed 's/:/\\:/g')
    #echo $esc_hct
    ls -1d */device/scsi_device/$esc_hct:* | cut -f 1 -d "/"  >> $tmpfile
done
#cat $tmpfile
sd_count=$(wc -l $tmpfile | cut -f 1 -d ' ')
echo "Found $sd_count devices to remove. List stored in $tmpfile. "
read -p "Proceed? (y/N)" yn
case $yn in
    y | Y) echo Proceeding...;;
    n | N | * ) echo Exiting.
                exit;;
esac

counter=1
while read sd; do
    echo -n "[$counter of $sd_count] Offlining and Deleting $sd..."
    multipathd -k"del path $sd"
    echo offline > /sys/block/$sd/device/state
    echo 1 > /sys/block/$sd/device/delete
    #echo Done!
    counter=$((counter + 1))
done < $tmpfile

# At the end, this tool will leave some temp files hanging around...
# Feel free to get rid of them. 
# $TMPDIR/tmp.*.rport-*.infi - list of [ scsi_target_id target_wwpn ] tuples for each HBA port.
# $TMPDIR/tmp.*.sd_list.infi - list of sdX devices to clean up
