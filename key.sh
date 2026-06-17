#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# VPS SSH key-only login setup script
#
# Usage:
#   sudo ./key.sh [user]
#
# Examples:
#   sudo ./key.sh root
#   CREATE_USER=1 sudo ./key.sh deploy
#   CREATE_USER=1 ADD_SUDO=1 sudo ./key.sh deploy
#   ROOT_LOGIN=no sudo ./key.sh deploy
#   KEY_PASSPHRASE='your-passphrase' sudo ./key.sh root
#
# What it does:
#   1. Generate an ed25519 SSH key pair on the VPS.
#   2. Add the public key to the target user's authorized_keys.
#   3. Enable public-key SSH login.
#   4. Disable password and keyboard-interactive SSH login.
#   5. Print the private key so you can save it locally.

SSHD_CONFIG="/etc/ssh/sshd_config"
MANAGED_BEGIN="# BEGIN managed by VPSScript key.sh"
MANAGED_END="# END managed by VPSScript key.sh"

TARGET_USER="${1:-root}"
CREATE_USER="${CREATE_USER:-0}"
ADD_SUDO="${ADD_SUDO:-0}"
ROOT_LOGIN="${ROOT_LOGIN:-prohibit-password}"
KEY_PASSPHRASE="${KEY_PASSPHRASE:-}"
KEY_COMMENT="${KEY_COMMENT:-vps-$(hostname)-$(date +%Y%m%d%H%M%S)}"

BACKUP=""
KEY_DIR=""
PRIVATE_KEY_PATH=""
PUBLIC_KEY_PATH=""
PUBKEY=""

info() {
  printf '[INFO] %s\n' "$*"
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID}" -eq 0 ]] || die "Please run as root, for example: sudo ./key.sh root"
}

validate_input() {
  [[ -n "${TARGET_USER}" ]] || die "User cannot be empty"

  if [[ "${TARGET_USER}" != "root" && ! "${TARGET_USER}" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then
    die "Unsafe username: ${TARGET_USER}"
  fi

  case "${ROOT_LOGIN}" in
    yes|no|prohibit-password|without-password|forced-commands-only) ;;
    *) die "Invalid ROOT_LOGIN value: ${ROOT_LOGIN}" ;;
  esac

  if [[ "${TARGET_USER}" == "root" && "${ROOT_LOGIN}" == "no" ]]; then
    die "TARGET_USER is root but ROOT_LOGIN=no would disable root SSH login. Use ROOT_LOGIN=prohibit-password or choose a normal sudo user."
  fi
}

find_sshd() {
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
  elif [[ -x /usr/sbin/sshd ]]; then
    printf '/usr/sbin/sshd\n'
  else
    die "sshd not found. Please install OpenSSH Server first."
  fi
}

ensure_user() {
  if id "${TARGET_USER}" >/dev/null 2>&1; then
    return
  fi

  [[ "${CREATE_USER}" == "1" ]] || die "User ${TARGET_USER} does not exist. Use CREATE_USER=1 to create it."

  info "Creating user: ${TARGET_USER}"
  useradd -m -s /bin/bash "${TARGET_USER}"
}

maybe_add_sudo() {
  [[ "${ADD_SUDO}" == "1" ]] || return 0
  [[ "${TARGET_USER}" != "root" ]] || return 0

  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "${TARGET_USER}"
    info "Added ${TARGET_USER} to sudo group"
  elif getent group wheel >/dev/null 2>&1; then
    usermod -aG wheel "${TARGET_USER}"
    info "Added ${TARGET_USER} to wheel group"
  else
    info "No sudo/wheel group found; skipped ADD_SUDO"
  fi
}

generate_key_pair() {
  command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen not found"

  KEY_DIR="$(mktemp -d /tmp/vps-ssh-key.XXXXXX)"
  chmod 700 "${KEY_DIR}"

  PRIVATE_KEY_PATH="${KEY_DIR}/id_ed25519"
  PUBLIC_KEY_PATH="${KEY_DIR}/id_ed25519.pub"

  ssh-keygen \
    -q \
    -t ed25519 \
    -a 100 \
    -N "${KEY_PASSPHRASE}" \
    -C "${KEY_COMMENT}" \
    -f "${PRIVATE_KEY_PATH}"

  PUBKEY="$(cat "${PUBLIC_KEY_PATH}")"
  info "Generated ed25519 SSH key pair on this VPS"
}

install_authorized_key() {
  local home_dir ssh_dir auth_keys group_name

  home_dir="$(getent passwd "${TARGET_USER}" | cut -d: -f6)"
  [[ -n "${home_dir}" ]] || die "Cannot determine home directory for ${TARGET_USER}"

  group_name="$(id -gn "${TARGET_USER}")"
  ssh_dir="${home_dir}/.ssh"
  auth_keys="${ssh_dir}/authorized_keys"

  install -d -m 700 -o "${TARGET_USER}" -g "${group_name}" "${ssh_dir}"
  touch "${auth_keys}"
  chown "${TARGET_USER}:${group_name}" "${auth_keys}"
  chmod 600 "${auth_keys}"

  if ! grep -qxF "${PUBKEY}" "${auth_keys}"; then
    printf '%s\n' "${PUBKEY}" >> "${auth_keys}"
  fi

  chown "${TARGET_USER}:${group_name}" "${auth_keys}"
  chmod 600 "${auth_keys}"

  if command -v restorecon >/dev/null 2>&1; then
    restorecon -R "${ssh_dir}" >/dev/null 2>&1 || true
  fi

  info "Installed public key to ${auth_keys}"
}

