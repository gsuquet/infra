# GKE Autopilot facts and cost figures

Detail for [RFC 0024](../rfc/0024-gke.md); check date, sources and **(unverified)** marks: see its
[Context](../rfc/0024-gke.md#context).

## Autopilot facts kept for a later decision

| Need | Autopilot |
|---|---|
| Privileged pods | Only for allowlisted partners; Falco, Tetragon and Cilium are not on the list |
| hostPath | Read-only `/var/log` only |
| Host namespaces | Blocked |
| `NET_ADMIN` | Dropped; re-enabled per cluster with `allow_net_admin` |
| Workloads in `kube-system` | Not allowed: cert-manager leader election moves to `cert-manager` |
| Webhooks | Allowed; GKE excludes managed namespaces and rejects webhooks on nodes, persistentvolumes, certificatesigningrequests, tokenreviews |
| Unprivileged DaemonSets, CRDs | Allowed (DaemonSet minimum 1m CPU / 2 MiB on bursting clusters) |
| Gateway API | GKE Gateway "is always enabled"; Experimental channel CRDs cannot be installed |
| Node SSH | Blocked |
| Own Cilium | Not applicable: DPv2 is the Cilium |
| Requests | No requests means 0.5 vCPU / 2 GiB; minimum 50m / 52 MiB with bursting, else 250m / 512 MiB; CPU:memory between 1:1 and 1:6.5, the smaller is raised. The tenant LimitRange must set default requests. |

## Cost figures

- Besides the management fee: nodes and boot disks, Cloud NAT gateway and per-GB processing with private nodes or external IPv4 addresses with public nodes, egress, persistent disks, DPv2 metrics in Managed Prometheus (per sample) and Logging/Monitoring above the free allotment, all **(unverified figures)**. No load balancer cost.
- Rough Autopilot baseline (1.25 vCPU, 3 GiB requests **(estimate, measure on kind first)**, us-central1 list:
  vCPU $0.0445 on demand / $0.0133 Spot, GiB $0.0049225 / $0.0014767 per hour) is about $51/month on demand and
  $15 on Spot; the Standard baseline should fit one 2 vCPU / 8 GiB node **(unverified sizing)**. Use those figures
  only as an upper bound to compare against the calculator.

## Sources

- [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing)
- [Autopilot resource requests](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/autopilot-resource-requests)
- [Autopilot security](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/autopilot-security)
- [Autopilot partner workloads](https://docs.cloud.google.com/kubernetes-engine/docs/how-to/run-autopilot-partner-workloads)
- [Autopilot partners](https://docs.cloud.google.com/kubernetes-engine/docs/resources/autopilot-partners)
