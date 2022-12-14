#!/usr/bin/ksh
# Program name: lsseas
# Purpose: display details and informations about Shared Ethernet Adapters 
# Disclaimer: This programm is provided "as is". please contact me if you found bugs. Use it at you own risks
# Last update:  Jan 8, 2022
# Version: 3.0
# License :

# All functions are named f_function.
# All variables are named v_variable.
# All coloring variable are begining with c.

# This script must be run on a Virtual I/O Server only.
# You have to be root to run the script.


echo "Execution date:"
date

echo "VIOS hostname:"
hostname
# Function f_sort_a_numbered_line 
echo "Firmware level: "
lsmcode -A 

# Purpose : Sort a line
echo "Card info: "
lscfg


#Ivan 
echo "FC info: "
lscfg | grep -i fcs | awk {'print $2'} | xargs -i fcstat {} | egrep "REPORT|link|ID|Type:|Speed|Name:"

echo "NPIV map info: "
/usr/ios/cli/ioscli lsmap -all -npiv -fmt : -field 'name' 'Physloc' 'ClntID' 'ClntName' 'FC name' 'FC loc code' 'VFC client name' 'VFC client DRC' 'Status'

echo "vSCSI map info: "
/usr/ios/cli/ioscli lsmap -all -fmt :


#End Ivan
function f_sort_a_numbered_line {
  v_line="$1"
  v_delim="$2"
  echo ${v_line} | tr "${v_delim}" '\n' | sort -un | tr '\n' "${v_delim}"
}

# Function f_norm
# Purpose : Remove trailing and heading space, and \n from a given strings
function f_norm {
  v_string_to_norm="$1"
  echo "${v_string_to_norm}" | sed 's/^[ ]*//;s/[ ]*$//g' | sed 's/\n//g'
}

# Function f_cut_entstat
# Purpose : separate entstat output in multiple file.
# Those files will be named /tmp/enstat.shared_ethernet_adapter.children_adapter.
# You can modify this function if you want to put the files in another directory.
function f_cut_entstat {
  v_ioscli_bin="/usr/ios/cli/ioscli"
  v_parent_adapter=$1
  # Parent adapter is needed, using awk -v to use shell variables in awk
  ${v_ioscli_bin} entstat -all $1 | awk -v parent_adapter="$v_parent_adapter" '{ 
    # All adapters in enstat are separated by "ETHERNET STATISTICS (entx)
    # This is a new adapter if $1 equals "ETHERNET and $2 equals "STATISTICS"
    if ($1 == "ETHERNET" && $2 == "STATISTICS") {
      # Replace open parenthesis by nothing
      gsub("\\(","")
      # Replace closing parenthesis by nothing
      gsub("\\)","")
      adapter=$3
      # New SEA without control channel (only if file exists) .. this part is strange I dont understand the output of entstat some have Control Adapter some not ...
      if ( v_is_new_sea == 1) {
        if( system( "[ -f /tmp/enstat."parent_adapter"."adapter" ] " )  == 0 ) {
          adapter=$3".controladapter"
          v_is_new_sea=0
        }
      }
    }
    else if ( $1 == "Control" && $2 == "Adapter:" ) {
      v_is_new_sea=1
    }
    else {
      # The adapter statitics will be printed in an output file
      print >"/tmp/enstat."parent_adapter"."adapter
    }
  }'
}