backup_sshd_config() {
  [[ -f "${SSHD_CONFIG}" ]] || die "Cannot find ${SSHD_CONFIG}"
  BACKUP="${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
  cp -a "${SSHD_CONFIG}" "${BACKUP}"
  info "Backed up sshd_config to ${BACKUP}"
}

write_sshd_config() {
  local tmp
  tmp="$(mktemp)"

  awk -v begin="${MANAGED_BEGIN}" -v end="${MANAGED_END}" '
    $0 == begin { skip=1; next }
    $0 == end { skip=0; next }
    skip != 1 { print }
  ' "${SSHD_CONFIG}" > "${tmp}"

  {
    printf '%s\n' "${MANAGED_BEGIN}"
    printf '%s\n' "PubkeyAuthentication yes"
    printf '%s\n' "PasswordAuthentication no"
    printf '%s\n' "KbdInteractiveAuthentication no"
    printf '%s\n' "ChallengeResponseAuthentication no"
    printf '%s\n' "PermitEmptyPasswords no"
    printf '%s\n' "PermitRootLogin ${ROOT_LOGIN}"
    printf '%s\n' "${MANAGED_END}"
    printf '\n'
    cat "${tmp}"
  } > "${SSHD_CONFIG}"

  rm -f "${tmp}"
  info "Wrote SSH key-only login settings to ${SSHD_CONFIG}"
}

validate_sshd_config() {
  local sshd_bin effective
  sshd_bin="$(find_sshd)"
  mkdir -p /run/sshd

  if ! "${sshd_bin}" -t -f "${SSHD_CONFIG}"; then
    cp -a "${BACKUP}" "${SSHD_CONFIG}"
    die "sshd config test failed. Rolled back to ${BACKUP}"
  fi

  effective="$(${sshd_bin} -T -f "${SSHD_CONFIG}" -C "user=${TARGET_USER},host=localhost,addr=127.0.0.1" 2>/dev/null || true)"

  if [[ -n "${effective}" ]]; then
    echo "${effective}" | grep -q '^pubkeyauthentication yes$' || {
      cp -a "${BACKUP}" "${SSHD_CONFIG}"
      die "Effective config check failed: PubkeyAuthentication is not yes. Rolled back."
    }

    echo "${effective}" | grep -q '^passwordauthentication no$' || {
      cp -a "${BACKUP}" "${SSHD_CONFIG}"
      die "Effective config check failed: PasswordAuthentication is not no. Rolled back."
    }

    if echo "${effective}" | grep -q '^kbdinteractiveauthentication yes$'; then
      cp -a "${BACKUP}" "${SSHD_CONFIG}"
      die "Effective config check failed: KbdInteractiveAuthentication is still yes. Rolled back."
    fi
  fi

  info "sshd config validation passed"
}

reload_ssh() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null \
      || systemctl reload sshd 2>/dev/null \
      || systemctl restart ssh 2>/dev/null \
      || systemctl restart sshd 2>/dev/null \
      || die "Failed to reload/restart SSH service"
  else
    service ssh reload 2>/dev/null \
      || service sshd reload 2>/dev/null \
      || service ssh restart 2>/dev/null \
      || service sshd restart 2>/dev/null \
      || die "Failed to reload/restart SSH service"
  fi

  info "SSH service reloaded"
}

print_result() {
  cat <<EOF

============================================================
DONE
============================================================

Target user:
  ${TARGET_USER}

Public key installed on VPS:
  $(getent passwd "${TARGET_USER}" | cut -d: -f6)/.ssh/authorized_keys

Save the following PRIVATE KEY to your local computer, for example:
  ~/.ssh/${TARGET_USER}_vps_ed25519

Then run on your local computer:
  chmod 600 ~/.ssh/${TARGET_USER}_vps_ed25519
  ssh -i ~/.ssh/${TARGET_USER}_vps_ed25519 ${TARGET_USER}@YOUR_SERVER_IP

------------------------ PRIVATE KEY ------------------------
$(cat "${PRIVATE_KEY_PATH}")
---------------------- END PRIVATE KEY ----------------------

------------------------- PUBLIC KEY ------------------------
$(cat "${PUBLIC_KEY_PATH}")
----------------------- END PUBLIC KEY ----------------------

Do NOT close your current SSH session yet.
Open a new terminal and test key login first.

Test that password login is disabled:
  ssh -o PubkeyAuthentication=no -o PreferredAuthentications=password ${TARGET_USER}@YOUR_SERVER_IP

That password-only test should fail.

Temporary key directory on VPS:
  ${KEY_DIR}

After saving the private key locally and confirming login works, remove it from VPS:
  rm -rf '${KEY_DIR}'

SSH config backup:
  ${BACKUP}

Rollback command if needed:
  cp -a '${BACKUP}' '${SSHD_CONFIG}' && sshd -t && { systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || service ssh reload 2>/dev/null || service sshd reload; }

============================================================
EOF
}

main() {
  require_root
  validate_input
  ensure_user
  maybe_add_sudo
  generate_key_pair
  install_authorized_key
  backup_sshd_config
  write_sshd_config
  validate_sshd_config
  reload_ssh
  print_result
}

main "$@"
