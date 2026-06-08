#!/bin/bash
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ── Configuration (override via env vars in the Deployment) ───────────────────
BLOCK_DEVICE="${BLOCK_DEVICE:-/dev/iscsi-vol}"
IQN="${IQN:-iqn.2024-01.com.example:harvester-target}"
TARGET_NAME="${TARGET_NAME:-harvester-vol}"
CHAP_USERID="${CHAP_USERID:-}"
CHAP_PASSWORD="${CHAP_PASSWORD:-}"

# ── Cleanup on exit / SIGTERM ─────────────────────────────────────────────────
cleanup() {
  log "Caught signal — removing iSCSI target from kernel..."
  targetcli /iscsi delete "${IQN}"         2>/dev/null || true
  targetcli /backstores/block delete "${TARGET_NAME}" 2>/dev/null || true
  targetcli saveconfig                      2>/dev/null || true
  log "Cleanup done, exiting"
}
trap cleanup SIGTERM SIGINT EXIT

# ── 1. Load LIO kernel modules ────────────────────────────────────────────────
# The host kernel already has these; modprobe works from a privileged container.
log "Loading LIO kernel modules..."
for mod in target_core_mod target_core_iblock iscsi_target_mod; do
  if modprobe "${mod}" 2>/dev/null; then
    log "  ✓ ${mod}"
  else
    log "  ~ ${mod} (already loaded or built-in)"
  fi
done

# ── 2. Ensure configfs is mounted ─────────────────────────────────────────────
# On SLE Micro, systemd usually mounts this; check and mount if missing.
if ! grep -q "configfs /sys/kernel/config" /proc/mounts; then
  log "Mounting configfs..."
  mount -t configfs configfs /sys/kernel/config
fi

# ── 3. Wait for the Longhorn block device ────────────────────────────────────
log "Waiting for block device ${BLOCK_DEVICE}..."
until [ -b "${BLOCK_DEVICE}" ]; do
  sleep 2
done
log "Block device ${BLOCK_DEVICE} is ready"

# ── 4. Remove any stale LIO config for our target (idempotent) ───────────────
log "Clearing stale config (if any)..."
targetcli /iscsi delete "${IQN}"              2>/dev/null || true
targetcli /backstores/block delete "${TARGET_NAME}" 2>/dev/null || true

# ── 5. Create iSCSI target ───────────────────────────────────────────────────
log "Creating iSCSI target..."
targetcli <<EOF
/backstores/block create name=${TARGET_NAME} dev=${BLOCK_DEVICE} write_back=false
/iscsi create ${IQN}
/iscsi/${IQN}/tpg1/luns create /backstores/block/${TARGET_NAME}
/iscsi/${IQN}/tpg1/ set attribute authentication=0
/iscsi/${IQN}/tpg1/ set attribute generate_node_acls=1
saveconfig
EOF

# ── 6. Optional: CHAP authentication ─────────────────────────────────────────
if [ -n "${CHAP_USERID}" ] && [ -n "${CHAP_PASSWORD}" ]; then
  log "Enabling CHAP authentication..."
  targetcli <<EOF
/iscsi/${IQN}/tpg1/ set attribute authentication=1
/iscsi/${IQN}/tpg1/auth set userid=${CHAP_USERID}
/iscsi/${IQN}/tpg1/auth set password=${CHAP_PASSWORD}
saveconfig
EOF
fi

log "──────────────────────────────────────────────"
log "iSCSI target is READY"
log "  IQN    : ${IQN}"
log "  Device : ${BLOCK_DEVICE}"
log "  Portal : 0.0.0.0:3260 (all node interfaces)"
log "──────────────────────────────────────────────"

# ── 7. Stay alive (LIO runs in kernel space) ─────────────────────────────────
# Run sleep in background so bash can receive signals and fire the trap.
sleep infinity &
BGPID=$!
wait $BGPID