# Function f_shared_ethernet_adapter_entstat_info
# Purpose : extract informations from entstat file for Shared Ethernet adapters.
function f_shared_ethernet_adapter_enstat_info {
  v_shared_ethernet_adapter=$1
  v_children_adapter=$2
  v_enstat_file=/tmp/enstat.${v_shared_ethernet_adapter}.${v_children_adapter}
  # Changing in IFS, we do not want space to be the IFS.
  OLD_IFS=$IFS
  IFS="|"
  # Building a ksh table with all informations about the SEA adapter.
  set -A v_table_sea_details $(awk '
    /Number of adapters:/                      { printf $NF"|" }
    /State:/                                   { printf $NF"|" }
    /Number of Times Server became Backup:/    { printf $NF"|" }
    /Number of Times Server became Primary:/   { printf $NF"|" }
    /High Availability Mode:/                  { printf $NF"|" }
    /Priority:/                                { printf $NF"|" }
    # Matching "SEA Flags set boolean for SEA Flags to 1 and go to next line.
    /SEA Flags:/                               { v_a_get_flags=1; next }
    # Matching VLAN Ids, VLAN Ids is the first line after the SEA Flags set boolean for flags to 0, set boolean for VLAN Ids to 1.
    /VLAN Ids :/			       { v_a_get_vlan_ids=1; v_a_get_flags=0 }
    # If matching something begining with < and the boolean for SEA Flags is set to 1 build the record for the flags.
    /\<*/                                      { if (v_a_get_flags == 1) {$1="";v_all_flags=v_all_flags $0} }
    # Real Side Statistics  is the first line after the Vlan Ids set boolean for vlans to 0.
    /Real Side Statistics:/                    { v_a_get_vlan_ids=0 }
    # If matching an interface after Vlan Ids flag is set to 1 build the records for the vlan ids.
    /ent[0-9]*:/                               { if (v_a_get_vlan_ids == 1) {$1=""; v_all_vlan_id=v_all_vlan_id $0} }
    END { printf v_all_vlan_id 
          # Remove all > for SEA Flags
          printf "|"
          gsub(/>/,"",v_all_flags)
          printf v_all_flags
        }
  ' ${v_enstat_file})
  # Replace IFS by OLD_IFS (default one)
  IFS=$OLD_IFS
  return ${v_table_sea_details}
}

# Function f_phy_entstat_info
# Purpose : extract informations from entstat file for Real Adapters.
function f_phy_entstat_info {
  v_shared_ethernet_adapter=$1
  v_physical_adapter=$2
  v_enstat_file=/tmp/enstat.${v_shared_ethernet_adapter}.${v_physical_adapter}
  # Changing in IFS, we do not want space to be the IFS
  OLD_IFS=$IFS
  IFS="|"
  set -A v_table_phy_details $( awk -F ':' '
    # On some systems there is a space before link status ... if someone can explain
    /^Link Status|^Physical Port Link Status/                   { v_speed_selected_found=0 ; print $NF"|"}
    # SRIOV Case
    /Physical Port Speed:/          { v_speed_selected_found=1 ; print "not_applicable|"$NF"|" }
    /Media Speed Selected:/         { v_speed_selected_found=1 ; print $NF }
    # For some adapter you cant select the speed field _Media Speed Selected_ will never be found
    # In this case print _not_applicable_ for selected speed
    # Hard to understand no pipe on the last print so two pipes are printed here
    /Media Speed Running:/          { if (v_speed_selected_found == 0) {
                                                                          print "not_applicable"
                                                                       }
                                      print "|"$NF"|" 
                                    }
    # if 802.3ad 
    /IEEE 802.3ad Port Statistics:/ { v_is_lacp=1 }
    /Actor State:/                  { v_is_actor=1 }
    /Actor System:/                 { print $NF"|"}
    # Partner after Actor
    /Partner State:/                { v_is_partn=1 ; v_is_actor=0 }
    /Partner System:/               { { print $NF"|"} }
    /Partner Port:/                 { { print $NF"|"} } 
    /Synchronization:/              { if (v_is_lacp == 1 && v_is_actor == 1) { print $NF"|" }
                                      if (v_is_lacp == 1 && v_is_partn == 1) { print $NF"|" }
                                    }
  ' ${v_enstat_file})
  IFS=$OLD_IFS
  return ${v_table_phy_details}
}

# Function f_veth_adapter_entstat_info
# Purpose : extract informations from entstat file for Virtual Ethernet Adapters.
function f_veth_adapter_entstat_info {
  v_shared_ethernet_adapter=$1
  v_veth_adapter=$2
  v_enstat_file=/tmp/enstat.${v_shared_ethernet_adapter}.${v_veth_adapter}
  # Changing in IFS, we do not want space to be the IFS
  OLD_IFS=$IFS
  IFS="|"
  set -A v_table_veth_details $(awk '
    /Port VLAN ID:/                       { printf $NF"|" }
    /Switch ID:/                          { v_switch_found=0 ; v_get_vlan_tag_id=0 ; printf $NF"|" }
    # For more than 9 vlan vlans are printed on multiple lines
                                          { if (v_get_vlan_tag_id == 1 ) {
                                              for (i=1;i<=NF;i++) {
                                                v_all_vlan_tag_id=v_all_vlan_tag_id" "$i
                                              }
                                            }
                                          }
    # On some systems there is a space before Switch Mode ... if someone can explain
    /Switch Mode/                         { v_switch_found=1 ; printf $NF"|" }
    /Priority:/                           { printf $2"|"$NF"|" }
    /VLAN Tag IDs:/                       { v_get_vlan_tag_id=1 ; for (i=2;i<=NF;i++) {
                                                                    if ($i ~ /[0-9][0-9]*/ ) {
                                                                      v_all_vlan_tag_id=v_all_vlan_tag_id" "$i 
                                                                    }
                                                                  }
                                          }
    # On some old box there is not vswitch mode the v_switch_found flag is here for that, adding not applicable in this case
    END { if (v_switch_found == 1 ) {
            printf v_all_vlan_tag_id
          }
          else {
            printf "N/A|"v_all_vlan_tag_id
          }
        }
  ' ${v_enstat_file})
  # Replace IFS by OLD_IFS (default one)
  IFS=$OLD_IFS
  return ${v_table_veth_details}
}

# Function f_veth_buffer_entstat_info 
# Purpose : extract information from enstat file about buffers
function f_veth_buffer_entstat_info {
  v_shared_ethernet_adapter=$1
  v_veth_adapter=$2
  v_is_control_adapter=0
  v_enstat_file=/tmp/enstat.${v_shared_ethernet_adapter}.${v_veth_adapter}
  if [[ -e "${v_enstat_file}.controladapter" ]]; then
    v_is_control_adapter=1
  fi
  OLD_IFS=$IFS
  IFS="|"
  # if this is a control adapter columns 4 is control skip it
  if [[ ${v_is_control_adapter} -eq 1 ]]; then
    set -A v_table_veth_buffers $(awk '
      #No Resource Errors is at the end of the line of Max Collision Errors
      /Max Collision Errors/        { print $NF"|" }
      /Hypervisor Send Failures/    { print $NF"|" }
      /Hypervisor Receive Failures/ { print $NF"|" }
      /Receive Buffers/             { v_receive_buffers=1 }
      /Min Buffers/                 {  if (v_receive_buffers == 1 ) {
                                         v_tiny_buffers=v_tiny_buffers","$3
                                         v_smal_buffers=v_smal_buffers","$5
                                         v_medi_buffers=v_medi_buffers","$6
                                         v_larg_buffers=v_larg_buffers","$7
                                         v_huge_buffers=v_huge_buffers","$8
                                      }
                                    }
      /Max Buffers/                 {  if (v_receive_buffers == 1 ) {
                                         v_tiny_buffers=v_tiny_buffers","$3
                                         v_smal_buffers=v_smal_buffers","$5
                                         v_medi_buffers=v_medi_buffers","$6
                                         v_larg_buffers=v_larg_buffers","$7
                                         v_huge_buffers=v_huge_buffers","$8
                                      }
                                    }
      /Max Allocated/               {  if (v_receive_buffers == 1 ) {
                                         v_tiny_buffers=v_tiny_buffers","$3
                                         v_smal_buffers=v_smal_buffers","$5
                                         v_medi_buffers=v_medi_buffers","$6
                                         v_larg_buffers=v_larg_buffers","$7
                                         v_huge_buffers=v_huge_buffers","$8
                                      }
                                    }
      END { printf v_tiny_buffers"|"v_smal_buffers"|"v_medi_buffers"|"v_larg_buffers"|"v_huge_buffers }
      ' ${v_enstat_file})
  else
    set -A v_table_veth_buffers $(awk '
      #No Resource Errors is at the end of the line of Max Collision Errors
      /Max Collision Errors/        { print $NF"|" }
      /Hypervisor Send Failures/    { print $NF"|" }
      /Hypervisor Receive Failures/ { print $NF"|" }
      /Receive Buffers/             { v_receive_buffers=1 }
      /Min Buffers/                 { if (v_receive_buffers == 1 ) {
                                         v_tiny_buffers=v_tiny_buffers","$3
                                         v_smal_buffers=v_smal_buffers","$4
                                         v_medi_buffers=v_medi_buffers","$5
                                         v_larg_buffers=v_larg_buffers","$6
                                         v_huge_buffers=v_huge_buffers","$7
                                      }
                                    } 
      /Max Buffers/                 { if (v_receive_buffers == 1 ) {
                                         v_tiny_buffers=v_tiny_buffers","$3
                                         v_smal_buffers=v_smal_buffers","$4
                                         v_medi_buffers=v_medi_buffers","$5
                                         v_larg_buffers=v_larg_buffers","$6
                                         v_huge_buffers=v_huge_buffers","$7
                                      }
                                    }
      /Max Allocated/               { if (v_receive_buffers == 1 ) {
                                         v_tiny_buffers=v_tiny_buffers","$3
                                         v_smal_buffers=v_smal_buffers","$4
                                         v_medi_buffers=v_medi_buffers","$5
                                         v_larg_buffers=v_larg_buffers","$6
                                         v_huge_buffers=v_huge_buffers","$7
                                      }
                                    }
    END { printf v_tiny_buffers"|"v_smal_buffers"|"v_medi_buffers"|"v_larg_buffers"|"v_huge_buffers }
    ' ${v_enstat_file})
  fi
  # Replace IFS by OLD_IFS (default one)
  IFS=$OLD_IFS
  return ${v_table_veth_buffers} 
}

# Function f_get_slot_hpath
# Purpose : get slot number and what I'm calling hardware path for an adapter
function f_get_slot_hpath {
  v_adapter=$1
  v_hardware_path=$(lscfg -l ${v_adapter} | awk '{print $2}')
  v_slot=$(echo ${v_hardware_path} | cut -d "-" -f 3)
  echo ${v_slot} ${v_hardware_path}
}

# Main
# Purpose display information about Shared Ethernet Adapters
v_color=0
v_buffers=0
v_version="2.0 20200108"

# Usage: lsseas [ options ] 
#   -b, --buffers               print buffers details
#   -c, --color                 color the output for readability
#   -v, --version               print the version of lsseas
v_usage_string="Usage: lsseas [ options ]\n  -b,                   print buffers details\n  -c,                  color the output for readability\n -h,               print the help\n  -v,               print the version\n"

# Get options
while getopts "cvhb" optchar ; do
  case $optchar in
    b) v_buffers=1;;
    c) v_color=1 ;;
    v) echo ${v_version}
       exit 253 ;;
    h) echo ${v_usage_string}
       echo "version : ${v_version}"
       exit 254 ;;
    *) echo "Bad option(s)"
       echo ${v_usage}
       echo ${v_usage_string}
       exit 252 ;;
  esac
