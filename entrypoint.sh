#!/bin/bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Configuration ─────────────────────────────────────────────────────────────
# Multi-target mode: set BLOCK_DEVICE_1/IQN_1/TARGET_NAME_1, _2, _3 ... in the
# Deployment env vars. Each index maps one Longhorn PVC to one iSCSI IQN.
#
# Single-target (legacy) fallback: set BLOCK_DEVICE / IQN / TARGET_NAME.
CHAP_USERID="${CHAP_USERID:-}"
CHAP_PASSWORD="${CHAP_PASSWORD:-}"

# Build TARGETS array: each element is "device|iqn|name"
TARGETS=()
if [ -n "${BLOCK_DEVICE_1:-}" ]; then
  i=1
  while true; do
    _dev_var="BLOCK_DEVICE_${i}"; _iqn_var="IQN_${i}"; _name_var="TARGET_NAME_${i}"
    _dev="${!_dev_var:-}"; _iqn="${!_iqn_var:-}"; _name="${!_name_var:-}"
    [ -z "${_dev}" ] && break
    TARGETS+=("${_dev}|${_iqn}|${_name}")
    ((i++))
  done
else
  # Legacy single-target
  _dev="${BLOCK_DEVICE:-/dev/iscsi-vol}"
  _iqn="${IQN:-iqn.2024-01.com.example:harvester-target}"
  _name="${TARGET_NAME:-harvester-vol}"
  TARGETS=("${_dev}|${_iqn}|${_name}")
fi

# ── Cleanup on exit / SIGTERM ─────────────────────────────────────────────────
cleanup() {
  log "Caught signal — removing iSCSI targets from kernel..."
  for _t in "${TARGETS[@]}"; do
    IFS='|' read -r _dev _iqn _name <<< "${_t}"
    targetcli /iscsi delete "${_iqn}"              2>/dev/null || true
    targetcli /backstores/block delete "${_name}"  2>/dev/null || true
  done
  targetcli saveconfig 2>/dev/null || true
  log "Cleanup done, exiting"
}
trap cleanup SIGTERM SIGINT EXIT

# ── 1. Load LIO kernel modules ────────────────────────────────────────────────
log "Loading LIO kernel modules..."
for mod in target_core_mod target_core_iblock iscsi_target_mod; do
  if modprobe "${mod}" 2>/dev/null; then
    log "  ✓ ${mod}"
  else
    log "  ~ ${mod} (already loaded or built-in)"
  fi
done

# ── 2. Ensure configfs is mounted ─────────────────────────────────────────────
if ! grep -q "configfs /sys/kernel/config" /proc/mounts; then
  log "Mounting configfs..."
  mount -t configfs configfs /sys/kernel/config
fi

# ── 3–6. Configure one iSCSI target per PVC ──────────────────────────────────
for _t in "${TARGETS[@]}"; do
  IFS='|' read -r _dev _iqn _name <<< "${_t}"

  log "Waiting for block device ${_dev}..."
  until [ -b "${_dev}" ]; do sleep 2; done
  log "  ${_dev} is ready"

  log "Clearing stale config for ${_iqn} (if any)..."
  targetcli /iscsi delete "${_iqn}"              2>/dev/null || true
  targetcli /backstores/block delete "${_name}"  2>/dev/null || true

  log "Creating iSCSI target ${_iqn} → ${_dev}..."
  targetcli <<EOF
/backstores/block create name=${_name} dev=${_dev} write_back=false
/iscsi create ${_iqn}
/iscsi/${_iqn}/tpg1/luns create /backstores/block/${_name}
/iscsi/${_iqn}/tpg1/ set attribute authentication=0
/iscsi/${_iqn}/tpg1/ set attribute generate_node_acls=1
saveconfig
EOF

  if [ -n "${CHAP_USERID}" ] && [ -n "${CHAP_PASSWORD}" ]; then
    log "Enabling CHAP for ${_iqn}..."
    targetcli <<EOF
/iscsi/${_iqn}/tpg1/ set attribute authentication=1
/iscsi/${_iqn}/tpg1/auth set userid=${CHAP_USERID}
/iscsi/${_iqn}/tpg1/auth set password=${CHAP_PASSWORD}
saveconfig
EOF
  fi
done

# ── 7. Print summary ──────────────────────────────────────────────────────────
log "──────────────────────────────────────────────"
log "iSCSI targets READY — portal: 0.0.0.0:3260"
for _t in "${TARGETS[@]}"; do
  IFS='|' read -r _dev _iqn _name <<< "${_t}"
  log "  ${_iqn}  →  ${_dev}"
done
log "──────────────────────────────────────────────"

# ── 8. Stay alive (LIO runs in kernel space) ──────────────────────────────────
sleep infinity &
BGPID=$!
wait $BGPID
