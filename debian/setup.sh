#!/usr/bin/env bash
# Securely sets up a Debian server:
# - Updates APT sources
# - Upgrades system packages
# - Installs core tools
# - Creates a sudo user and deploys SSH keys
# - Hardens SSH daemon
# - Enables UFW firewall and unattended upgrades

set -euo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive

readonly PATH=/usr/sbin:/sbin:$PATH
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly ENV_FILE="$SCRIPT_DIR/.env"

log_info()  { printf '%s: [INFO]  %s\n' "$SCRIPT_NAME" "$*"; }
log_error() { printf '%s: [ERROR] %s\n' "$SCRIPT_NAME" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

# Verify script is running as root.
ensure_root() {
  [[ "$EUID" -eq 0 ]] || die "This script must be run as root."
}

# Check that required environment variables are set.
validate_env() {
  local var
  for var in NEW_ROOT_PASSWORD NEW_USERNAME NEW_PASSWORD NEW_SSH_PORT; do
    [[ -n "${!var:-}" ]] || die "Missing env var: $var"
  done
}

# Change the root user’s password.
change_root_password() {
  log_info "Changing root password"
  echo "root:${NEW_ROOT_PASSWORD}" | chpasswd
}

# Populate official Debian repository entries.
update_sources() {
  log_info "Configuring APT sources"
  : > /etc/apt/sources.list
  cat <<EOF > /etc/apt/sources.list.d/debian.sources
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://security.debian.org/debian-security
Suites: bookworm-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

# Install and configure the UFW firewall.
install_ufw() {
  log_info "Installing and configuring UFW"
  apt-get update -qq
  apt-get install -y ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw --force enable
}

# Perform a full system upgrade.
upgrade_system() {
  log_info "Upgrading system packages"
  apt-get update -qq
  apt-get -y upgrade
  apt-get -y dist-upgrade
  apt-get -y autoremove --purge
  apt-get clean
}

# Install essential utilities.
install_packages() {
  log_info "Installing essential packages"
  apt-get update -qq
  apt-get install -y sudo unattended-upgrades apt-listchanges
}

# Create or update the sudo user and deploy SSH keys.
create_user() {
  log_info "Creating or updating user: $NEW_USERNAME"
  if ! id "$NEW_USERNAME" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$NEW_USERNAME"
  fi
  echo "${NEW_USERNAME}:${NEW_PASSWORD}" | chpasswd
  usermod -aG sudo "$NEW_USERNAME"

  local home_dir
  home_dir=$(getent passwd "$NEW_USERNAME" | cut -d: -f6)
  mkdir -p "$home_dir/.ssh"
  printf '%s\n' "${NEW_SSH_KEYS[@]:-}" > "$home_dir/.ssh/authorized_keys"
  chmod 700 "$home_dir/.ssh"
  chmod 600 "$home_dir/.ssh/authorized_keys"
  chown -R "$NEW_USERNAME:$NEW_USERNAME" "$home_dir/.ssh"
}

# Harden the SSH daemon configuration.
configure_ssh() {
  log_info "Configuring SSH daemon"
  local cfg=/etc/ssh/sshd_config
  sed -i \
    -e 's/^#\?PermitRootLogin .*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' \
    -e 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' \
    -e "s|^#\?Port .*|Port $NEW_SSH_PORT|" \
    "$cfg"
  systemctl enable ssh
  systemctl restart ssh
  ufw allow "${NEW_SSH_PORT}/tcp"
  ufw limit "${NEW_SSH_PORT}/tcp"
  ufw --force reload
}

# Enable and tune unattended security upgrades.
configure_unattended_upgrades() {
  log_info "Setting up unattended upgrades"
  dpkg-reconfigure --frontend=noninteractive unattended-upgrades
  sed -i \
    -e 's|^//\?\s*Unattended-Upgrade::Remove-Unused-Kernel-Packages.*|Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";|' \
    -e 's|^//\?\s*Unattended-Upgrade::Remove-New-Unused-Dependencies.*|Unattended-Upgrade::Remove-New-Unused-Dependencies "true";|' \
    -e 's|^//\?\s*Unattended-Upgrade::Remove-Unused-Dependencies.*|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' \
    -e 's|^//\?\s*Unattended-Upgrade::Automatic-Reboot.*|Unattended-Upgrade::Automatic-Reboot "true";|' \
    -e 's|^//\?\s*Unattended-Upgrade::Automatic-Reboot-Time.*|Unattended-Upgrade::Automatic-Reboot-Time "12:00";|' \
    /etc/apt/apt.conf.d/50unattended-upgrades
  systemctl enable --now unattended-upgrades
}

main() {
  log_info "Starting server setup"
  source "$ENV_FILE"
  ensure_root
  validate_env

  change_root_password
  update_sources
  install_ufw
  upgrade_system
  install_packages
  create_user
  configure_ssh
  configure_unattended_upgrades

  log_info "Server setup complete – rebooting now"
  reboot
}

main "$@"