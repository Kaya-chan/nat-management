#!/usr/bin/env bash
set -euo pipefail
# ==========================================
# VPS NAT + LXC Manager (Shell Automation)
# Commands:
#   setup
#   create <name>
#   start <name>
#   stop <name>
#   delete <name>
# ==========================================

LOCK_FILE="/var/lock/vps-nat.lock"
DEFAULT_BRIDGE="br-nat"
DEFAULT_SUBNET="10.10.0.0/24"
DEFAULT_GW_IP="10.10.0.1"
DEFAULT_WAN_IF="eth0"
DEFAULT_DNS="1.1.1.1 8.8.8.8"
DEFAULT_SSH_PRIV_PORT="22"
STATE_DIR="/var/lib/vps-nat"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

gen_idnat() { 
  echo "nat-$(tr -dc 'a-f0-9' </dev/urandom | head -c 8)"
}
log()  { echo -e "[\e[32mINFO\e[0m] $*"; }
warn() { echo -e "[\e[33mWARN\e[0m] $*" >&2; }
die()  { echo -e "[\e[31mERR\e[0m]  $*" >&2; exit 1; }

need_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root (sudo)."
}

with_lock() {
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "Another vps process is running. Try again later."
}

detect_virt() {
  if command -v systemd-detect-virt >/dev/null 2>&1; then
    local v
    v="$(systemd-detect-virt || true)"
    if [[ "$v" == "openvz" || "$v" == "lxc" ]]; then
      die "Virtualization detected: $v. LXC inside $v usually won't work. Use KVM/baremetal."
    fi
    log "Virtualization: ${v:-unknown} (OK)"
  else
    warn "systemd-detect-virt not found. Skipping virt check."
  fi
}


ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

os_id() {
  . /etc/os-release
  echo "${ID:-}"
}

os_like() {
  . /etc/os-release
  echo "${ID_LIKE:-}"
}

ensure_ubuntu_debian() {
  local id like
  id="$(os_id)"
  like="$(os_like)"
  if [[ "$id" != "ubuntu" && "$id" != "debian" && "$like" != *"debian"* ]]; then
    die "This script is intended for Ubuntu/Debian. Detected: $id ($like)"
  fi
}

# ------------------------
# iptables helpers (tagged rules)
# ------------------------
iptables_has_rule() {
  # usage: iptables_has_rule <table> <chain> <args...>
  local table="$1"; shift
  local chain="$1"; shift
  iptables -t "$table" -C "$chain" "$@" >/dev/null 2>&1
}

iptables_add_once() {
  local table="$1"; shift
  local chain="$1"; shift
  if ! iptables_has_rule "$table" "$chain" "$@"; then
    iptables -t "$table" -A "$chain" "$@"
  fi
}

# Remove iptables rules by comment tag (safe-ish)
iptables_remove_by_tag() {
  local tag="$1"
  # Delete from nat PREROUTING
  bash -lc "iptables -t nat -S PREROUTING | nl -ba | grep -F -- '$tag' | awk '{print \$1}' | sort -rn | while read -r n; do iptables -t nat -D PREROUTING \"\$n\"; done" || true
  # Delete from filter FORWARD
  bash -lc "iptables -S FORWARD | nl -ba | grep -F -- '$tag' | awk '{print \$1}' | sort -rn | while read -r n; do iptables -D FORWARD \"\$n\"; done" || true
}

get_mem_used_bytes() {
  local name="$1"
  # cgroup v2: memory.current
  lxc-cgroup -n "$name" memory.current 2>/dev/null || echo ""
}

get_mem_max_bytes() {
  local name="$1"
  lxc-cgroup -n "$name" memory.max 2>/dev/null || echo ""
}

get_cpu_usage_pct_1s() {
  local name="$1"
  local a b
  a="$(lxc-cgroup -n "$name" cpu.stat 2>/dev/null | awk '/usage_usec/ {print $2}' || true)"
  [[ -n "$a" ]] || { echo ""; return 0; }
  sleep 1
  b="$(lxc-cgroup -n "$name" cpu.stat 2>/dev/null | awk '/usage_usec/ {print $2}' || true)"
  [[ -n "$b" ]] || { echo ""; return 0; }

  # delta usage_usec over 1s -> percent of 1 CPU = delta/1_000_000*100
  local delta=$(( b - a ))
  # if multiple CPUs assigned, percent can exceed 100; keep raw
  awk -v d="$delta" 'BEGIN { printf "%.1f", (d/1000000)*100 }'
}

get_disk_used_pct() {
  local name="$1"
  # Output example: "23%"
  lxc-attach -n "$name" -- bash -lc "df -P / | tail -1 | awk '{print \$5}'" 2>/dev/null || echo ""
}

get_disk_used_human() {
  local name="$1"
  lxc-attach -n "$name" -- bash -lc "df -hP / | tail -1 | awk '{print \$3\"/\"\$2\" (\"\$5\")\"}'" 2>/dev/null || echo ""
}

is_port_listening() {
  local port="$1"
  ss -lntH 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"
}

