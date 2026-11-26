# Hardware and boot assets for Talos on Raspberry Pi

<!-- readability: allow-code CM[45] -->

Which boards, boot media and images fit, and what changes on x86. **(unverified)** is defined in
[current state](0025-talos-raspberry-pi-rollout.md#current-state). Evidence for [RFC 0025](../rfc/0025-talos-raspberry-pi.md); the RFC holds the decision.

## Boards and boot media

| Board | Talos v1.14 status | Overlay | Use |
| --- | --- | --- | --- |
| Pi 4B (8 GiB) | In the [support matrix][matrix]; "officially tested" per the [Pi guide][rpi]. u-boot `rpi_arm64_defconfig`. | `rpi_generic` | **Yes** |
| CM4 | In the matrix, but only "community tested on one variant ... using Super 6C boards". Carrier matters (PCIe, eMMC vs Lite). | `rpi_generic` | Yes |
| Pi 5 | Not in the matrix; [Unofficial Ports][unofficial] only (`talos-rpi5/talos-builder`). Provider 0.12.0 `talos_image_factory_urls` accepts `sbc = "rpi_5"`; a working Image Factory `rpi_5` overlay and its support level **(unverified)**. | none official | No |
| CM5 | Not mentioned in any Talos doc **(unverified)**. | none | No |

All SBC ports are "community-maintained and provided as-is", with no official support for boot failures or firmware
quirks. Metal is Tier 1, but the tiers do not list SBCs. Pi 4 has no TPM and no UEFI SecureBoot on this u-boot
path (SecureBoot in the matrix is "arm64: UEFI" only) **(inferred)**.

| Boot medium | Fit | Notes |
| --- | --- | --- |
| SD card | Lab only | Documented default (`dd` to `/dev/mmcblk0`). Slow random writes, low endurance: bad for etcd and images. |
| USB 3 SSD (Pi 4B) | **Recommended** | Needs USB in the EEPROM `BOOT_ORDER`; recent EEPROMs try SD then USB by default **(unverified)**. u-boot USB boot with every USB-SATA bridge **(unverified)**: some need UAS quirks; test the exact enclosure before buying several. |
| NVMe | CM4 carrier with PCIe | Pi 4B has no PCIe: NVMe only through USB. u-boot NVMe boot on CM4 carriers with `rpi_generic` **(unverified)**. |
| eMMC (CM4 non-Lite) | Acceptable | Better than SD; flashing needs `rpiboot`. **(unverified)** for Talos. |
| SD boot + SSD data | Fallback | `STATE` on SD; `EPHEMERAL` moved to SSD by `VolumeConfig` `provisioning.diskSelector`; 1.14 can also split `ETCD`, `CRI`, `KUBELET`, `LOG`. Only when USB boot fails. |

Talos 1.14 replaces `.machine.install` with `UnattendedInstallConfig` (CEL `volumeSelector`). On an SBC the raw
image is the installed system: point the selector at the boot disk. Behavior when they differ on `rpi_generic`
**(unverified)**.

Firmware, once per board before the first Talos boot: write the "Misc utility images" EEPROM image with Raspberry Pi
Imager to a spare SD card, boot it, wait for the green LED to blink fast.

## Boot assets

```yaml
# Schematic for a headless Pi 4B / CM4 node; its ID is the hash of this content.
overlay:
  name: rpi_generic
  image: siderolabs/sbc-raspberrypi
  options:
    configTxtAppend: |
      dtoverlay=disable-wifi
      dtoverlay=disable-bt
customization:
  systemExtensions:
    officialExtensions: []  # siderolabs/iscsi-tools + siderolabs/util-linux-tools only if Longhorn is chosen
```

| Rule | Why |
| --- | --- |
| Installers come only from the [Image Factory][factory]: `factory.talos.dev/metal-installer/<schematic-id>:<talos-version>`. | `ghcr.io/siderolabs/installer` is no longer published since 1.14; provider examples still show `ghcr.io/siderolabs/installer:v1.9.0`: do not copy them. |
| `config.txt` changes live in the schematic (`configTxt` / `configTxtAppend`); upgrade only with the installer of the same schematic. | `config.txt` is set at build time, cannot change on a running node, and custom content "is not preserved automatically during upgrades". |
| Fan control (`gpio-fan`, `pwm-gpio-fan`) goes in `config.txt` when needed; `gpu_mem` / CMA only with the `vc4` extension, not needed headless. | Headless nodes. |
| No extension for Kubernetes, Cilium or Argo CD; Longhorn needs `iscsi-tools` and `util-linux-tools` on every node. | Extensions follow the storage choice. |
| Adding an extension = new schematic ID + Talos upgrade to it. | Extensions activate only at install or upgrade. |
| Kernel arguments go in `customization.extraKernelArgs`, not the machine config. | Schematic owns boot. |
| Schematic YAML in Git; ID derived by `talos_image_factory_schematic`; `talos_image_factory_urls` returns `disk_image` and `installer` per `talos_version`, `architecture`, `platform` or `sbc`. | Reproducible assets. |

Reference: the "vanilla" Pi schematic ID is `ee21ef4a5ef808a9b7484cc0dda0f25075021691c8c09a276591eedb638ea1f9`.

## Local x86 servers

| Topic | Raspberry Pi (arm64) | x86 server (amd64) |
| --- | --- | --- |
| Boot assets | Raw image with `rpi_generic`, written by hand | ISO on USB or PXE; `platform = "metal"`, `architecture = "amd64"`, no overlay |
| Install | Image is the system disk | From ISO to the disk of `UnattendedInstallConfig.volumeSelector` (e.g. `disk.transport == 'nvme'`) |
| Extensions | None by default | Microcode (`intel-ucode` / `amd-ucode`), NIC or GPU firmware; one schematic per (architecture, hardware family) |
| Firmware security | No TPM, no SecureBoot **(inferred)** | UEFI SecureBoot with UKI, TPM-sealed disk keys (`tpm`), `lockdown=integrity` |
| Reboots | `kexec` | `kexec`, except SecureBoot: full firmware reboot, slower |
| Disks | USB SSD | NVMe/SATA; Longhorn and even Ceph realistic; RAID and LVM documents in 1.14 |
| Roles | Workers, or control planes in a Pi-only cluster | Better control planes (etcd fsync latency, memory): x86 control planes, Pi workers |
| Images | arm64 | amd64: a mixed cluster needs multi-arch images everywhere |

The module is the same; per-node `arch`, `schematic` and install selector carry the difference.

## Sources

- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): Disk Encryption][encryption]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): System Extensions][extensions]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): Image Factory][factory]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): Support Matrix][matrix]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): Raspberry Pi Series][rpi]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): SecureBoot][secureboot]
- [Terraform Registry, `siderolabs/talos` 0.12.0: talos_image_factory_schematic][tf-schematic]
- [Terraform Registry, `siderolabs/talos` 0.12.0: talos_image_factory_urls][tf-urls]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): Unofficial Ports][unofficial]
- [Sidero Labs, Talos v1.14 (accessed 2026-11-18): What's New in 1.14][whats-new]

[encryption]: https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/storage-and-disk-management/disk-encryption.md
[extensions]: https://docs.siderolabs.com/talos/v1.14/build-and-extend-talos/custom-images-and-development/system-extensions.md
[factory]: https://docs.siderolabs.com/talos/v1.14/learn-more/image-factory.md
[matrix]: https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix.md
[rpi]: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/rpi_generic.md
[secureboot]: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/bare-metal-platforms/secureboot.md
[tf-schematic]: https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/resources/image_factory_schematic
[tf-urls]: https://registry.terraform.io/providers/siderolabs/talos/0.12.0/docs/data-sources/image_factory_urls
[unofficial]: https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/single-board-computers/unofficial.md
[whats-new]: https://docs.siderolabs.com/talos/v1.14/getting-started/what's-new-in-talos.md
