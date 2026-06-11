# Talos `metal-amd64` — bare-metal install for the gt platform

Operator guide for installing Talos Linux on a real amd64 machine and getting it
to the point where [`DEPLOY.md`](../DEPLOY.md) Step 2 (GitOps / `helm install
chart/gt`) takes over. This is the **hardware-specific detail** behind DEPLOY.md
Step 1.

> **Scope.** One physical box (or VM treated as metal) booting the Talos
> `metal-amd64` image. The chart + boot seeds + probes were already validated
> end-to-end on a local Talos cluster (hq-talos-migration.1, smoke §6 7/7); what
> this guide covers is exactly the part that spike could NOT validate: the real
> installer, disks, network, and storage.

Talos is an immutable, API-driven OS: **no shell, no SSH, no package manager**.
Everything is done from your workstation with `talosctl`.

---

## 0. Workstation prerequisites

```sh
# NixOS (this repo's operator host): wrap each command, or open one shell
nix-shell -p talosctl kubectl kubernetes-helm
```

- `talosctl` **matching the Talos version you boot** (image and CLI drift apart).
- `kubectl`, `helm` ≥ 3.
- This repo checked out (`gt-core-labs/gt-app-proxy`).

Keep everything this install produces (`_out/` configs, `talosconfig`,
`kubeconfig`) in a **durable, private** directory — they are the keys to the
cluster. Do NOT use `/tmp`.

---

## 1. Get the `metal-amd64` image

Two options:

**a) Stock image (no extensions)** — fine for the gt platform with
`local-path` storage:

```
https://github.com/siderolabs/talos/releases/download/v1.12.7/metal-amd64.iso
```

**b) Image Factory (recommended if you want a CSI later)** — build a schematic
at <https://factory.talos.dev> selecting `metal-amd64` plus the system
extensions your storage needs (e.g. `siderolabs/iscsi-tools` +
`siderolabs/util-linux-tools` for Longhorn). The factory gives you a schematic
ID and an installer URL like:

```
factory.talos.dev/installer/<schematic-id>:v1.12.7
```

Record the schematic ID — **upgrades must use the same installer URL** or the
extensions silently disappear.

Write the ISO to a USB stick and boot the machine from it (UEFI preferred):

```sh
sudo dd if=metal-amd64.iso of=/dev/sdX bs=4M status=progress oflag=sync
```

The node boots into **maintenance mode** and prints its IP on the console
(also visible in your DHCP leases). It has installed nothing yet.

---

## 2. Generate machine configs

```sh
export NODE_IP=192.168.1.50                      # maintenance-mode IP from the console
export CLUSTER_ENDPOINT="https://${NODE_IP}:6443" # single node: the node itself; multi-CP: a VIP

talosctl gen config gt-metal "${CLUSTER_ENDPOINT}" --output-dir _out
#   → _out/controlplane.yaml  _out/worker.yaml  _out/talosconfig
```

### 2a. Find the real install disk

```sh
talosctl -n "${NODE_IP}" get disks --insecure
```

### 2b. Patches — write these BEFORE applying

`patches/install-disk.yaml` — the disk Talos installs to (**it will be wiped**):

```yaml
machine:
  install:
    disk: /dev/nvme0n1        # ← from `get disks`; /dev/sda on SATA boxes
```

`patches/single-node.yaml` — **only for a one-box cluster**: let workloads run
on the control plane:

```yaml
cluster:
  allowSchedulingOnControlPlanes: true
```

`patches/network.yaml` — static addressing if you don't trust DHCP leases
(recommended: the cluster endpoint must not move):

```yaml
machine:
  network:
    hostname: gt-metal-1
    interfaces:
      - interface: eth0        # confirm with: talosctl -n <ip> get links --insecure
        addresses: [192.168.1.50/24]
        routes:
          - network: 0.0.0.0/0
            gateway: 192.168.1.1
    nameservers: [1.1.1.1, 8.8.8.8]
```

If you built a Factory image, also pin the installer so upgrades keep the
extensions:

```yaml
machine:
  install:
    image: factory.talos.dev/installer/<schematic-id>:v1.12.7
```

Apply the patches to the controlplane config:

```sh
talosctl machineconfig patch _out/controlplane.yaml \
  --patch @patches/install-disk.yaml \
  --patch @patches/single-node.yaml \
  --patch @patches/network.yaml \
  -o _out/controlplane.yaml
```

---

## 3. Install + bootstrap

```sh
# Push the config — the node installs Talos to the disk and reboots off it.
talosctl apply-config --insecure -n "${NODE_IP}" --file _out/controlplane.yaml

# Point talosctl at the now-permanent node.
export TALOSCONFIG="$PWD/_out/talosconfig"
talosctl config endpoint "${NODE_IP}"
talosctl config node "${NODE_IP}"

# Bootstrap etcd — run ONCE, on ONE control-plane node, ever.
talosctl bootstrap

# Watch it converge (STAGE: Running, READY: true).
talosctl dashboard          # or: talosctl health --wait-timeout 10m

# Kubeconfig.
talosctl kubeconfig .
export KUBECONFIG="$PWD/kubeconfig"
kubectl get nodes -o wide   # node Ready
```

