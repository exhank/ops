#!/usr/bin/env bash
#
# Copies .env and setup.sh to a remote host, runs the setup script, and cleans up.

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/../.env"
readonly REMOTE_TMP_DIR="$HOME/.temp-setup"

# load_env reads environment variables from the .env file.
load_env() {
  if [[ -r "${ENV_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${ENV_FILE}"
  else
    printf '%s: [ERROR] Cannot read %s\n' \
      "${SCRIPT_NAME}" "${ENV_FILE}" >&2
    exit 1
  fi
}

# copy_files uploads .env and setup.sh to the remote host.
copy_files() {
  scp -q -P "${REMOTE_SSH_PORT}" \
    "${ENV_FILE}" \
    "${SCRIPT_DIR}/setup.sh" \
    "${REMOTE_USERNAME}@${REMOTE_HOST}:${REMOTE_TMP_DIR}"
}

# run_remote_setup executes the remote setup script and removes the temp dir.
run_remote_setup() {
  ssh -q -p "${REMOTE_SSH_PORT}" \
    "${REMOTE_USERNAME}@${REMOTE_HOST}" <<EOF
chmod +x "${REMOTE_TMP_DIR}/setup.sh"
"${REMOTE_TMP_DIR}/setup.sh"
rm -rf "${REMOTE_TMP_DIR}"
EOF
}

# main orchestrates the overall workflow.
main() {
  load_env
  copy_files
  run_remote_setup
}

main "$@"