done

v_ioscli_bin="/usr/ios/cli/ioscli"
v_sys_id=$(lsattr -El sys0 -a systemid | awk '{print $2}')
v_ioslevel=$(${v_ioscli_bin} ioslevel)
v_hostname=$(hostname)
v_date=$(date)
echo "running lssea on ${v_hostname} | ${v_sys_id} | ioslevel ${v_ioslevel} | ${v_version} | ${v_date}"

# Put a zero here if you do not want colors
if tty -s ; then
  esc=`printf "\033"`
  extd="${esc}[1m"
  w="${esc}[1;30m"         #gray
  r="${esc}[1;31m"         #red
  g="${esc}[1;32m"         #green
  y="${esc}[1;33m"         #yellow
  b="${esc}[1;34m"         #blue
  m="${esc}[1;35m"         #magenta/pink
  c="${esc}[1;36m"         #cyan
  i="${esc}[7m"            #inverted
  n=`printf "${esc}[m\017"` #normal
  # Did not find better to disable color ... any ideas ?
  if [[ ${v_color} -eq 0 ]]; then
    w=${n}
    r=${n}
    g=${n}
    y=${n}
    b=${n}
    c=${n}
    m=${n}
    i=${n}
  fi
fi

# For coloring debugging purpose
#all colors uncomment to check
#printf "%-5s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" "$w gray $n" "$r red $n" "$g green $n" "$y yellow $n" "$b blue $n" "$m magenta $n" "$c cyan $n" "$i inverted $n"
#legend
#echo "$r fail $n"
#echo "$g ok $n"
#echo "$y warning $n"

