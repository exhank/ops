#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly REMOTE_DIR="~/.debian-setup"

main() {
  source "${SCRIPT_DIR}/../.env"

  scp -P "${REMOTE_SSH_PORT}" -r \
    "${SCRIPT_DIR}/setup.sh" \
    "${SCRIPT_DIR}/../.env" \
    "${REMOTE_USERNAME}@${REMOTE_HOST}:${REMOTE_DIR}"

  ssh -p "${REMOTE_SSH_PORT}" \
    "${REMOTE_USERNAME}@${REMOTE_HOST}" "\
      chmod +x '${REMOTE_DIR}/setup.sh' && \
      '${REMOTE_DIR}/setup.sh' && \
      rm -rf '${REMOTE_DIR}'"
}

main "$@"
