# Options and risks of Talos on Raspberry Pi

<!-- readability: allow-code R2 CM4 -->

Evidence for the [options](../rfc/0025-talos-raspberry-pi.md#options-considered) and the
[risks](../rfc/0025-talos-raspberry-pi.md#drawbacks-and-risks) of RFC 0025.

## Options

### Ephemeral `cluster-talos`

- Configs, talosconfig and kubeconfig are ephemeral; `talos_machine` and `talos_cluster` are fed through `_wo`
  arguments.
- `bootstrap-cilium` installs Cilium from `rendered/cilium/`, as on kind (ADR-0015).

### `talos_machine_secrets` in state

- Encryption is that of RFC 0022. State carries the PKI.
- Not proposed either: the same in a second R2 bucket with its own token. It changes the settled state layout (one
  bucket) and needs a `landing-zone/cloudflare` change, both owner sign-offs, and still puts the PKI in state.

### Talos inline manifests

- Talos installs Cilium from a `KubeInlineManifestConfig` document; no bootstrap module for Cilium in the first apply.
- Talos re-applies inline manifests on every `upgrade-k8s` with server-side apply and pruning (since 1.13), while
  Argo CD owns `rendered/cilium`.
- The second install path has a second set of values outside the catalog (ADR-0015).

### Do nothing

- A reboot stops the API.
- The frozen repo stays outside the platform catalog, rendered manifests and the `network-policy` default deny.

## Risks and mitigations

| Risk | Detail |
| --- | --- |
| Firmware or u-boot regression | Pi boards are community-maintained in Talos. Keep the schematic in Git. |
| First apply | On a maintenance-mode node. Test `talos_machine` and `talos_machine_configuration_apply` in the rehearsal and the spike. |
| Health gate | The rehearsal confirms both points; the second apply is for the bootstrap modules, inside the [Cilium window](0025-talos-raspberry-pi-enrollment.md#rules). |
| Overhead | Control plane and etcd; Longhorn would add more. Measure on the rehearsal and the spike. |
| Experimental drift setting | Read release notes on each provider bump. |
| Drain on first create | See the Drain wiring row of [Enrollment rules](0025-talos-raspberry-pi-enrollment.md#rules). |
