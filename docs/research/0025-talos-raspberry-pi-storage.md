# Storage on the Talos cluster

<!-- readability: allow-code V1 -->

Storage options on Raspberry Pis. **(unverified)** is defined in
[current state](0025-talos-raspberry-pi-rollout.md#current-state). Evidence for [RFC 0025](../rfc/0025-talos-raspberry-pi.md); the RFC holds the decision.

## Storage

Sidero Labs recommends storage disks apart from the install disk and warns against NFS ([Storage][storage]).

| Option | Fit for Pis | Needs |
| --- | --- | --- |
| `UserVolumeConfig` + local-path-provisioner | **Start here.** No replication: data dies with the node. | User volume at `/var/mnt/<name>`, provisioner root on it, privileged label on its namespace. |
| App replication on local volumes (CloudNativePG) | Good for databases | 3 nodes for real HA. |
| Longhorn V1 | Possible with 3 SSD Pis | `iscsi-tools`, `util-linux-tools`, a `UserVolumeConfig` or `RawVolumeConfig` disk per node; CPU and memory on 8 GiB **(unverified, measure)**. Longhorn under workload isolation **(unverified)**: in-tree iSCSI does not work with it; test first. |
| Rook/Ceph | No | "can be rather slow for small clusters", "may eat up a significant amount of the resources". |
| NFS | No | Discouraged by Sidero Labs. |

Talos 1.14 enables `SecurityProfileConfig.workloadIsolation: true` by default on new clusters. Disk encryption
without a TPM: `nodeID` keys (protect a removed disk only) or `kms` (network KMS).

## Sources

- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): Disk Encryption][encryption]
- [Sidero Labs, Kubernetes guides: Local Storage][local-storage]
- [Sidero Labs, Kubernetes guides: Longhorn][longhorn]
- [Sidero Labs, Kubernetes guides: Storage][storage]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): User Volumes][user-volumes]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): What's New in 1.14][whats-new]

[encryption]: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-encryption.md
[local-storage]: https://docs.siderolabs.com/kubernetes-guides/csi/local-storage.md
[longhorn]: https://docs.siderolabs.com/kubernetes-guides/csi/longhorn.md
[storage]: https://docs.siderolabs.com/kubernetes-guides/csi/storage.md
[user-volumes]: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-management/user.md
[whats-new]: https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos.md
