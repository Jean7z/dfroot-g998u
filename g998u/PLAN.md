# Port DFRoot → SM-G998U (G998USQSJHZB1)

Root efímero vía CVE-2026-43284 (DirtyFrag) + KernelSU como LKM, para
**Samsung Galaxy S21 Ultra US (SM-G998U)** con Bootloader bloqueado.

Base: `kurtulusakyuz/dfroot-s21` (a su vez fork de `diabl0w/DFRoot`, GPL-2.0).
Este repo añade el port al firmware US **`abG998USQSJHZB1`**
(kernel `5.4.274-qgki-30957850`, Android 15 / One UI 7, Snapdragon SM8350).

## Dispositivo verificado (real, via adb, 2026-11-05)

| Dato | Valor |
|---|---|
| Modelo / codename | SM-G998U / `p3q` (SM8350, lahaina) |
| Kernel | `5.4.274-qgki-30957850-abG998USQSJHZB1` (comp. 24-feb-2026) |
| Firmware | G998USQSJHZB1 — One UI 7.0, Android 15, SPL 2026-01-01 |
| Bootloader | locked (`flash.locked=1`), Knox 0x0 (`warranty_bit=0`) |
| SELinux | Enforcing — `SELINUX_DEVELOP=y` (flip a permissive posible) |

Config exacta extraída con adb: [`g998u/kernel-config/g998u-hzb1.config`](kernel-config/g998u-hzb1.config)
(7539 líneas de `/proc/config.gz`). Puntos clave:

- `CONFIG_KPROBES=y` + `CONFIG_KPROBES_QGKI=y` → bypass DEFEX por kprobe viable
- `CONFIG_MODULES=y`, `CONFIG_MODULE_SIG` **no** → LKM sin firma carga
- `CONFIG_SECURITY_DEFEX=y` → DEFEX activo, hay que bypassarlo (ya resuelto en base)
- `CONFIG_FUTEX_PI=y`, `CONFIG_XFRM_USER=y`, `CONFIG_INET_ESP=y` → primitiva DirtyFrag con bloques in-kernel
- `CONFIG_DEBUG_INFO_BTF` **no** → sin BTF (por eso GhostLock/CVE-2026-43499 no soporta 5.4-qgki; vía descartada)
- `CONFIG_ANDROID_VENDOR_HOOKS=y` → coincide con la causa del fallo de KernelSnitch en 5.4

## Qué se hereda del fork base (sin tocar)

- Exploit completo (ESP→page cache→crash_dump64→hook `libc++.so`→insmod): genérico Android 15
- Resolvedor de símbolos **device-agnóstico** (pass-1 base fija `0xffffffc010000000` + scan 64 MB; sin tablas por-firmware)
- `sud` (root shell stateless), mrun/ksudshim, manager, foreground guards (panic/Odin)
- Bypass DEFEX por dpolicy-injection, KDP/RKP-safe (tracepoints + task_work, sin text-patch)

## Qué cambia para G998U

1. **Árbol kernel + vermagic**: `kernel-G998USQSJHZB1/` (fuente Samsung OSRC o mirror comunitario
   `yanzihan/android_kernel_samsung_sm8350-p3q` @ `df91946`, Makefile 5.4.274 exacto — pero defconfig CHN/HK,
   se sustituye por nuestra config US real).
   `LOCALVERSION=-30957850-abG998USQSJHZB1`
2. **Rebuild de 2 .ko + APK**: `kernel-ksu` → `kko`; `dfmod` → `dirtyfrag-android15-5.4.ko`
   (se re-encrustan con `.incbin`, vermagic exacto obligatorio).
3. **Validación RE contra vmlinux HZB1** (una vez por firmware):
   - 78 símbolos del enum del resolvedor (`kernel-ksu/infra/symbol_resolver.h`) — `tools/check_symbol.c` lo automatiza
   - layout `selinuxfs` (`kernel-ksu/compat/selinux_publish_54.c`, capturado de HZC2)
   - offsets DEFEX `+0x3ed`/`+0x3f6` y tamaños dpolicy (`kernel-ksu/compat/samsung_defex.c`)
4. **Candidatos `vendor_file`** Qualcomm con ≥8 KB libres (`app/src/main/java/df/root/ExploitRunner.java:136-142`)
5. Cosmético: título UI (`MainActivity.java:77`)

## Fuente del kernel p3q HZB1

- **Oficial (defconfig US incluida):** `opensource.samsung.com/uploadSearch?searchValue=G998`
  → fila SM-G998U Android 15 (uploadId 14026) → Source → zip
  `SM-G998U_15_Opensource_G998USQSJHZAA_..._G998USQSJHZB1.zip` (~500–900 MB; requiere browser por CSRF/captcha).
- **Fallback CI:** mirror público `yanzihan/android_kernel_samsung_sm8350-p3q` (clone directo, sin captcha)
  + nuestra `g998u-hzb1.config` real vía `olddefconfig` (riesgo documentado: símbolos vendor Kconfig nuevos).

## Entorno de compilación

La compilación no corre en el teléfono: este repo incluye un
[GitHub Actions workflow](../.github/workflows/g998u-build.yml) que en Ubuntu runner hace
toolchain fetch → prepare del árbol → build del LKM → check symbols → rebuild del APK → artifacts.
(Colab descartado: sesiones efímeras, 12 GB RAM, setup de ~5 GB por sesión.)

## Limitaciones (heredadas, no filosofía)

- Root **efímero**: reboot limpia; re-carga con la app en primer plano
- Sin Zygisk/LSPosed aún; `su` solo por PATH/absoluto
- Nada de overlayfs cerca de `/system` (watchdog reset)
- Ejecutar solo sobre firmwares cuyo parche DirtyFrag (post 2026-05, SMR) **no** haya llegado
  → HZB1 (SPL 2026-01) conserva la ventana; **no actualizar firmware** sin revisar

## Licencia

GPL-2.0 (obligatoria: derivado de `diabl0w/DFRoot`). Solo úsalo en dispositivos propios o con autorización.
