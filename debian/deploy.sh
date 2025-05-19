#!/usr/bin/env bash
#
# Perform remote setup by copying .env and setup.sh to a remote host
# then running setup.sh as root (direct, sudo, or su).
# Supports SSH auth via key or password (sshpass).
set -euo pipefail
IFS=$'\n\t'

#######################################
# Print usage information.
# Globals: None
# Arguments: None
# Outputs: to STDOUT
# Returns: exit 0
#######################################
usage() {
  cat <<EOF
Usage: ${0##*/} [--env-file PATH] [--help]
  --env-file PATH  Path to .env file (default: ../.env relative to script)
  --help           Display this help and exit
EOF
  exit 0
}

#######################################
# Print an error message with timestamp, then exit.
# Globals: None
# Arguments: message
# Outputs: to STDERR
# Returns: exit 1
#######################################
err() {
  local msg timestamp
  msg="$*"
  timestamp="$(date +'%Y-%m-%dT%H:%M:%S%z')"
  echo "[$timestamp] ERROR: ${msg}" >&2
  exit 1
}

#######################################
# Parse command-line arguments.
# Globals: SCRIPT_DIR, ENV_FILE
# Arguments: CLI arguments
# Sets: ENV_FILE
# Returns: exit on failure
#######################################
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        usage
        ;;
      --env-file)
        [[ -n "${2:-}" ]] || err "--env-file requires an argument"
        ENV_FILE="$2"
        shift
        ;;
      *)
        err "Unknown argument: $1"
        ;;
    esac
    shift
  done
}

#######################################
# Load and verify configuration from ENV_FILE.
# Globals: ENV_FILE
# Sets: REMOTE_HOST, REMOTE_SSH_PORT, REMOTE_USERNAME, SSH_PASSWORD, ROOT_PASSWORD
# Returns: exit on failure
#######################################
load_env() {
  [[ -r "${ENV_FILE}" ]] || err "Cannot read env file: ${ENV_FILE}"
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
  for var in REMOTE_HOST REMOTE_SSH_PORT REMOTE_USERNAME; do
    [[ -n "${!var:-}" ]] || err "${var} must be set in ${ENV_FILE}"
  done
}

#######################################
# Ensure sshpass is available if SSH_PASSWORD is set.
# Globals: SSH_PASSWORD
# Modifies: SSH_PASSWORD
# Returns: exit on failure if sshpass missing
#######################################
ensure_sshpass() {
  if [[ -n "${SSH_PASSWORD:-}" ]] && ! command -v sshpass >/dev/null; then
    err "sshpass not found; install sshpass or unset SSH_PASSWORD"
  fi
}

#######################################
# Build SSH and SCP command arrays.
# Globals: SSH_PASSWORD
# Sets: SSH_CMD, SCP_CMD
#######################################
build_ssh_commands() {
  if [[ -n "${SSH_PASSWORD:-}" ]]; then
    SSH_CMD=(sshpass -p "${SSH_PASSWORD}" ssh -o StrictHostKeyChecking=no)
    SCP_CMD=(sshpass -p "${SSH_PASSWORD}" scp -o StrictHostKeyChecking=no)
  else
    SSH_CMD=(ssh -o StrictHostKeyChecking=no)
    SCP_CMD=(scp -o StrictHostKeyChecking=no)
  fi
}

#######################################
# Prepare a local temporary directory for files.
# Globals: SCRIPT_DIR
# Sets: LOCAL_TEMP_DIR
# Returns: exit on failure
#######################################
prepare_local_temp() {
  LOCAL_TEMP_DIR="$(mktemp -d)" || err "Failed to create local temp dir"
  trap 'rm -rf "${LOCAL_TEMP_DIR}"' EXIT
  cp "${ENV_FILE}" "${SCRIPT_DIR}/setup.sh" "${LOCAL_TEMP_DIR}/" \
    || err "Failed to copy files to local temp dir"
}

#######################################
# Copy files to remote host and prepare remote dir.
# Globals: SCP_CMD, SSH_CMD, REMOTE_SSH_PORT, REMOTE_USERNAME, REMOTE_HOST, LOCAL_TEMP_DIR
# Sets: REMOTE_TEMP_DIR
# Returns: exit on failure
#######################################
copy_files() {
  REMOTE_TEMP_DIR="/tmp/tmp.setup.$(openssl rand -hex 6)"
  "${SSH_CMD[@]}" -p "${REMOTE_SSH_PORT}" \
    "${REMOTE_USERNAME}@${REMOTE_HOST}" -- "mkdir -p '${REMOTE_TEMP_DIR}'" \
    || err "Failed to create remote temp dir"
  "${SCP_CMD[@]}" -P "${REMOTE_SSH_PORT}" -r "${LOCAL_TEMP_DIR}/" \
    "${REMOTE_USERNAME}@${REMOTE_HOST}:${REMOTE_TEMP_DIR}/" \
    || err "Failed to copy files to remote host"
}

#######################################
# Run setup.sh as root on remote host.
# Globals: SSH_CMD, REMOTE_SSH_PORT, REMOTE_USERNAME, REMOTE_HOST, REMOTE_TEMP_DIR, ROOT_PASSWORD
# Returns: exit on failure
#######################################
run_remote_setup() {
  local ssh_opts=( -p "${REMOTE_SSH_PORT}" )
  [[ "${REMOTE_USERNAME}" != "root" ]] && ssh_opts+=( -t )
  "${SSH_CMD[@]}" "${ssh_opts[@]}" \
    "${REMOTE_USERNAME}@${REMOTE_HOST}" <<EOF
set -euo pipefail
trap 'rm -rf "${REMOTE_TEMP_DIR}"' EXIT
cd "${REMOTE_TEMP_DIR}/${LOCAL_TEMP_DIR##*/}"
source .env
chmod +x setup.sh

# Elevate and run
if (( EUID == 0 )); then
  ./setup.sh
elif sudo -n true 2>/dev/null; then
  sudo ./setup.sh
else
  printf '%s\n' "$ROOT_PASSWORD" | \
  su - root -c "${REMOTE_TEMP_DIR}/${LOCAL_TEMP_DIR##*/}/setup.sh"
fi
EOF
}

#######################################
# Main entrypoint.
#######################################
main() {
  readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  readonly ENV_FILE="${SCRIPT_DIR}/../.env"
  parse_args "$@"
  load_env
  ensure_sshpass
  build_ssh_commands
  prepare_local_temp
  copy_files
  run_remote_setup
}

main "$@"
