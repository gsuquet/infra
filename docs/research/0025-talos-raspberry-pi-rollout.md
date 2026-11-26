# Current state, rollout and operations

<!-- readability: allow-code R2 CM4 -->

Evidence for [RFC 0025](../rfc/0025-talos-raspberry-pi.md); its [operational impact](../rfc/0025-talos-raspberry-pi.md#operational-impact) comes first.

## Current state

- `olympus` today: one Raspberry Pi (arm64, `olympus.local`, `k3s_server` group, no agents, API 6443, TLS SAN
  `olympus.local`), k3s `v1.34.1+k3s1`, embedded datastore, Ansible edits `cmdline.txt` for cgroups; homelab sizes
  target a Pi 4 with 8 GiB. Not recorded: model, Pi count, boot media, disks, network, power. The homelab line "a
  Talos cluster runs on the Raspberry Pi nodes" describes the target, not the present.
- The one R2 token of the `terraform-state` bucket is shared by `tf` and `tf:read`; only the Cloudflare token has a
  read-only twin. The problem this causes is in the [RFC context](../rfc/0025-talos-raspberry-pi.md#context).
- Checked 2026-11-18 on `docs.siderolabs.com` (`www.talos.dev` redirects): Talos `v1.14.6` (Linux 6.18, Kubernetes
  1.37), provider 0.12.0 (`0.13.0-alpha.1` exists), Cilium 1.20.5. **(unverified)**: no allowed source (memory,
  inference, `raspberrypi.com`, `factory.talos.dev`, `github.com/siderolabs/*`); needs hardware or a later study.

## Gates

| Step | Gate before the next step |
| --- | --- |
| Owner answers hardware and secrets questions | The step itself |
| Local rehearsal: `talosctl cluster create` + draft module | Ephemeral contract, first-IP bootstrap, health gate, Cilium values, CRD set, `network-policy`, one upgrade |
| One-Pi spike | Flash, boot media, EEPROM, maintenance-mode apply, eBPF check list |
| Write `modules/cluster-talos` and `clusters/name` | The step itself |
| Build next to `olympus`, move workloads, archive `gsuquet/homelab` | Last step |

Rehearsal: QEMU starts nodes in maintenance mode (the flag that
skips config injection is **(unverified)**); Docker has no maintenance mode or real boot path. Spike and eBPF
results go to a `docs/reference/` page on Talos on Raspberry Pi, linked from the Implementation section of RFC 0025.

## Operational detail

- Blast radius: a bad schematic or installer bricks nodes until reflashed; a lost bundle without backup loses the
  cluster PKI; the `cilium` component gains Talos overrides in the cluster's `cluster.yaml` and `gateway-api-crds` must
  ship TLSRoute.
- Tasks: adds `mise run cluster:upgrade <name>` and `mise run cluster:creds <name>` to the ADR-0019 task set
  (`cluster:up|plan|down`).
- Migration: the secrets bundle moves from the local file to the backend later without PKI rotation.
- Security: the shared read-write R2 token still
  writes every state; the public discovery service sees encrypted affiliate data; the privileged namespaces are those of Cilium, Falco,
  Tetragon and the Cilium test only.
- Cost: the hardware is Pis, SSDs, enclosures, switch and power; Image Factory and discovery are public; power draw not
  measured.
- Observability: `talosctl health` and node `Ready` after Cilium; the Cilium connectivity test; Argo CD watches the
  adopted bootstrap applications; the eBPF check list results come before runtime security.

## Follow-ups

- Read the bundle from Proton Pass (`pass-cli run`) instead of the local file.
- A read-only R2 state token for read-only plans, for every root.
- Longhorn or another replicated storage once 3 SSD Pis and its workload-isolation test pass.
- Pi 5 and CM5 once they enter the Talos support matrix.
- Disk encryption of `STATE` and `EPHEMERAL` (`nodeID` or `kms`) on Pis; TPM-sealed keys on x86.
- Renovate custom managers for the Talos and Kubernetes versions (RFC 0023).
- Falco and Tetragon on the Pi cluster after the eBPF check list.

## Sources

- `gsuquet/homelab` (frozen): `ansible/inventory/`, `ansible/roles/os_raspberrypi/`, `docs/reference/gitops-layout.md`
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): QEMU, re-checked 2026-11-19][qemu]

[qemu]: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/local-platforms/qemu.md
