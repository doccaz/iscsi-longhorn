# iSCSI Target on Harvester via Longhorn

Exposes a Longhorn block volume as an iSCSI target to external hosts.
Uses kernel LIO (already in SLE Micro) configured from a privileged BCI container — no packages installed on the host OS.

## How it works

```
External Host
     │  iSCSI port 3260
     ▼
Node running the pod  (hostNetwork: true)
     │  configfs (/sys/kernel/config)
     ▼
Kernel LIO target subsystem  (built into SLE Micro kernel)
     │  raw block device
     ▼
Longhorn PVC  (3 replicas → data redundancy across nodes)
```

**Redundancy model:** Longhorn keeps 3 replicas across your nodes. If the node
running the pod fails, Kubernetes reschedules the pod to a healthy node and
Longhorn re-attaches the volume there. Expect ~30–60 s of downtime during
failover — the external host must reconnect. This is not zero-downtime HA.

For multi-portal (network redundancy without node failover), see the
Multi-portal section below.

---

## Prerequisites

- Harvester cluster (3 nodes, SLE Micro)
- A container registry reachable from the cluster (e.g. Docker Hub, Harbor)
- `kubectl` configured for your Harvester cluster
- `docker` or `podman` to build the image

---

## 1. Build and push the image

```bash
cd iscsi-target

docker build -t your-registry/iscsi-target:latest .
docker push your-registry/iscsi-target:latest
```

Replace `your-registry` with your actual registry (e.g. `docker.io/myuser`).

---

## 2. Update the Deployment

Edit `k8s/03-deployment.yaml` and set:

| Field | Where | Example |
|---|---|---|
| `image` | containers[0].image | `docker.io/myuser/iscsi-target:latest` |
| `IQN` env var | containers[0].env | `iqn.2024-01.com.yourcompany:storage1` |
| `storage` | PVC resources | adjust to your volume size |

IQN format: `iqn.<year>-<month>.<reversed-domain>:<name>`

---

## 3. Deploy to Harvester

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

Check the logs to confirm the target is running:
```bash
kubectl -n iscsi-target logs -f deploy/iscsi-target
```

You should see:
```
iSCSI target is READY
  IQN    : iqn.2024-01.com.example:harvester-target
  Device : /dev/iscsi-vol
  Portal : 0.0.0.0:3260 (all node interfaces)
```

---

## 4. Connect from an external host

### Linux

```bash
# Install iSCSI initiator
apt install open-iscsi        # Debian/Ubuntu
dnf install iscsi-initiator-utils  # RHEL/Rocky

# Discover the target
iscsiadm -m discovery -t st -p <node-ip>

# Login
iscsiadm -m node \
  --targetname iqn.2024-01.com.example:harvester-target \
  --portal <node-ip>:3260 \
  --login

# Verify — new block device should appear
lsblk
dmesg | tail -20
```

### Windows

1. Open **iSCSI Initiator** (search in Start menu)
2. **Discovery** tab → **Discover Portal** → enter `<node-ip>`
3. **Targets** tab → connect to the discovered IQN

---

## 5. Multi-portal (network redundancy)

If your nodes have multiple NICs, the target already listens on all of them
(`0.0.0.0:3260`). Connect from the external host using both IPs:

```bash
# Discover on both NICs of the node
iscsiadm -m discovery -t st -p 192.168.1.10
iscsiadm -m discovery -t st -p 10.0.0.10

# Login to all discovered sessions
iscsiadm -m node --login

# Verify two sessions exist
iscsiadm -m session

# Install and configure multipath
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

## 6. CHAP authentication (optional)

Create the secret:
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
  --targetname iqn.2024-01.com.example:harvester-target \
  --op update -n node.session.auth.authmethod -v CHAP
iscsiadm -m node \
  --targetname iqn.2024-01.com.example:harvester-target \
  --op update -n node.session.auth.username -v myuser
iscsiadm -m node \
  --targetname iqn.2024-01.com.example:harvester-target \
  --op update -n node.session.auth.password -v mysecurepassword
iscsiadm -m node \
  --targetname iqn.2024-01.com.example:harvester-target \
  --portal <node-ip>:3260 \
  --login
```

---

## 7. Pinning to a specific node (optional)

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
Check if LIO modules are available on the host:
```bash
# SSH into the Harvester node and run:
modinfo target_core_mod
modinfo iscsi_target_mod
```

**"Device not found"**
The Longhorn volume may still be attaching. Check:
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