is_port_forwarded_iptables() {
  local port="$1"
  # cek DNAT rule existing di PREROUTING nat
  iptables -t nat -S PREROUTING 2>/dev/null | grep -qE -- "--dport ${port}\b"
}

assert_port_free() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || die "Invalid port: $port"
  (( port >= 1 && port <= 65535 )) || die "Port out of range: $port"

  if is_port_listening "$port"; then
    die "Port $port is already LISTENING on host (ss). Choose another."
  fi

  if is_port_forwarded_iptables "$port"; then
    die "Port $port already used in iptables PREROUTING DNAT. Choose another."
  fi
}

is_ip_in_subnet_24() {
  # minimal check: 10.10.0.X
  local ip="$1"
  [[ "$ip" =~ ^10\.10\.0\.[0-9]{1,3}$ ]]
}

is_ip_allocated_in_state() {
  local ip="$1"
  shopt -s nullglob
  local f
  for f in "$STATE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    [[ "$(jq -r '.private_ip // empty' "$f" 2>/dev/null || true)" == "$ip" ]] && return 0
  done
  return 1
}

is_ip_used_on_bridge() {
  local ip="$1"
  # best effort: check ARP/neigh table (aktif kalau ada traffic)
  ip neigh show 2>/dev/null | grep -qE "\\b${ip}\\b"
}

assert_ip_free() {
  local ip="$1"
  is_ip_in_subnet_24 "$ip" || die "IP $ip not in expected subnet 10.10.0.0/24 (adjust checker if needed)."

  if is_ip_allocated_in_state "$ip"; then
    die "IP $ip already allocated in state files."
  fi

  # Optional best-effort check (tidak selalu akurat kalau host belum pernah ngomong ke IP tsb)
  if is_ip_used_on_bridge "$ip"; then
    die "IP $ip appears in host neighbor table (ip neigh). Likely in use."
  fi
}

# ------------------------
# tc helpers
# ------------------------
tc_apply_limit() {
  local dev="$1" rate="$2"
  # remove existing qdisc if present
  tc qdisc del dev "$dev" root >/dev/null 2>&1 || true
  tc qdisc add dev "$dev" root tbf rate "$rate" burst 32kbit latency 400ms
}

tc_remove_limit() {
  local dev="$1"
  tc qdisc del dev "$dev" root >/dev/null 2>&1 || true
}

# ------------------------
# netplan / bridge setup
# ------------------------
find_wan_if_auto() {
  # best-effort: interface with default route
  local ifc
  ifc="$(ip route | awk '/default/ {print $5; exit}')"
  echo "${ifc:-$DEFAULT_WAN_IF}"
}

apply_sysctl_ip_forward() {
  log "Enable IPv4 forwarding..."
  echo 1 > /proc/sys/net/ipv4/ip_forward
  if ! grep -qE '^\s*net\.ipv4\.ip_forward\s*=\s*1\s*$' /etc/sysctl.conf; then
    # uncomment if exists, else append
    if grep -qE '^\s*#\s*net\.ipv4\.ip_forward\s*=' /etc/sysctl.conf; then
      sed -i 's/^\s*#\s*net\.ipv4\.ip_forward\s*=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    else
      echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf
    fi
  fi
  sysctl -p >/dev/null
}

ensure_packages_setup() {
  log "apt update/upgrade + install dependencies..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -y
  apt upgrade -y
  apt install -y lxc lxc-templates uidmap iptables iptables-persistent bridge-utils jq curl dnsutils lvm2
  apt install -y lxcfs netfilter-persistent qemu-utils cloud-image-utils debootstrap uuid-runtime

  # tc lives in iproute2 (usually installed)
  apt install -y iproute2
}

ensure_bridge_ifupdown() {
  local bridge="$1" gw_ip="$2"

  if ip link show "$bridge" >/dev/null 2>&1; then
    log "Bridge $bridge already exists (skip create)."
    return
  fi

  local ifdir="/etc/network/interfaces.d"
  local iffile="${ifdir}/99-${bridge}.cfg"

  mkdir -p "$ifdir"

  log "Netplan not found. Creating ifupdown bridge $bridge with IP $gw_ip/24 (NAT subnet)..."
  cat > "$iffile" <<EOF
auto ${bridge}
iface ${bridge} inet static
  address ${gw_ip}
  netmask 255.255.255.0
  bridge_ports none
  bridge_stp off
  bridge_fd 0
EOF

  # Bring up now (best effort).
  command -v ifdown >/dev/null 2>&1 && ifdown "$bridge" >/dev/null 2>&1 || true
  command -v ifup  >/dev/null 2>&1 && ifup  "$bridge" >/dev/null 2>&1 || true

  # Fallback: create bridge live if ifup didn't create it.
  if ! ip link show "$bridge" >/dev/null 2>&1; then
    ip link add name "$bridge" type bridge >/dev/null 2>&1 || true
    ip addr add "${gw_ip}/24" dev "$bridge" >/dev/null 2>&1 || true
    ip link set "$bridge" up >/dev/null 2>&1 || true
  fi

  ip link show "$bridge" >/dev/null 2>&1 || die "Failed to bring up bridge $bridge. Check /etc/network/interfaces(.d)."
}

