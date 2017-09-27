#!/bin/bash
# shellcheck disable=SC2034
set -e

function osd_activate {
  if [[ -z "${OSD_DEVICE}" ]] || [[ ! -b "${OSD_DEVICE}" ]]; then
    log "ERROR: you either provided a non-existing device or no device at all."
    log "You must provide a device to build your OSD ie: /dev/sdb"
    exit 1
  fi

  CEPH_DISK_OPTIONS=()

  if [[ ${OSD_FILESTORE} -eq 1 ]] && [[ ${OSD_DMCRYPT} -eq 0 ]]; then
    if [[ -n "${OSD_JOURNAL}" ]]; then
      CLI+=("${OSD_JOURNAL}")
    else
      CLI+=("${OSD_DEVICE}")
    fi
    JOURNAL_PART=$(ceph-disk list "${CLI[@]}" | grep journal | sed -r 's/^.*\s([^ ]+)$/\1/') # This is a privileged container so 'ceph-disk list' works
    JOURNAL_UUID=$(get_part_uuid "${JOURNAL_PART}" || true)
  fi

  # creates /dev/mapper/<uuid> for dmcrypt
  # usually after a reboot they don't go created
  udevadm trigger

  # watch the udev event queue, and exit if all current events are handled
  udevadm settle --timeout=600

  DATA_PART=$(dev_part "${OSD_DEVICE}" 1)
  MOUNTED_PART=${DATA_PART}

  if [[ ${OSD_DMCRYPT} -eq 1 ]] && [[ ${OSD_FILESTORE} -eq 1 ]]; then
    DATA_UUID=$(get_part_uuid "$(dev_part "${OSD_DEVICE}" 1)")
    LOCKBOX_UUID=$(get_part_uuid "$(dev_part "${OSD_DEVICE}" 3)")
    JOURNAL_PART=$(ceph-disk list "${OSD_DEVICE}" | awk '/ceph journal/ {print $1}') # This is a privileged container so 'ceph-disk list' works
    JOURNAL_UUID=$(get_part_uuid "${JOURNAL_PART}")

    mount_lockbox "$DATA_UUID" "$LOCKBOX_UUID"

    CEPH_DISK_OPTIONS+=('--dmcrypt')
    MOUNTED_PART="/dev/mapper/${DATA_UUID}"

    open_encrypted_parts_filestore
  fi

  if [[ -z "${CEPH_DISK_OPTIONS[*]}" ]]; then
    ceph-disk -v --setuser ceph --setgroup disk activate --no-start-daemon "${DATA_PART}"
  else
    ceph-disk -v --setuser ceph --setgroup disk activate "${CEPH_DISK_OPTIONS[@]}" --no-start-daemon "${DATA_PART}"
  fi

  OSD_ID=$(grep "${MOUNTED_PART}" /proc/mounts | awk '{print $2}' | sed -r 's/^.*-([0-9]+)$/\1/')

  apply_ceph_ownership_to_disks

  log "SUCCESS"
  exec /usr/bin/ceph-osd "${CLI_OPTS[@]}" -f -i "${OSD_ID}" --setuser ceph --setgroup disk
}
