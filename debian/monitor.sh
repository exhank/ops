#!/bin/bash
#
# Monitor system sensors and disk SMART temperatures.
#
# Globals:
#   None
# Arguments:
#   None

set -euo pipefail
IFS=$'\n\t'

#######################################
# Display hardware sensor readings and SMART disk temps.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes sensor data and SMART temperature attributes to stdout.
#######################################
monitor() {
  # Show all sensor readings
  sensors || {
    echo "sensors command failed" >&2
    return 1
  }

  # Loop over disks a and b for Airflow_Temperature_Cel
  for dev in /dev/sda /dev/sdb /dev/sdc; do
    sudo smartctl -A "${dev}" \
      | grep -i 'min/max' \
      || echo "No temperature info on ${dev}"
  done
}

#######################################
# Main entry point: clear screen and rerun monitor every second.
# Globals:
#   None
# Arguments:
#   None
#######################################
main() {
  while true; do
    clear
    monitor
    sleep 2
  done
}

main "$@"