ensure_bridge_netplan() {
  local bridge="$1" gw_ip="$2"
  local netplan_file="/etc/netplan/99-${bridge}.yaml"

  if [[ ! -d /etc/netplan ]] || ! command -v netplan >/dev/null 2>&1; then
    ensure_bridge_ifupdown "$bridge" "$gw_ip"
    return
  fi

  if ip link show "$bridge" >/dev/null 2>&1; then
    log "Bridge $bridge already exists (skip netplan create)."
    return
  fi

  # Try to detect primary WAN interface config file; we won't destroy existing config.
  log "Creating netplan bridge $bridge with IP $gw_ip/24 (NAT subnet)..."
  cat > "$netplan_file" <<EOF
network:
  version: 2
  renderer: networkd
  bridges:
    ${bridge}:
      interfaces: []
      addresses:
        - ${gw_ip}/24
      dhcp4: false
      parameters:
        stp: false
EOF

  netplan apply
  ip link show "$bridge" >/dev/null 2>&1 || die "Failed to bring up bridge $bridge. Check netplan."
}

ensure_base_nat_rules() {
  local subnet="$1" wan="$2"
  log "Ensuring base NAT rules for subnet $subnet via $wan ..."
  iptables_add_once nat POSTROUTING -s "$subnet" -o "$wan" -j MASQUERADE
  iptables_add_once filter FORWARD -s "$subnet" -j ACCEPT
  iptables_add_once filter FORWARD -d "$subnet" -m state --state ESTABLISHED,RELATED -j ACCEPT

  netfilter-persistent save >/dev/null 2>&1 || true
}

ensure_lxc_default_conf() {
  local bridge="$1"
  local f="/etc/lxc/default.conf"

  log "Ensuring /etc/lxc/default.conf uses bridge $bridge ..."
  touch "$f"

  # Replace or append lxc.net.0.*
  grep -q '^lxc.net.0.type' "$f" && sed -i 's/^lxc\.net\.0\.type.*/lxc.net.0.type = veth/' "$f" || echo 'lxc.net.0.type = veth' >> "$f"
  grep -q '^lxc.net.0.link' "$f" && sed -i "s/^lxc\.net\.0\.link.*/lxc.net.0.link = ${bridge}/" "$f" || echo "lxc.net.0.link = ${bridge}" >> "$f"
  grep -q '^lxc.net.0.flags' "$f" && sed -i 's/^lxc\.net\.0\.flags.*/lxc.net.0.flags = up/' "$f" || echo 'lxc.net.0.flags = up' >> "$f"

  # hwaddr line optional
  grep -q '^lxc.net.0.hwaddr' "$f" || echo 'lxc.net.0.hwaddr = 00:16:3e:xx:xx:xx' >> "$f"
}

# ------------------------
# LXC Create helpers
# ------------------------
lxc_exists() {
  local name="$1"
  lxc-info -n "$name" >/dev/null 2>&1
}

lxc_state() {
  local name="$1"
  lxc-info -n "$name" -sH 2>/dev/null || true
}

lxc_wait_for_state() {
  local name="$1" want="$2" timeout="${3:-30}"
  local i=0
  while (( i < timeout )); do
    [[ "$(lxc_state "$name")" == "$want" ]] && return 0
    sleep 1
    ((i++))
  done
  return 1
}

container_config_path() {
  local name="$1"
  echo "/var/lib/lxc/${name}/config"
}

state_file_by_idnat() {
  local idNat="$1"
  echo "${STATE_DIR}/${idNat}.json"
}