Additional workers later: boot the ISO, then
`talosctl apply-config --insecure -n <worker-ip> --file _out/worker.yaml`.

---

## 4. Storage — REQUIRED before the chart

**Real Talos ships NO storage provisioner.** (The local `talosctl cluster
create` docker provisioner bundles `local-path-provisioner`; metal does not —
PVCs will sit `Pending` forever if you skip this.)

**Single node — local-path (validated shape):**

```sh
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/v0.0.33/deploy/local-path-storage.yaml
kubectl -n local-path-storage get pods   # provisioner Running
```

local-path needs a writable host path; Talos's filesystem is read-only except
`/var`, so point it there if the default doesn't apply (patch the
`local-path-config` ConfigMap to use `/var/local-path-provisioner`).

Then ALWAYS install the chart with the class pinned (the spike hit "spec is
immutable" upgrade conflicts when the class was left implicit):

```
--set storageClass=local-path
```

**Constraint that follows:** `local-path` is ReadWriteOnce. The shared eventlog
PVC wants RWX when API replicas and the daemon singleton spread across nodes.
On a single node this is moot (everything co-schedules); keep `api.replicas=1`
+ `daemons` on the same node, or flip the eventlog to Postgres
(`GT_EVENTLOG_PG=1`, hq-talos-migration.10–.12) and the RWX need disappears.
Multi-node without the PG flag → install Longhorn/Ceph/NFS instead and set
`storageClass` accordingly.

---

## 5. Images

The cluster pulls `codecsrayo/gt-core-mcp-server:embeddings` (+ `gt-web`,
`gt-docs`) from Docker Hub — published automatically by each repo's
`docker-publish` workflow on push to main. No side-loading is involved on a
real cluster (the registry dance in the spike notes was a local-cluster
workaround). Air-gapped? Run a private registry and override
`mcpServer.image.repository` etc. in values.

---

## 6. Hand off to DEPLOY.md

From here the flow is hardware-independent — continue at
[`DEPLOY.md`](../DEPLOY.md) **Step 2**:

1. Secrets → `values-secret.yaml` from
   [`chart/gt/values-secret.yaml.example`](../chart/gt/values-secret.yaml.example).
   Boot-fatal if missing: `GT_OIDC_REDIRECT_URI` (oauth build), RS256 PEMs.
   `oauthSeedSecretGoogle` empty ⇒ google IdP seeds disabled.
2. `helm install gt ./chart/gt -n gt --create-namespace -f values-secret.yaml
   --set storageClass=local-path` (or the Argo CD Application).
3. Readiness IS the headline: a pod that panics at boot never goes Ready and
   never receives traffic (validated live in the spike).
4. Data: greenfield ⇒ boot seeds populate everything (admin, knowledge, IdP,
   rigs); migration ⇒ run [`migrate/`](../migrate/README.md) **before** scaling
   the API up, and note the migrated Dolt volume already contains `hq_default`
   (multi-tenant `GT_DOLT_BASE_URL` is safe). Greenfield + multi-tenant is NOT
   wired yet — leave `mcpServer.doltBaseUrl` empty (single-tenant) for a fresh
   install.
5. Smoke §6: port-forward + the 7 checks (gt-core
   `scripts/greenfield-smoke.sh` logic; 7/7 expected).

---

## 7. Day-2: upgrades & reset

```sh
# Talos OS upgrade (use the SAME factory installer URL if you used Factory).
talosctl upgrade --image ghcr.io/siderolabs/installer:v1.12.8 --preserve

# Kubernetes upgrade.
talosctl upgrade-k8s --to 1.35.5

# Wipe a node back to maintenance mode (DESTROYS its data).
talosctl reset --graceful=false --reboot
```

---

## Pitfalls (learned the hard way)

| Symptom | Cause / fix |
| --- | --- |
| PVCs `Pending` forever | no storage provisioner on metal — install one (§4) |
| `helm upgrade`: "PVC/StatefulSet spec is immutable" | chart rendered without `storageClass` while the cluster defaulted one — always pin `--set storageClass=...` from install |
| API pod CrashLoop: "GitHub App config is half-set" / "GT_DOLT_BASE_URL is malformed" | chart older than `a2e42c4` rendering set-but-empty env — pull latest chart |
| minio-init Job loops "waiting for minio..." | chart older than `a2e42c4` (mc config dir not writable as non-root) |
| Upgrade lost iscsi/extensions | upgraded with the stock installer instead of the Factory schematic URL |
| `talosctl` works, `kubectl` times out | you exported the wrong file — `TALOSCONFIG` and `KUBECONFIG` are different artifacts |
