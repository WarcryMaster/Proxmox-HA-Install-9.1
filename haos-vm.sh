#!/usr/bin/env bash

# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE

source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)

function header_info {
  clear
  cat <<"EOF"
    __  __                        ___              _      __              __     ____  _____
   / / / /___  ____ ___  ___     /   |  __________(_)____/ /_____ _____  / /_   / __ \/ ___/
  / /_/ / __ \/ __ `__ \/ _ \   / /| | / ___/ ___/ / ___/ __/ __ `/ __ \/ __/  / / / /\__ \
 / __  / /_/ / / / / / /  __/  / ___ |(__  |__  ) (__  ) /_/ /_/ / / / / /_   / /_/ /___/ /
/_/ /_/\____/_/ /_/ /_/\___/  /_/  |_/____/____/_/____/\__/\__,_/_/ /_/\__/   \____//____/
EOF
}

header_info
echo -e "\n Loading..."

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
RANDOM_UUID="$(cat /proc/sys/kernel/random/uuid)"
VERSIONS=(stable beta dev)
DISK_SIZE="32G"

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
HA=$(echo "\033[1;34m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")

BOLD=$(echo "\033[1m")
BFR="\\r\\033[K"
TAB="  "

CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"
INFO="${TAB}💡${TAB}${CL}"
OS="${TAB}🖥️${TAB}${CL}"
CONTAINERTYPE="${TAB}📦${TAB}${CL}"
DISKSIZE="${TAB}💾${TAB}${CL}"
CPUCORE="${TAB}🧠${TAB}${CL}"
RAMSIZE="${TAB}🛠️${TAB}${CL}"
CONTAINERID="${TAB}🆔${TAB}${CL}"
HOSTNAME="${TAB}🏠${TAB}${CL}"
BRIDGE="${TAB}🌉${TAB}${CL}"
GATEWAY="${TAB}🌐${TAB}${CL}"
DEFAULT="${TAB}⚙️${TAB}${CL}"
MACADDRESS="${TAB}🔗${TAB}${CL}"
VLANTAG="${TAB}🏷️${TAB}${CL}"
CREATING="${TAB}🚀${TAB}${CL}"
ADVANCED="${TAB}🧩${TAB}${CL}"
CLOUD="${TAB}☁️${TAB}${CL}"

THIN="discard=on,ssd=1,"

set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "INTERRUPTED"' SIGINT
trap 'post_update_to_api "failed" "TERMINATED"' SIGTERM

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  post_update_to_api "failed" "${command}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null || true
    qm destroy $VMID &>/dev/null || true
  fi
}

function cleanup() {
  popd >/dev/null
  post_update_to_api "done" "none"
  rm -rf $TEMP_DIR
}

TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Homeassistant OS VM" --yesno "This will create a New Homeassistant OS VM. Proceed?" 10 58; then
  :
else
  header_info && echo -e "${CROSS}${RD}User exited script${CL}\n" && exit
fi

# ---- FUNCIONES DE MENÚ Y DESCARGA ----
function msg_info() { local msg="$1"; echo -ne "${TAB}${YW}${msg}${CL}"; }
function msg_ok() { local msg="$1"; echo -e "${BFR}${CM}${GN}${msg}${CL}"; }
function msg_error() { local msg="$1"; echo -e "${BFR}${CROSS}${RD}${msg}${CL}"; }

function check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    msg_error "Please run as root"
    exit 1
  fi
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    msg_error "Only amd64 is supported"
    exit 1
  fi
}

function ensure_pv() {
  if ! command -v pv &>/dev/null; then
    apt-get update -qq
    apt-get install -y pv
  fi
}

function download_and_validate_xz() {
  local url="$1"
  local file="$2"
  if [[ -s "$file" ]]; then
    if xz -t "$file" &>/dev/null; then
      msg_ok "Using cached image $(basename "$file")"
      return
    else
      rm -f "$file"
    fi
  fi
  msg_info "Downloading $(basename "$file")...\n"
  curl -fSL -o "$file" "$url"
  if ! xz -t "$file" &>/dev/null; then
    msg_error "Downloaded file corrupted"
    rm -f "$file"
    exit 1
  fi
  msg_ok "Downloaded and validated $(basename "$file")"
}

function extract_xz_with_pv() {
  local file="$1"
  local target="$2"
  msg_info "Decompressing $(basename "$file")\n"
  xz -dc "$file" | pv -N "Extracting" >"$target"
  msg_ok "Decompressed to $target"
}

# ---- AJUSTES POR DEFECTO ----
BRANCH="stable"
VMID=$(get_valid_nextid)
HN="haos-${VMID}"
CORE_COUNT=2
RAM_SIZE=4096
BRIDGE="vmbr0"
STORAGE="local-lvm"
DISK_SIZE="32G"

# ---- DESCARGA DE IMAGEN ----
URL="https://github.com/home-assistant/operating-system/releases/download/${BRANCH}/haos_ova-${BRANCH}.qcow2.xz"
CACHE_DIR="/var/lib/vz/template/cache"
CACHE_FILE="$CACHE_DIR/$(basename "$URL")"
FILE_IMG="/var/lib/vz/template/tmp/${CACHE_FILE##*/%.xz}"

mkdir -p "$CACHE_DIR" "$(dirname "$FILE_IMG")"
download_and_validate_xz "$URL" "$CACHE_FILE"
extract_xz_with_pv "$CACHE_FILE" "$FILE_IMG"

# ---- CREAR VM ----
msg_info "Creating VM shell...\n"
qm create "$VMID" -machine q35 -bios ovmf -agent 1 -tablet 0 -localtime 1 \
  -cores "$CORE_COUNT" -memory "$RAM_SIZE" -name "$HN" \
  -net0 "virtio,bridge=$BRIDGE,macaddr=$GEN_MAC" \
  -onboot 1 -ostype l26 -scsihw virtio-scsi-pci
msg_ok "VM shell created"

# ---- CREAR EFI ----
msg_info "Creating EFI disk...\n"
qm set "$VMID" --efidisk0 "${STORAGE}:size=512M,format=qcow2,efitype=4m"

# ---- IMPORTAR DISCO ROOT ----
msg_info "Importing root disk...\n"
qm importdisk "$VMID" "$FILE_IMG" "$STORAGE" --format qcow2

DISK_REF=$(pvesm list "$STORAGE" | awk -v id="$VMID" '$5 ~ ("vm-"id"-disk-") {print $1}' | tail -n1)
if [ -z "$DISK_REF" ]; then
  msg_error "Failed to detect imported disk"
  exit 1
fi
msg_ok "Imported disk: $DISK_REF"

# ---- ASIGNAR DISCO Y CONFIG ----
msg_info "Attaching root disk and configuring VM...\n"
qm set "$VMID" \
  --scsi0 "$DISK_REF,ssd=1,discard=on" \
  --boot order=efidisk0,scsi0 \
  --serial0 socket \
  --agent enabled=1
qm resize "$VMID" scsi0 "$DISK_SIZE"
msg_ok "Disk resized to $DISK_SIZE"

# ---- INICIO ----
qm start "$VMID"
msg_ok "Home Assistant OS VM started! VMID=$VMID"

rm -f "$FILE_IMG"
msg_ok "Temporary files cleaned"