find_idnat_by_name() {
  local name="$1"
  local f
  shopt -s nullglob
  for f in "$STATE_DIR"/*.json; do
    [[ -f "$f" ]] || continue
    if [[ "$(jq -r '.name // empty' "$f" 2>/dev/null || true)" == "$name" ]]; then
      basename "$f" .json
      return 0
    fi
  done
  return 1
}

read_state() {
  local file="$1" key="$2"
  jq -r "$key // empty" "$file" 2>/dev/null || true
}

nat_apply_from_state() {
  local f="$1"

  local idNat name ip ssh_port priv_ssh tag veth wan subnet bw
  idNat="$(read_state "$f" '.idNat')"
  name="$(read_state "$f" '.name')"
  ip="$(read_state "$f" '.private_ip')"
  ssh_port="$(read_state "$f" '.ssh_public_port')"
  priv_ssh="$(read_state "$f" '.private_ssh_port')"
  tag="$(read_state "$f" '.tag')"
  veth="$(read_state "$f" '.veth')"
  wan="$(read_state "$f" '.wan')"
  subnet="$(read_state "$f" '.subnet')"
  bw="$(read_state "$f" '.bw')"

  if [[ -z "$idNat" ]]; then
    local derived_idNat
    derived_idNat="$(basename "$f" .json)"
    if [[ -n "$derived_idNat" ]]; then
      idNat="$derived_idNat"
      warn "State missing idNat, using filename: $f"
    fi
  fi

  local missing=()
  [[ -n "$idNat" ]] || missing+=("idNat")
  [[ -n "$ip" ]] || missing+=("private_ip")
  [[ -n "$ssh_port" ]] || missing+=("ssh_public_port")
  if (( ${#missing[@]} > 0 )); then
    warn "Invalid state (missing ${missing[*]}): $f"
    return 1
  fi

  [[ -n "$wan" ]] || wan="$(find_wan_if_auto)"
  [[ -n "$subnet" ]] || subnet="$DEFAULT_SUBNET"
  ensure_base_nat_rules "$subnet" "$wan"

  local fallback_tag="vps:${idNat}:name=${name}:ssh:${ssh_port}->${ip}:${priv_ssh:-22}"

  iptables_add_once nat PREROUTING -p tcp --dport "$ssh_port" -j DNAT --to-destination "${ip}:${priv_ssh:-22}" -m comment --comment "${tag:-$fallback_tag}"
  iptables_add_once filter FORWARD -p tcp -d "$ip" --dport "${priv_ssh:-22}" -j ACCEPT -m comment --comment "${tag:-$fallback_tag}"

  if [[ -n "$bw" && -n "$veth" ]]; then
    if ip link show "$veth" >/dev/null 2>&1; then
      tc_apply_limit "$veth" "$bw"
    else
      warn "veth not found ($veth) for idNat=$idNat name=$name (container down?)"
    fi
  fi
}

# ------------------------
# create command implementation
# ------------------------
cmd_info() {
  local q="$1"
  [[ -n "$q" ]] || die "Missing name or idNat"

  local idNat="$q"
  local f=""

  # if not nat-*, treat as name
  if [[ "$q" != nat-* ]]; then
    idNat="$(find_idnat_by_name "$q" || true)"
    [[ -n "$idNat" ]] || die "State not found for name '$q'"
  fi

  f="$(state_file_by_idnat "$idNat")"
  [[ -f "$f" ]] || die "State file not found: $f"

  local name lxc_name ip ssh_port veth bw ram cpu disk os
  name="$(read_state "$f" '.name')"
  lxc_name="$name" # di script kamu lxc_name==name
  ip="$(read_state "$f" '.private_ip')"
  ssh_port="$(read_state "$f" '.ssh_public_port')"
  veth="$(read_state "$f" '.veth')"
  bw="$(read_state "$f" '.bw')"
  ram="$(read_state "$f" '.ram_mb')"
  cpu="$(read_state "$f" '.cpu')"
  disk="$(read_state "$f" '.disk_gb')"
  os="$(read_state "$f" '.os')"

  echo ""
  log "INFO (from state):"
  echo "  idNat      : $idNat"
  echo "  name       : $name"
  echo "  private_ip : $ip"
  echo "  ssh_port   : $ssh_port"
  echo "  veth       : $veth"
  echo "  bw         : ${bw:-none}"
  echo "  ram_mb     : ${ram:-}"
  echo "  cpu        : ${cpu:-}"
  echo "  disk_gb    : ${disk:-}"
  echo "  os         : ${os:-}"

  echo ""
  log "LXC status:"
  if lxc_exists "$lxc_name"; then
    echo "  state: $(lxc_state "$lxc_name")"
    lxc-info -n "$lxc_name" || true
  else
    warn "Container '$lxc_name' not found."
  fi

echo ""
log "Live metrics:"
if lxc_exists "$name"; then
  local mem_used mem_max cpu_pct disk
  mem_used="$(get_mem_used_bytes "$name")"
  mem_max="$(get_mem_max_bytes "$name")"
  cpu_pct="$(get_cpu_usage_pct_1s "$name")"
  disk="$(get_disk_used_human "$name")"

  echo "  mem_used_bytes : ${mem_used:-}"
  echo "  mem_max_bytes  : ${mem_max:-}"
  echo "  cpu_pct_1s     : ${cpu_pct:-}"
  echo "  disk_root      : ${disk:-}"
else
  echo "  (container absent)"
fi

  echo ""
  log "iptables rules (match idNat):"
  iptables -t nat -S PREROUTING | grep -F "vps:${idNat}:" || true
  iptables -S FORWARD | grep -F "vps:${idNat}:" || true

  echo ""
  log "tc qdisc (if any):"
  if [[ -n "$veth" ]]; then
    tc qdisc show dev "$veth" 2>/dev/null || true
  fi
}

cmd_list() {
  echo ""
  log "LIST (state files):"
  printf "%-14s %-14s %-14s %-6s %-9s %-14s %-18s\n" "idNat" "name" "private_ip" "ssh" "state" "mem_used" "disk(/)"
  printf "%-14s %-14s %-14s %-6s %-9s %-14s %-18s\n" "-----" "----" "----------" "---" "-----" "-------" "-------"

  shopt -s nullglob
  local f idNat name ip ssh st mem disk
  for f in "$STATE_DIR"/*.json; do
    idNat="$(basename "$f" .json)"
    name="$(jq -r '.name // empty' "$f")"
    ip="$(jq -r '.private_ip // empty' "$f")"
    ssh="$(jq -r '.ssh_public_port // empty' "$f")"

    if [[ -n "$name" ]] && lxc_exists "$name"; then
      st="$(lxc_state "$name")"
      mem="$(get_mem_used_bytes "$name")"
      disk="$(get_disk_used_human "$name")"
    else
      st="absent"
      mem=""
      disk=""
    fi

    printf "%-14s %-14s %-14s %-6s %-9s %-14s %-18s\n" "$idNat" "$name" "$ip" "$ssh" "$st" "${mem:-}" "${disk:-}"
  done

  echo ""
  log "Tip:"
  echo "  ./vps info <name|idNat>"
}


cmd_reconcile() {
  log "Reconciling NAT + tc from state directory: $STATE_DIR"
  ensure_cmd jq
  ensure_cmd iptables
  ensure_cmd tc

  local ok=0 fail=0
  shopt -s nullglob
  local f idNat name

  for f in "$STATE_DIR"/*.json; do
    idNat="$(basename "$f" .json)"
    name="$(read_state "$f" '.name')"

    # Skip if state is broken
    if [[ -z "$name" ]]; then
      warn "Skip invalid state: $f"
      ((fail++)) || true
      continue
    fi

    # Only apply tc if container exists (veth appears)
    # NAT rules can be applied regardless (but won't forward unless container has IP)
    log "Reconcile: idNat=$idNat name=$name"
    if nat_apply_from_state "$f"; then
      ((ok++)) || true
    else
      warn "Failed reconcile: $f"
      ((fail++)) || true
    fi
  done

  netfilter-persistent save >/dev/null 2>&1 || true

  log "Reconcile done ✅ ok=$ok fail=$fail"
  if (( fail > 0 )); then
    return 1
  fi
}

cmd_create() {
  local name="$1"; shift || true

  # Defaults
  local os_spec="ubuntu:jammy"
  local ip=""
  local ssh_port=""
  local ram="1024"     # MB
  local cpu="1"        # vCPU
  local bw=""          # e.g. 10mbit
  local disk=""        # GB (requires --vg)
  local vg=""          # VG name for lvm backend
  local bridge="$DEFAULT_BRIDGE"
  local subnet="$DEFAULT_SUBNET"
  local wan="$DEFAULT_WAN_IF"
  local hostname="$name"
  local hosts_map=""   # "google.com=5.180.255.138,foo.com=1.2.3.4"
  local dns="$DEFAULT_DNS"
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --os) os_spec="$2"; shift 2;;
      --ip) ip="$2"; shift 2;;
      --ssh-port) ssh_port="$2"; shift 2;;
      --ram) ram="$2"; shift 2;;
      --cpu) cpu="$2"; shift 2;;
      --bw) bw="$2"; shift 2;;
      --disk) disk="$2"; shift 2;;
      --vg) vg="$2"; shift 2;;
      --bridge) bridge="$2"; shift 2;;
      --subnet) subnet="$2"; shift 2;;
      --wan) wan="$2"; shift 2;;
      --hostname) hostname="$2"; shift 2;;
      --hosts) hosts_map="$2"; shift 2;;
      --dns) dns="$2"; shift 2;;
      -h|--help) usage_create; exit 0;;
      *) die "Unknown option: $1";;
    esac
  done

  [[ -n "$ip" ]] || die "Missing --ip (example: --ip 10.10.0.10)"
  [[ -n "$ssh_port" ]] || die "Missing --ssh-port (example: --ssh-port 22010)"

  assert_port_free "$ssh_port"
  assert_ip_free "$ip"

  # Validate os_spec
  local distro release
  distro="${os_spec%%:*}"
  release="${os_spec##*:}"
  [[ -n "$distro" && -n "$release" && "$distro" != "$release" ]] || die "Invalid --os. Use format ubuntu:jammy or debian:bookworm"

  # Disk limit requires LVM VG
  if [[ -n "$disk" ]]; then
    [[ -n "$vg" ]] || die "--disk requires --vg <VGNAME> for real disk quota (LVM)."
    ensure_cmd vgs
    vgs "$vg" >/dev/null 2>&1 || die "VG '$vg' not found. Create/choose an LVM volume group first."
  fi

  if lxc_exists "$name"; then
    die "Container '$name' already exists."
  fi

  # Ensure base setup prerequisites exist (bridge/nat)
  ip link show "$bridge" >/dev/null 2>&1 || die "Bridge '$bridge' not found. Run: ./vps setup"
  ensure_base_nat_rules "$subnet" "$wan"

  # Create container with optional LVM backend disk limit
  log "Creating container: $name (OS=${distro}:${release}) ..."
  local create_ok=0
  {
    if [[ -n "$disk" ]]; then
      log "Using LVM backend (VG=$vg, disk=${disk}G) ..."
      # lxc-create supports -B lvm with --vgname and --fssize
      lxc-create -n "$name" -t download -B lvm --vgname "$vg" --fssize "${disk}G" -- -d "$distro" -r "$release" -a amd64
    else
      lxc-create -n "$name" -t download -- -d "$distro" -r "$release" -a amd64
    fi
    create_ok=1
  } || create_ok=0

  if [[ "$create_ok" -ne 1 ]]; then
    die "Failed to create LXC container."
  fi
  if [[ ! -f "/var/lib/lxc/$name/config" ]]; then
    die "Container config not found: /var/lib/lxc/$name/config (lxc-create incomplete)."
  fi

  # Rollback handler
  local idNat
  idNat="$(gen_idnat)"

  local tag="vps:${idNat}:name=${name}:ssh:${ssh_port}->${ip}:${DEFAULT_SSH_PRIV_PORT}"
  local veth="veth-${name}"
  local cfg
  cfg="$(container_config_path "$name")"

  rollback() {
    warn "Rolling back container '$name' ..."
    # remove iptables + tc + destroy container
    iptables_remove_by_tag "$tag" || true
    tc_remove_limit "$veth" || true
    lxc-stop -n "$name" >/dev/null 2>&1 || true
    lxc-destroy -n "$name" >/dev/null 2>&1 || true
  }
  trap rollback ERR

  # Configure networking + fixed veth name for tc shaping
  log "Configuring network IP/gateway + veth pair..."
  {
    echo ""
    echo "# --- managed by vps script ---"
    echo "lxc.net.0.link = ${bridge}"
    echo "lxc.net.0.flags = up"
    echo "lxc.net.0.type = veth"
    echo "lxc.net.0.veth.pair = ${veth}"
    echo "lxc.net.0.ipv4.address = ${ip}/24"
    echo "lxc.net.0.ipv4.gateway = ${DEFAULT_GW_IP}"
  } >> "$cfg"

  # Resource limits
  log "Applying limits: RAM=${ram}MB CPU=${cpu}vCPU BW=${bw:-none} DISK=${disk:-default}..."
  # cgroup2 memory
  {
    echo "lxc.cgroup2.memory.max = ${ram}M"
    echo "lxc.cgroup2.memory.swap.max = 0"
  } >> "$cfg"

  # CPU quota: cpu.max = quota period (in microseconds)
  # period 100000us; quota = cpu * 100000
  local period=100000
  local quota=$(( cpu * period ))
  echo "lxc.cgroup2.cpu.max = ${quota} ${period}" >> "$cfg"

  # Start container
  log "Starting container..."
  lxc-start -n "$name" -d
  lxc_wait_for_state "$name" "RUNNING" 30 || die "Container didn't reach RUNNING state."

  # Set hostname inside container
  log "Setting hostname: $hostname"
  lxc-attach -n "$name" -- bash -lc "echo '$hostname' > /etc/hostname; hostname '$hostname' || true; sed -i 's/^127.0.1.1.*/127.0.1.1\t$hostname/' /etc/hosts || true; grep -q '^127.0.1.1' /etc/hosts || echo -e '127.0.1.1\t$hostname' >> /etc/hosts"

  # Set DNS inside container (simple resolv.conf)
  log "Setting DNS: $dns"
  local resolv=""
  for d in $dns; do resolv+="nameserver $d"$'\n'; done
  lxc-attach -n "$name" -- bash -lc "printf '%s' \"$resolv\" > /etc/resolv.conf"

  # /etc/hosts mapping (optional)
  if [[ -n "$hosts_map" ]]; then
    log "Applying /etc/hosts mappings: $hosts_map"
    IFS=',' read -r -a pairs <<< "$hosts_map"
    for p in "${pairs[@]}"; do
      local host="${p%%=*}"
      local addr="${p##*=}"
      [[ -n "$host" && -n "$addr" ]] || die "Invalid --hosts entry: $p (use domain=ip)"
      lxc-attach -n "$name" -- bash -lc "grep -qE '\\s${host}\$' /etc/hosts && sed -i \"s/.*\\s${host}\$/${addr} ${host}/\" /etc/hosts || echo \"${addr} ${host}\" >> /etc/hosts"
    done
  fi

  # Ensure SSH installed and running in container (ubuntu/debian)
  log "Installing SSH server inside container (if needed)..."
  lxc-attach -n "$name" -- bash -lc "apt-get update -y && apt-get install -y openssh-server >/dev/null; systemctl enable ssh >/dev/null 2>&1 || true; systemctl restart ssh || service ssh restart"

  # Set root password (random)
  local pass
  pass="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 14)"
  log "Setting root password..."
  lxc-attach -n "$name" -- bash -lc "echo 'root:${pass}' | chpasswd"

  # NAT port forward SSH
  log "Adding SSH port-forward: ${ssh_port} -> ${ip}:${DEFAULT_SSH_PRIV_PORT}"
  iptables_add_once nat PREROUTING -p tcp --dport "$ssh_port" -j DNAT --to-destination "${ip}:${DEFAULT_SSH_PRIV_PORT}" -m comment --comment "$tag"
  iptables_add_once filter FORWARD -p tcp -d "$ip" --dport "$DEFAULT_SSH_PRIV_PORT" -j ACCEPT -m comment --comment "$tag"
  netfilter-persistent save >/dev/null 2>&1 || true

  # Bandwidth limit via tc (optional)
  if [[ -n "$bw" ]]; then
    log "Applying bandwidth limit on host veth '${veth}': ${bw}"
    ip link show "$veth" >/dev/null 2>&1 || die "Host veth '${veth}' not found. (Container network may be misconfigured.)"
    tc_apply_limit "$veth" "$bw"
  fi

  # Smoke test internet
  log "Testing internet inside container..."
  lxc-attach -n "$name" -- bash -lc "ping -c 1 -W 2 1.1.1.1 >/dev/null && echo 'OK: internet reachable' || (echo 'WARN: cannot reach internet' && exit 0)"

  trap - ERR
  local state_file="${STATE_DIR}/${idNat}.json"
  cat > "$state_file" <<EOF
{
  "idNat": "${idNat}",
  "name": "${name}",
  "hostname": "${hostname}",
  "private_ip": "${ip}",
  "ssh_public_port": ${ssh_port},
  "private_ssh_port": ${DEFAULT_SSH_PRIV_PORT},
  "veth": "${veth}",
  "bridge": "${bridge}",
  "subnet": "${subnet}",
  "wan": "${wan}",
  "ram_mb": ${ram},
  "cpu": ${cpu},
  "bw": "${bw}",
  "disk_gb": "${disk}",
  "tag": "${tag}"
}
EOF
chmod 600 "$state_file"

  echo ""
  log "DONE ✅ Container created:"
  echo "  ID      : $idNat"
  echo "  Name      : $name"
  echo "  Hostname  : $hostname"
  echo "  Private IP: $ip"
  echo "  SSH       : ssh root@<HOST_PUBLIC_IP> -p $ssh_port"
  echo "  Password  : $pass"
  if [[ -n "$bw" ]]; then echo "  Bandwidth : $bw"; fi
  echo "  RAM       : ${ram}MB"
  echo "  CPU       : ${cpu} vCPU (quota)"
  if [[ -n "$disk" ]]; then echo "  Disk      : ${disk}GB (LVM backend)"; else echo "  Disk      : default (no hard quota)"; fi
}

