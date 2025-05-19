#!/bin/bash
#
# Perform initial Debian server bootstrap: users, SSH, firewall, upgrades.
set -euo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND=noninteractive

# Constants
readonly PATH=/usr/sbin:/sbin:$PATH
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly ENV_FILE="$SCRIPT_DIR/.env"
readonly APT_SRC="/etc/apt/sources.list.d/debian.sources"

log_info()  { printf '%s: [INFO]  %s\n'  "$SCRIPT_NAME" "$*"; }
log_error() { printf '%s: [ERROR] %s\n' "$SCRIPT_NAME" "$*">&2; }
die()       { log_error "$*"; exit 1; }

#######################################
# Ensure running as root.
#######################################
ensure_root() {
  [[ "$EUID" -eq 0 ]] || die "Must be run as root."
}

#######################################
# Verify Debian platform.
#######################################
ensure_debian() {
  [[ -r /etc/os-release ]] || die "/etc/os-release missing"
  . /etc/os-release
  [[ "$ID" == "debian" ]] || die "Only Debian supported (ID=$ID)"
}

#######################################
# Load and validate environment file.
#######################################
load_env() {
  [[ -r "$ENV_FILE" ]] || die "Env file not found: $ENV_FILE"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  for var in NEW_ROOT_PASSWORD NEW_USERNAME NEW_PASSWORD NEW_SSH_PORT; do
    [[ -n "${!var:-}" ]] || die "Missing env var: $var"
  done
}

#######################################
# Configure APT to use official Debian repos.
#######################################
update_sources() {
  log_info "Configuring APT sources"
  : > /etc/apt/sources.list
  cat <<EOF > "$APT_SRC"
Types: deb deb-src
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

# Types: deb
# URIs: https://mirrors.tuna.tsinghua.edu.cn/debian
# Suites: bookworm bookworm-updates bookworm-backports
# Components: main contrib non-free non-free-firmware
# Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://security.debian.org/debian-security
Suites: bookworm-security
Components: main contrib non-free non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
  apt-get update
}

#######################################
# Install packages in one batch.
# Globals: none
# Arguments: list of packages
#######################################
install_pkgs() {
  log_info "Installing: $*"
  apt-get install -y --no-install-recommends "$@" \
    || die "apt-get install failed: $*"
}

#######################################
# Change root password.
#######################################
change_root_password() {
  log_info "Changing root password"
  echo "root:${NEW_ROOT_PASSWORD}" | chpasswd \
    || die "chpasswd failed for root"
}

#######################################
# Create or update sudo user & SSH keys.
#######################################
create_user() {
  log_info "Creating/updating user: $NEW_USERNAME"
  if ! id "$NEW_USERNAME" &>/dev/null; then
    useradd --create-home --shell /bin/bash "$NEW_USERNAME"
  fi
  echo "${NEW_USERNAME}:${NEW_PASSWORD}" | chpasswd \
    || die "chpasswd failed: $NEW_USERNAME"
  usermod -aG sudo "$NEW_USERNAME"
  local homedir
  homedir=$(getent passwd "$NEW_USERNAME" | cut -d: -f6)
  mkdir -p "$homedir/.ssh"
  printf '%s\n' "${NEW_SSH_KEYS[@]:-}" \
    > "$homedir/.ssh/authorized_keys"
  chmod 700 "$homedir/.ssh" \
    && chmod 600 "$homedir/.ssh/authorized_keys"
  chown -R "$NEW_USERNAME:$NEW_USERNAME" "$homedir/.ssh"
}

#######################################
# Harden SSH: disable root/password, set port.
#######################################
configure_ssh() {
  log_info "Configuring sshd"
  local cfg=/etc/ssh/sshd_config
  sed -i \
    -e 's/^#\?PermitRootLogin .*/PermitRootLogin no/' \
    -e 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' \
    -e 's/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/' \
    -e "s|^#\?Port .*|Port ${NEW_SSH_PORT}|" \
    "$cfg"
  systemctl enable ssh \
    && systemctl restart ssh \
    || die "SSH restart failed"
}

#######################################
# Set up UFW and allow SSH.
#######################################
configure_ufw() {
  log_info "Setting up UFW"
  install_pkgs ufw
  ufw default deny incoming
  ufw default allow outgoing
  ufw limit "${NEW_SSH_PORT}/tcp"
  ufw --force enable
}

#######################################
# Full system upgrade.
#######################################
upgrade_system() {
  log_info "Upgrading system"
  apt-get -y -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" upgrade
  apt-get -y dist-upgrade --autoremove --purge
  apt-get clean
}

#######################################
# Configure unattended security upgrades.
#######################################
configure_unattended() {
  log_info "Enabling unattended upgrades"
  dpkg-reconfigure --frontend=noninteractive unattended-upgrades
  sed -i \
    -e 's|^//\?\s*Unattended-Upgrade::Remove-Unused-Kernel-Packages.*|Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";|' \
    -e 's|^//\?\s*Unattended-Upgrade::Remove-New-Unused-Dependencies.*|Unattended-Upgrade::Remove-New-Unused-Dependencies "true";|' \
    -e 's|^//\?\s*Unattended-Upgrade::Remove-Unused-Dependencies.*|Unattended-Upgrade::Remove-Unused-Dependencies "true";|' \
    -e 's|^//\?\s*Unattended-Upgrade::Automatic-Reboot .*|Unattended-Upgrade::Automatic-Reboot "true";|' \
    -e 's|^//\?\s*Unattended-Upgrade::Automatic-Reboot-Time.*|Unattended-Upgrade::Automatic-Reboot-Time "04:00";|' \
    /etc/apt/apt.conf.d/50unattended-upgrades
  systemctl enable --now unattended-upgrades
}

main() {
  ensure_root
  ensure_debian
  load_env

  update_sources
  install_pkgs sudo ufw unattended-upgrades

  configure_ufw
  upgrade_system

  change_root_password
  create_user
  configure_ssh

  configure_unattended

  log_info "Setup complete; rebooting"
  reboot
}

main "$@"
