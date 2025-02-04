# unset_interactive_vars: Unsets all variables related to the test console.
unset_interactive_vars() {
  unset LOOKUP_IFACE LIMIT_SUBNET SKIP_SERVICE EXPECT_PEERS \
    SETUP_ZFS ZFS_FILTER ZFS_WIPE \
    SETUP_CEPH CEPH_WARNING CEPH_FILTER CEPH_WIPE \
    SETUP_OVN OVN_WARNING OVN_FILTER IPV4_SUBNET IPV4_START IPV4_END IPV6_SUBNET
}

# microcloud_interactive: outputs text that can be passed to `TEST_CONSOLE=1 microcloud init`
# to simulate terminal input to the interactive CLI.
# The lines that are output are based on the values passed to the listed environment variables.
# Any unset variables will be omitted.
microcloud_interactive() {
  LOOKUP_IFACE=${LOOKUP_IFACE:-} # filter string for the lookup interface table.
  LIMIT_SUBNET=${LIMIT_SUBNET:-} # (yes/no) input for limiting lookup of systems to the above subnet.
  SKIP_SERVICE=${SKIP_SERVICE:-} # (yes/no) input to skip any missing services. Should be unset if all services are installed.
  EXPECT_PEERS=${EXPECT_PEERS:-} # wait for this number of systems to be available to join the cluster.
  SETUP_ZFS=${SETUP_ZFS:-}       # (yes/no) input for initiating ZFS storage pool setup.
  ZFS_FILTER=${ZFS_FILTER:-}     # filter string for ZFS disks.
  ZFS_WIPE=${ZFS_WIPE:-}         # (yes/no) to wipe all disks.
  SETUP_CEPH=${SETUP_CEPH:-}     # (yes/no) input for initiating CEPH storage pool setup.
  CEPH_WARNING=${CEPH_WARNING:-} # (yes/no) input for warning about eligible disk detection.
  CEPH_FILTER=${CEPH_FILTER:-}   # filter string for CEPH disks.
  CEPH_WIPE=${CEPH_WIPE:-}       # (yes/no) to wipe all disks.
  SETUP_OVN=${SETUP_OVN:-}       # (yes/no) input for initiating OVN network setup.
  OVN_WARNING=${OVN_WARNING:-}   # (yes/no) input for warning about eligible interface detection.
  OVN_FILTER=${OVN_FILTER:-}     # filter string for OVN interfaces.
  IPV4_SUBNET=${IPV4_SUBNET:-}   # OVN ipv4 gateway subnet.
  IPV4_START=${IPV4_START:-}     # OVN ipv4 range start.
  IPV4_END=${IPV4_END:-}         # OVN ipv4 range end.
  IPV6_SUBNET=${IPV6_SUBNET:-}   # OVN ipv6 range.

  setup=$(cat << EOF
${LOOKUP_IFACE}                                         # filter the lookup interface
$([ -n "${LOOKUP_IFACE}" ] && printf "select")          # select the interface
$([ -n "${LOOKUP_IFACE}" ] && printf -- "---")
${LIMIT_SUBNET}                                             # limit lookup subnet (yes/no)
$([ "yes" = "${SKIP_SERVICE}" ] && printf "%s" "${SKIP_SERVICE}")  # skip MicroOVN/MicroCeph (yes/no)
expect ${EXPECT_PEERS}                                      # wait until the systems show up
select-all                                                  # select all the systems
---
EOF
)

if [ -n "${SETUP_ZFS}" ]; then
  setup=$(cat << EOF
${setup}
${SETUP_ZFS}                                            # add local disks (yes/no)
$([ "${SETUP_ZFS}" = "yes" ] && printf "wait 300ms")    # wait for the table to populate
${ZFS_FILTER}                                           # filter zfs disks
$([ "${SETUP_ZFS}" = "yes" ] && printf "select-all")    # select all disk matching the filter
$([ "${SETUP_ZFS}" = "yes" ] && printf -- "---" )
$([ "${ZFS_WIPE}"  = "yes" ] && printf "select-all")    # wipe all disks
$([ "${SETUP_ZFS}" = "yes" ] && printf -- "---")
EOF
)
fi

if [ -n "${SETUP_CEPH}" ]; then
  setup=$(cat << EOF
${setup}
${SETUP_CEPH}                                           # add remote disks (yes/no)
${CEPH_WARNING}                                         # continue with some peers missing disks? (yes/no)
$([ "${SETUP_CEPH}" = "yes" ] && printf "wait 300ms")   # wait for the table to populate
${CEPH_FILTER}                                          # filter ceph disks
$([ "${SETUP_CEPH}" = "yes" ] && printf "select-all")   # select all disk matching the filter
$([ "${SETUP_CEPH}" = "yes" ] && printf -- "---")
$([ "${CEPH_WIPE}"  = "yes" ] && printf "select-all")   # wipe all disks
$([ "${SETUP_CEPH}" = "yes" ] && printf -- "---")
EOF
)
fi


if [ -n "${SETUP_OVN}" ]; then
  setup=$(cat << EOF
${setup}
${SETUP_OVN}                                           # agree to setup OVN
${OVN_WARNING}                                         # continue with some peers missing an interface? (yes/no)
$([ "${SETUP_OVN}" = "yes" ] && printf "wait 300ms")   # wait for the table to populate
${OVN_FILTER}                                          # filter interfaces
$([ "${SETUP_OVN}" = "yes" ] && printf "select-all")   # select all interfaces matching the filter
$([ "${SETUP_OVN}" = "yes" ] && printf -- "---")
${IPV4_SUBNET}                                         # setup ipv4/ipv6 gateways and ranges
${IPV4_START}
${IPV4_END}
${IPV6_SUBNET}
EOF
)
fi

# clear comments and empty lines.
echo "${setup}" | sed -e '/^\s*#/d' -e '/^\s*$/d'
}