cmd_delete_nat() {
  local idNat="$1"
  [[ -n "$idNat" ]] || die "Missing idNat"

  local state_file="${STATE_DIR}/${idNat}.json"
  local tag_prefix="vps:${idNat}:"
  local veth=""

  if [[ -f "$state_file" ]]; then
    veth="$(jq -r '.veth // empty' "$state_file" 2>/dev/null || true)"
  fi

  log "Deleting NAT rules for idNat=$idNat ..."
  iptables_remove_by_tag "$tag_prefix" || true
  netfilter-persistent save >/dev/null 2>&1 || true

  if [[ -n "$veth" ]]; then
    log "Removing tc limit on $veth ..."
    tc_remove_limit "$veth" || true
  fi

  log "Done delete-nat ✅"
}


cmd_get() {
  local idNat="$1"
  [[ -n "$idNat" ]] || die "Missing idNat"

  local state_file="${STATE_DIR}/${idNat}.json"
  if [[ -f "$state_file" ]]; then
    log "State file:"
    cat "$state_file"
    echo ""
  else
    warn "State file not found: $state_file (will still try to lookup iptables by tag)"
  fi

  log "iptables match (nat PREROUTING):"
  iptables -t nat -S PREROUTING | grep -F "vps:${idNat}:" || true

  log "iptables match (filter FORWARD):"
  iptables -S FORWARD | grep -F "vps:${idNat}:" || true

  log "Done."
}

