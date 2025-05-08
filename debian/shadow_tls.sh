#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

export PATH="/usr/sbin:/sbin:$PATH"

readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly ENV_FILE="${SCRIPT_DIR}/.env"
readonly SNELL_PORT=58443

log_info()  { printf '%s: [INFO]  %s\n'  "$SCRIPT_NAME" "$*"; }
log_error() { printf '%s: [ERROR] %s\n' "$SCRIPT_NAME" "$*" >&2; }

die() {
  log_error "$*"
  exit 1
}

# Ensure script is run as root.
ensure_root() {
  [[ "$EUID" -eq 0 ]] || die "Must be run as root."
}

# Check that required environment variables are set.
validate_env() {
  for var in SNELL_PSK SHADOW_TLS_PASSWORD; do
    [[ -n "${!var:-}" ]] || die "Environment variable $var is not set"
  done
}

# Install Snell server.
install_snell() {
  log_info "Installing Snell server"
  apt-get update -qq
  apt-get install -y unzip
  wget https://dl.nssurge.com/snell/snell-server-v4.1.1-linux-amd64.zip
  unzip snell-server-v4.1.1-linux-amd64.zip -d /usr/local/bin
  rm -f snell-server-v4.1.1-linux-amd64.zip
  chmod +x /usr/local/bin/snell-server
}

# Configure Snell server.
configure_snell() {
  log_info "Configuring Snell server"
  mkdir /etc/snell
  cat > /etc/snell/snell-server.conf <<EOF
[snell-server]
listen = 127.0.0.1:${SNELL_PORT}
psk = ${SNELL_PSK}
ipv6 = false
EOF
  cat > /etc/systemd/system/snell.service <<EOF
[Unit]
Description=Snell Proxy Service
After=network.target

[Service]
Type=simple
User=nobody
Group=nogroup
LimitNOFILE=32768
ExecStart=/usr/local/bin/snell-server -c /etc/snell/snell-server.conf
AmbientCapabilities=CAP_NET_BIND_SERVICE
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=snell-server

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now snell
}

# Install ShadowTLS server.
install_shadow_tls() {
  log_info "Installing ShadowTLS server"
  wget https://github.com/ihciah/shadow-tls/releases/download/v0.2.25/shadow-tls-x86_64-unknown-linux-musl -O /usr/local/bin/shadow-tls
  chmod +x /usr/local/bin/shadow-tls
}

# Configure ShadowTLS server.
configure_shadow_tls() {
  log_info "Configuring ShadowTLS server"
  local shadow_tls_port=8443
  cat > /etc/systemd/system/shadow-tls.service <<EOF
[Unit]
Description=Shadow-TLS Server Service
Documentation=man:sstls-server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/shadow-tls --fastopen --v3 server --listen ::0:${shadow_tls_port} --server 127.0.0.1:${SNELL_PORT} --tls gateway.icloud.com --password ${SHADOW_TLS_PASSWORD}
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=shadow-tls

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now shadow-tls

  ufw allow ${shadow_tls_port}/tcp
  ufw --force reload
}

main() {
  source "$ENV_FILE"

  ensure_root
  validate_env

  install_snell
  configure_snell
  install_shadow_tls
  configure_shadow_tls

  log_info "ShadowTLS server installed and configured successfully"
}

main "$@"
