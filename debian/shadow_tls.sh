#!/usr/bin/env bash
#
# Install and configure Snell and ShadowTLS servers.
#
# Globals:
#   SCRIPT_NAME, SCRIPT_DIR, ENV_FILE, SNELL_PORT, SHADOW_TLS_PORT
#   SNELL_VERSION, SNELL_URL, SHADOW_TLS_VERSION, SHADOW_TLS_URL
#   SNELL_PSK, SHADOW_TLS_PASSWORD

set -euo pipefail
IFS=$'\n\t'

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly ENV_FILE="${SCRIPT_DIR}/.env"

readonly SNELL_PORT=58443
readonly SHADOW_TLS_PORT=8443

readonly SNELL_VERSION="v4.1.1"
readonly SNELL_URL="https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-amd64.zip"
readonly SHADOW_TLS_VERSION="v0.2.25"
readonly SHADOW_TLS_URL="https://github.com/ihciah/shadow-tls/releases/download/${SHADOW_TLS_VERSION}/shadow-tls-x86_64-unknown-linux-musl"

log_info()  { printf '%s: [INFO]  %s\n'  "$SCRIPT_NAME" "$*"; }
log_error() { printf '%s: [ERROR] %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()      { log_error "$*"; exit 1; }

#######################################
# Ensure script is run as root.
# Globals: none
#######################################
ensure_root() {
  if [[ "$EUID" -ne 0 ]]; then
    die "Must be run as root."
  fi
}

#######################################
# Load environment variables from file.
# Globals:
#   ENV_FILE
#######################################
load_env() {
  [[ -r "$ENV_FILE" ]] || die "Cannot read env file: $ENV_FILE"
  # shellcheck source=/dev/null
  source "$ENV_FILE"
}

#######################################
# Validate required environment variables.
# Globals:
#   SNELL_PSK, SHADOW_TLS_PASSWORD
#######################################
validate_env() {
  local missing=false
  for var in SNELL_PSK SHADOW_TLS_PASSWORD; do
    if [[ -z "${!var:-}" ]]; then
      log_error "Environment variable $var is not set"
      missing=true
    fi
  done
  $missing && die "Missing required environment variables."
}

#######################################
# Install Snell server if not already present.
#######################################
install_snell() {
  log_info "Installing Snell server"
  if [[ -x "/usr/local/bin/snell-server" ]]; then
    log_info "snell-server already installed; skipping"
    return
  fi
  apt-get update -qq
  apt-get install -y curl unzip
  local tmp_zip
  tmp_zip="$(mktemp --suffix=".zip")"
  curl -fsSL "$SNELL_URL" -o "$tmp_zip"
  unzip -qo "$tmp_zip" -d /usr/local/bin
  rm -f "$tmp_zip"
  chmod +x /usr/local/bin/snell-server
}

#######################################
# Configure Snell systemd service.
#######################################
configure_snell() {
  log_info "Configuring Snell server"
  mkdir -p /etc/snell
  cat > /etc/snell/snell-server.conf <<-EOF
	[snell-server]
	listen = 127.0.0.1:${SNELL_PORT}
	psk    = ${SNELL_PSK}
	ipv6   = false
	EOF

  cat > /etc/systemd/system/snell.service <<-EOF
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
  systemctl enable --now snell.service
}

#######################################
# Install ShadowTLS server if needed.
#######################################
install_shadow_tls() {
  log_info "Installing ShadowTLS server"
  if [[ -x "/usr/local/bin/shadow-tls" ]]; then
    log_info "shadow-tls already installed; skipping"
    return
  fi
  curl -fsSL "$SHADOW_TLS_URL" -o /usr/local/bin/shadow-tls
  chmod +x /usr/local/bin/shadow-tls
}

#######################################
# Configure ShadowTLS systemd service and firewall.
#######################################
configure_shadow_tls() {
  log_info "Configuring ShadowTLS server"
  cat > /etc/systemd/system/shadow-tls.service <<-EOF
	[Unit]
	Description=Shadow-TLS Server Service
	Documentation=man:sstls-server
	After=network-online.target
	Wants=network-online.target

	[Service]
	Type=simple
	ExecStart=/usr/local/bin/shadow-tls --fastopen \
	  --v3 server \
	  --listen ::0:${SHADOW_TLS_PORT} \
	  --server 127.0.0.1:${SNELL_PORT} \
	  --tls gateway.icloud.com \
	  --password ${SHADOW_TLS_PASSWORD}
	StandardOutput=syslog
	StandardError=syslog
	SyslogIdentifier=shadow-tls

	[Install]
	WantedBy=multi-user.target
	EOF

  systemctl daemon-reload
  systemctl enable --now shadow-tls.service

  if command -v ufw &>/dev/null; then
    ufw allow "${SHADOW_TLS_PORT}/tcp"
    ufw --force reload
  else
    log_info "ufw not found; skipping firewall configuration"
  fi
}

#######################################
# Main entry point.
#######################################
main() {
  ensure_root
  load_env
  validate_env

  install_snell
  configure_snell
  install_shadow_tls
  configure_shadow_tls

  log_info "Snell & ShadowTLS installation complete"
}

main "$@"