cmd_start() {
  local name="$1"
  lxc_exists "$name" || die "Container '$name' not found."
  log "Starting $name..."
  lxc-start -n "$name" -d
  lxc_wait_for_state "$name" "RUNNING" 30 || die "Failed to start."
  log "RUNNING"
}

cmd_stop() {
  local name="$1"
  lxc_exists "$name" || die "Container '$name' not found."
  log "Stopping $name..."
  lxc-stop -n "$name" || true
  log "STOPPED"
}

cmd_delete() {
  local name="$1"
  lxc_exists "$name" || die "Container '$name' not found."

  log "Deleting $name..."

  local idNat=""
  idNat="$(find_idnat_by_name "$name" || true)"

  # stop/destroy container
  lxc-stop -n "$name" >/dev/null 2>&1 || true
  lxc-destroy -n "$name"

  # cleanup nat + tc via idNat/state
  if [[ -n "$idNat" ]]; then
    cmd_delete_nat "$idNat"
    rm -f "${STATE_DIR}/${idNat}.json" || true
  else
    warn "No state found for $name. Fallback cleanup by scanning iptables for name=${name}"
    iptables_remove_by_tag "name=${name}:" || true
    tc_remove_limit "veth-${name}" || true
    netfilter-persistent save >/dev/null 2>&1 || true
  fi

  log "Deleted ✅"
}


