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

## Quick start — Helm chart (recommended)

`charts/iscsi-longhorn/` wraps everything below (namespace, PVCs, Deployment,
CHAP secret) into one parameterized chart — the target list, write-protection
mode, CHAP, and node placement are all `values.yaml` knobs instead of manually
edited manifests.

The chart is published as a Helm repo via GitHub Pages:

```bash
helm repo add iscsi-longhorn https://doccaz.github.io/iscsi-longhorn
helm repo update

helm install iscsi-target iscsi-longhorn/iscsi-longhorn \
  --set image.repository=your-registry/iscsi-target \
  --set image.tag=latest
```

Or install straight from a local checkout:

```bash
helm install iscsi-target ./charts/iscsi-longhorn \
  --set image.repository=your-registry/iscsi-target \
  --set image.tag=latest
```

For the SQL Server FCI/WSFC lab scenario (see below), use the bundled preset —
it provisions a witness + data LUN pair with read/write access for both nodes:

```bash
helm install sql-iscsi iscsi-longhorn/iscsi-longhorn \
  --set image.repository=your-registry/iscsi-target \
  -f charts/iscsi-longhorn/examples/values-sql-fci.yaml
```

See `charts/iscsi-longhorn/values.yaml` for all options. The sections below
describe the same deployment using raw manifests in `k8s/`, useful if you'd
rather not use Helm or want to see exactly what gets created.

**Releasing new chart versions:** bump `version:` in
`charts/iscsi-longhorn/Chart.yaml`, commit, and push to `main`. The
`.github/workflows/release-charts.yml` workflow (chart-releaser) packages the
chart, creates a GitHub Release (tag `iscsi-longhorn-<version>`) with the
`.tgz` attached, and updates the `gh-pages` branch's `index.yaml` — no manual
`helm package`/`helm repo index` steps needed.

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

## Testing SQL Server FCI / WSFC (lab only)

This project can be used to lab-test a SQL Server **Failover Cluster Instance (FCI)**
under Harvester without owning an external enterprise SAN + CSI driver. Windows
Server Failover Clustering (WSFC) requires shared storage that supports **SCSI-3
Persistent Reservations (SCSI-3 PR)**. Longhorn/KubeVirt PVCs attached directly to a
VM do not support PR for shared volumes — that path needs an external SAN, a CSI
driver with RWX + Block support, and the KubeVirt `PersistentReservation` feature
gate (which drives `qemu-pr-helper`).

The workaround: **bypass KubeVirt storage entirely.** Expose Longhorn-backed block
devices as real iSCSI LUNs from this pod (kernel LIO, which fully implements SPC-3
PR), and connect the Windows guest VMs directly to them with the **in-guest iSCSI
initiator** — same as connecting to any physical iSCSI SAN. WSFC then talks SCSI-3 PR
straight to LIO.

> **This is a lab/testing substitute, not a production pattern.** For production HA,
> prefer SQL Server Always On **Availability Groups** (no shared storage, no SCSI-3 PR
> needed). If FCI is strictly required in production, use a certified enterprise SAN
> with a CSI driver instead of this container.

### 1. Provision two LUNs: witness + data

A typical two-node FCI test cluster needs a small witness/quorum disk and a data
disk. Add both to `k8s/02-pvc.yaml` and map them in `03-deployment.yaml` using the
multi-target env vars (see section 3 above):

```yaml
env:
- name: BLOCK_DEVICE_1
  value: /dev/iscsi-witness
- name: IQN_1
  value: iqn.2024-01.com.example:sql-witness
- name: TARGET_NAME_1
  value: sql-witness

- name: BLOCK_DEVICE_2
  value: /dev/iscsi-data
- name: IQN_2
  value: iqn.2024-01.com.example:sql-data
- name: TARGET_NAME_2
  value: sql-data
```

A 1 GB PVC is enough for the witness disk; size the data disk for your test database.

### 2. Connect both SQL Server VMs

On **each** Windows Server node that will join the WSFC cluster:

1. Open **iSCSI Initiator** (`iscsicpl.exe`).
2. Discover the target portal — the Harvester node IP running this pod (see step 4
   in the main setup above).
3. Log in to **both** IQNs (witness and data).
4. In **Disk Management**, bring the new disks online and initialize them (leave
   them unformatted/raw if WSFC will format them, or format NTFS if required by
   your FCI setup).

