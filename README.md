# iSCSI Target on Harvester via Longhorn

Exposes one or more Longhorn block volumes as iSCSI targets to external hosts.
Uses kernel LIO (already in SLE Micro) configured from a privileged SLE BCI Python container (`registry.suse.com/bci/python:3`) — no packages installed on the host OS.

## How it works

```
External Host
     │  iSCSI port 3260
     ▼
Node running the pod  (hostNetwork: true)
     │  configfs (/sys/kernel/config)
     ▼
Kernel LIO target subsystem  (built into SLE Micro kernel)
     │  raw block devices
     ▼
Longhorn PVCs  (3 replicas → data redundancy across nodes)
```

**Redundancy model:** Longhorn keeps 3 replicas across your nodes. If the node
running the pod fails, Kubernetes reschedules the pod to a healthy node and
Longhorn re-attaches the volumes there. Expect ~30–60 s of downtime during
failover — the external host must reconnect. This is not zero-downtime HA.

For multi-portal (network redundancy without node failover), see the
Multi-portal section below.

---

## Prerequisites

- Harvester cluster (3 nodes, SLE Micro)
- A container registry reachable from the cluster (e.g. Docker Hub, Harbor)
- `kubectl` configured for your Harvester cluster
- `podman` to build and push the image

---

## 1. Build and push the image

```bash
cd iscsi-longhorn

podman build -t your-registry/iscsi-target:latest .
podman push your-registry/iscsi-target:latest
```

Replace `your-registry` with your actual registry (e.g. `docker.io/myuser`).

---

## 2. Define your PVCs (`k8s/02-pvc.yaml`)

Add one PVC block per iSCSI target you want to expose. Each PVC maps to one IQN.

```yaml
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: iscsi-vol-1          # ← matches volumes[].claimName in 03-deployment.yaml
  namespace: iscsi-target
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Block
  storageClassName: longhorn
  resources:
    requests:
      storage: 100Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: iscsi-vol-2
  namespace: iscsi-target
spec:
  accessModes: [ReadWriteOnce]
  volumeMode: Block
  storageClassName: longhorn
  resources:
    requests:
      storage: 200Gi
```

---

## 3. Update the Deployment (`k8s/03-deployment.yaml`)

The entrypoint reads **indexed env var groups** to map each PVC to an IQN:

| Env var | Example | Description |
|---|---|---|
| `BLOCK_DEVICE_N` | `/dev/iscsi-vol-1` | Device path inside the container |
| `IQN_N` | `iqn.2024-01.com.example:target-1` | iSCSI Qualified Name |
| `TARGET_NAME_N` | `vol-1` | Internal LIO backstore name (no spaces) |

Replace `N` with `1`, `2`, `3` … for each target. For every group you add:

1. Add the three `BLOCK_DEVICE_N` / `IQN_N` / `TARGET_NAME_N` env vars.
2. Add a matching `volumeDevices` entry (same `devicePath` as `BLOCK_DEVICE_N`).
3. Add a matching `volumes` entry pointing to the PVC from step 2.

**Example — two targets:**

```yaml
env:
- name: BLOCK_DEVICE_1
  value: /dev/iscsi-vol-1
- name: IQN_1
  value: iqn.2024-01.com.yourcompany:storage-a
- name: TARGET_NAME_1
  value: vol-1

- name: BLOCK_DEVICE_2
  value: /dev/iscsi-vol-2
- name: IQN_2
  value: iqn.2024-01.com.yourcompany:storage-b
- name: TARGET_NAME_2
  value: vol-2

volumeDevices:
- name: data-1
  devicePath: /dev/iscsi-vol-1
- name: data-2
  devicePath: /dev/iscsi-vol-2

volumes:
- name: data-1
  persistentVolumeClaim:
    claimName: iscsi-vol-1
- name: data-2
  persistentVolumeClaim:
    claimName: iscsi-vol-2
```

IQN format: `iqn.<year>-<month>.<reversed-domain>:<name>`

> **Single-target (legacy) mode:** if you set only `BLOCK_DEVICE` / `IQN` /
> `TARGET_NAME` (no numeric suffix), the entrypoint falls back to the old
> single-target behaviour.

---

## 4. Deploy to Harvester

```bash
kubectl apply -f k8s/01-namespace.yaml
kubectl apply -f k8s/02-pvc.yaml
kubectl apply -f k8s/03-deployment.yaml
```

