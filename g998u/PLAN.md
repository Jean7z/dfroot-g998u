# Galaxy S21 Ultra G998U port

## Target

This repository targets the US Snapdragon Samsung Galaxy S21 Ultra (`SM-G998U`, `p3q`) on firmware `G998USQSJHZB1`.

| Property | Validated target |
| --- | --- |
| Android | 15 / One UI 7 |
| Kernel | `5.4.274-qgki-30957850-abG998USQSJHZB1` |
| Bootloader | Locked |
| SELinux | Enforcing; the exploit flow can set permissive for the root session |

The checked-in `g998u/kernel-config/g998u-hzb1.config` was captured from the device. `g998u-hzb1-resolved.config` is the resolved configuration used by CI. The build uses the Samsung OSRC HZB1 kernel archive, not the incomplete community p3q tree.

## Runtime architecture

The flow is: DirtyFrag exploit → `sud` root shell → embedded `df_self` stage → KernelSU LKM → module initialization and device mounts → framework soft reboot when configured.

The module runner and `ksudshim.sh` provide installation and lifecycle operations for KernelSU modules. Module files are not bundled. Root lasts until a full reboot; the exploit and KernelSU load must be repeated afterward. The foreground guard must remain enabled because a background LKM load may crash the device.

## Port boundaries

The exploit framework derives from `diabl0w/DFRoot`. The Samsung 5.4 compatibility layer has historical roots in the S21 SM-G991B/HZC2 implementation. Names such as `CONFIG_KSU_S21_54` and `compat/s21_54.h` are inherited identifiers; they are not the target device.

The G998U build must use its own HZB1 kernel tree, configuration, local version and module outputs. Do not use G991B binaries or treat a matching `5.4` version alone as ABI compatibility. Active G998U symbol discovery scans the Samsung 5.4 text range and must not fall back to a G991B/HZC2 address.

## Build and validation

`.github/workflows/g998u-app.yml` builds the APK for app-only changes. `.github/workflows/g998u-build.yml` is a manual full build that prepares the HZB1 kernel, builds KernelSU and `df_self`, embeds both payloads and packages the APK.

The full build must verify:

- kernel release equals `5.4.274-qgki-30957850-abG998USQSJHZB1`;
- `kko` and `df_self` were produced and embedded;
- both module vermagic strings match the target release;
- the final APK exists.

CI build success verifies compilation and artifact packaging. It does not replace runtime validation on the target device. The symbol report is diagnostic; actual module build/modpost and device load are the decisive checks.

## Known limitations

- Root is ephemeral and depends on the DirtyFrag vulnerability remaining unpatched on the installed firmware.
- Kernel payloads are specific to HZB1; another firmware requires a separately verified port.
- GitHub Actions debug APKs use an ephemeral runner signing key and may not update an APK installed with a different signer.
- A full kernel build requires the Samsung OSRC archive and can take substantially longer than the app-only workflow.