Both nodes must connect to the *same* two LUNs — that's what gives WSFC shared
storage. Access is unrestricted (`demo_mode_write_protect=0`, `generate_node_acls=1`)
by default, so any initiator that can reach port 3260 gets read/write access. Enable
[CHAP](#7-chap-authentication-optional) if you want to restrict who can connect.

### 3. Validate storage in WSFC

From either node, run the storage-only cluster validation:

```powershell
Test-Cluster -Node "SQL-NODE-01","SQL-NODE-02" -Include "Storage"
```

A **Passed** result for the persistent reservation tests confirms LIO is correctly
handling `PERSISTENT RESERVE IN`/`OUT` (SPC-3 PR) and you can proceed with WSFC and
SQL Server FCI installation.

### Caveats

- **Not zero-downtime.** As noted above, this pod runs as a single replica; if its
  node fails, Kubernetes reschedules it and the iSCSI sessions drop (~30–60 s). The
  Windows initiators will need to reconnect — WSFC itself will treat this the same
  way it would treat a SAN controller failover blip, but it's not equivalent to true
  multipath SAN redundancy.
- **Lab-grade PR, not hardware-offloaded.** LIO's PR implementation is spec-complete,
  but there's no redundant target-side hardware here — this is meant for validating
  cluster *behavior* (failover logic, validation wizards, application testing), not
  for production availability guarantees.

### Production considerations

**KubeVirt's native `PersistentReservation` feature gate is the "proper" way to
get SCSI-3 PR to a guest**, forwarding PR ioctls through `qemu-pr-helper` to a
shared PVC. It requires an external SAN, a CSI driver with RWX + Block
support, and that feature gate enabled on the KubeVirt CR — none of which this
chart depends on, since it bypasses KubeVirt storage entirely. See
`reference/links.txt` for further notes.

**The production-viable path is the same one this chart demonstrates, just
pointed at a real SAN:** bypass KubeVirt storage entirely and connect the
guest OS's in-guest iSCSI initiator directly to the array's iSCSI target (or
an iSCSI gateway in front of FC storage), exactly as done here with
Longhorn-backed LIO LUNs. This is also the traditional way WSFC has been
deployed on virtualized platforms for years (VMware, Hyper-V), precisely
because hypervisor-level clustered-disk pass-through has always been
fragile/vendor-specific.

Performance implications of that approach in production:

- **Extra network layer.** In-guest iSCSI means the guest does full TCP/IP +
  iSCSI protocol processing in software over a virtual NIC, then crosses the
  hypervisor's SDN overlay (Harvester uses Kube-OVN — Geneve/VXLAN
  encapsulation) before reaching a physical NIC. This is a longer path than a
  CSI-backed `virtio-blk`/`virtio-scsi` device, and there's no hardware
  iSCSI/TOE offload available to the VM — the guest's software initiator
  spends vCPU cycles that would otherwise go to the application (e.g. SQL
  Server query processing).
- **Latency matters more than throughput.** Raw sequential throughput on
  10/25GbE with jumbo frames can approach line rate, but the real-world impact
  for an OLTP FCI workload is slightly higher per-IO latency (e.g. log write
  commit latency), not necessarily lower peak IOPS.
- **Overlay MTU overhead.** Kube-OVN's encapsulation adds header bytes per
  packet, eating into effective MTU unless jumbo frames (9000) are configured
  consistently end-to-end — physical switches, Harvester network, VM vNIC, and
  guest OS. Easier to get wrong on an SDN platform than on a flat physical
  network.
- **Mitigations that work in practice:** a dedicated storage VLAN/network with
  jumbo frames end-to-end, in-guest MPIO across multiple vNICs/paths for
  redundancy and aggregate throughput, sizing vCPU with headroom for the
  software iSCSI initiator, tuning RSS on the guest NIC, and loosening WSFC
  heartbeat/lease timeouts slightly versus a bare-metal deployment to avoid
  false failovers from occasional latency spikes.

None of this is exotic — it's the same order of overhead accepted by any
in-guest-iSCSI WSFC deployment run in production for over a decade. The
trade-off is acceptable for most OLTP workloads in exchange for a working
SCSI-3 PR path that doesn't depend on the KubeVirt `PersistentReservation`
feature gate at all.

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
