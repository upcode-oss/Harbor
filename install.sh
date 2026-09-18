#!/usr/bin/env bash
# Reproducible, profile-based Upcode Harbor installer.
set -euo pipefail

APP_ROOT=/opt/upcode-harbor
SERVICE_USER=upcode-harbor
WEB_USER=upcode-harbor-web
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
NODE_REQUIRED_MAJOR=20
LOG_FILE=/tmp/upcode-harbor-install.log
LAST_STEP_LOG=/tmp/upcode-harbor-install-last.log

WITH_DOCKER=0
WITH_LXD=0
WITH_LIBVIRT=0
WITH_K3S=0
WITH_POSTGRESQL=0
WITH_FTP=0
WITH_OPENVPN=0
WITH_ZFS=0
INSTALL_SELECTION_MADE=0
SKIP_NGINX=0
NGINX_SELECTION_MADE=0
UPDATES_ENABLED=0
UPDATE_PUBLIC_KEY=
RELEASE_VERSION=
RESUME_INSTALLATION=0
REINSTALL=0
REINSTALL_BACKUP_DIR=

CORE_PACKAGES=(
  build-essential gcc g++ make python3 python3-pip python3-venv python3-dev
  libpq-dev libpam-modules libpam-modules-bin libpam-runtime pamtester
  git lshw openssl gawk coreutils curl jq ca-certificates gnupg sudo whiptail debian-archive-keyring
  nftables fail2ban cron openssh-client openssh-server iproute2 isc-dhcp-client util-linux
  e2fsprogs xfsprogs btrfs-progs dosfstools exfatprogs ntfs-3g parted
)

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh [OPTIONS]

Without component options, an interactive checklist selects Docker, K3s,
LXC/LXD, ZFS, and the nginx HTTPS proxy. OpenSSH is always installed.

Profiles:
  --profile core             No optional platform components
  --profile containers       Docker and LXD
  --profile virtualization   libvirt/KVM and websockify
  --profile cluster          Docker and K3s/kubectl
  --profile full             All supported components

Individual options:
  --with-docker --with-k3s --with-lxc/--with-lxd --with-zfs
  --with-libvirt --with-postgresql --with-ftp --with-openvpn
  --skip-nginx               Skip nginx/Certbot installation and HTTPS proxy setup
  --with-nginx               Enable nginx setup (default; overrides recorded choice)
  --update-public-key PATH   Enable signed updates with this public key
  --disable-updates          Install without the update facility (default)
  --resume                   Rebuild configuration and finish an interrupted install
  --reinstall                Back up a broken installation and install from scratch
  --release-version VERSION  Override the local initial release version
  -h, --help

No keys or checksum variables are required for installation. Official HTTPS
repositories and their package signatures are used by default. For additional
pinning, set NODESOURCE_KEY_SHA256, DOCKER_GPG_SHA256, K3S_INSTALL_SHA256,
and/or KUBECTL_SHA256. Set KUBECTL_VERSION only to override the version that
K3s installs automatically.
EOF
}

enable_profile() {
  WITH_DOCKER=0
  WITH_LXD=0
  WITH_LIBVIRT=0
  WITH_K3S=0
  WITH_POSTGRESQL=0
  WITH_FTP=0
  WITH_OPENVPN=0
  WITH_ZFS=0
  case "$1" in
    core) ;;
    containers) WITH_DOCKER=1; WITH_LXD=1 ;;
    virtualization) WITH_LIBVIRT=1 ;;
    cluster) WITH_DOCKER=1; WITH_K3S=1 ;;
    full)
      WITH_DOCKER=1; WITH_LXD=1; WITH_LIBVIRT=1; WITH_K3S=1
      WITH_POSTGRESQL=1; WITH_FTP=1; WITH_OPENVPN=1; WITH_ZFS=1
      ;;
    *) printf 'Unknown profile: %s\n' "$1" >&2; exit 2 ;;
  esac
  INSTALL_SELECTION_MADE=1
}

ensure_checklist_tool() {
  command -v whiptail >/dev/null 2>&1 && return

  printf 'Installing the terminal checklist dependency (whiptail)...\n'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y whiptail
  command -v whiptail >/dev/null 2>&1
}

