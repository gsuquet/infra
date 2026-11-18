# Study: Talos on Raspberry Pi and local servers

Status: research, no decision recorded yet. Date: 2026-11-18.

This study prepares `modules/cluster-talos` and the first Talos cluster that replaces the k3s cluster `olympus`, which `gsuquet/homelab` still runs.
It covers the hardware, the boot assets, the Terraform flow with the `siderolabs/talos` provider, the network and storage choices, the upgrades and the eBPF limits that matter for Falco and Tetragon.
It ends with a proposed module interface and the open questions for the owner.

## How to read this study

- Versions checked: Talos **v1.14** docs (examples pin `v1.14.6`, Linux 6.18, Kubernetes 1.37), Terraform provider `siderolabs/talos` **0.12.0** (latest stable, 2026-09-21; `0.13.0-alpha.1` exists), Cilium docs **stable** (examples pin 1.20.5).
- Each claim with a link was checked against `docs.siderolabs.com`, `registry.terraform.io` or `docs.cilium.io` on the date above. `www.talos.dev` now redirects to `siderolabs.com`, and the docs live on `docs.siderolabs.com`.
- **Unverified** marks a claim that no allowed source confirms: it comes from memory, from an inference, or from a source outside the allowed domains (`raspberrypi.com`, `factory.talos.dev`, `github.com/siderolabs/*`). Each one needs a check on real hardware or in a later study.

## Current hardware: `olympus`

What `gsuquet/homelab` says about `olympus`:

| Fact | Source in `gsuquet/homelab` |
| ---- | --------------------------- |
| One host, `olympus.local`, in the `k3s_server` group. No `k3s_agent` hosts. | `ansible/inventory/hosts.yml` |
| k3s `v1.34.1+k3s1`, API on port 6443, TLS SAN `olympus.local`, embedded datastore (`use_external_database: false`). | `ansible/inventory/group_vars/` |
| Raspberry Pi, arm64. The `os_raspberrypi` role edits `cmdline.txt` for cgroups. | `ansible/roles/os_raspberrypi/` |
| Resource sizes target "a Raspberry Pi 4 with 8 GiB". | `docs/reference/gitops-layout.md` |

What is **not** recorded: the number of Pis on hand, the exact model of each (Pi 4B vs CM4 vs Pi 5), the boot medium (SD card or USB SSD), the attached disks, the network (switch, VLAN, DHCP reservations) and the power setup (PoE or USB-C).
These facts drive most choices below, so they are the first open questions.

Note: `homelab/docs/explanation/why-the-platform-runs-on-a-local-cluster-first.md` says "At home, a Talos cluster runs on the Raspberry Pi nodes". The inventory shows k3s on a single Pi. That sentence describes the target, not the present.

## Supported boards

| Board | Status in Talos v1.14 | Overlay | Notes |
| ----- | --------------------- | ------- | ----- |
| Raspberry Pi 4B | Supported. Listed in the [support matrix](https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix.md); "officially tested" per the [Raspberry Pi guide](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/rpi_generic.md). | `rpi_generic` | Boots through u-boot (`rpi_arm64_defconfig`). |
| Compute Module 4 | Listed in the support matrix, but only "community tested on one variant of the Compute Module 4 using Super 6C boards". | `rpi_generic` | Carrier board matters (PCIe, eMMC vs Lite). |
| Raspberry Pi 5 | **Not supported.** Not in the support matrix; listed under [Unofficial Ports](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/unofficial.md) (`talos-rpi5/talos-builder`, a community builder). | none official | The provider data source `talos_image_factory_urls` 0.12.0 accepts `sbc = "rpi_5"` ([docs](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/data-sources/image_factory_urls)). **Unverified:** whether the Image Factory serves a working `rpi_5` overlay, and with which support level. |
| Compute Module 5 | **Not mentioned** in any Talos doc. Treat as unsupported. | none | **Unverified.** |

All SBC ports are "community-maintained and provided as-is"; Sidero Labs gives no official support for boot failures or firmware quirks ([Unofficial Ports](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/unofficial.md)).
Metal is a Tier 1 platform, but the tiers do not list SBCs ([support matrix](https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix.md)).

**Recommendation:** build the production cluster on Pi 4B (8 GiB) or CM4 only. Do not buy Pi 5 or CM5 for Talos until they enter the support matrix.

## EEPROM and firmware