cmd_setup() {
  local bridge="$DEFAULT_BRIDGE"
  local subnet="$DEFAULT_SUBNET"
  local wan=""
  local gw_ip="$DEFAULT_GW_IP"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --bridge) bridge="$2"; shift 2;;
      --subnet) subnet="$2"; shift 2;;
      --wan) wan="$2"; shift 2;;
      --gw) gw_ip="$2"; shift 2;;
      -h|--help) usage_setup; exit 0;;
      *) die "Unknown option: $1";;
    esac
  done

  [[ -n "$wan" ]] || wan="$(find_wan_if_auto)"
  log "Setup params: bridge=$bridge subnet=$subnet gw=$gw_ip wan=$wan"

  detect_virt
  ensure_ubuntu_debian
  ensure_packages_setup

  ensure_cmd lxc-checkconfig
  lxc-checkconfig >/dev/null || true

  apply_sysctl_ip_forward
  ensure_bridge_netplan "$bridge" "$gw_ip"
  ensure_base_nat_rules "$subnet" "$wan"
  ensure_lxc_default_conf "$bridge"

  log "Setup complete ✅"
  log "Next: ./vps create <name> --ip <ip> --ssh-port <port> --os ubuntu:jammy ..."
}

usage() {
  cat <<EOF
Usage:
  $0 setup [--wan eth0] [--bridge br-nat] [--subnet 10.10.0.0/24] [--gw 10.10.0.1]
  $0 create <name> --os ubuntu:jammy --ip 10.10.0.10 --ssh-port 22010 [options]
  $0 start <name>
  $0 stop <name>
  $0 delete <name>
  $0 reconcile

Run:
  $0 setup --wan eth0
  $0 create vps-01 --os ubuntu:jammy --ip 10.10.0.10 --ssh-port 22010 --ram 1024 --cpu 1 --bw 10mbit --hostname vps01
EOF
}