select_optional_components() {
  [[ -t 0 && -t 1 ]] || {
    printf '%s\n' 'No interactive terminal is available. Select components with --profile or --with-* options.' >&2
    return 2
  }

  ensure_checklist_tool

  local selection component nginx_default=ON
  [[ $SKIP_NGINX == 0 ]] || nginx_default=OFF
  if ! selection=$(whiptail \
    --title 'Upcode Harbor Installation' \
    --ok-button 'Continue' \
    --cancel-button 'Cancel' \
    --separate-output \
    --checklist $'Select optional components.\n\nArrow keys: Navigate | Space: Toggle | Tab: Select button\n\nOpenSSH is always installed and cannot be deselected.' \
    20 82 8 \
    docker 'Docker Container Runtime' OFF \
    k3s 'K3s Kubernetes' OFF \
    lxc 'LXC/LXD Systemcontainer' OFF \
    zfs 'ZFS Storage' OFF \
    nginx 'Nginx HTTPS Reverse Proxy' "$nginx_default" \
    3>&1 1>&2 2>&3); then
    printf 'Component selection cancelled.\n' >&2
    return 2
  fi

  WITH_DOCKER=0
  WITH_K3S=0
  WITH_LXD=0
  WITH_ZFS=0
  local selected_nginx=0
  while IFS= read -r component; do
    component=${component//\"/}
    case "$component" in
      docker) WITH_DOCKER=1 ;;
      k3s) WITH_K3S=1 ;;
      lxc) WITH_LXD=1 ;;
      zfs) WITH_ZFS=1 ;;
      nginx) selected_nginx=1 ;;
      '') ;;
      *) printf 'Invalid component returned by checklist: %s\n' "$component" >&2; return 2 ;;
    esac
  done <<<"$selection"
  if [[ $NGINX_SELECTION_MADE == 0 ]]; then
    SKIP_NGINX=$((1 - selected_nginx))
  fi
  INSTALL_SELECTION_MADE=1

  printf 'Selected optional components:'
  local selected=0
  if [[ $WITH_DOCKER == 1 ]]; then printf ' Docker'; selected=1; fi
  if [[ $WITH_K3S == 1 ]]; then printf ' K3s'; selected=1; fi
  if [[ $WITH_LXD == 1 ]]; then printf ' LXC/LXD'; selected=1; fi
  if [[ $WITH_ZFS == 1 ]]; then printf ' ZFS'; selected=1; fi
  if [[ $SKIP_NGINX == 0 ]]; then printf ' Nginx'; selected=1; fi
  [[ $selected == 1 ]] || printf ' none'
  printf ' (OpenSSH is always included)\n'
}

primary_server_ip() {
  local address
  address=$(ip -4 route get 1.1.1.1 2>/dev/null \
    | awk '{for (index = 1; index <= NF; index++) if ($index == "src") {print $(index + 1); exit}}' \
    || true)
  if [[ $address =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ && $address != 127.* ]]; then
    printf '%s\n' "$address"
    return
  fi
  hostname -I 2>/dev/null \
    | awk '{for (index = 1; index <= NF; index++) if ($index ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $index !~ /^127\./) {print $index; exit}}' \
    || true
}

print_access_information() {
  local server_ip server_name
  if [[ $SKIP_NGINX == 1 ]]; then
    printf 'Nginx setup skipped. Configure your own HTTPS reverse proxy for remote access.\n'
    printf 'Local upstreams: frontend http://127.0.0.1:9200 and API http://127.0.0.1:9500.\n'
    printf 'Route /api/ and /ws/ to the API, stripping those prefixes and forwarding WebSocket upgrades.\n'
    printf 'Proxy configuration template: %s/deploy/nginx/upcode-harbor.conf\n' "$RELEASE_DIR"
  else
    server_ip=$(primary_server_ip)
    if [[ -n $server_ip ]]; then
      printf 'Open Upcode Harbor: https://%s/\n' "$server_ip"
    else
      server_name=$(hostname -f 2>/dev/null || hostname)
      printf 'Open Upcode Harbor: https://%s/\n' "$server_name"
    fi
    printf 'Ports 9200 and 9500 are internal loopback services; remote access uses nginx on HTTPS port 443.\n'
    printf 'The browser may require confirmation of the automatically generated certificate.\n'
  fi
  if [[ -n ${SUDO_USER:-} && $SUDO_USER != root ]]; then
    printf 'Login with an existing Linux/PAM account, for example: %s\n' "$SUDO_USER"
  else
    printf 'Login with an existing Linux/PAM username and password.\n'
  fi
}

