# eBPF and runtime security on Talos

Kernel features that Cilium, Falco and Tetragon need, and the check for each. **(unverified)** is defined in
[current state](0025-talos-raspberry-pi-rollout.md#current-state). Evidence for [RFC 0025](../rfc/0025-talos-raspberry-pi.md); the RFC holds the decision.

## eBPF check list

| Item | Finding | Status |
| --- | --- | --- |
| Kernel | Linux 6.18.48 in Talos 1.14.0, above Falco modern eBPF (5.8) and Cilium (5.10). | Verified (moves in patches) |
| Same kernel on Pi | One arm64 kernel for all SBCs; the overlay adds firmware, u-boot, device trees. | **(inferred)** |
| BTF | Cilium requires `CONFIG_DEBUG_INFO_BTF=y`; Talos documents full Cilium support and "full kernel module support for eBPF". Check: `talosctl -n <node> ls /sys/kernel/btf/vmlinux`. | **(unverified)** |
| Kernel modules | `CONFIG_MODULE_SIG_FORCE`, `module.sig_enforce=1`: Falco's kernel-module driver cannot load; use `modern_ebpf`. | Verified |
| Lockdown | 1.14 SecureBoot images run `lockdown=integrity`, no longer `confidentiality`, which "improves compatibility with eBPF tooling"; the Pi boots without SecureBoot, so none expected. Check: `talosctl read /sys/kernel/security/lockdown`. | Pi **(unverified)** |
| Tetragon `Override` | Needs `CONFIG_BPF_KPROBE_OVERRIDE` and error injection on the target; `Sigkill` does not. Same gap in the homelab runtime-security doc. | **(unverified)** arm64 |
| sysctls | KSPP sysctls (since 1.12) restrict kernel pointers, `/proc`, unprivileged BPF. `kernel.perf_event_paranoid` decides if Falco starts with `CAP_PERFMON` alone (homelab needed `SYS_ADMIN` at 4). Check: `talosctl get kernelparamstatus`. | Value **(unverified)** |
| Workload isolation | containerd, kubelet and pods run under `sandboxd` in their own PID and mount namespaces; eBPF hooks stay kernel-wide. Whether `hostPID` agents still see `machined`, `apid` in `/proc` **(unverified)**. | **(unverified)** |
| Pod Security | Falco, Tetragon, Cilium need privileged namespaces: the namespace checks allow it on those platform namespaces only. | Design note |

The check list runs on the first Pi before Falco or Tetragon is enabled there; results go to a
`docs/reference/` page on Talos on Raspberry Pi, linked from the Implementation section of RFC 0025.

## Sources

- `gsuquet/homelab` (frozen): `docs/explanation/runtime-security-with-tetragon-and-falco.md`
- [Cilium (stable): System Requirements][cilium-req]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): Default Hardening][hardening]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): SecureBoot][secureboot]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): What's New in 1.14][whats-new]

[cilium-req]: https://docs.cilium.io/en/stable/operations/system_requirements/
[hardening]: https://docs.siderolabs.com/talos/v1.14/security/talos-default-hardening-and-cis-compliance.md
[secureboot]: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/bare-metal-platforms/secureboot.md
[whats-new]: https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos.md
