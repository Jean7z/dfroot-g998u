# DFRoot for Samsung Galaxy S21 Ultra (SM-G998U)

DFRoot provides an ephemeral root session for the US Snapdragon Galaxy S21 Ultra on firmware **G998USQSJHZB1**. It combines the DirtyFrag exploit path with a Samsung 5.4 KernelSU LKM. The kernel and exploit payloads are device and firmware specific.

## Supported target

| Property | Target |
| --- | --- |
| Device | Samsung Galaxy S21 Ultra, SM-G998U (`p3q`, Snapdragon 888) |
| Firmware | G998USQSJHZB1, Android 15 / One UI 7 |
| Kernel release | `5.4.274-qgki-30957850-abG998USQSJHZB1` |
| Bootloader | Locked |

Do not use these payloads on the Galaxy S21 SM-G991B or another G998U firmware without rebuilding and validating against that exact kernel. A full reboot removes root; the exploit must be run again.

## Runtime flow

1. Open DFRoot and run **Launch Root** while the activity remains in the foreground.
2. Load KernelSU from the app.
3. DFRoot initializes KernelSU module stages, applies its device-specific mounts, starts module services, then performs the configured framework soft reboot so Zygisk-capable modules can attach to the restarted Zygote.

The foreground guard is intentional: background loading of the kernel modules can cause a device crash. Optional **START AT BOOT** posts a notification that opens the guarded activity; it does not load modules in the background. `mrun.sh` provides Magisk-style module installation and lifecycle support. Zygisk Next, Vector and COPG are optional modules and are not bundled with DFRoot.

## Build

GitHub Actions provides two workflows:

- **G998U app build** builds the debug APK after app changes.
- **G998U kernel build** rebuilds KernelSU and DirtyFrag payloads against the HZB1 Samsung OSRC kernel, then packages the APK. Run it manually when kernel sources, kernel configuration or payload code changes.

The kernel workflow expects the public `Kernel.tar.gz` source archive configured in the workflow. It checks the kernel release and packaged module vermagic before uploading artifacts. The APK from GitHub Actions uses that runner's debug signing key; Android may reject it as an update if the installed app was signed with a different debug key.

For a local app build:

```sh
./gradlew :app:assembleDebug --no-daemon
```

For kernel payloads, run `bash g998u/ci/build.sh` in an Ubuntu environment with the required Android SDK and target kernel archive configured as `KERNEL_TARBALL_URL`.

## Port lineage

The exploit framework derives from [diabl0w/DFRoot](https://github.com/diabl0w/DFRoot). The Samsung 5.4 KernelSU compatibility layer originated in Galaxy S21 SM-G991B/HZC2 work; this repository adapts the device target and build to the G998U/HZB1 kernel. Internal identifiers such as `CONFIG_KSU_S21_54` remain compatibility names and do not define the supported handset.

## Safety and limits

- Root is temporary and is cleared by a full reboot.
- Keep the DFRoot activity open while loading kernel payloads.
- Do not use overlay mounts near `/system`; this device configuration has previously caused hard lockups.
- Validate the DirtyFrag patch level before updating firmware. An update may close the exploit window.

## License

GPL-2.0. Use only on devices you own or are authorized to test.