# set_remote: Adds and switches to the remote for the MicroCloud node with the given name.
set_remote() {
  remote="${1}"
  name="${2}"

  lxc remote switch local

  addr="$(lxc exec "${name}" -- lxc config get cluster.https_address)"

  if lxc remote list -f csv | cut -d',' -f1 | grep -qwF "${remote}" ; then
    lxc remote remove "${remote}"
  fi

  lxc exec "${name}" -- lxc config set core.trust_password test

  # Suppress the confirmation as it's noisy.
  lxc remote add "${remote}" "https://${addr}" --password "test" --accept-certificate > /dev/null 2>&1
  lxc remote switch "${remote}"
}

# validate_system_microceph: Ensures the node with the given name has correctly set up MicroCeph with the given resources.
validate_system_microceph() {
    name=${1}
    shift 1

    disks="${*}"

    echo "==> ${name} Validating MicroCeph. Using disks: {${disks}}"

    lxc remote switch local
    lxc exec "${name}" -- sh -ceu "
      microceph cluster list | grep -q ${name}

      count=0
      for disk in ${disks} ; do
        ceph_disks=\$(microceph cluster sql \"select name, path from disks join internal_cluster_members on internal_cluster_members.id = disks.member_id where path like '%\${disk}' and name = '${name}'\")
        echo \"\${ceph_disks}\" | grep -q \"/dev/disk/by-id/scsi-.*_lxd_\${disk}\"
        count=\$((count + 1))
      done

     query='{\"query\": \"select count(*) from disks join internal_cluster_members on internal_cluster_members.id = disks.member_id where internal_cluster_members.name = \\\"${name}\\\"\"}'
     count_disks=\$(curl --unix-socket /var/snap/microceph/common/state/control.socket ./cluster/internal/sql -X POST -d \"\${query}\" -s)
     echo \"\${count_disks}\" | jq '.status_code' | grep -q 200
     echo \"\${count_disks}\" | jq '.metadata .Results[0] .rows[0][0]' | grep -q \${count}
    "
}

# validate_system_microovn: Ensures the node with the given name has correctly set up MicroOVN with the given resources.
validate_system_microovn() {
    name=${1}

    echo "==> ${name} Validating MicroOVN"

    lxc remote switch local
    lxc exec "${name}" -- sh -ceu "microovn cluster list | grep -q ${name}"
}

# validate_system_lxd_zfs: Ensures the node with the given name has the given disk set up for ZFS storage.
validate_system_lxd_zfs() {
  name=${1}
  local_disk=${2:-}
  echo "    ${name} Validating ZFS storage"
  lxc config get "storage.backups_volume" --target "${name}" | grep -q '^local/backups$'
  lxc config get "storage.images_volume" --target "${name}" | grep -q '^local/images$'

  cfg=$(lxc storage show local)
  echo "${cfg}" | grep -q "config: {}"
  echo "${cfg}" | grep -q "status: Created"

  cfg=$(lxc storage show local --target "${name}")
  echo "${cfg}" | grep -q "source: local"
  echo "${cfg}" | grep -q "volatile.initial_source: .*${local_disk}"
  echo "${cfg}" | grep -q "zfs.pool_name: local"
  echo "${cfg}" | grep -q "driver: zfs"
  echo "${cfg}" | grep -q "status: Created"
  echo "${cfg}" | grep -q "/1.0/storage-pools/local/volumes/custom/backups?target=${name}"
  echo "${cfg}" | grep -q "/1.0/storage-pools/local/volumes/custom/images?target=${name}"
}

# validate_system_lxd_ceph: Ensures the node with the given name has ceph storage set up.
validate_system_lxd_ceph() {
  name=${1}
  remote_disks=${2:-0}
  echo "    ${name} Validating Ceph storage"
  cfg=$(lxc storage show remote)
  echo "${cfg}" | grep -q "ceph.cluster_name: ceph"
  echo "${cfg}" | grep -q "ceph.osd.pg_num: \"32\""
  echo "${cfg}" | grep -q "ceph.osd.pool_name: lxd_remote"
  echo "${cfg}" | grep -q "ceph.rbd.du: \"false\""
  echo "${cfg}" | grep -q "ceph.rbd.features: layering,striping,exclusive-lock,object-map,fast-diff,deep-flatten"
  echo "${cfg}" | grep -q "ceph.user.name: admin"
  echo "${cfg}" | grep -q "volatile.pool.pristine: \"true\""
  echo "${cfg}" | grep -q "status: Created"
  echo "${cfg}" | grep -q "driver: ceph"

  cfg=$(lxc storage show remote --target "${name}")
  echo "${cfg}" | grep -q "source: lxd_remote"
  echo "${cfg}" | grep -q "status: Created"
}

# validate_system_lxd_ovn: Ensures the node with the given name and config has ovn network set up correctly.
validate_system_lxd_ovn() {
  name=${1}
  num_peers=${2}
  ovn_interface=${3:-}
  ipv4_gateway=${4:-}
  ipv4_ranges=${5:-}
  ipv6_gateway=${6:-}

  echo "    ${name} Validating OVN network"
  addr=$(lxc exec local:"${name}" -- lxc config get cluster.https_address)

  num_conns=3
  if [ "${num_peers}" -lt "${num_conns}" ]; then
    num_conns="${num_peers}"
  fi

  lxc config get "network.ovn.northbound_connection" --target "${name}" | sed -e 's/,/\n/g' | wc -l | grep -q "${num_conns}"

  # Make sure there's no empty addresses.
  ! lxc config get "network.ovn.northbound_connection" --target "${name}" | sed -e 's/,/\n/g' | grep -q '^ssl:$' || false
  ! lxc config get "network.ovn.northbound_connection" --target "${name}" | sed -e 's/,/\n/g' | grep -q '^ssl::' || false

  cfg=$(lxc network show UPLINK)
  echo "${cfg}" | grep -q "status: Created"
  echo "${cfg}" | grep -q "type: physical"

  if [ -n "${ipv4_gateway}" ] ; then
    echo "${cfg}" | grep -q "ipv4.gateway: ${ipv4_gateway}"
  fi

  if [ -n "${ipv4_ranges}" ] ; then
    echo "${cfg}" | grep -q "ipv4.ovn.ranges: ${ipv4_ranges}"
  fi

  if [ -n "${ipv6_gateway}" ] ; then
    echo "${cfg}" | grep -q "ipv6.gateway: ${ipv6_gateway}"
  fi

  lxc network show UPLINK --target "${name}" | grep -q "parent: ${ovn_interface}"

  cfg=$(lxc network show default)
  echo "${cfg}" | grep -q "status: Created"
  echo "${cfg}" | grep -q "type: ovn"
  echo "${cfg}" | grep -q 'network: UPLINK'
}

# validate_system_lxd_fan: Ensures the node with the given name has the Ubuntu FAN network set up correctly.
validate_system_lxd_fan() {
  name=${1}
  echo "    ${name} Validating FAN network"
  cfg=$(lxc network show lxdfan0)
  echo "${cfg}" | grep -q "status: Created"
  echo "${cfg}" | grep -q "type: bridge"
  echo "${cfg}" | grep -q 'bridge.mode: fan'
}

# validate_system_lxd: Ensures the node with the given name has correctly set up LXD with the given resources.
validate_system_lxd() {
    name=${1}
    num_peers=${2}
    local_disk=${3:-}
    remote_disks=${4:-0}
    ovn_interface=${5:-}
    ipv4_gateway=${6:-}
    ipv4_ranges=${7:-}
    ipv6_gateway=${8:-}

    echo "==> ${name} Validating LXD with ${num_peers} peers"
    echo "    ${name} Local Disk: {${local_disk}}, Remote Disks: {${remote_disks}}, OVN Iface: {${ovn_interface}}"
    echo "    ${name} IPv4 Gateway: {${ipv4_gateway}}, IPv4 Ranges: {${ipv4_ranges}}"
    echo "    ${name} IPv6 Gateway: {${ipv6_gateway}}"

    lxc remote switch local

    # Call lxc list once to supress the welcome message.
    lxc exec "${name}" -- lxc list > /dev/null 2>&1

    # Add the peer as a remote.
    set_remote microcloud-test "${name}"

    # Ensure we are clustered and online.
    lxc cluster list -f csv | sed -e 's/,\?database-leader,\?//' | cut -d',' -f1,7 | grep  -q "${name}"
    lxc cluster list -f csv | wc -l | grep -q "${num_peers}"

    has_microovn=0
    has_microceph=0

    # These look like errors so suppress them to avoid confusion.
    {
      { lxc exec local:"${name}" -- microovn cluster list > /dev/null && has_microovn=1; } || true
      { lxc exec local:"${name}" -- microceph cluster list > /dev/null && has_microceph=1; } || true
    } > /dev/null 2>&1

    if [ "${has_microovn}" = 1 ] && [ -n "${ovn_interface}" ] ; then
      validate_system_lxd_ovn "${name}" "${num_peers}" "${ovn_interface}" "${ipv4_gateway}" "${ipv4_ranges}" "${ipv6_gateway}"
    else
      validate_system_lxd_fan "${name}"
    fi

    if [ -n "${local_disk}" ]; then
      validate_system_lxd_zfs "${name}" "${local_disk}"
    fi

    if [ "${has_microceph}" = 1 ] && [ "${remote_disks}" -gt 0 ] ; then
      validate_system_lxd_ceph "${name}" "${remote_disks}"
    fi

    echo "    ${name} Validating Profiles"
    if [ "${has_microceph}" = 1 ] && [ "${remote_disks}" -gt 0 ] ; then
       lxc profile device get default root pool | grep -q "remote"
    elif [ -n "${local_disk}" ] ; then
       lxc profile device get default root pool | grep -q "local"
    else
       ! lxc profile device list default | grep -q root || false
    fi

    if [ "${has_microovn}" = 1 ] && [ -n "${ovn_interface}" ] ; then
       lxc profile device get default eth0 network | grep -q "default"
    else
       lxc profile device get default eth0 network | grep -q "lxdfan0"
    fi

    lxc remote switch local
    lxc remote remove microcloud-test

    echo "==> ${name} Validated LXD"
}


# reset_snaps: Clears the state for existing snaps. This is a faster alternative to purging and re-installing snaps.
reset_snaps() {
  name="${1}"

  (
    set -eu
    if [ "${SKIP_SETUP_LOG}" = 1 ]; then
      exec > /dev/null
    fi

    # These are set to always pass in case the snaps are already disabled.
    echo "Disabling LXD and MicroCloud for ${name}"
    lxc exec "${name}" -- sh -c "
      if pidof -q lxd ; then
        kill -9 \$(pidof lxd)
      fi

      snap disable lxd > /dev/null 2>&1 || true

      if pidof -q microcloud ; then
        kill -9 \$(pidof microcloud)
      fi

      snap disable microcloud > /dev/null 2>&1 || true

      systemctl stop snap.lxd.daemon snap.lxd.daemon.unix.socket > /dev/null 2>&1 || true
      if ps -u lxd -o pid= ; then
        kill -9 \$(ps -u lxd -o pid=)
      fi

      rm -rf /var/snap/lxd/common/lxd
      rm -rf /var/snap/microcloud/*/*
    "

    echo "Resetting MicroCeph for ${name}"
    lxc exec "${name}" -- sh -c "
      if snap list | grep -q microceph ; then
        snap disable microceph > /dev/null 2>&1 || true

        # Kill any remaining processes.
        if ps -e -o '%p %a' | grep -v grep | grep -qe 'ceph-' -qe 'microceph' ; then
          kill -9 \$(ps -e -o '%p %a' | grep -e 'ceph-' -e 'microceph' | grep -v grep | awk '{print \$1}') || true
        fi

        # Remove modules to get rid of any kernel owned processes.
        modprobe -r rbd ceph

        # Wipe the snap state so we can start fresh.
        rm -rf /var/snap/microceph/*/*
        snap enable microceph > /dev/null 2>&1 || true

        # microceph.osd requires this directory to exist but doesn't create it after install.
        # OSDs won't show up and ceph will freeze creating volumes without it, so make it here.
        mkdir -p /var/snap/microceph/current/run
        snap run --shell microceph -c 'snapctl restart microceph.osd' || true
      fi
    "

    echo "Resetting MicroOVN for ${name}"
    lxc exec "${name}" -- sh -c "
      if snap list | grep -q microovn ; then
        microovn.ovn-appctl exit || true
        microovn.ovs-appctl exit --cleanup || true
        microovn.ovs-dpctl del-dp system@ovs-system || true
        snap disable microovn > /dev/null 2>&1 || true

        # Kill any remaining processes.
        if ps -e -o '%p %a' | grep -v grep | grep -qe 'ovs-' -qe 'ovn-' -qe 'microovn' ; then
          kill -9 \$(ps -e -o '%p %a' | grep -e 'ovs-' -e 'ovn-' -e 'microovn' | grep -v grep | awk '{print \$1}') || true
        fi

        # Wipe the snap state so we can start fresh.
        rm -rf /var/snap/microovn/*/*
        snap enable microovn > /dev/null 2>&1 || true
      fi
    "

    echo "Enabling LXD and MicroCloud for ${name}"
    lxc exec "${name}" -- sh -c "
      snap enable lxd > /dev/null 2>&1 || true
      snap enable microcloud > /dev/null 2>&1 || true
      snap start lxd > /dev/null 2>&1 || true
      snap start microcloud > /dev/null 2>&1 || true
      snap refresh lxd --channel latest/stable --cohort=+

      lxd waitready
    "
  )
}

# reset_system: Starts the given system and resets its snaps, and devices.
# Makes only `num_disks` and `num_ifaces` disks and interfaces available for the next test.
reset_system() {
  if [ "${SNAPSHOT_RESTORE}" = 1 ]; then
    restore_system "${*}"
    return
  fi

  name=$1
  num_disks=${2:-0}
  num_ifaces=${3:-0}

  echo "==> Resetting ${name} with ${num_disks} disk(s) and ${num_ifaces} extra interface(s)"
  (
    set -eu
    if [ "${SKIP_SETUP_LOG}" = 1 ]; then
      exec > /dev/null 2>&1
    fi

    lxc start "${name}" || true

    lxc file push "${MICROCLOUD_SNAP_PATH}" "${name}"/root/microcloud.snap

    lxc exec "${name}" -- ip link del lxdfan0 || true

    # Rescan for any disks we hid from the previous run.
    lxc exec "${name}" -- sh -c "
      for h in /sys/class/scsi_host/host*; do
          echo '- - -' > \${h}/scan
      done
    "

    reset_snaps "${name}"

    lxc exec "${name}" -- zpool destroy -f local || true

    # Hide any extra disks for this run.
    lxc exec "${name}" -- sh -c "
      disks=\$(lsblk -o NAME,SERIAL | grep \"lxd_disk[0-9]\" | cut -d\" \" -f1 | tac)
      count_disks=\$(echo \"\${disks}\" | wc -l)
      for d in \${disks} ; do
        if [ \${count_disks} -gt \${num_disks} ]; then
          echo 1 > /sys/block/\${d}/device/delete
        else
          wipefs -af /dev/\${d}
          dd if=/dev/zero of=/dev/\${d} bs=4096 count=100
        fi

        count_disks=\$((count_disks - 1))
      done
    "

    # Disable all extra interfaces.
    max_ifaces=$(lxc network ls -f csv | grep -cF microbr)
    for i in $(seq 1 "${max_ifaces}") ; do
      iface="enp$((i + 5))s0"
      lxc exec "${name}" -- ip link set "${iface}" down
    done

    # Re-enable as many interfaces as we want for this run.
    for i in $(seq 1 "${num_ifaces}") ; do
      iface="enp$((i + 5))s0"
      lxc exec "${name}" -- ip link set "${iface}" up
      lxc exec "${name}" -- sh -c "echo 1 > /proc/sys/net/ipv6/conf/${iface}/disable_ipv6" > /dev/null
    done
  )

  echo "==> Reset ${name}"
}

# cluster_reset: Resets cluster-wide settings in preparation for reseting test nodes.
cluster_reset() {
  name=${1}
  (
    set -eu
    if [ "${SKIP_SETUP_LOG}" = 1 ]; then
      exec > /dev/null 2>&1
    fi

    lxc exec "${name}" -- sh -c "
      for m in \$(lxc ls -f csv -c n) ; do
        lxc rm \$m -f
      done

      for f in \$(lxc image ls -f csv -c f) ; do
        lxc image rm \$f
      done

      echo 'config: {}' | lxc profile edit default || true
      lxc storage rm local || true
    "

    lxc exec "${name}" -- sh -c "
      if snap list | grep -q microceph ; then
        # Ceph might not be responsive if we haven't set it up yet.
        microceph_setup=0
        if timeout -k 3 3 microceph cluster list ; then
          microceph_setup=1
        fi

        if [ \$microceph_setup = 1 ]; then
          microceph.ceph tell mon.\* injectargs '--mon-allow-pool-delete=true'
          lxc storage rm remote || true
          microceph.rados purge lxd_remote --yes-i-really-really-mean-it --force
          microceph.rados purge .mgr --yes-i-really-really-mean-it --force

          for pool in \$(microceph.ceph osd pool ls) ; do
            microceph.ceph osd pool rm \${pool} \${pool} --yes-i-really-really-mean-it
          done

          for pool in \$(microceph.ceph osd ls) ; do
            microceph.ceph osd out \${pool}
            microceph.ceph osd down \${pool} --definitely-dead
            microceph.ceph osd purge \${pool} --yes-i-really-mean-it --force
            microceph.ceph osd destroy \${pool} --yes-i-really-mean-it --force
          done
        fi
      fi
    "
  )
}

# reset_systems: Concurrently or sequentially resets the specified number of systems.
reset_systems() {
  if [ "${SNAPSHOT_RESTORE}" = 1 ]; then
    restore_systems "${*}"
    return
  fi

  num_vms=3
  num_disks=3
  num_ifaces=1

	if echo "${1}" | grep -Pq '\d+'; then
    num_vms="${1}"
    shift 1
  fi

  if echo "${1}" | grep -Pq '\d+'; then
    num_disks="${1}"
    shift 1
  fi

  if echo "${1}" | grep -Pq '\d+'; then
    num_ifaces="${1}"
    shift 1
  fi

  for i in $(seq 1 "${num_vms}") ; do
    name=$(printf "micro%02d" "$i")
    if [ "$i" = 1 ]; then
      cluster_reset "${name}"
    fi

    if [ "${CONCURRENT_SETUP}" = 1 ]; then
      reset_system "${name}" "${num_disks}" "${num_ifaces}" &
    else
      reset_system "${name}" "${num_disks}" "${num_ifaces}"
    fi
  done

  # Pause any extra systems.
  total_machines="$(lxc list -f csv -c n micro | wc -l)"
  for i in $(seq "$((1 + num_vms))" "${total_machines}"); do
    name=$(printf "micro%02d" "$i")
    lxc pause "${name}" || true
  done

  if [ "${CONCURRENT_SETUP}" = 1 ]; then
    wait
  fi
}

# restore_systems: Restores the systems from a snapshot at snap0.
restore_systems() {
  num_vms=3
  num_disks=3
  num_extra_ifaces=1

  if echo "${1}" | grep -Pq '\d+'; then
    num_vms=${1}
    shift 1
  fi

  if echo "${1}" | grep -Pq '\d+'; then
    num_disks=${1}
    shift 1
  fi

  if echo "${1}" | grep -Pq '\d+'; then
    num_extra_ifaces=${1}
    shift 1
  fi

  lxc stop --all --force

  (
    set -eu
    if [ "${SKIP_SETUP_LOG}" = 1 ]; then
      exec > /dev/null
    fi

    for i in $(seq 1 "${num_extra_ifaces}") ; do
      network="microbr$((i - 1))"
      lxc profile device remove default "eth${i}"
      lxc network delete "${network}" || true
      lxc network create "${network}" \
        ipv4.address="10.${i}.123.1/24" ipv4.dhcp=false ipv4.nat=true \
        ipv6.address="fd42:${i}:1234:1234::1/64" ipv6.nat=true

      lxc profile device add default "eth${i}" nic network="${network}" name="eth${i}"
    done
  )

  for n in $(seq 1 "${num_vms}") ; do
    name="$(printf "micro%02d" "${n}")"
    if [ "${CONCURRENT_SETUP}" = 1 ]; then
      restore_system "${name}" "${num_disks}" "${num_extra_ifaces}" &
    else
      restore_system "${name}" "${num_disks}" "${num_extra_ifaces}"
    fi
  done

  if [ "${CONCURRENT_SETUP}" = 1 ]; then
    wait
  fi
}

restore_system() {
  name="${1}"
  shift 1

  num_disks="0"
  if echo "${1}" | grep -Pq '\d+'; then
    num_disks="${1}"
    shift 1
  fi

  num_extra_ifaces="0"
  if echo "${1}" | grep -Pq '\d+'; then
    num_extra_ifaces="${1}"
    shift 1
  fi

  echo "==> Restoring ${name} from snapshot snap0 with ${num_disks} fresh disks and ${num_extra_ifaces} extra interfaces"

  (
    set -eu

    if [ "${SKIP_SETUP_LOG}" = 1 ]; then
      exec > /dev/null
    fi

    lxc remote switch local
    lxc project switch microcloud-test

    if lxc list "${name}" -f csv -c s | grep -qxF "RUNNING"; then
      lxc stop "${name}" --force
    fi

    lxc restore "${name}" snap0

    for disk in $(lxc config device list "${name}") ; do
      if lxc config device get "${name}" "${disk}" type | grep -qF "disk" ; then
        lxc config device remove "${name}" "${disk}"
      fi

      volume="${name}-${disk}"
      if lxc storage volume list zpool -f csv | grep -q "^custom,${volume}" ; then
        lxc storage volume delete zpool "${volume}"
      fi
    done


    for n in $(seq 1 "${num_disks}") ; do
      disk="${name}-disk${n}"
      lxc storage volume create zpool "${disk}" size=5GiB --type=block
      lxc config device add "${name}" "disk${n}" disk pool=zpool source="${disk}"
    done

    lxc start "${name}"

    lxd_wait_vm "${name}"

    # Sleep some time so the snaps are fully set up.
    sleep 3

    for i in $(seq 1 "${num_extra_ifaces}") ; do
      network="enp$((i + 5))s0"
      lxc exec "${name}" -- ip link set "${network}" up
      lxc exec "${name}" -- sh -c "echo 1 > /proc/sys/net/ipv6/conf/${network}/disable_ipv6"
    done
  )

  echo "==> Restored ${name}"
}


# cleanup: try to clean everything that is in the lxd-cloud project
cleanup_systems() {
  lxc remote switch local
  if lxc remote list -f csv | cut -d',' -f1 | grep -qF microcloud-test; then
      lxc remote remove microcloud-test || true
  fi
  lxc project switch microcloud-test
  echo "==> Removing systems"
  lxc list -c n -f csv | xargs --no-run-if-empty lxc delete --force
  lxc image list -c f -f csv | xargs --no-run-if-empty lxc image delete

  for profile in $(lxc profile list -f csv | cut -d, -f1 | grep -vxF default); do
    lxc profile delete "${profile}"
  done

  for volume in $(lxc storage volume list -f csv -c t,n zpool | grep -F "custom," | cut -d',' -f2-); do
    lxc storage volume delete zpool "${volume}"
  done

  echo 'config: {}' | lxc profile edit default

  lxc remote switch local
  lxc project switch default
  lxc project delete microcloud-test

  for net in $(lxc network ls -f csv | grep microbr | cut -d',' -f1) ; do
    lxc network delete "${net}"
  done

  lxc storage delete zpool
  echo "==> All systems removed"
}

# setup_lxd: create a dedicate project in the host's LXD to use for the testbed
#            it also sets core.https_address to make the LXD API available to MAAS and Juju
setup_lxd_project() {
  # Create project
  (
    set -eu

    if [ "${SKIP_SETUP_LOG}" = 1 ]; then
      exec > /dev/null
    fi

    lxc remote switch local
	  lxc project create microcloud-test || true
	  lxc project switch microcloud-test

    # Create a zfs pool so we can use fast snapshots.
    lxc storage create zpool zfs volume.size=5GiB

    lxc remote list -f csv | cut -d',' -f1 | grep -qxF "ubuntu-minimal" || lxc remote add ubuntu-minimal https://cloud-images.ubuntu.com/minimal/releases/ --protocol simplestreams --auth-type none

    # Setup default profile
    cat << EOF | lxc profile edit default
config:
  cloud-init.user-data: |
    #cloud-config
    write_files:
      - content: |
          #!/bin/sh
          exec curl --unix-socket /dev/lxd/sock lxd/1.0 -X PATCH -d '{"state": "Ready"}'
        path: /var/lib/cloud/scripts/per-boot/ready.sh
        permissions: "0755"
EOF

    lxc profile set default boot.autostart true
    lxc profile device add default root disk pool=zpool path=/
    lxc profile device add default eth0 nic network=lxdbr0 name=eth0

    lxc profile set default environment.TEST_CONSOLE=1
    lxc profile set default environment.DEBIAN_FRONTEND=noninteractive
  )
}

create_system() {
  name="${1}"
  num_disks="${2:-0}"
  shift 2

  echo "==> ${name} Creating VM with ${num_disks} disks"
  (
    set -eu

    if [ "${SKIP_SETUP_LOG}" = 1 ]; then
      exec > /dev/null
    fi

    lxc init ubuntu-minimal:22.04 "${name}" --vm -c limits.cpu=2 -c limits.memory=4GiB

    for n in $(seq 1 "${num_disks}") ; do
      disk="${name}-disk${n}"
      lxc storage volume create zpool "${disk}" size=5GiB --type=block
      lxc config device add "${name}" "disk${n}" disk pool=zpool source="${disk}"
    done

    lxc start "${name}"
  )
}

setup_system() {
  name="${1}"
  shift 1

  echo "==> ${name} Setting up"

  # Bring enp6s0 up but disable IPv6 (should do through netplan).
  lxc exec "${name}" -- ip link set enp6s0 up
  lxc exec "${name}" -- sh -c "echo 1 > /proc/sys/net/ipv6/conf/enp6s0/disable_ipv6" > /dev/null

  (
    set -eu

    if [ "${SKIP_SETUP_LOG}" = 1 ]; then
      exec > /dev/null
    fi

    # Install the snaps.
    lxc exec "${name}" -- apt-get update
    lxc exec "${name}" -- apt-get install --no-install-recommends -y snapd curl jq zfsutils-linux htop

    lxc exec "${name}" -- sh -c "PATH=\$PATH:/snap/bin snap install snapd"

    # Snaps can occasionally fail to install properly, so repeatedly try.
    lxc exec "${name}" -- sh -c "
      export PATH=\$PATH:/snap/bin
      while ! test -e /snap/bin/microceph ; do
        snap install microceph || true
        sleep 1
      done

      while ! test -e /snap/bin/microovn ; do
        snap install microovn || true
        sleep 1
      done

      if test -e /snap/bin/lxd ; then
        snap remove lxd --purge
      fi

      while ! test -e /snap/bin/lxd ; do
        snap install lxd --channel latest/stable --cohort='+' || true
        sleep 1
      done
    "

    lxc file push "${MICROCLOUD_SNAP_PATH}" "${name}"/root/microcloud.snap
    lxc exec "${name}" -- sh -c "PATH=\$PATH:/snap/bin snap install --devmode /root/microcloud.snap"
  )

  # Sleep some time so the snaps are fully set up.
  sleep 3


  lxc stop "${name}"

  lxc snapshot "${name}" snap0

  lxc start "${name}"

  lxd_wait_vm "${name}"

  echo "==> ${name} Finished Setting up"
}

# Creates a new system with the given number of disks.
new_system() {
  name=${1}
  num_disks=${2:-0}

  create_system "${name}" "${num_disks}"
  lxd_wait_vm "${name}"
  # Sleep some time so the vm is fully set up.
  sleep 3
  setup_system "${name}"
}

new_systems() {
  num_vms=3
  num_disks=3
  num_ifaces=1

  if echo "${1}" | grep -qP '\d+'; then
    num_vms="${1}"
    shift 1
  fi

  if echo "${1}" | grep -qP '\d+'; then
    num_disks="${1}"
    shift 1
  fi

  if echo "${1}" | grep -qP '\d+'; then
    num_ifaces="${1}"
    shift 1
  fi

  setup_lxd_project

  echo "==> Creating ${num_ifaces} extra network interfaces"
  for i in $(seq 1 "${num_ifaces}"); do
    # Create uplink network
    lxc network create "microbr$((i - 1))" \
        ipv4.address="10.${i}.123.1/24" ipv4.dhcp=false ipv4.nat=true \
        ipv6.address="fd42:${i}:1234:1234::1/64" ipv6.nat=true
    lxc profile device add default "eth${i}" nic network="microbr$((i - 1))" name="eth${i}"
  done

  if [ "${CONCURRENT_SETUP}" = 1 ]; then
    for n in $(seq 1 "${num_vms}"); do
      name=$(printf "micro%02d" "${n}")
      create_system "${name}" "${num_disks}" &
    done

    wait

    for n in $(seq 1 "${num_vms}"); do
      name=$(printf "micro%02d" "${n}")

      (
       lxd_wait_vm "${name}"
       # Sleep some time so the vm is fully set up.
       sleep 3
       setup_system "${name}"
      ) &

    done

    wait

  else
    for n in $(seq 1 "${num_vms}"); do
      name="$(printf "micro%02d" "${n}")"
      create_system "${name}" "${num_disks}"
      lxd_wait_vm "${name}"

      # Sleep some time so the vm is fully set up.
      sleep 3

      setup_system "${name}"
    done
  fi
}

wait_snapd() {
  name="${1}"

  for i in $(seq 60); do # Wait up to 60s.
    if lxc exec "${name}" -- systemctl show snapd.seeded.service --value --property SubState | grep -qx exited; then
      return 0 # Success.
    fi

    sleep 1
  done

  echo "snapd not seeded after ${i}s"
  return 1 # Failed.
}

lxd_wait_vm() {
  name="${1}"

  echo "==> ${name} Awaiting VM..."
  for round in $(seq 640); do
    if lxc info "${name}" | grep -qF "Status: READY" ; then
      wait_snapd "${name}"
      echo "    ${name} VM is ready"
      return 0
    fi

    # Sometimes the VM just won't start, so retry after 3 minutes.
    if [ "$((round % 180))" = 0 ]; then
      echo "==> ${name} Timeout (${round}s): Re-initializing VM"
      lxc restart "${name}" --force
    fi

    sleep 1
  done

  echo "    ${name} VM failed to start"
  return 1
}