#Ivan shows mtu_bypass
v_en=$(${v_ioscli_bin} lsdev | grep -i ^en | grep -v ent | grep Available | awk {'print $1'} )
for v_en in ${v_en}; do
       echo "Virtual ethernet adapters are : ${v_en}"
       lsattr -El ${v_en} | egrep "netaddr|mtu_bypass" | grep -v netaddr6 | awk {'print $1,":",$2'}
done

# Get all Shared Ethernet Adapters 
v_seas=$(${v_ioscli_bin} lsdev -virtual -field name description | awk '$2 == "Shared" && $3 == "Ethernet" && $4 == "Adapter" {print $1}')

for v_sea in ${v_seas} ; do
  # Get enstat for all Shared Ethernet Adapters
  f_cut_entstat ${v_sea}
  f_shared_ethernet_adapter_enstat_info ${v_sea} ${v_sea}
  # Here are all SEA possible states 
  # INIT:     The Shared Ethernet Adapter failover protocol has just been initiated.
  # PRIMARY:  The Shared Ethernet Adapter is actively connecting traffic between the VLANs to the network.
  # BACKUP:   The Shared Ethernet Adapter is idle and not connecting traffic between the VLANs and the network.
  # RECOVERY: The primary Shared Ethernet Adapter recovered from a failure and is ready to be active again.
  # NOTIFY:   The backup Shared Ethernet Adapter detected that the primary Shared Ethernet Adapter recovered from a failure and that it needs to become idle again.
  # LIMBO:    One of the following situations is true: the physical network is not operational, the physical network's state is unknown, the Shared Ethernet Adapter cannot ping the specified remote host.
  #possible states in entstat output Disabled,Sharing,Auto,Standby
  #color state Sharing
  if [[ ${v_table_sea_details[4]} == "Sharing" || ${v_table_sea_details[4]} == "Auto" ]]; then
    # Sharing case
    if [[ ${v_table_sea_details[4]} == "Sharing" ]]; then
      case ${v_table_sea_details[1]} in
        "PRIMARY"|"BACKUP"|"LIMBO") ssc=$r ;;
        "PRIMARY_SH"|"BACKUP_SH") ssc=$g ;;
        "RECOVERY"|"NOTIFY"|"INIT") scc=$y ;;
        *) scc=$n ;;
      esac
    # Auto case
    elif [[ ${v_table_sea_details[4]} == "Auto" ]];then
      case ${v_table_sea_details[1]} in
        "LIMBO") ssc=$r ;;
        "PRIMARY") ssc=$g ;;
        "BACKUP") ssc=$y ;;
        "RECOVERY"|"NOTIFY"|"INIT") scc=$y ;;
        *) scc=$n ;;
      esac
    fi 
    v_is_not_failover=0
  else
    v_is_not_failover=1
  fi
    
  # SEA failover case.
  if [[ ${v_is_not_failover} -eq 0 ]]; then 
    v_sorted_vlans=$(f_sort_a_numbered_line "${v_table_sea_details[6]}" ' ')
    echo "+------------------------------------------------------+"
    echo "SEA : $b ${v_sea} $n"
    echo "ha_mode              : ${v_table_sea_details[4]}"
    echo "state                : $ssc${v_table_sea_details[1]}$n"
    echo "number of adapters   : ${v_table_sea_details[0]}"
    echo "become backup/primary: ${v_table_sea_details[2]}/${v_table_sea_details[3]}"
    echo "priority             : ${v_table_sea_details[5]}"
    echo "vlans                : ${v_sorted_vlans}"
    echo "flags                : ${v_table_sea_details[7]}"
    echo "+------------------------------------------------------+"
  # SEA no failover case.
  elif [[ ${v_is_not_failover} -eq 1 ]]; then
    v_sorted_vlans=$(f_sort_a_numbered_line "${v_table_sea_details[6]}" ' ')
    echo "+------------------------------------------------------+"
    echo "SEA : $b ${v_sea} $n"
    echo "number of adapters   : ${v_table_sea_details[0]}"
    echo "state                : ${v_table_sea_details[1]}"
    echo "vlans                : ${v_sorted_vlans}"
    echo "flags                : ${v_table_sea_details[2]}"
    echo "+------------------------------------------------------+"
  fi
  # Get all necessary attributes real_adapter,virt_adapters,pvid_adapter,ctl_chan,ha_mode,largesend,large_receive,accounting,thread
  set -A v_table_sea_attr $(${v_ioscli_bin} lsdev -dev ${v_sea} -attr real_adapter,virt_adapters,pvid_adapter,ctl_chan,ha_mode,largesend,large_receive,accounting,thread)
  # REAL ADAPTERS and ETHERCHANNEL type.
  # EtherChannel / IEEE 802.3ad Link Aggregation.
  if [[ $(${v_ioscli_bin} lsdev -dev ${v_table_sea_attr[1]} -field description | tail -1 | awk '{print $1}') == "EtherChannel" ]]; then
    v_real_adapter_type="EC"
    set -A v_table_ec_attr  $(${v_ioscli_bin} lsdev -dev ${v_table_sea_attr[1]} -attr adapter_names,hash_mode,mode,use_jumbo_frame)
    v_list_ec_adapter=$(echo "${v_table_ec_attr[1]}" | awk -F ',' '{for (i=1; i<=NF; i++) print $i}')
    echo "$i ETHERCHANNEL $n"
    printf "%-7s %-30s %-10s %-15s %-10s\n" "adapter" "phys_adapters" "mode" "hash_mode" "jumbo"
    printf "%-7s %-30s %-10s %-15s %-10s\n" "-------" "-------------" "----" "---------" "-----"
    printf "%-7s %-30s %-10s %-15s %-10s\n" ${v_table_sea_attr[1]} ${v_table_ec_attr[1]} ${v_table_ec_attr[3]} ${v_table_ec_attr[2]} ${v_table_ec_attr[4]}
    echo "$i REAL ADAPTERS $n"
    printf "%-7s %-4s %-30s %-4s %-21s %-21s %-17s %-11s %-17s %-12s %-11s\n" "adapter" "slot" "hardware_path" "link" "selected_speed" "running_speed" "actor_system" "actor_sync" "partner_system" "partner_port" "partner_sync"
    printf "%-7s %-4s %-30s %-4s %-21s %-21s %-17s %-11s %-17s %-12s %-11s\n" "-------" "----" "-------------" "----" "--------------" "-------------" "------------" "----------" "--------------" "------------" "------------"
    for v_a_ec_adapter in ${v_list_ec_adapter} ; do
      f_phy_entstat_info ${v_sea} ${v_a_ec_adapter}
      t_phy_slot_hpath=$(f_get_slot_hpath  ${v_a_ec_adapter})
      # Color case link.
      case "$(f_norm ${v_table_phy_details[0]})" in 
        "Up") cl=$g;;
        *)    cl=$r;;
      esac
      # Color case synchonisation.
      case "$(f_norm ${v_table_phy_details[7]})" in
        "IN_SYNC") cps=$g;;
        *)         cps=$r;;
      esac
      case "$(f_norm ${v_table_phy_details[4]})" in
        "IN_SYNC") cas=$g;;
        *)         cas=$r;;
      esac
      # Color case speed running.
      case $(f_norm "${v_table_phy_details[2]}" | tr -s ' ' '_') in
        "Unknown") crs=$r;;
        *)         crs=$g;;
      esac

      printf "%-7s %-4s %-30s $cl%-4s$n %-21s $crs%-21s$n %-17s $cas%-11s$n %-17s %-12s $cps%-11s$n\n" "${v_a_ec_adapter}" $(echo ${t_phy_slot_hpath} | awk '{print $1}') $(echo ${t_phy_slot_hpath} | awk '{print $2}') "$(f_norm "${v_table_phy_details[0]}")" $(f_norm "${v_table_phy_details[1]}" | tr -s ' ' '_' ) $(f_norm "${v_table_phy_details[2]}" | tr -s ' ' '_') $(f_norm "${v_table_phy_details[3]}") $(f_norm "${v_table_phy_details[4]}") $(f_norm "${v_table_phy_details[5]}") $(f_norm "${v_table_phy_details[6]}") "$(f_norm ${v_table_phy_details[7]})"
    done
  # Not an etherchannel.
  else
    echo "$i REAL ADAPTERS $n"
    f_phy_entstat_info ${v_sea} ${v_table_sea_attr[1]}
    t_phy_slot_hpath=$(f_get_slot_hpath  ${v_table_sea_attr[1]})
    v_a_ec_adapter=${v_table_sea_attr[1]}
    # Color case link.
    case "$(f_norm ${v_table_phy_details[0]})" in 
      "Up") cl=$g;;
      *)    cl=$r;;
    esac
    # Color case speed running.
    case $(f_norm "${v_table_phy_details[2]}" | tr -s ' ' '_') in
      "Unknown") crs=$r;;
      *)         crs=$g;;
    esac
    printf "%-7s %-4s %-30s %-4s %-21s %-21s\n" "adapter" "slot" "hardware_path" "link" "selected_speed" "running_speed" 
    printf "%-7s %-4s %-30s %-4s %-21s %-21s\n" "-------" "----" "-------------" "----" "--------------" "-------------"
    printf "%-7s %-4s %-30s $cl%-4s$n %-21s $crs%-21s$n %-17s $cas%-11s$n %-17s %-12s $cps%-11s$n\n" "${v_a_ec_adapter}" $(echo ${t_phy_slot_hpath} | awk '{print $1}') $(echo ${t_phy_slot_hpath} | awk '{print $2}') "$(f_norm "${v_table_phy_details[0]}")" $(f_norm "${v_table_phy_details[1]}" | tr -s ' ' '_' ) $(f_norm "${v_table_phy_details[2]}" | tr -s ' ' '_')
  fi
  v_list_veth_adapter=$(echo "${v_table_sea_attr[2]}" | awk -F ',' '{for (i=1; i<=NF; i++) print $i}')
  # VIRTUAL ADAPTERS type.
  echo "$i VIRTUAL ADAPTERS $n"
  printf "%-7s %-4s %-30s %-8s %-6s %-13s %-15s %-7s %-14s\n" "adapter" "slot" "hardware_path" "priority" "active" "port_vlan_id" "vswitch" "mode" "vlan_tags_ids"
  printf "%-7s %-4s %-30s %-8s %-6s %-13s %-15s %-7s %-14s\n" "-------" "----" "-------------" "--------" "------" "------------" "-------" "----" "-------------"

  for v_a_veth in ${v_list_veth_adapter} ; do
    f_veth_adapter_entstat_info ${v_sea} ${v_a_veth}
    t_veth_slot_hpath=$(f_get_slot_hpath ${v_a_veth})
    # color case active
    case $(f_norm ${v_table_veth_details[1]}) in
      "False") ca=$w;;
      "True")  ca=$b;;
    esac
    v_vlan_count=$(echo $(f_sort_a_numbered_line $(echo ${v_table_veth_details[5]} | tr -s ' ' ',')))
    printf "%-7s %-4s %-30s %-8s $ca%-6s$n %-13s %-15s %-7s %-${#v_vlan_count}s\n" "${v_a_veth}" $(echo ${t_veth_slot_hpath} | awk '{print $1}')  $(echo ${t_veth_slot_hpath} | awk '{print $2}') $(f_norm ${v_table_veth_details[0]}) $(f_norm ${v_table_veth_details[1]}) $(f_norm ${v_table_veth_details[2]}) $(f_norm ${v_table_veth_details[3]}) $(f_norm ${v_table_veth_details[4]}) $(f_sort_a_numbered_line $(echo ${v_table_veth_details[5]} | tr -s ' ' ',') ' ' )
  done
  # CONTROL CHANNEL type. 
  v_ctl_chan_exists=$(${v_ioscli_bin} lsdev -dev ${v_sea} -attr ctl_chan} | tail -1 | awk '$1 ~ "^ent" {print "exists"}' )
  if [[ "${v_ctl_chan_exists}" != "exists" ]]; then
    echo "$i NO CONTROL CHANNEL $n"
    # SEA Sharing or Auto without control channel
    if [[ ${v_table_sea_details[4]} == "Sharing" || ${v_table_sea_details[4]} == "Auto" ]]; then
      v_control_channel_pvid=$(grep "Control Channel PVID:" /tmp/enstat.${v_sea}.${v_sea} | awk '{print $NF}')
      echo "ctl_chan port_vlan_id: ${v_control_channel_pvid}"
    fi
  else 
    echo "$i CONTROL CHANNEL $n"
    f_veth_adapter_entstat_info ${v_sea} ${v_table_sea_attr[4]}
    t_ctl_slot_hpath=$(f_get_slot_hpath ${v_table_sea_attr[4]})
    printf "%-7s %-4s %-30s %-13s %-15s\n" "adapter" "slot" "hardware_path" "port_vlan_id" "vswitch"
    printf "%-7s %-4s %-30s %-13s %-15s\n" "-------" "----" "-------------" "------------" "-------"
    printf "%-7s %-4s %-30s %-13s %-15s\n" ${v_table_sea_attr[4]} $(echo ${t_ctl_slot_hpath} | awk '{print $1}') $(echo ${t_ctl_slot_hpath} | awk '{print $2}') $(f_norm ${v_table_veth_details[0]}) $(f_norm ${v_table_veth_details[1]})
  fi
  if [[ ${v_buffers} -eq 1 ]]; then
    v_list_buff_adapter=$(echo "${v_table_sea_attr[2]}" | awk -F ',' '{for (i=1; i<=NF; i++) print $i}')
    echo "$i BUFFERS $n"
    printf "%-7s %-4s %-30s %-19s %-17s %-17s %-60s\n" "adapter" "slot" "hardware_path" "no_resources_errors" "hyp_recv_failures" "hyp_send_failures" "tiny,small,medium,large,huge (min,max,alloc)"
    printf "%-7s %-4s %-30s %-19s %-17s %-17s %-60s\n" "-------" "----" "-------------" "-------------------" "-----------------" "-----------------" "--------------------------------------------"
    for v_a_buff in ${v_list_buff_adapter} ; do
      f_veth_buffer_entstat_info ${v_sea} ${v_a_buff}
      b_veth_slot_hpath=$(f_get_slot_hpath ${v_a_buff})
      v_smal=$(f_norm ${v_table_veth_buffers[3]} | sed "s/^.\(.*\)/\1/" )
      v_tiny=$(f_norm ${v_table_veth_buffers[4]} | sed "s/^.\(.*\)/\1/" )
      v_medi=$(f_norm ${v_table_veth_buffers[5]} | sed "s/^.\(.*\)/\1/" )
      v_larg=$(f_norm ${v_table_veth_buffers[6]} | sed "s/^.\(.*\)/\1/" )
      v_huge=$(f_norm ${v_table_veth_buffers[7]} | sed "s/^.\(.*\)/\1/" )
      v_smal_min=$(echo ${v_smal} | cut -d ',' -f 1)
      v_smal_max=$(echo ${v_smal} | cut -d ',' -f 2)
      v_smal_alo=$(echo ${v_smal} | cut -d ',' -f 3)
      v_tiny_min=$(echo ${v_tiny} | cut -d ',' -f 1)
      v_tiny_max=$(echo ${v_tiny} | cut -d ',' -f 2)
      v_tiny_alo=$(echo ${v_tiny} | cut -d ',' -f 3)
      v_medi_min=$(echo ${v_medi} | cut -d ',' -f 1)
      v_medi_max=$(echo ${v_medi} | cut -d ',' -f 2)
      v_medi_alo=$(echo ${v_medi} | cut -d ',' -f 3)
      v_larg_min=$(echo ${v_larg} | cut -d ',' -f 1)
      v_larg_max=$(echo ${v_larg} | cut -d ',' -f 2)
      v_larg_alo=$(echo ${v_larg} | cut -d ',' -f 3)
      v_huge_min=$(echo ${v_larg} | cut -d ',' -f 1)
      v_huge_max=$(echo ${v_larg} | cut -d ',' -f 2)
      v_huge_alo=$(echo ${v_larg} | cut -d ',' -f 3)
      if [[ "${v_smal_max}" == "${v_smal_alo}" ]] ; then v_p_smal="${v_smal_min},$r${v_smal_max}$n,$y${v_smal_alo}$n" ; else v_p_smal="${v_smal_min},$g${v_smal_max}$n,$g${v_smal_alo}$n" ; fi
      if [[ "${v_tiny_max}" == "${v_tiny_alo}" ]] ; then v_p_tiny="${v_tiny_min},$r${v_tiny_max}$n,$y${v_tiny_alo}$n" ; else v_p_tiny="${v_tiny_min},$g${v_tiny_max}$n,$g${v_tiny_alo}$n" ; fi
      if [[ "${v_medi_max}" == "${v_medi_alo}" ]] ; then v_p_medi="${v_medi_min},$r${v_medi_max}$n,$y${v_medi_alo}$n" ; else v_p_medi="${v_medi_min},$g${v_medi_max}$n,$g${v_medi_alo}$n" ; fi
      if [[ "${v_larg_max}" == "${v_larg_alo}" ]] ; then v_p_larg="${v_larg_min},$r${v_larg_max}$n,$y${v_larg_alo}$n" ; else v_p_larg="${v_larg_min},$g${v_larg_max}$n,$g${v_larg_alo}$n" ; fi
      if [[ "${v_huge_max}" == "${v_huge_alo}" ]] ; then v_p_huge="${v_huge_min},$r${v_huge_max}$n,$y${v_huge_alo}$n" ; else v_p_huge="${v_huge_min},$g${v_huge_max}$n,$g${v_huge_alo}$n" ; fi
      printf "%-7s %-4s %-30s %-19s %-17s %-17s %-${#v_p_smal}s %-${#v_p_tiny}s %-${#v_p_medi}s %-${#v_p_larg}s %-${#v_p_huge}s\n" "${v_a_buff}" $(echo ${b_veth_slot_hpath} | awk '{print $1}')  $(echo ${b_veth_slot_hpath} | awk '{print $2}') $(f_norm ${v_table_veth_buffers[0]}) $(f_norm ${v_table_veth_buffers[1]}) $(f_norm ${v_table_veth_buffers[2]}) "${v_p_smal}" "${v_p_tiny}" "${v_p_medi}" "${v_p_larg}" "${v_p_huge}"
    done
  fi
done