- Update the bootloader EEPROM once per board, before the first Talos boot: write the "Misc utility images" EEPROM image with Raspberry Pi Imager to a spare SD card, boot it, wait for the green LED to blink fast ([Raspberry Pi guide](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/rpi_generic.md#updating-the-eeprom)).
- Boot from USB needs the EEPROM `BOOT_ORDER` to include USB. Recent EEPROM releases try SD then USB by default. **Unverified** (source is `raspberrypi.com`, outside the allowed domains).
- The `rpi_generic` overlay ships the firmware, u-boot and `config.txt`. `config.txt` is set at image build time (`configTxt` or `configTxtAppend` overlay options). It cannot change on a running node, and custom `config.txt` content "is not preserved automatically during upgrades" ([config.txt information](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/rpi_generic.md#configtxt-information)). Consequence: keep `config.txt` changes in the schematic, and always upgrade with the installer of the same schematic.
- Useful `config.txt` items for headless nodes: `dtoverlay=disable-wifi`, `dtoverlay=disable-bt`, fan control (`gpio-fan` or `pwm-gpio-fan`). GPU memory (`gpu_mem`, CMA) only matters with the `vc4` extension, which a headless node does not need.
- The Pi 4 has no TPM and no UEFI Secure Boot in this boot path (u-boot). SecureBoot in the support matrix is "arm64: UEFI" only. **Inferred**, not stated for the Pi.

## Image Factory schematic and system extensions

A schematic is a YAML document that the [Image Factory](https://docs.siderolabs.com/talos/v1.14/learn-more/image-factory.md) turns into boot assets. Its ID is the hash of its content, so the same YAML always gives the same ID. The installer image for a schematic is `factory.talos.dev/metal-installer/<schematic-id>:<talos-version>`.

Since Talos 1.14, `ghcr.io/siderolabs/installer` is **no longer published**: installers come only from the Image Factory ([Upgrading Talos](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md#talosctl-upgrade)). The provider examples still show `ghcr.io/siderolabs/installer:v1.9.0`; do not copy them.

Proposed schematic for a headless Pi 4 / CM4 node:

```yaml
overlay:
  name: rpi_generic
  image: siderolabs/sbc-raspberrypi
  options:
    configTxtAppend: |
      dtoverlay=disable-wifi
      dtoverlay=disable-bt
customization:
  systemExtensions:
    officialExtensions: []  # add siderolabs/iscsi-tools + siderolabs/util-linux-tools only if Longhorn is chosen
```

- The "vanilla" Raspberry Pi schematic ID is `ee21ef4a5ef808a9b7484cc0dda0f25075021691c8c09a276591eedb638ea1f9` ([Raspberry Pi guide](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/rpi_generic.md#download-the-image)).
- No system extension is required for Kubernetes, Cilium or Argo CD. Extensions follow the storage choice: Longhorn needs `siderolabs/iscsi-tools` and `siderolabs/util-linux-tools` on every node ([Longhorn on Talos](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)).
- Extensions activate only at install or upgrade ([System Extensions](https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/custom-images-and-development/system-extensions.md)). Adding one means a new schematic ID and a Talos upgrade to it.
- Kernel arguments go in `customization.extraKernelArgs` of the schematic, not in the machine config.
- In Terraform: `talos_image_factory_schematic` posts the schematic and returns its ID; the data source `talos_image_factory_urls` returns `disk_image` and `installer` URLs for a `talos_version`, `architecture`, `platform` or `sbc` ([provider docs](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/image_factory_schematic)). The schematic YAML lives in Git; the ID is derived.

## Boot media

| Medium | Fit | Notes |
| ------ | --- | ----- |
| SD card | Lab only | The documented default path (`dd` the raw image to `/dev/mmcblk0`). Slow random writes and low endurance: a bad home for etcd and container images. |
| USB 3 SSD (Pi 4B) | **Recommended** | Write the raw image to the SSD and boot from it. Needs a USB boot order in the EEPROM. **Unverified:** u-boot USB boot on Pi 4 with every USB-SATA bridge; some bridges need UAS quirks. Test the exact enclosure before buying several. |
| NVMe | CM4 carrier with PCIe, or Pi 5 | The Pi 4B has no PCIe slot, so NVMe only through a USB adapter (same as USB SSD). **Unverified:** u-boot NVMe boot on CM4 carriers with `rpi_generic`. |
| eMMC (CM4 non-Lite) | Acceptable | Better than SD. Flashing needs `rpiboot` on the carrier. **Unverified** for Talos specifically. |
| SD boot + SSD data | Fallback | Boot and `STATE` on SD, `EPHEMERAL` (etcd, containerd, kubelet) moved to the SSD with a `VolumeConfig` `provisioning.diskSelector`. Talos 1.14 can also place `ETCD`, `CRI`, `KUBELET` and `LOG` on dedicated partitions ([Upgrading Talos, volumes](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md#volumes-and-storage)). Use this only when USB boot fails. |

Talos 1.14 replaces `.machine.install` with the `UnattendedInstallConfig` document, which selects the install disk with a CEL `volumeSelector` ([Upgrading Talos, install](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md#install-files-and-container-runtime)). On an SBC the raw image is already the installed system; point the selector at the same disk. **Unverified:** the exact behavior when the boot disk and the selected install disk differ on `rpi_generic`.

## First flashing and enrollment with Terraform

The flow keeps one manual, physical step (writing the image) and does the rest from `clusters/<name>/` with `mise run cluster:up <name>`.

1. **Schematic and image URL (Terraform, no node needed).** `talos_image_factory_schematic` plus `talos_image_factory_urls` (`sbc = "rpi_generic"`, `architecture = "arm64"`) give the `disk_image` URL as an output.
2. **Flash (human).** Download, `xz -d`, write to the boot medium, insert, power on. A mise task can print the URL and the `dd` command, but must not run `dd` or `sudo` itself.
3. **Maintenance mode.** The node boots without config, gets a DHCP address and waits for a config on the Talos API (port 50000) without TLS client auth ([Raspberry Pi guide](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/rpi_generic.md#bootstrapping-the-node) uses `talosctl apply-config --insecure`). Reserve the address in DHCP (or give a static address in the config) before step 4: every resource below is keyed on the node address.
4. **Secrets.** A secrets bundle generated once outside the module and passed as an ephemeral input (see the next section) gives the cluster PKI and the admin client config.
5. **Machine configs.** The ephemeral resource `talos_machine_configuration` renders **one config per node** (`for_each` over the nodes map), with `talos_version` pinned to the version used at creation ("the config-generation contract", [provider docs](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine)), `kubernetes_version`, and `config_patches` that carry the role, hostname, VIP, install selector and labels. Patches must go here: `talos_machine` 0.12.0 has no `config_patches` argument, only `machine_configuration[_wo]`, `image`, `client_configuration[_wo]`, `kubeconfig[_wo]`, `drain_on_upgrade`, `ignore_kubernetes_upgrade_drift`, `reboot_mode` and `on_destroy` ([talos_machine schema](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine)).
6. **Apply.** `talos_machine` (new in 0.12.0) applies the config and, with `image` set, keeps the OS version in sync. **Unverified:** that `talos_machine` applies to a node in maintenance mode on the first run. The provider docs do not describe the insecure first apply; `talos_machine_configuration_apply` is the older resource that the official examples use for that step. Test both on one Pi before writing the module.
7. **Bootstrap.** `talos_cluster` bootstraps etcd on one control-plane node (`node` "Must be an IP"; a hostname goes in `endpoint`), lists every control-plane IP in `control_plane_nodes` ("Required for HA clusters"), tracks `kubernetes_version`, and completes "once the Talos layer (etcd, apid, kubelet) is healthy"; it "does not wait for Kubernetes components" ([talos_cluster](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/cluster)). That suits a CNI-less cluster: the nodes stay `NotReady` until Cilium runs. `talos_machine_bootstrap` is the older single-purpose resource.
8. **Credentials.** `talos_client_configuration` (talosconfig) exists only as a data source and an ephemeral resource. `talos_cluster_kubeconfig` (kubeconfig) exists as a data source, a resource and an ephemeral resource ([provider index, 0.12.0](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs)). The module uses the ephemeral forms only (see the next section).
9. **Bootstrap boundary.** `modules/bootstrap-gateway-api`, `modules/bootstrap-cilium` and `modules/bootstrap-argocd` run as on kind, against the **first control-plane IP** (`bootstrap_endpoint` output), not the VIP: the VIP "will not come alive until after you have bootstrapped Kubernetes" and its election depends on etcd and the API server ([Virtual (shared) IP](https://docs.siderolabs.com/talos/v1.14/networking/advanced/vip.md)), and `talos_cluster` returns before Kubernetes components are ready. Gate the bootstrap modules on the ephemeral `talos_cluster_health` with `skip_kubernetes_checks = true`: the full check waits for `Ready` nodes, which never happens before Cilium, so it would deadlock. **Unverified:** that the skipped check also proves the API server answers, and that an ephemeral resource can gate the `helm`/`kubernetes` providers in the same apply; the local rehearsal must confirm both. Cilium must arrive in time: after bootstrap, Talos "will hang at phase 18/19 with `retrying error: node not ready`", and "you have about 10 minutes to apply Cilium before the node retries" ([Deploy Cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md#machine-configuration-prerequisites)). In one `terraform apply` the gap is short.

### Machine secrets in state and the R2 backend

With `talos_machine_secrets` as a resource, the state holds the Kubernetes CA key, the etcd CA key, the Talos OS CA key, the service-account key, the etcd encryption secret, the bootstrap token and the `os:admin` client key. With `talos_cluster_kubeconfig` as a resource, it also holds a cluster-admin kubeconfig.
The provider schema marks these as sensitive, which hides them in plan output but still writes them to state ([talos_machine_secrets](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine_secrets)).

Consequences for `terraform-state` on R2 (`clusters/<name>/terraform.tfstate`):

- **Anyone who can plan holds cluster root and can rewrite the state.** Only the Cloudflare API token has a read-only twin. The R2 state token is shared by `tf` and `tf:read` (both load `landing-zone/cloudflare/pass/state.env`) and is read-write on the whole `terraform-state` bucket. With option A, any process that can plan, agents included, would read the full Talos and Kubernetes PKI and the key that encrypts Kubernetes Secrets in etcd, and could tamper with every state object in the bucket. This is the main reason to keep secrets out of state.
- **R2 has no object versioning** (`landing-zone/cloudflare/README.md`). A corrupted or deleted state loses the only copy of the PKI. Talos can rebuild a secrets bundle from a control-plane config (**unverified**: `talosctl gen secrets --from-controlplane-config`), but that needs a working node and a talosconfig.
- Terraform has no client-side state encryption (OpenTofu has). **Unverified** for Terraform 1.17.

The provider supports a secret-free state: ephemeral resources `talos_machine_secrets`, `talos_machine_configuration`, `talos_client_configuration`, `talos_cluster_kubeconfig`, `talos_cluster_health` (already in 0.11.0), and write-only inputs (`machine_configuration_wo`, `client_configuration_wo`, `kubeconfig_wo`) on `talos_machine` and `talos_cluster` ([Using Ephemeral Resources](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/guides/using_ephemeral_resources)). It needs Terraform 1.11 or later; the repo pins 1.17.2.
The guide warns: ephemeral secrets **must** live in a secret manager, or each run generates a new PKI.

Options:

In every option except A, the module has one contract: the bundle is an ephemeral input variable, configs, talosconfig and kubeconfig are ephemeral, and `talos_machine`/`talos_cluster` take the `_wo` arguments. Only the **source** of the bundle changes.

| Option | Bundle source | State content | Needs | Agent `plan` |
| ------ | ------------- | ------------- | ----- | ------------ |
| A. `talos_machine_secrets` resource in the cluster root | Terraform state | Full PKI, admin creds | Nothing new | State token = cluster root (rejected) |
| B. Secrets backend | Bundle generated once, stored in the secrets backend, read at plan time by a mise task or an ephemeral resource of that backend | Hashes and IDs only | The secrets backend (open study) must support Terraform ephemeral reads | Plan needs secret access |
| C. Local file (stopgap) | Bundle generated once (`talosctl gen secrets`, or a throwaway root with local state), kept **outside the repo**, plus an offline backup; a mise task passes it as `TF_VAR_machine_secrets` | Hashes and IDs only | Nothing new | Only on the machine that holds the file |

**Recommendation:** C now, B when the secrets backend exists. Both keep the settled state layout (bucket `terraform-state`, key `clusters/<name>/terraform.tfstate`) and keep secrets out of state, so the shared read-write R2 token stops being a cluster-root token. Moving from C to B changes only where the mise task reads the bundle; no PKI rotation.

- **Not proposed:** option A in a second R2 bucket with its own token. It would change the settled state layout (one bucket, `terraform-state`) and need a `landing-zone/cloudflare` change, both of which need owner sign-off, and it still puts the PKI in state.
- **Unverified:** the mapping from the `talosctl gen secrets` YAML to the provider's `machine_secrets` object (field names differ). The throwaway-root variant avoids the mapping: its `talos_machine_secrets` output already has the right shape.
- **Hand-off to the secrets backend study:** the backend must serve Terraform ephemeral reads at plan time (not only ESO), and must allow an offline backup of the Talos bundle, which is the only copy of the cluster PKI.

## Control-plane topology and endpoint

etcd needs a majority, so the useful control-plane counts are 1 and 3. Two control-plane nodes are worse than one: either loss stops etcd.

| Nodes | Topology | Trade-off |
| ----- | -------- | --------- |
| 1 Pi | 1 control plane, workloads allowed on it | Same as `olympus` today. No HA; a reboot (upgrade) stops the API. |
| 3 Pis | 3 control planes, workloads allowed, no workers | **Recommended for 3 to 4 Pis.** Survives one node loss. etcd and the control plane cost part of each 8 GiB node (**unverified** figure; measure). |
| 5+ nodes | 3 control planes + workers | Only when there are enough nodes; x86 servers make better control planes (see below). |

Workloads on control planes: Talos 1.14 lists the control-plane `NoSchedule` taint in `KubeNodeConfig`, which replaces `.cluster.allowSchedulingOnControlPlanes` ([Upgrading Talos, Kubernetes](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md#kubernetes)).

Endpoint options for the Kubernetes API (the `cluster_endpoint` in every machine config):

- **Layer 2 VIP (recommended for the long-lived endpoint).** A `Layer2VIPConfig` on each control plane; the nodes elect the owner through etcd. Requirements: all control planes on one L2 segment; an unused address outside the DHCP pool ([Virtual (shared) IP](https://docs.siderolabs.com/talos/v1.14/networking/advanced/vip.md)). Caveats: the VIP comes up only after bootstrap; failover after a crash takes "up to a minute"; **never** use the VIP as the talosconfig endpoint, because it depends on etcd health. With one control plane, the VIP still gives a stable address for a later move to three.
- **DNS name with one A record per control plane.** Works without L2, but clients do not skip a dead node quickly ([Production Clusters](https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes.md#dns-records)).
- **External TCP load balancer.** No such device at home. Not worth it.

Use a DNS name that resolves to the VIP as the endpoint (for example `k8s.<cluster>.<home-domain>`), and add it to the API server cert SANs, so the VIP can change without new certificates. This endpoint goes in the long-lived kubeconfig; the first `terraform apply` bootstraps through the first control-plane IP instead, because the VIP does not exist yet (step 9 above). The talosconfig lists the control-plane node addresses as endpoints; `talosctl` fails over between them ([Production Clusters, step 13](https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes.md)).

Remote access through Cloudflare Tunnel is out of scope here. The Talos API is gRPC with mutual TLS, so only a TCP proxy can carry it ([Production Clusters](https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes.md#ensure-network-access)).

### Discovery

Talos uses a discovery service registry by default, the public `https://discovery.talos.dev/`, with affiliate data encrypted by a cluster key ([Discovery](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/discovery.md)). KubePrism uses discovery to learn the control-plane addresses. Keeping it on is the low-effort default; it is a dependency on an external service for a home cluster (open question).

## KubePrism

KubePrism is a TCP load balancer on `localhost:7445` on every node, enabled by default. It balances across the external endpoint, the local API server (on control planes) and every control-plane address from discovery, and drops unhealthy ones ([KubePrism](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/kubeprism.md)).
Talos points kubelet, the scheduler and the controller manager at it. Host-network components that talk to the API, such as Cilium, must be pointed at it too. With KubePrism, a VIP failover does not affect workloads inside the cluster ([VIP, impact on workloads](https://docs.siderolabs.com/talos/v1.14/networking/advanced/vip.md#impact-on-workloads)).

Configured by the `KubePrismConfig` document in Talos 1.14 (the old `.machine.features.kubePrism` is deprecated). Keep the default.

## Cilium on Talos

### Machine config

Talos 1.14 splits the old `cluster.network.cni` and `cluster.proxy` fields into documents. To install no CNI and no kube-proxy ([Deploy Cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md#machine-configuration-prerequisites)):

```yaml
apiVersion: v1alpha1
kind: KubeFlannelCNIConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeProxyConfig
enabled: false
```

On Talos earlier than 1.14, or with an older config contract, the same is `cluster.network.cni.name: none` and `cluster.proxy.disabled: true`. The module does **not** support that format: infra is greenfield, so it validates `config_contract >= v1.14` and renders only multi-document configs. A future contract bump is a deliberate migration. Apply the patch to all nodes, before bootstrap.

### Helm values (kube-proxy replacement)

From the Talos guide, "Without kube-proxy" tab:

```yaml
ipam:
  mode: kubernetes
kubeProxyReplacement: true
k8sServiceHost: localhost   # KubePrism
k8sServicePort: 7445
securityContext:
  capabilities:
    ciliumAgent: [CHOWN, KILL, NET_ADMIN, NET_RAW, IPC_LOCK, SYS_ADMIN, SYS_RESOURCE, DAC_OVERRIDE, FOWNER, SETGID, SETUID]
    cleanCiliumState: [NET_ADMIN, SYS_ADMIN, SYS_RESOURCE]
cgroup:
  autoMount:
    enabled: false          # Talos already mounts cgroup2 and bpffs
  hostRoot: /sys/fs/cgroup
```

Why each Talos-specific value: Talos forbids workloads from loading kernel modules, so `SYS_MODULE` is dropped from the agent capabilities; Talos mounts cgroup v2 and bpffs itself; IPAM must be `kubernetes` ([Deploy Cilium, prerequisites](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md#prerequisites)).

Gateway API on Cilium also needs, from the Talos guide's "Without kube-proxy + Gateway API" tab:

```yaml
kubeProxyReplacement: true
gatewayAPI:
  enabled: true
  enableAlpn: true          # "required to negotiate HTTP/2": needed for GRPCRoute over TLS
  enableAppProtocol: true
```

([Deploy Cilium](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md); `l7Proxy` stays at its default `true`). Cilium does not install the Gateway API CRDs, and the ones from Gateway API v1.6.3 "must be installed" first: GatewayClass, Gateway, HTTPRoute, GRPCRoute, BackendTLSPolicy, ReferenceGrant and **TLSRoute**; TCPRoute, UDPRoute and ListenerSet are optional ([Cilium Gateway API](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)). So the `gateway-api-crds` component must ship every CRD Cilium requires, TLSRoute included, pinned to v1.6.3 (bumped together with Cilium). That matches the plan: `gateway-api-crds` owns the CRDs and comes before Cilium. Without a LoadBalancer implementation at home, use `gatewayAPI.hostNetwork.enabled: true` or keep traffic on the `cloudflared` tunnel (open question).

Known issue: Talos `forwardKubeDNSToHost` (on by default) with Cilium `bpf.masquerade: true` can break CoreDNS; the fix is `forwardKubeDNSToHost: false` ([Deploy Cilium, known issues](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md#known-issues)). In Talos 1.14 this setting sits in the `hostDNS` section of `ResolverConfig`.

Cilium's connectivity test needs `pod-security.kubernetes.io/enforce=privileged` on its namespace on Talos (same page). The cluster policy layer must allow that label for the test namespace only.

### Install method

The Talos guide offers Helm, an inline manifest (`KubeInlineManifestConfig`) and the Cilium CLI. **Use Helm through `modules/bootstrap-cilium`, not the inline manifest.** Reasons:

- Talos only creates missing inline-manifest resources and re-applies them on `talosctl upgrade-k8s` ([Deploy Cilium, inline manifest](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md)); since Talos 1.13 this uses server-side apply with pruning ([Upgrading Kubernetes](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes.md#kubernetes-manifest-synchronization)). Every Kubernetes upgrade would then fight Argo CD, which owns `rendered/cilium`.
- Helm keeps the bootstrap path the same as on kind; only the values differ.

The same reasoning applies to CoreDNS, which Talos deploys as a bootstrap manifest and updates on `upgrade-k8s`. Argo CD must not also manage CoreDNS, or Talos must stop deploying it (`KubeCoreDNSConfig`; open question).

The homelab `bootstrap-cilium` module templates the full upstream `values.yaml` (186 KB). The infra module should take a short values file per target (kind, Talos), so the Talos deltas above stay readable and reviewable.

## Storage for stateful workloads

Sidero Labs recommends separate disks for storage, apart from the Talos install disk, and warns against NFS ([Storage](https://docs.siderolabs.com/kubernetes-guides/csi/storage.md)).

| Option | Fit for Pis | Needs |
| ------ | ----------- | ----- |
| `UserVolumeConfig` + local-path-provisioner | **Start here.** Simple, no replication: data is lost with the node ([Local Storage](https://docs.siderolabs.com/kubernetes-guides/csi/local-storage.md)). | A user volume (mounted at `/var/mnt/<name>`, [User Volumes](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/user.md)); provisioner root set to that path; privileged label on its namespace. |
| App-level replication on local volumes (e.g. CloudNativePG) | Good for databases | Three nodes for real HA. |
| Longhorn (V1 data engine) | Possible with 3 SSD-backed Pis | `iscsi-tools` and `util-linux-tools` extensions; a `UserVolumeConfig` or `RawVolumeConfig` disk per node ([Longhorn](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md)). CPU and memory cost on 8 GiB Pis: **unverified**, measure. |
| Rook/Ceph | No | "Ceph can be rather slow for small clusters" and "may eat up a significant amount of the resources" ([Storage](https://docs.siderolabs.com/kubernetes-guides/csi/storage.md#rookceph)). |
| NFS | No | Discouraged by Sidero Labs. |

Talos 1.14 enables workload isolation (`SecurityProfileConfig.workloadIsolation: true`) by default for new clusters, and "the deprecated in-tree Kubernetes iSCSI volume plugin does not work" with it ([What's new in 1.14](https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos.md)). **Unverified:** Longhorn (a CSI driver that calls `iscsiadm` from the host) under workload isolation. Test before choosing Longhorn.

Disk encryption: the Pi has no TPM, so `STATE` and `EPHEMERAL` can use `nodeID` keys (protects a removed disk only) or `kms` (needs a network KMS) ([Disk Encryption](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-encryption.md)).

## Upgrades driven from Terraform

### Talos OS

- `talos_machine.image` set to `factory.talos.dev/metal-installer/<schematic-id>:<version>`. A new version or a new schematic ID upgrades the node in place; `drain_on_upgrade` cordons and drains first and needs a kubeconfig, preferably `kubeconfig_wo` from the ephemeral `talos_cluster_kubeconfig` ([talos_machine](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine)).
- Upgrade one node at a time. Talos refuses a control-plane upgrade that would lose etcd quorum, but other quorum-based software (Longhorn, CloudNativePG) has no such guard ([Upgrading Talos, FAQ](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md#faqs)). With `for_each`, Terraform cannot chain instances through `depends_on`; the provider docs suggest `terraform apply -parallelism=1`. A `mise run cluster:upgrade <name>` task should force it.
- Upgrade through each minor release: "upgrade to the latest patch release of all intermediate minor releases" ([supported upgrade paths](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md#supported-upgrade-paths)). The module input is one version, so a skip of a minor needs several applies; a variable validation can reject a jump of more than one minor from the last applied version (**unverified**: how the module learns the running version; `talos_machine` reads it on refresh).
- A/B images allow `talosctl rollback`. An invalid installer reference aborts the upgrade.
- Do **not** bump `talos_version` of `talos_machine_configuration` on each upgrade: it is the config contract of the cluster's creation. Bumping it is a separate, deliberate change ([talos_machine, upgrade example](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine#upgrade-example)).
- Upgrades keep old defaults: a cluster upgraded to 1.14 gets neither workload isolation nor filesystem trim until the documents are added ([Upgrading Talos, config changes](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md#machine-configuration-changes)). The module should set these documents explicitly, so new and upgraded clusters match.

### Kubernetes

- `talos_cluster.kubernetes_version` drives the upgrade: it runs Talos `upgrade-k8s` (pre-pull, static pods one by one with health gates, kubelet node by node, bootstrap manifests re-applied) ([talos_cluster](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/cluster#upgrading-kubernetes)).
- Set `ignore_kubernetes_upgrade_drift = true` on `talos_machine`, so `talos_machine` does not push new image tags in parallel; the provider marks this flag **experimental**. Keep `kubernetes_version` in `talos_machine_configuration` equal to `talos_cluster.kubernetes_version`, so new nodes join at the right version.
- Talos 1.14 supports Kubernetes 1.33 to 1.37 ([support matrix](https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix.md)). Check the matrix before each Talos minor upgrade.

### Version pins

Pin the Talos version, the Kubernetes version and the provider in Terraform, and let Renovate propose bumps (custom regex managers for the Talos and Kubernetes versions; **unverified**: datasource choice). Upgrade order: Talos first (within the supported Kubernetes range), then Kubernetes.

## eBPF, BTF and runtime security (Falco, Tetragon)

| Item | Finding | Status |
| ---- | ------- | ------ |
| Kernel version | Linux 6.18.48 in Talos 1.14.0 ([What's new](https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos.md#component-updates)). Above Falco modern eBPF (5.8) and Cilium (5.10) minimums. | Verified (version may move in patch releases) |
| Same kernel on Pi | One arm64 kernel for all SBCs; the overlay brings firmware, u-boot and device trees. | **Inferred** from the overlay model |
| BTF (`CONFIG_DEBUG_INFO_BTF`) | Cilium now lists `CONFIG_DEBUG_INFO_BTF=y` as a base requirement ([Cilium system requirements](https://docs.cilium.io/en/stable/operations/system_requirements/)), and Talos documents full Cilium support and "full kernel module support for eBPF". So BTF is very likely present on amd64 and arm64. | **Unverified** directly. Check: `talosctl -n <node> ls /sys/kernel/btf/vmlinux` |
| Kernel modules | `CONFIG_MODULE_SIG_FORCE` and `module.sig_enforce=1`: only signed modules load ([Talos hardening](https://docs.siderolabs.com/talos/v1.14/security/talos-default-hardening-and-cis-compliance.md)). Falco's kernel-module driver cannot work; use `modern_ebpf`. | Verified |
| Lockdown | Talos 1.14 SecureBoot images run `lockdown=integrity`, no longer `confidentiality`, "which improves compatibility with eBPF tooling" ([What's new, lockdown](https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos.md#kernel-lockdown-mode)). The Pi boots without SecureBoot, so no lockdown is expected there. | Pi state **unverified**. Check: `talosctl read /sys/kernel/security/lockdown` |
| Tetragon `Override` | Needs `CONFIG_BPF_KPROBE_OVERRIDE` and error-injection support on the target function. | **Unverified** on Talos arm64; `homelab/docs/explanation/runtime-security-with-tetragon-and-falco.md` records the same gap. `Sigkill` does not depend on it. |
| sysctls | Since Talos 1.12, KSPP sysctls restrict kernel pointers, `/proc` and unprivileged BPF ([Talos hardening](https://docs.siderolabs.com/talos/v1.14/security/talos-default-hardening-and-cis-compliance.md#runtime-sysctl-settings)). The exact `kernel.perf_event_paranoid` value decides whether Falco starts with `CAP_PERFMON` alone (homelab needed `SYS_ADMIN` at value 4 on Colima). | Value **unverified**. Check: `talosctl get kernelparamstatus` |
| Workload isolation | In 1.14 containerd, kubelet and pods run in a dedicated PID and mount namespace under `sandboxd`. eBPF hooks are kernel-wide, so events still cover every process. **Unverified:** whether `hostPID` agents still see host services (`machined`, `apid`) in `/proc` for process enrichment. | **Unverified** |
| Pod Security | Falco, Tetragon and Cilium need privileged namespaces. The cluster policy layer must allow the privileged label on those platform namespaces. | Design note |

Plan: run a short check list on the first Pi before enabling Falco or Tetragon there, and record the results in the repo (the homelab doc has the same open item).

## What local x86 servers change

| Topic | Raspberry Pi (arm64) | x86 server (amd64) |
| ----- | -------------------- | ------------------ |
| Boot assets | Raw disk image with the `rpi_generic` overlay, written by hand | ISO on USB, or PXE from the Image Factory; no overlay. `talos_image_factory_urls` with `platform = "metal"`, `architecture = "amd64"`. |
| Install | Image is the system disk | Install from ISO to a disk chosen by `UnattendedInstallConfig.volumeSelector` (CEL, e.g. `disk.transport == 'nvme'`). |
| Extensions | None by default | CPU microcode (`siderolabs/intel-ucode` or `siderolabs/amd-ucode`), NIC or GPU firmware as needed. One schematic per (architecture, hardware family). |
| Firmware security | No TPM, no SecureBoot (inferred) | UEFI SecureBoot with UKI, TPM-sealed disk keys (`tpm` key kind), `lockdown=integrity` by default ([SecureBoot](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/bare-metal-platforms/secureboot.md)). |
| Reboots | `kexec` | `kexec`, except with SecureBoot: full firmware reboot, slower ([Upgrading Talos](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md#talosctl-upgrade)) |
| Disks | USB SSD | NVMe/SATA direct; Longhorn and even Ceph become realistic. RAID and LVM documents exist in 1.14. |
| Roles | Workers, or control planes in a Pi-only cluster | Better control planes (etcd fsync latency, memory). A mixed cluster: x86 control planes, Pi workers. |
| Images | arm64 | amd64. A mixed cluster needs multi-arch images everywhere (already a rule in homelab). |

The module stays the same; the per-node input (`arch`, `schematic`, install selector) carries the difference.

## Proposed shape of `modules/cluster-talos`

Goal: the same output contract as `modules/cluster-kind`, so `bootstrap-*` modules and the `helm`/`kubernetes` providers do not care which module made the cluster.

### Inputs

| Name | Type | Notes |
| ---- | ---- | ----- |
| `name` | `string` | Cluster name. |
| `talos_version` | `string` | Installed Talos version, e.g. `v1.14.6`. Drives `talos_machine.image`. |
| `config_contract` | `string` | `talos_version` of `talos_machine_configuration`. Pinned at creation, changed only on purpose. Validation: `>= v1.14`. |
| `kubernetes_version` | `string` | Feeds both `talos_cluster` and `talos_machine_configuration`. |
| `endpoint` | `object({ host = string, port = optional(number, 6443) })` | DNS name or VIP for the long-lived API endpoint. Added to cert SANs. Not used for bootstrap. |
| `vip` | `object({ address = string, link = string })`, nullable | Renders `Layer2VIPConfig` on control planes. |
| `schematics` | `map(object({ overlay = optional(object({ name = string, image = string, options = optional(any) })), extensions = optional(list(string), []), extra_kernel_args = optional(list(string), []) }))` | One entry per hardware family (`rpi4`, `x86-intel`, ...). |
| `nodes` | `map(object({ ip = string, endpoint = optional(string), role = string, arch = string, schematic = string, install_selector = optional(string), labels = optional(map(string), {}), patches = optional(list(string), []) }))` | Key = hostname. `ip` is required and validated as an IP (`talos_cluster.node`, `control_plane_nodes` and `talos_cluster_health` need IPs); `endpoint` is an optional hostname to connect through. Validation: `role` in `controlplane`/`worker`; control-plane count 1 or 3+ and odd. |
| `allow_scheduling_on_control_planes` | `bool` | Default `true` for Pi-only clusters. |
| `pod_subnet`, `service_subnet` | `string` | Match `cluster-kind` names. |
| `cluster_patches` | `list(string)` | Extra documents for every node (e.g. `ResolverConfig`, `SysctlConfig`). |
| `cni` | `string` | `"none"` only for now (Cilium from `bootstrap-cilium`); renders the `KubeFlannelCNIConfig` delete and `KubeProxyConfig` documents. |
| `discovery_service_endpoint` | `string`, nullable | `null` = Talos default public service. |
| `machine_secrets` | `object`, `ephemeral = true`, required | The secrets bundle (options B or C). The module never creates secrets. |
| `drain_on_upgrade` | `bool` | Default `true`. |

No `kubeconfig_path`/`talosconfig_path` inputs: ephemeral values cannot be written by `local_file`, and admin credentials must not land in the repo tree. A mise task (`cluster:creds <name>`) writes them with `talosctl`/`kubectl` into a path outside the repo (e.g. under `~/.config`) when a human needs them.

Fixed inside the module, not inputs: KubePrism on 7445, `SecurityProfileConfig.workloadIsolation`, `FilesystemTrimConfig`, `ignore_kubernetes_upgrade_drift = true`.

### Outputs

| Name | Notes |
| ---- | ----- |
| `name`, `endpoint` | Same names as `cluster-kind`. `endpoint` is the VIP DNS name. |
| `bootstrap_endpoint` | `https://<first control-plane IP>:6443`, for the `helm`/`kubernetes` providers of the bootstrap modules in the first apply. |
| `cluster_ca_certificate`, `client_certificate`, `client_key`, `kubeconfig` | Always **ephemeral** (`ephemeral = true`), never stored. Same names as `cluster-kind`, but the root wires them only into provider configuration. **Unverified:** that the `helm` and `kubernetes` providers accept ephemeral values in their configuration on Terraform 1.17 (the language allows ephemeral values in provider blocks; the providers' behavior needs the rehearsal). If `cluster-kind` keeps non-ephemeral outputs, the root modules differ slightly per target. |
| `talosconfig` | Ephemeral. |
| `k8s_service_host`, `k8s_service_port` | `localhost` and `7445`, for `bootstrap-cilium`. `cluster-kind` should expose the same pair (its API server address), so the Cilium module takes them from either. |
| `cilium_target` | `"talos"`, to select the Cilium values file. |
| `schematic_ids`, `installer_images`, `disk_image_urls` | Per schematic; `disk_image_urls` drives the manual flashing step. |
| `nodes` | Map of node name to address and role, for the talosconfig endpoints and for tasks. |

### Resource graph

```text
talos_image_factory_schematic[schematic]
  -> data.talos_image_factory_urls[schematic]           (installer, disk_image)
var.machine_secrets (ephemeral)
  -> ephemeral talos_machine_configuration[node]        (config_contract, kubernetes_version, config_patches per node)
  -> ephemeral talos_client_configuration
  -> talos_machine[node]                                (machine_configuration_wo, client_configuration_wo, image,
                                                         ignore_kubernetes_upgrade_drift)
  -> talos_cluster                                      (node = first CP ip, control_plane_nodes = all CP ips,
                                                         client_configuration_wo, kubernetes_version)
  -> ephemeral talos_cluster_health                     (skip_kubernetes_checks = true; gate for bootstrap modules)
  -> ephemeral talos_cluster_kubeconfig
```

The cluster root `clusters/<name>/` then calls `bootstrap-gateway-api`, `bootstrap-cilium` and `bootstrap-argocd`, with the R2 backend key `clusters/<name>/terraform.tfstate`.

## Proposed next steps

1. Owner answers the open questions below, at least the hardware inventory and the secrets option.
2. **Local rehearsal, no hardware.** `talosctl cluster create` on a dev machine, with a draft `modules/cluster-talos` and the bootstrap modules. Proves: the ephemeral contract end to end (secret-free state, providers fed by ephemeral outputs), the bootstrap through the first control-plane IP and the `talos_cluster_health` gate, the Cilium values, the Gateway API CRD set, the default-deny policy layer and a Talos/Kubernetes upgrade. With the **QEMU** provisioner, nodes can start in maintenance mode, so it also answers `talos_machine` vs `talos_machine_configuration_apply` for the first apply (**unverified**: the exact `talosctl cluster create` flag that skips config injection; the QEMU page does not document it). The **Docker** provisioner has no maintenance mode and no real kernel or boot path. Cannot prove: anything Pi-specific (boot media, EEPROM, u-boot, `rpi_generic` overlay) or the arm64 kernel items (BTF, lockdown, sysctls) on the target hardware.
3. One-Pi spike on a spare board, for the Pi-specific items only: flash, boot media and EEPROM, maintenance-mode apply on real hardware, the eBPF check list. Record results in this file.
4. Write `modules/cluster-talos` and `clusters/<name>/` from the rehearsal and the spike.
5. Build the 3-node cluster next to `olympus`, move workloads, then archive `gsuquet/homelab`.

## Open questions for the owner

1. **Hardware inventory.** How many Pis, which models (4B 8 GiB only, CM4, any Pi 5), which boot media, which SSDs and USB enclosures, PoE or USB-C power? Is `olympus` the only Pi today?
2. **Topology.** One control plane first, or wait for three Pis? Are x86 servers in scope for the first cluster, and as control planes?
3. **Cluster name.** Keep `olympus` for the Talos cluster (and run both side by side under different names during the move), or a new name?
4. **Network.** Same L2 segment for all nodes (needed for the VIP)? Free address for the VIP outside DHCP? DHCP reservations or static addresses in the Talos config? Internal DNS name for the API endpoint?
5. **Machine secrets.** Accept C (local bundle outside the repo, offline backup) as the stopgap and B when the secrets backend exists? Where does the offline backup live?
6. **Agent access.** Should agents be able to run `terraform plan` on Talos clusters at all? With B or C, plan needs the bundle, so agent planning means secret access.
7. **R2 read-only state token.** `tf` and `tf:read` share one read-write R2 token for the whole `terraform-state` bucket, so "read-only" plans can still write any state. Should `tf:read` (and agents) get a separate read-only R2 token, per bucket or per key prefix? This matters for every root, not only Talos.
8. **Pi 5 / CM5.** Exclude until they enter the support matrix, or allow the unofficial port for a lab node?
9. **Storage.** local-path first and add Longhorn later, or Longhorn from day one (needs extensions in the schematic, hence a new schematic and an upgrade to add it later)?
10. **CoreDNS ownership.** Leave CoreDNS to Talos (updated by `upgrade-k8s`) and keep it out of the catalog, or disable it in Talos and manage it as a component?
11. **Gateway on bare metal.** Cilium Gateway in host-network mode, a LoadBalancer implementation (Cilium LB IPAM with L2 announcements), or only `cloudflared` for ingress?
12. **Discovery service.** Accept the public `discovery.talos.dev`, or disable it (KubePrism then learns control planes only from the endpoint)?
13. **Runtime security on Pis.** Run Falco and Tetragon on the Pi cluster, given 8 GiB nodes and the unchecked kernel items above?
14. **`olympus` migration window.** Acceptable downtime for the move, and which stateful data must move (volumes, databases)?

## Sources

All accessed 2026-11-18.

- Sidero Labs, Talos v1.14 docs (VIP, Cilium Gateway values and QEMU pages re-checked 2026-11-19): [Raspberry Pi Series](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/rpi_generic.md), [Support Matrix](https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix.md), [Unofficial Ports](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/unofficial.md), [Image Factory](https://docs.siderolabs.com/talos/v1.14/learn-more/image-factory.md), [System Extensions](https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/custom-images-and-development/system-extensions.md), [Production Clusters](https://docs.siderolabs.com/talos/v1.14/getting-started/prodnotes.md), [Virtual (shared) IP](https://docs.siderolabs.com/talos/v1.14/networking/advanced/vip.md), [KubePrism](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/kubeprism.md), [Discovery](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/system-configuration/discovery.md), [Upgrading Talos Linux](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos.md), [User Volumes](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/user.md), [Disk Encryption](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-encryption.md), [Default Hardening](https://docs.siderolabs.com/talos/v1.14/security/talos-default-hardening-and-cis-compliance.md), [What's New in 1.14](https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos.md), [SecureBoot](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/bare-metal-platforms/secureboot.md), [QEMU](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/local-platforms/qemu.md).
- Sidero Labs, Kubernetes guides: [Deploy Cilium CNI](https://docs.siderolabs.com/kubernetes-guides/cni/deploying-cilium.md), [Upgrading Kubernetes](https://docs.siderolabs.com/kubernetes-guides/advanced-guides/upgrading-kubernetes.md), [Storage](https://docs.siderolabs.com/kubernetes-guides/csi/storage.md), [Local Storage](https://docs.siderolabs.com/kubernetes-guides/csi/local-storage.md), [Longhorn](https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md).
- Terraform Registry, `siderolabs/talos` 0.12.0: [talos_machine](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine), [talos_cluster](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/cluster), [talos_machine_secrets](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine_secrets), [talos_machine_configuration_apply](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/machine_configuration_apply), [talos_image_factory_schematic](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/image_factory_schematic), [talos_image_factory_urls](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/data-sources/image_factory_urls), [talos_cluster_health](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/ephemeral-resources/cluster_health), [Using Ephemeral Resources](https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/guides/using_ephemeral_resources).
- Cilium docs (stable): [System Requirements](https://docs.cilium.io/en/stable/operations/system_requirements/), [Gateway API support](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/).
- `gsuquet/homelab` (frozen): `ansible/inventory/`, `ansible/roles/os_raspberrypi/`, `docs/reference/gitops-layout.md`, `docs/explanation/runtime-security-with-tetragon-and-falco.md`, `docs/reference/terraform-modules/cluster-kind/index.md`.