Wait for the pod to be ready:
```bash
kubectl -n iscsi-target get pods -w
```

Find which node the pod landed on and note its IP:
```bash
kubectl -n iscsi-target get pod -o wide
# Note the NODE column, then:
kubectl get node <node-name> -o wide
# Note the INTERNAL-IP — this is your iSCSI portal address
```

Check the logs to confirm all targets are running:
```bash
kubectl -n iscsi-target logs -f deploy/iscsi-target
```

You should see something like:
```
iSCSI targets READY — portal: 0.0.0.0:3260
  iqn.2024-01.com.example:target-1  →  /dev/iscsi-vol-1
  iqn.2024-01.com.example:target-2  →  /dev/iscsi-vol-2
```

---

## 5. Connect from an external host

### Linux

```bash
# Install iSCSI initiator
apt install open-iscsi        # Debian/Ubuntu
dnf install iscsi-initiator-utils  # RHEL/Rocky

# Discover all targets on the node
iscsiadm -m discovery -t st -p <node-ip>

# Login to a specific target
iscsiadm -m node \
  --targetname iqn.2024-01.com.example:target-1 \
  --portal <node-ip>:3260 \
  --login

# Verify — new block device should appear
lsblk
dmesg | tail -20
```

To log in to **all** discovered targets at once:
```bash
iscsiadm -m node --login
```

### Windows

1. Open **iSCSI Initiator** (search in Start menu)
2. **Discovery** tab → **Discover Portal** → enter `<node-ip>`
3. **Targets** tab → connect to each discovered IQN

---

## 6. Multi-portal (network redundancy)

If your nodes have multiple NICs, the target already listens on all of them
(`0.0.0.0:3260`). Connect from the external host using both IPs:

```bash
iscsiadm -m discovery -t st -p 192.168.1.10
iscsiadm -m discovery -t st -p 10.0.0.10

iscsiadm -m node --login

iscsiadm -m session

apt install multipath-tools

cat > /etc/multipath.conf <<EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
}
EOF

systemctl restart multipathd
multipath -ll   # should show two paths to the same device
```

---

## 7. CHAP authentication (optional)

CHAP applies globally to all targets exposed by this pod. Create the secret:
```bash
kubectl create secret generic iscsi-chap \
  -n iscsi-target \
  --from-literal=username=myuser \
  --from-literal=password=mysecurepassword
```

Uncomment the `CHAP_USERID` and `CHAP_PASSWORD` env vars in `03-deployment.yaml`,
then re-apply:
```bash
kubectl apply -f k8s/03-deployment.yaml
```

On the external host, configure CHAP before logging in:
```bash
iscsiadm -m node \
  --targetname iqn.2024-01.com.example:target-1 \
  --op update -n node.session.auth.authmethod -v CHAP
iscsiadm -m node \
  --targetname iqn.2024-01.com.example:target-1 \
  --op update -n node.session.auth.username -v myuser
iscsiadm -m node \
  --targetname iqn.2024-01.com.example:target-1 \
  --op update -n node.session.auth.password -v mysecurepassword
iscsiadm -m node \
  --targetname iqn.2024-01.com.example:target-1 \
  --portal <node-ip>:3260 \
  --login
```

---

## 8. Pinning to a specific node (optional)

By default the pod can land on any node. To keep it on a predictable IP,
uncomment and set `nodeSelector` in `03-deployment.yaml`:

```yaml
nodeSelector:
  kubernetes.io/hostname: harvester-node-1
```

Trade-off: the pod will NOT reschedule if that node fails.

---

## Troubleshooting

**Pod stuck in Pending**
```bash
kubectl -n iscsi-target describe pod <pod-name>
# Usually: PVC not bound, or image pull error
kubectl -n iscsi-target get pvc
```

**"Failed to load kernel module"**
```bash
# SSH into the Harvester node and run:
modinfo target_core_mod
modinfo iscsi_target_mod
```

**"Device not found"**
```bash
kubectl -n longhorn-system get volume
```

**iSCSI sessions drop after pod reschedule**
Expected — the external host must re-login:
```bash
iscsiadm -m node --logout
iscsiadm -m discovery -t st -p <new-node-ip>
iscsiadm -m node --login
```

**Inspect live LIO config inside the pod**
```bash
kubectl -n iscsi-target exec -it deploy/iscsi-target -- targetcli ls
```
