# DFRoot device and module runbook

This file records the working activation flow for this repository. It is specific to the Galaxy S21 Ultra SM-G998U on G998USQSJHZB1; it is not a general KernelSU guide.

## Device and root model

- Device: Samsung Galaxy S21 Ultra US, SM-G998U (`p3q`, Snapdragon 888).
- Firmware/kernel: G998USQSJHZB1, Android 15 / One UI 7, `5.4.274-qgki-30957850-abG998USQSJHZB1`.
- Root is ephemeral. A full device reboot clears the loaded exploit and KernelSU LKM. Installed module files persist under `/data/adb/modules`, but must be initialized again after root is restored.
- Keep DFRoot in the foreground when exploiting and loading KernelSU. The foreground guard exists because background LKM loading can crash the phone.

## What the components do

- **KernelSU LKM (`kko`)** provides the root manager and module lifecycle while loaded. In this port, it is injected after DirtyFrag obtains root; it is not a persistent kernel root.
- **Zygisk Next** is the Zygisk implementation for KernelSU. It injects Zygisk modules into Zygote and app processes. It is the injection layer, not the Xposed framework itself. The [Zygisk Next FAQ](https://github.com/Dr-TSNG/ZygiskNext/wiki/Basics-%26-FAQ) lists KernelSU as a supported root implementation.
- **Vector** is the current JingMatrix Xposed-compatible ART hooking framework (the successor/renaming of LSPosed). It is itself a Zygisk module; it depends on a working Zygisk implementation. It runs Xposed modules inside selected apps and provides the manager used to activate and scope those modules. See [Vector's README](https://github.com/JingMatrix/Vector#readme).
- **COPG** is a separate Zygisk module for per-app device identity and system/app customization. It is not an Xposed module and does not depend on Vector, but it does need a working Zygisk implementation. Its current installation notes list Zygisk Next, ReZygisk or NeoZygisk and advise against built-in Magisk Zygisk; see [COPG's README](https://github.com/AlirezaParsi/COPG#installation).

Relationship: **KernelSU → Zygisk Next → Vector/Xposed modules and COPG**. Vector and COPG are independent consumers of Zygisk.

## Recommended setup and activation

For the most reliable first activation, install or update all desired KernelSU modules before starting the DFRoot activation flow:

1. In KernelSU Manager, install and enable Zygisk Next.
2. Install and enable Vector from the official [JingMatrix/Vector releases](https://github.com/JingMatrix/Vector/releases).
3. Install and enable COPG from the official [AlirezaParsi/COPG releases](https://github.com/AlirezaParsi/COPG/releases), if wanted.
4. Open DFRoot and tap **Launch Root**. Keep its activity open until the exploit reports success.
5. Tap **Load KernelSU**. The app stages its files, loads `kko`, then runs KernelSU `post-fs-data`, the DFRoot mount stage, and KernelSU `services`.
6. The app waits up to 20 seconds for the Vector daemon (`vectord`) and COPG controller (`controller`) when those modules are installed and enabled. If ready, it marks `/dev/dfroot_modules_ready` and schedules a framework restart by killing Zygote after a short delay.
7. After Android comes back, open Vector from its system notification or launcher. In Vector, install/enable the Xposed modules you want and enable each for the intended apps. Open COPG's WebUI from KernelSU Manager to configure its profiles/features.

The app's framework restart is a **soft framework restart**, not a full device reboot: Android's Zygote processes restart so Zygisk can initialize against the current modules. It does not make root persistent. The KernelSU `post-fs-data` and `services` stages are explicitly run by DFRoot, and `mrun.sh` is told not to run `post-fs-data` a second time during its mount stage.

### Re-activating after module changes

Current code short-circuits **Load KernelSU** if KernelSU is already live and `/dev/dfroot_modules_ready` exists. That marker survives a framework restart but disappears on a full device reboot. For a newly installed/updated module after the current activation, the supported reliable route is:

1. Reboot the phone fully.
2. Open DFRoot, run **Launch Root**, then **Load KernelSU** again.

The module ZIP and settings remain on storage; the full reboot resets the live root session and readiness marker so the lifecycle stages run again. Do not assume pressing **Load KernelSU** a second time in the same session will rerun the stages.

## The two soft-restart controls

There are two related but distinct behaviors in the app:

- The manual/boot **Auto Soft Reboot** preference is passed into the exploit run.
- After module startup succeeds, `loadKsu()` separately schedules the framework restart for Zygisk. In the current code this restart is not gated by that preference.

That framework restart only replaces Zygote. A full power reboot is still required to reset the ephemeral root session and `/dev/dfroot_modules_ready`.

## Verification from ADB

Use the absolute KernelSU `su` path because Android's shell `PATH` may not contain the mirror:

```sh
adb shell /data/adb/ksu/bin/su -c 'id'
adb shell /data/adb/ksu/bin/su -c 'cat /sys/fs/selinux/enforce'
adb shell /data/adb/ksu/bin/su -c 'grep "^kernelsu " /proc/modules'
adb shell /data/adb/ksu/bin/su -c 'test -e /dev/dfroot_modules_ready && echo modules-ready'
adb shell /data/adb/ksu/bin/su -c 'ls -ld /data/adb/modules/zygisk_vector /data/adb/modules/COPG 2>/dev/null'
adb shell /data/adb/ksu/bin/su -c 'pidof vectord controller'
```

Expected signs:

- `id` reports `uid=0`.
- SELinux value `0` means permissive for this root session; `1` means enforcing.
- `/proc/modules` contains `kernelsu`.
- The readiness marker exists after a successful module start.
- `vectord` and/or `controller` should be present only if the corresponding module is installed, enabled and its service started. A missing PID is a signal to inspect logs and module status, not proof by itself that Zygisk is broken.

Useful logs:

```sh
adb logcat -d -s dfroot
adb shell /data/adb/ksu/bin/su -c 'dmesg | grep -iE "dfroot|kernelsu|zygisk|vector|copg"'
```

The app's output should include `DFROOT_KSU_LIVE=1`, `DFROOT_POSTFSDATA_RC=0`, `DFROOT_SERVICES_RC=0`, `DFROOT_DAEMONS_READY=1` and `DFROOT_FRAMEWORK_RESTART_SCHEDULED` on a successful path. If daemon readiness fails, the code skips the framework restart and reports the failure.

`DFROOT_DAEMONS_READY=1` is not a complete Zygisk health check: current code waits for `vectord` and `controller` only when the matching Vector/COPG module directories exist and are enabled. It does not directly verify Zygisk Next or test injection into a selected app. Confirm Zygisk Next in KernelSU and Vector's own framework status after the restart.

## Troubleshooting notes

- If Vector says the framework is inactive, check that Zygisk Next is enabled in KernelSU, its module is not disabled, Vector's module is installed/enabled, and the app is not excluded by a KernelSU unmount/denylist setting. Then reactivate DFRoot using the sequence above.
- If the Vector manager does not open, use its launcher icon or its system notification. A shell result ending in `com.android.shell/.BugreportWarningActivity` is Android's bug-report warning activity, not the Vector manager.
- COPG is not managed from Vector's Xposed-module list. Check COPG's KernelSU module status, `controller` process, and COPG WebUI separately.
- A module directory existing on disk does not prove that the module initialized in the current root session. Check KernelSU's status, startup markers, daemon/process status and module-specific UI.
- Do not run `ksud post-fs-data`, `ksud services` or `mrun.sh boot` manually as part of the normal flow; DFRoot already sequences them and duplicate stage execution can cause duplicate mounts or scripts.
- Never load the LKMs in the background or skip the foreground guard.

## Relevant implementation

- `app/src/main/java/df/root/ExploitRunner.java`: loads KernelSU, runs module stages, checks Vector/COPG daemons and schedules the framework restart.
- `app/src/main/java/df/root/MainActivity.java`: foreground guard, manual activation, boot flow and restart preferences.
- `app/src/main/java/df/root/BootReceiver.java`: posts the boot notification; actual exploit and load run through the visible activity.
- `app/src/main/assets/mrun.sh`: module mounts, install operations and lifecycle helpers.

This runbook describes the current branch implementation (last checked 2026-11-07). Upstream module instructions and behavior can change; use the linked official docs for version-specific requirements.