backup_broken_installation() {
  [[ $SCRIPT_DIR != "$APP_ROOT" && $SCRIPT_DIR != "$APP_ROOT"/* ]] || {
    printf 'Run --reinstall from a separate source checkout, not from %s.\n' "$APP_ROOT" >&2
    return 1
  }
  [[ ! -L /var/backups/upcode-harbor ]] || {
    printf 'Refusing to use a symlinked reinstall backup root.\n' >&2
    return 1
  }

  local backup_id
  backup_id="reinstall-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  REINSTALL_BACKUP_DIR="/var/backups/upcode-harbor/$backup_id"
  install -d -o root -g root -m 0700 /var/backups/upcode-harbor "$REINSTALL_BACKUP_DIR"

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now upcode-harbor.target upcode-harbor-health.timer >/dev/null 2>&1 || true
    systemctl stop upcode-harbor-api.service upcode-harbor-web.service upcode-harbor-worker.service >/dev/null 2>&1 || true
  fi

  local -a sources=(
    "$APP_ROOT"
    /etc/upcode-harbor
    /var/lib/upcode-harbor
    /var/lib/upcode-harbor-web
    /var/log/upcode-harbor
    /usr/share/upcode-harbor
    /usr/local/libexec/upcode-harbor-bin
    /usr/local/libexec/upcode-harbor-privileged
    /usr/local/libexec/upcode-harbor-command
    /usr/local/libexec/upcode-harbor-updater
    /usr/local/libexec/upcode-harbor-health-check
    /usr/local/libexec/upcode-harbor-post-install-smoke
    /usr/local/bin/upcode-harbor
    /etc/sudoers.d/upcode-harbor
    /etc/tmpfiles.d/upcode-harbor.conf
    /etc/pam.d/upcode-harbor
    /etc/nginx/sites-enabled/upcode-harbor
    /etc/nginx/sites-available/upcode-harbor
    /etc/systemd/system/upcode-harbor-api.service
    /etc/systemd/system/upcode-harbor-health-recover.service
    /etc/systemd/system/upcode-harbor-health.service
    /etc/systemd/system/upcode-harbor-health.timer
    /etc/systemd/system/upcode-harbor-update@.service
    /etc/systemd/system/upcode-harbor-web.service
    /etc/systemd/system/upcode-harbor-worker.service
    /etc/systemd/system/upcode-harbor.target
  )
  local -a labels=(
    app-root config state web-state logs update-trust command-links
    privileged-helper command-helper updater health-check post-install-smoke
    cli-launcher sudoers tmpfiles pam-service nginx-enabled nginx-available
    systemd-api systemd-health-recover systemd-health systemd-health-timer
    systemd-update systemd-web systemd-worker systemd-target
  )
  local backed_up=0 index source
  for index in "${!sources[@]}"; do
    source=${sources[$index]}
    if [[ -e $source || -L $source ]]; then
      mv -- "$source" "$REINSTALL_BACKUP_DIR/${labels[$index]}"
      backed_up=1
    fi
  done

  [[ $backed_up == 1 ]] || {
    printf 'No existing Upcode Harbor installation was found to reinstall.\n' >&2
    return 1
  }
  printf 'Existing Upcode Harbor installation backed up to: %s\n' "$REINSTALL_BACKUP_DIR"
}

load_recorded_profile() {
  local profile_file=/var/lib/upcode-harbor/install-profile
  [[ -f $profile_file && ! -L $profile_file ]] || return 1
  [[ $(stat -c '%U:%a' "$profile_file") == root:640 ]] || {
    printf 'Refusing unsafe recorded install profile: %s\n' "$profile_file" >&2
    return 2
  }

  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      SKIP_NGINX)
        [[ $value == 0 || $value == 1 ]] || {
          printf 'Invalid recorded nginx selection.\n' >&2
          return 2
        }
        if [[ $NGINX_SELECTION_MADE == 0 ]]; then SKIP_NGINX=$value; fi
        ;;
      WITH_DOCKER|WITH_LXD|WITH_LIBVIRT|WITH_K3S|WITH_POSTGRESQL|WITH_FTP|WITH_OPENVPN|WITH_ZFS)
        [[ $value == 0 || $value == 1 ]] || {
          printf 'Invalid recorded install profile value for %s.\n' "$key" >&2
          return 2
        }
        printf -v "$key" '%s' "$value"
        ;;
    esac
  done <"$profile_file"
  INSTALL_SELECTION_MADE=1
}

while (($#)); do
  case "$1" in
    --profile) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; enable_profile "$2"; shift 2 ;;
    --skip-nginx) SKIP_NGINX=1; NGINX_SELECTION_MADE=1; shift ;;
    --with-nginx) SKIP_NGINX=0; NGINX_SELECTION_MADE=1; shift ;;
    --with-docker) WITH_DOCKER=1; INSTALL_SELECTION_MADE=1; shift ;;
    --with-lxc|--with-lxd) WITH_LXD=1; INSTALL_SELECTION_MADE=1; shift ;;
    --with-libvirt) WITH_LIBVIRT=1; INSTALL_SELECTION_MADE=1; shift ;;
    --with-k3s) WITH_K3S=1; INSTALL_SELECTION_MADE=1; shift ;;
    --with-postgresql) WITH_POSTGRESQL=1; INSTALL_SELECTION_MADE=1; shift ;;
    --with-ftp) WITH_FTP=1; INSTALL_SELECTION_MADE=1; shift ;;
    --with-openvpn) WITH_OPENVPN=1; INSTALL_SELECTION_MADE=1; shift ;;
    --with-zfs) WITH_ZFS=1; INSTALL_SELECTION_MADE=1; shift ;;
    --update-public-key) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; UPDATE_PUBLIC_KEY=$2; UPDATES_ENABLED=1; shift 2 ;;
    --disable-updates) UPDATES_ENABLED=0; shift ;;
    --resume) RESUME_INSTALLATION=1; shift ;;
    --reinstall) REINSTALL=1; shift ;;
    --release-version) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; RELEASE_VERSION=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown installer option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  printf 'This installer must run as root. Use sudo ./install.sh.\n' >&2
  exit 1
fi
if [[ $RESUME_INSTALLATION == 1 && $REINSTALL == 1 ]]; then
  printf '%s\n' '--resume and --reinstall cannot be used together.' >&2
  exit 2
fi

if [[ $RESUME_INSTALLATION == 1 && $INSTALL_SELECTION_MADE == 0 ]]; then
  load_recorded_profile || status=$?
  if [[ ${status:-0} == 2 ]]; then
    exit 2
  fi
fi
if [[ $INSTALL_SELECTION_MADE == 0 ]]; then
  select_optional_components
fi

if [[ $UPDATES_ENABLED == 1 ]]; then
  [[ -n $UPDATE_PUBLIC_KEY && -f $UPDATE_PUBLIC_KEY ]] || {
    printf '%s\n' '--update-public-key must reference a readable public-key file.' >&2
    exit 2
  }
fi
if [[ -z $RELEASE_VERSION ]]; then
  base_version=$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([^"]*\)".*/\1/p' "$SCRIPT_DIR/upcode-harbor/package.json" | head -n 1)
  [[ -n $base_version ]] || base_version=0.0.0
  RELEASE_VERSION="${base_version}-local-$(date -u +%Y%m%d%H%M%S)"
fi
[[ $RELEASE_VERSION =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
  printf 'Invalid release version: %s\n' "$RELEASE_VERSION" >&2
  exit 2
}

RELEASE_DIR="$APP_ROOT/releases/$RELEASE_VERSION"
RELEASE_STAGING="$APP_ROOT/releases/.${RELEASE_VERSION}.$$"
if [[ $RESUME_INSTALLATION == 1 ]]; then
  [[ -L $APP_ROOT/current ]] || {
    printf 'No interrupted Upcode Harbor installation is available to resume.\n' >&2
    exit 1
  }
  RELEASE_DIR=$(readlink -f "$APP_ROOT/current")
  [[ ${RELEASE_DIR%/*} == "$APP_ROOT/releases" && -d $RELEASE_DIR ]] || {
    printf 'The current Upcode Harbor release link is invalid; refusing to resume.\n' >&2
    exit 1
  }
  RELEASE_VERSION=${RELEASE_DIR##*/}
  [[ $RELEASE_VERSION =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
    printf 'The current Upcode Harbor release version is invalid; refusing to resume.\n' >&2
    exit 1
  }
  [[ -x $RELEASE_DIR/upcode-harbor-service/venv/bin/python3 ]] || {
    printf 'The current Upcode Harbor backend environment is incomplete; refusing to resume.\n' >&2
    exit 1
  }
  RELEASE_STAGING=
elif [[ $REINSTALL == 0 && ( -e $APP_ROOT/current || -L $APP_ROOT/current ) ]]; then
  printf 'An Upcode Harbor installation already exists. Use the signed updater, or --resume if installation stopped after release creation.\n' >&2
  exit 1
elif [[ $REINSTALL == 0 && ( -e $RELEASE_DIR || -e $RELEASE_STAGING ) ]]; then
  printf 'Release already exists: %s\n' "$RELEASE_DIR" >&2
  exit 1
fi

CURRENT_STEP=0
TOTAL_STEPS=14
cleanup() {
  if [[ -n ${RELEASE_STAGING:-} && $RELEASE_STAGING == /opt/upcode-harbor/releases/.* && -d $RELEASE_STAGING ]]; then
    rm -rf -- "$RELEASE_STAGING"
  fi
}
trap cleanup EXIT

run_step() {
  local title=$1
  local function_name=$2
  CURRENT_STEP=$((CURRENT_STEP + 1))
  printf '[%02d/%02d] %s\n' "$CURRENT_STEP" "$TOTAL_STEPS" "$title"
  if "$function_name" >>"$LOG_FILE" 2>&1; then
    printf '    OK\n'
  else
    tail -n 60 "$LOG_FILE" >"$LAST_STEP_LOG" || true
    printf '    FAILED\n' >&2
    sed 's/^/      /' "$LAST_STEP_LOG" | tail -n 20 >&2
    exit 1
  fi
}

verify_sha256() {
  local expected=$1
  local file=$2
  [[ $expected =~ ^[0-9a-fA-F]{64}$ ]] || {
    printf 'A pinned SHA-256 value is required for %s.\n' "$file" >&2
    return 1
  }
  printf '%s  %s\n' "$expected" "$file" | sha256sum -c -
}

verify_optional_sha256() {
  local expected=$1
  local file=$2
  if [[ -n $expected ]]; then
    verify_sha256 "$expected" "$file"
  else
    printf 'No pinned SHA-256 supplied for %s; relying on HTTPS and upstream signatures.\n' "$file"
  fi
}

step_validate_source() {
  local submodule=upcode-harbor/public/novnc
  local novnc_dir="$SCRIPT_DIR/$submodule"
  local expected actual
  [[ -f $SCRIPT_DIR/.gitmodules ]]
  grep -Fq 'path = upcode-harbor/public/novnc' "$SCRIPT_DIR/.gitmodules"
  grep -Fq 'url = https://github.com/novnc/noVNC.git' "$SCRIPT_DIR/.gitmodules"
  [[ -f $SCRIPT_DIR/upcode-harbor/package-lock.json ]]
  [[ -f $SCRIPT_DIR/upcode-harbor-service/requirements.lock ]]

  if ! command -v git >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y git ca-certificates
  fi
  # Trust only these checkout paths when invoked through sudo.
  local git_command=(git -c "safe.directory=$SCRIPT_DIR" -c "safe.directory=$novnc_dir")
  if "${git_command[@]}" -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    expected=$("${git_command[@]}" -C "$SCRIPT_DIR" ls-files -s -- "$submodule" | awk '$1 == "160000" {print $2}')
    [[ $expected =~ ^[0-9a-f]{40,64}$ ]] || {
      printf 'The source checkout does not pin a noVNC submodule commit.\n' >&2
      return 1
    }
    printf 'Preparing noVNC at pinned commit %s...\n' "$expected"
    "${git_command[@]}" -C "$SCRIPT_DIR" \
      -c "submodule.$submodule.url=https://github.com/novnc/noVNC.git" \
      submodule update --init --checkout -- "$submodule"
    actual=$("${git_command[@]}" -C "$novnc_dir" rev-parse HEAD)
    [[ $expected == "$actual" ]]
    "${git_command[@]}" -C "$novnc_dir" diff --quiet
    "${git_command[@]}" -C "$novnc_dir" diff --cached --quiet
  fi
  [[ -f $novnc_dir/vnc.html ]] || {
    printf 'noVNC is missing. Run the installer from a Git checkout so it can download the pinned submodule automatically.\n' >&2
    return 1
  }
}

step_install_core_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  local core_packages=("${CORE_PACKAGES[@]}")
  if [[ $SKIP_NGINX == 0 ]]; then
    core_packages+=(nginx certbot python3-certbot python3-certbot-nginx)
  fi
  apt-get install -y "${core_packages[@]}"
  systemctl enable --now ssh.service

  if [[ $WITH_ZFS == 1 ]] && ! apt-cache show zfsutils-linux >/dev/null 2>&1; then
    # zfsutils-linux is shipped in Debian's contrib component. Minimal Debian
    # images commonly enable only main, so add a narrowly scoped, Debian-signed
    # source instead of silently omitting ZFS from the full profile.
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ ${ID:-} == debian && ${VERSION_CODENAME:-} =~ ^[a-z0-9][a-z0-9_-]*$ ]] || {
      printf 'ZFS packages are unavailable from the configured APT sources.\n' >&2
      return 1
    }
    install -d -o root -g root -m 0755 /etc/apt/sources.list.d
    cat > /etc/apt/sources.list.d/upcode-harbor-zfs.sources <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: ${VERSION_CODENAME}
Components: contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
    chmod 0644 /etc/apt/sources.list.d/upcode-harbor-zfs.sources
    apt-get update
    apt-cache show zfsutils-linux >/dev/null 2>&1 || {
      printf 'ZFS packages remain unavailable after enabling Debian contrib.\n' >&2
      return 1
    }
  fi

  local packages=()
  [[ $WITH_LXD == 0 ]] || packages+=(lxd)
  [[ $WITH_LIBVIRT == 0 ]] || packages+=(qemu-kvm qemu-utils libvirt-daemon-system bridge-utils dnsmasq virt-install libvirt-clients websockify sshfs cloud-image-utils genisoimage)
  [[ $WITH_POSTGRESQL == 0 ]] || packages+=(postgresql)
  [[ $WITH_FTP == 0 ]] || packages+=(vsftpd ftp)
  [[ $WITH_OPENVPN == 0 ]] || packages+=(openvpn)
  [[ $WITH_ZFS == 0 ]] || packages+=(zfsutils-linux linux-headers-"$(uname -r)" dkms)
  ((${#packages[@]} == 0)) || apt-get install -y "${packages[@]}"
}

step_install_node() {
  local major=0
  if [[ -x /usr/bin/node ]]; then
    major=$(/usr/bin/node --version | sed 's/^v//' | cut -d. -f1)
  fi
  if ((major < NODE_REQUIRED_MAJOR)); then
    local key_tmp
    key_tmp=$(mktemp)
    curl -fsSL -o "$key_tmp" https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key
    verify_optional_sha256 "${NODESOURCE_KEY_SHA256:-}" "$key_tmp"
    install -d -m 0755 /etc/apt/keyrings
    gpg --batch --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg "$key_tmp"
    rm -f -- "$key_tmp"
    chmod 0644 /etc/apt/keyrings/nodesource.gpg
    printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_%s.x nodistro main\n' "$NODE_REQUIRED_MAJOR" > /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
  fi
  major=$(/usr/bin/node --version | sed 's/^v//' | cut -d. -f1)
  ((major >= NODE_REQUIRED_MAJOR))
  /usr/bin/npm --version
}

step_install_optional_platforms() {
  if [[ $WITH_DOCKER == 1 ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ ${ID:-} == debian || ${ID:-} == ubuntu ]]
    [[ -n ${VERSION_CODENAME:-} ]]
    local docker_key
    docker_key=$(mktemp)
    curl -fsSL -o "$docker_key" "https://download.docker.com/linux/${ID}/gpg"
    verify_optional_sha256 "${DOCKER_GPG_SHA256:-}" "$docker_key"
    install -d -m 0755 /etc/apt/keyrings
    install -o root -g root -m 0644 "$docker_key" /etc/apt/keyrings/docker.asc
    rm -f -- "$docker_key"
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' "$(dpkg --print-architecture)" "$ID" "$VERSION_CODENAME" > /etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
  fi
  if [[ $WITH_LXD == 1 ]]; then
    lxd init --auto
  fi
  if [[ $WITH_K3S == 1 ]]; then
    local download_dir kubectl_version kubectl_sha256
    download_dir=$(mktemp -d)
    curl -fsSL -o "$download_dir/k3s-install.sh" https://get.k3s.io
    verify_optional_sha256 "${K3S_INSTALL_SHA256:-}" "$download_dir/k3s-install.sh"
    chmod 0700 "$download_dir/k3s-install.sh"
    INSTALL_K3S_EXEC='server --disable traefik --disable servicelb' sh "$download_dir/k3s-install.sh"
    if [[ -n ${KUBECTL_VERSION:-} ]]; then
      kubectl_version=$KUBECTL_VERSION
      [[ $kubectl_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
        printf 'Invalid kubectl version: %s\n' "$kubectl_version" >&2
        return 1
      }
      curl -fsSL -o "$download_dir/kubectl" "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
      if [[ -n ${KUBECTL_SHA256:-} ]]; then
        kubectl_sha256=$KUBECTL_SHA256
      else
        kubectl_sha256=$(curl -fsSL "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl.sha256")
      fi
      verify_sha256 "$kubectl_sha256" "$download_dir/kubectl"
      install -o root -g root -m 0755 "$download_dir/kubectl" /usr/local/bin/kubectl
    elif [[ -n ${KUBECTL_SHA256:-} ]]; then
      printf 'KUBECTL_SHA256 requires KUBECTL_VERSION.\n' >&2
      return 1
    fi
    command -v kubectl
    rm -rf -- "$download_dir"
  fi
}

step_create_service_accounts() {
  getent group "$SERVICE_USER" >/dev/null || groupadd --system "$SERVICE_USER"
  id "$SERVICE_USER" >/dev/null 2>&1 || useradd --system --gid "$SERVICE_USER" --home-dir /var/lib/upcode-harbor --shell /usr/sbin/nologin "$SERVICE_USER"
  getent group "$WEB_USER" >/dev/null || groupadd --system "$WEB_USER"
  id "$WEB_USER" >/dev/null 2>&1 || useradd --system --gid "$WEB_USER" --home-dir /var/lib/upcode-harbor-web --shell /usr/sbin/nologin "$WEB_USER"
  for group in adm; do getent group "$group" >/dev/null && usermod -aG "$group" "$SERVICE_USER"; done
  [[ $WITH_DOCKER == 0 ]] || usermod -aG docker "$SERVICE_USER"
  [[ $WITH_LXD == 0 ]] || usermod -aG lxd "$SERVICE_USER"
  if [[ $WITH_LIBVIRT == 1 ]]; then
    usermod -aG libvirt,kvm "$SERVICE_USER"
    if getent group libvirt-qemu >/dev/null; then
      usermod -aG libvirt-qemu "$SERVICE_USER"
    fi
  fi
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 /etc/upcode-harbor
  if find /etc/upcode-harbor -xdev -type l -print -quit | grep -q .; then
    printf 'Refusing to install over symlinks below /etc/upcode-harbor.\n' >&2
    return 1
  fi
  chown -R "$SERVICE_USER:$SERVICE_USER" /etc/upcode-harbor
  find /etc/upcode-harbor -xdev -type d -exec chmod 0700 {} +
  find /etc/upcode-harbor -xdev -type f -exec chmod 0600 {} +
  install -d -o root -g root -m 0755 "$APP_ROOT" "$APP_ROOT/releases"
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 /var/lib/upcode-harbor
  install -d -o "$WEB_USER" -g "$WEB_USER" -m 0700 /var/lib/upcode-harbor-web
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 /var/log/upcode-harbor
  install -d -o root -g "$SERVICE_USER" -m 0750 /var/lib/upcode-harbor/updates /var/lib/upcode-harbor/update-state
  install -d -o root -g root -m 0700 /var/backups/upcode-harbor
  for directory in app-store compose app-data customization; do
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0750 "/var/lib/upcode-harbor/$directory"
  done
  for directory in ssh_keys authorized_keys; do
    install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 "/var/lib/upcode-harbor/$directory"
  done
}

step_copy_release() {
  install -d -o root -g root -m 0755 "$RELEASE_STAGING"
  tar \
    --exclude='.git' --exclude='.venv' --exclude='venv' \
    --exclude='node_modules' --exclude='.next' --exclude='__pycache__' \
    --exclude='*.pyc' --exclude='upcode-harbor/.env.local' \
    --exclude='upcode-harbor/tsconfig.tsbuildinfo' \
    --exclude='upcode-harbor-service/ssh_keys' \
    --exclude='upcode-harbor-service/authorized_keys' \
    --exclude='upcode-harbor/public/novnc/package-lock.json' \
    -C "$SCRIPT_DIR" -cf - . | tar -C "$RELEASE_STAGING" -xf -
}

step_build_release() {
  printf 'NEXT_PUBLIC_API_BASE_URL=\nNEXT_PUBLIC_WS_BASE_URL=\n' >"$RELEASE_STAGING/upcode-harbor/.env.local"
  (cd "$RELEASE_STAGING/upcode-harbor" && /usr/bin/npm ci && /usr/bin/npm run build)
  (cd "$RELEASE_STAGING/upcode-harbor-service" && python3 -m venv venv && venv/bin/pip install --no-deps -r requirements.lock)
  (cd "$RELEASE_STAGING/upcode-harbor-cli" && python3 -m venv venv && venv/bin/pip install --no-deps -r requirements.lock)
  chown -R root:root "$RELEASE_STAGING"
  find "$RELEASE_STAGING" -type d -exec chmod u=rwx,go=rx {} +
  find "$RELEASE_STAGING" -type f -perm /022 -exec chmod go-w {} +
  mv -- "$RELEASE_STAGING" "$RELEASE_DIR"
  ln -s "$RELEASE_DIR" "$APP_ROOT/.current.$$"
  mv -Tf -- "$APP_ROOT/.current.$$" "$APP_ROOT/current"
}

step_configure_mutable_state() {
  ln -sfn /var/lib/upcode-harbor/app-store "$APP_ROOT/app-store"
  ln -sfn /var/lib/upcode-harbor/compose "$APP_ROOT/compose"
  ln -sfn /var/lib/upcode-harbor/customization "$APP_ROOT/customization"
  cp -a "$RELEASE_DIR/app-store-templates/." /var/lib/upcode-harbor/app-store/
  chown -R "$SERVICE_USER:$SERVICE_USER" /var/lib/upcode-harbor/app-store
  if [[ $WITH_LIBVIRT == 1 ]]; then
    local iso_group=libvirt
    getent group libvirt-qemu >/dev/null && iso_group=libvirt-qemu
    install -d -o "$SERVICE_USER" -g "$iso_group" -m 2770 /var/lib/libvirt/isos
    find /var/lib/libvirt/isos -maxdepth 1 -xdev -type f -iname '*.iso' \
      -exec chown "$SERVICE_USER:$iso_group" {} + -exec chmod 0640 {} +
  fi
  if [[ $WITH_K3S == 1 ]]; then
    install -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0600 /etc/rancher/k3s/k3s.yaml /etc/upcode-harbor/kubeconfig
  fi
  cat > /etc/upcode-harbor/service.env <<EOF
UPCODE_HARBOR_COOKIE_SECURE=true
UPCODE_HARBOR_COOKIE_SAMESITE=strict
UPCODE_HARBOR_SESSION_TTL_SECONDS=3600
KUBECONFIG=/etc/upcode-harbor/kubeconfig
EOF
  chown "$SERVICE_USER:$SERVICE_USER" /etc/upcode-harbor/service.env
  chmod 0600 /etc/upcode-harbor/service.env
  install -o "$WEB_USER" -g "$WEB_USER" -m 0600 /dev/null /var/lib/upcode-harbor-web/web.env
  if [[ $UPDATES_ENABLED == 1 ]]; then
    install -d -o root -g root -m 0755 /usr/share/upcode-harbor
    install -o root -g root -m 0644 "$UPDATE_PUBLIC_KEY" /usr/share/upcode-harbor/update-public.pem
  fi
  cat > /var/lib/upcode-harbor/install-profile <<EOF
WITH_DOCKER=$WITH_DOCKER
WITH_LXD=$WITH_LXD
WITH_LIBVIRT=$WITH_LIBVIRT
WITH_K3S=$WITH_K3S
WITH_POSTGRESQL=$WITH_POSTGRESQL
WITH_FTP=$WITH_FTP
WITH_OPENVPN=$WITH_OPENVPN
WITH_ZFS=$WITH_ZFS
SKIP_NGINX=$SKIP_NGINX
UPDATES_ENABLED=$UPDATES_ENABLED
EOF
  chown root:"$SERVICE_USER" /var/lib/upcode-harbor/install-profile
  chmod 0640 /var/lib/upcode-harbor/install-profile
}

step_install_privilege_boundary() {
  install -d -o root -g root -m 0755 /usr/local/libexec /usr/local/libexec/upcode-harbor-bin
  install -o root -g root -m 0755 "$RELEASE_DIR/deploy/upcode-harbor-privileged" /usr/local/libexec/upcode-harbor-privileged
  install -o root -g root -m 0755 "$RELEASE_DIR/deploy/upcode-harbor-command" /usr/local/libexec/upcode-harbor-command
  install -o root -g root -m 0755 "$RELEASE_DIR/deploy/upcode-harbor-updater" /usr/local/libexec/upcode-harbor-updater
  install -o root -g root -m 0755 "$RELEASE_DIR/deploy/upcode-harbor-health-check" /usr/local/libexec/upcode-harbor-health-check
  install -o root -g root -m 0755 "$RELEASE_DIR/deploy/upcode-harbor-post-install-smoke" /usr/local/libexec/upcode-harbor-post-install-smoke
  local commands=(apt-get certbot chpasswd dhclient fail2ban-client groupadd groupdel gpasswd hostnamectl ip mkfs.btrfs mkfs.exfat mkfs.ext4 mkfs.ntfs mkfs.vfat mount nft nginx openvpn systemctl timedatectl umount useradd userdel usermod zfs zpool)
  local command
  for command in "${commands[@]}"; do
    ln -sfn /usr/local/libexec/upcode-harbor-command "/usr/local/libexec/upcode-harbor-bin/$command"
  done
  install -o root -g root -m 0440 "$RELEASE_DIR/deploy/sudoers/upcode-harbor" /etc/sudoers.d/upcode-harbor
  visudo -cf /etc/sudoers.d/upcode-harbor
  install -o root -g root -m 0644 "$RELEASE_DIR/deploy/tmpfiles/upcode-harbor.conf" /etc/tmpfiles.d/upcode-harbor.conf
  systemd-tmpfiles --create /etc/tmpfiles.d/upcode-harbor.conf
  install -o root -g root -m 0644 "$RELEASE_DIR/deploy/pam/upcode-harbor" /etc/pam.d/upcode-harbor
}

step_install_systemd_units() {
  install -o root -g root -m 0644 "$RELEASE_DIR"/deploy/systemd/* /etc/systemd/system/
  if [[ -f /etc/systemd/system/upcode-harbor.service ]]; then
    systemctl disable --now upcode-harbor.service || true
    rm -f -- /etc/systemd/system/upcode-harbor.service
  fi
  systemctl daemon-reload
}

step_configure_https() {
  if [[ $SKIP_NGINX == 1 ]]; then
    printf 'Skipping nginx and local HTTPS certificate setup.\n'
    return 0
  fi
  local tls_dir=/etc/upcode-harbor/tls
  local certificate=$tls_dir/server.crt
  local private_key=$tls_dir/server.key
  install -d -o "$SERVICE_USER" -g "$SERVICE_USER" -m 0700 "$tls_dir"
  if [[ -e $certificate || -e $private_key ]]; then
    [[ -f $certificate && -f $private_key && ! -L $certificate && ! -L $private_key ]] || {
      printf 'Both TLS certificate and key must be regular files.\n' >&2
      return 1
    }
  else
    local common_name server_ip san
    common_name=$(hostname -f 2>/dev/null || hostname)
    [[ $common_name =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || common_name=localhost
    server_ip=$(primary_server_ip)
    san="DNS:${common_name},DNS:localhost,IP:127.0.0.1"
    [[ $server_ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && san="$san,IP:$server_ip"
    openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 397 \
      -subj "/CN=$common_name" -addext "subjectAltName=$san" \
      -keyout "$private_key" -out "$certificate"
  fi
  openssl x509 -in "$certificate" -noout
  openssl pkey -in "$private_key" -check -noout
  chown "$SERVICE_USER:$SERVICE_USER" "$certificate" "$private_key"
  chmod 0600 "$certificate" "$private_key"
  install -o root -g root -m 0644 "$RELEASE_DIR/deploy/nginx/upcode-harbor.conf" /etc/nginx/sites-available/upcode-harbor
  if [[ -L /etc/nginx/sites-enabled/default ]]; then
    [[ $(readlink -f /etc/nginx/sites-enabled/default) == /etc/nginx/sites-available/default ]] || {
      printf 'Refusing to replace a custom nginx default-site link.\n' >&2
      return 1
    }
    rm -f -- /etc/nginx/sites-enabled/default
  elif [[ -e /etc/nginx/sites-enabled/default ]]; then
    printf 'Refusing to replace a custom nginx default-site file.\n' >&2
    return 1
  fi
  ln -sfn /etc/nginx/sites-available/upcode-harbor /etc/nginx/sites-enabled/upcode-harbor
  nginx -t
  systemctl enable nginx
  systemctl reload nginx
}

step_initialize_secrets() {
  cd /var/lib/upcode-harbor
  runuser -u "$SERVICE_USER" -- env HOME=/var/lib/upcode-harbor \
    PYTHONPATH="$RELEASE_DIR/upcode-harbor-service" \
    UPCODE_HARBOR_LOG_FILE=/var/log/upcode-harbor/api.log \
    "$RELEASE_DIR/upcode-harbor-service/venv/bin/python3" -c \
    "from lib.cluster_security import ensure_node_tls; from lib.encryption import EncryptionManager; from lib.session_tokens import _get_secret; EncryptionManager.ensure_key_exists(); _get_secret(); ensure_node_tls()"
}

step_install_cli() {
  cat > /usr/local/bin/upcode-harbor <<'EOF'
#!/usr/bin/env bash
exec /opt/upcode-harbor/current/upcode-harbor-cli/venv/bin/python /opt/upcode-harbor/current/upcode-harbor-cli/upcode-harbor "$@"
EOF
  chown root:root /usr/local/bin/upcode-harbor
  chmod 0755 /usr/local/bin/upcode-harbor
}

step_start_and_verify() {
  systemctl enable --now upcode-harbor.target upcode-harbor-health.timer
  systemctl restart upcode-harbor-api.service upcode-harbor-web.service upcode-harbor-worker.service
  /usr/local/libexec/upcode-harbor-health-check wait-api
  /usr/local/libexec/upcode-harbor-health-check wait-web
  /usr/local/libexec/upcode-harbor-post-install-smoke
}

: >"$LOG_FILE"
printf 'Upcode Harbor installer log: %s\n' "$LOG_FILE"
if [[ $RESUME_INSTALLATION == 1 ]]; then
  TOTAL_STEPS=7
  run_step 'Configure mutable state and update trust' step_configure_mutable_state
  run_step 'Install the privileged helper boundary' step_install_privilege_boundary
  run_step 'Install separate systemd units and probes' step_install_systemd_units
  run_step 'Configure the local HTTPS reverse proxy' step_configure_https
  run_step 'Generate application, session, and cluster keys' step_initialize_secrets
  run_step 'Install the CLI launcher' step_install_cli
  run_step 'Start services and run the post-install smoke test' step_start_and_verify
  trap - EXIT
  printf 'Installation resumed successfully. Release: %s\n' "$RELEASE_VERSION"
  print_access_information
  printf 'Status: systemctl status upcode-harbor.target\n'
  printf 'Smoke test: sudo /usr/local/libexec/upcode-harbor-post-install-smoke\n'
  exit 0
fi
TOTAL_STEPS=14
run_step 'Validate locked source and noVNC submodule' step_validate_source
if [[ $REINSTALL == 1 ]]; then
  backup_broken_installation
fi
run_step 'Install core and selected platform packages' step_install_core_packages
run_step "Install or verify Node.js ${NODE_REQUIRED_MAJOR}" step_install_node
run_step 'Install selected platform services' step_install_optional_platforms
run_step 'Create dedicated service accounts and data roots' step_create_service_accounts
run_step "Copy immutable release ${RELEASE_VERSION}" step_copy_release
run_step 'Install locked dependencies and build the release' step_build_release
run_step 'Configure mutable state and update trust' step_configure_mutable_state
run_step 'Install the privileged helper boundary' step_install_privilege_boundary
run_step 'Install separate systemd units and probes' step_install_systemd_units
run_step 'Configure the local HTTPS reverse proxy' step_configure_https
run_step 'Generate application, session, and cluster keys' step_initialize_secrets
run_step 'Install the CLI launcher' step_install_cli
run_step 'Start services and run the post-install smoke test' step_start_and_verify

trap - EXIT
printf 'Installation complete. Release: %s\n' "$RELEASE_VERSION"
[[ -z $REINSTALL_BACKUP_DIR ]] || printf 'Previous installation backup: %s\n' "$REINSTALL_BACKUP_DIR"
print_access_information
printf 'Status: systemctl status upcode-harbor.target\n'
printf 'Smoke test: sudo /usr/local/libexec/upcode-harbor-post-install-smoke\n'