usage_setup() {
  cat <<EOF
Usage:
  $0 setup [--wan eth0] [--bridge br-nat] [--subnet 10.10.0.0/24] [--gw 10.10.0.1]

Notes:
- setup is idempotent (safe to run again).
- it runs apt update/upgrade + installs LXC, iptables-persistent, etc.
- creates netplan bridge (99-<bridge>.yaml) if missing.
EOF
}

usage_create() {
  cat <<EOF
Usage:
  $0 create <name> --os ubuntu:jammy --ip 10.10.0.10 --ssh-port 22010 [options]

Options:
  --ram <MB>          (default 1024)
  --cpu <vCPU>        (default 1)  # hard quota via cgroup2 cpu.max
  --bw <rate>         e.g. 10mbit  (tc on veth-<name>)
  --disk <GB>         requires --vg <VGNAME> (LVM backend, real quota)
  --vg <VGNAME>       e.g. vg0
  --hostname <name>   hostname inside container (default = container name)
  --hosts "a.com=1.2.3.4,b.com=5.6.7.8"  add/replace lines in /etc/hosts inside container
  --dns "1.1.1.1 8.8.8.8"
  --bridge <bridge>   (default br-nat)
  --subnet <cidr>     (default 10.10.0.0/24)
  --wan <ifname>      (default eth0)

Example:
  $0 create vps-01 --os ubuntu:jammy --ip 10.10.0.10 --ssh-port 22010 \\
     --ram 1024 --cpu 1 --bw 10mbit --hostname vps01 --hosts "google.com=5.180.255.138"
EOF
}

main() {
  need_root
  with_lock

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    setup)  cmd_setup "$@";;
    create)
      local name="${1:-}"; [[ -n "$name" ]] || die "Missing name. See: $0 create --help"
      shift
      cmd_create "$name" "$@"
      ;;
    start)
      local name="${1:-}"; [[ -n "$name" ]] || die "Missing name."
      cmd_start "$name"
      ;;
    get)
      local idNat="${1:-}"; [[ -n "$idNat" ]] || die "Missing idNat."
      cmd_get "$idNat"
      ;;
    list)
      cmd_list
      ;;
    info)
      local q="${1:-}"; [[ -n "$q" ]] || die "Missing name or idNat."
      cmd_info "$q"
      ;;
    reconcile)
      cmd_reconcile
      ;;
    stop)
      local name="${1:-}"; [[ -n "$name" ]] || die "Missing name."
      cmd_stop "$name"
      ;;
    delete-nat)
      local idNat="${1:-}"; [[ -n "$idNat" ]] || die "Missing idNat."
      cmd_delete_nat "$idNat"
      ;;
    delete)
      local name="${1:-}"; [[ -n "$name" ]] || die "Missing name."
      cmd_delete "$name"
      ;;
    -h|--help|"") usage;;
    *) die "Unknown command: $cmd (try --help)";;
  esac
}

main "$@"
