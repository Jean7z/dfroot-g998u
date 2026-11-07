#!/usr/bin/env bash
# Build the G998U/HZB1 kernel payloads and debug APK on Ubuntu.
# The target requires the Samsung OSRC kernel source and matching configuration.
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------- parameters
KERNEL_TREE_NAME="kernel-G998USQSJHZB1"
KERNEL_TREE_SRC="${KERNEL_TREE_SRC:-}" # optional extracted Samsung OSRC tree
# Real device vermagic split:
#   5.4.274-qgki-30957850-abG998USQSJHZB1
#   = kernel.release(5.4.274) + CONFIG_LOCALVERSION("-qgki") + MAKE LOCALVERSION below
MAKE_LOCALVERSION="${MAKE_LOCALVERSION:--30957850-abG998USQSJHZB1}"
OUT="$REPO_ROOT/out/ci-prepare"
TC="$REPO_ROOT/toolchains"
CONFIG_SRC="$REPO_ROOT/g998u/kernel-config/g998u-hzb1-resolved.config"


log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
mkdir -p "$TC" "$OUT"

# ---------------------------------------------------------------- host tools
log "Install kernel build dependencies"
sudo apt-get -y update >/dev/null 2>&1 || true
sudo apt-get -y install bc bison flex libncurses5-dev libssl-dev cpio python3 git curl xz-utils >/dev/null

# ---------------------------------------------------------------- toolchains
CLANG_BIN=$(ls -d "$TC"/clang-r383902*/bin 2>/dev/null | head -1 || true)
if [ -z "$CLANG_BIN" ]; then
  log "Fetch Clang r383902 required by the target kernel"
  HAVE_CLANG=0
  for mirror in \
    "codeload.github.com/AOSP-10/prebuilts_clang_host_linux-x86_clang-r383902/tar.gz/refs/heads/10" \
    "codeload.github.com/david7xwshenanigans/clang-r383902/tar.gz/refs/heads/clang-r383902" ; do
    if curl -fsSL --retry 2 "https://$mirror" -o "$TC/clang-mirror.tgz"; then
      mkdir -p "$TC/clang-mirror-ex"
      tar -xzf "$TC/clang-mirror.tgz" -C "$TC/clang-mirror-ex" && \
      d=$(find "$TC/clang-mirror-ex" -maxdepth 2 -name bin -type d | head -1) && \
      [ -n "$d" ] && mv "$(dirname "$d")" "$TC/clang-r383902" && HAVE_CLANG=1 && break
    fi
    echo "Clang mirror unavailable: $mirror"
  done
  [ "$HAVE_CLANG" = 1 ] || { echo "ERROR: unable to download Clang r383902 from the configured mirrors" >&2; exit 2; }
  CLANG_BIN="$TC/clang-r383902/bin"
fi

GCC_A64_BIN=$(ls -d "$TC"/aarch64-linux-android-4.9*/bin 2>/dev/null | head -1 || true)
if [ -z "$GCC_A64_BIN" ]; then
  log "Prepare the AArch64 GCC cross-tool prefix"
  if ! command -v aarch64-linux-gnu-gcc >/dev/null 2>&1; then sudo apt-get -y install gcc-aarch64-linux-gnu >/dev/null; fi
  mkdir -p "$TC/aarch64-linux-android-4.9/bin"
  for t in gcc ld ar nm objcopy ranlib strip readelf gcc-ar as elfedit; do
    c=$(command -v "aarch64-linux-gnu-$t" 2>/dev/null || true)
    [ -n "$c" ] && ln -sf "$c" "$TC/aarch64-linux-android-4.9/bin/aarch64-linux-android-$t"
  done
fi
GCC_A64_BIN=$(ls -d "$TC"/aarch64-linux-android-4.9*/bin 2>/dev/null | head -1 || echo /usr/bin)

GCC_ARM_BIN=$(ls -d "$TC"/arm-linux-androideabi-4.9*/bin 2>/dev/null | head -1 || true)
if [ -z "$GCC_ARM_BIN" ]; then
  log "Prepare the ARM32 compatibility cross-tool prefix"
  if ! command -v arm-linux-gnueabihf-gcc >/dev/null 2>&1; then sudo apt-get -y install gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf >/dev/null; fi
  mkdir -p "$TC/arm-linux-androideabi-4.9/bin"
  for t in gcc ld ar nm objcopy ranlib strip readelf as elfedit; do
    c=$(command -v "arm-linux-gnueabihf-$t" 2>/dev/null || true)
    [ -n "$c" ] && ln -sf "$c" "$TC/arm-linux-androideabi-4.9/bin/arm-linux-androideabi-$t"
  done
fi
GCC_ARM_BIN=$(ls -d "$TC"/arm-linux-androideabi-4.9*/bin 2>/dev/null | head -1 || echo /usr/bin)

export PATH="$CLANG_BIN:$GCC_A64_BIN:$GCC_ARM_BIN:$PATH"
export BISON_PKGDATADIR="${BISON_PKGDATADIR:-/usr/share/bison}"
export PLATFORM_VERSION=11
export ANDROID_MAJOR_VERSION=r
# Samsung GPU Kconfig evaluates this numeric environment variable.
export SEC_BUILD_CONF_VENDOR_BUILD_OS=15

# ---------------------------------------------------------------- kernel tree
# Use an explicit OSRC tree, a local extracted tree, or the configured archive.
KERNEL_TARBALL_URL="${KERNEL_TARBALL_URL:-}"
if [ -n "$KERNEL_TREE_SRC" ]; then
  [ -f "$KERNEL_TREE_SRC/Makefile" ] || { echo "ERROR: invalid KERNEL_TREE_SRC: $KERNEL_TREE_SRC" >&2; exit 3; }
  KERNEL_DIR="$KERNEL_TREE_SRC"
elif [ -d "$REPO_ROOT/$KERNEL_TREE_NAME" ] && [ -f "$REPO_ROOT/$KERNEL_TREE_NAME/Makefile" ]; then
  KERNEL_DIR="$REPO_ROOT/$KERNEL_TREE_NAME"
elif [ -n "$KERNEL_TARBALL_URL" ]; then
  log "Download Samsung OSRC HZB1 kernel source"
  mkdir -p "$REPO_ROOT/.ci" "$REPO_ROOT/$KERNEL_TREE_NAME"
  curl -fsSL --retry 2 "$KERNEL_TARBALL_URL" -o "$REPO_ROOT/.ci/kernel.tar.gz"
  tar -xzf "$REPO_ROOT/.ci/kernel.tar.gz" -C "$REPO_ROOT/$KERNEL_TREE_NAME"
  KERNEL_DIR="$REPO_ROOT/$KERNEL_TREE_NAME"
  # Keep source mtimes stable so the extracted tree does not invalidate the prepared build cache.
  find "$KERNEL_DIR" -type f -exec touch -t 200001010000 {} + 2>/dev/null
else
  echo "ERROR: set KERNEL_TARBALL_URL or provide an extracted kernel tree" >&2; exit 3
fi
[ -f "$KERNEL_DIR/Makefile" ] || { echo "ERROR: kernel source has no Makefile: $KERNEL_DIR" >&2; exit 3; }

KL_VER=$(python3 -c "
import re,sys
mk=open(sys.argv[1]).read()
def g(p):
    m=re.search(rf'^{p} *= *(\d+)$',mk,re.M); return m.group(1)
print(f\"{g('VERSION')}.{g('PATCHLEVEL')}.{g('SUBLEVEL')}\")
" "$KERNEL_DIR/Makefile")
echo "kernel tree version: $KL_VER"
[ "$KL_VER" = "5.4.274" ] || { echo "ERROR: expected kernel 5.4.274, got $KL_VER" >&2; exit 4; }
[ -f "$CONFIG_SRC" ] || { echo "ERROR: missing target config: $CONFIG_SRC" >&2; exit 4; }

# ---------------------------------------------------------------- config + prepare + vmlinux (cacheable)
CACHED=0
if [ -f "$OUT/Module.symvers" ] && [ -f "$OUT/System.map" ] && [ -f "$OUT/.config" ] && \
   [ -f "$OUT/include/config/kernel.release" ] && [ -d "$OUT/scripts" ]; then
  log "Kernel preparation cache hit"
  CACHED=1
fi
if [ "$CACHED" = 0 ]; then
log "Configure the HZB1 kernel tree"
cp "$CONFIG_SRC" "$OUT/.config"
make -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
  CROSS_COMPILE="$GCC_A64_BIN/aarch64-linux-android-" \
  CROSS_COMPILE_COMPAT="$GCC_ARM_BIN/arm-linux-androideabi-" \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  LOCALVERSION="$MAKE_LOCALVERSION" \
  olddefconfig
make -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
  CROSS_COMPILE="$GCC_A64_BIN/aarch64-linux-android-" \
  CROSS_COMPILE_COMPAT="$GCC_ARM_BIN/arm-linux-androideabi-" \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  LOCALVERSION="$MAKE_LOCALVERSION" \
  modules_prepare


# MODVERSIONS requires symbol CRCs from Module.symvers, generated with vmlinux.
if grep -q "^CONFIG_MODVERSIONS=y" "$OUT/.config"; then
  log "Build vmlinux to generate Module.symvers and System.map"
  make -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
    CROSS_COMPILE="$GCC_A64_BIN/aarch64-linux-android-" \
    CROSS_COMPILE_COMPAT="$GCC_ARM_BIN/arm-linux-androideabi-" \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    LOCALVERSION="$MAKE_LOCALVERSION" \
    -j"$(nproc)" vmlinux || { echo "ERROR: vmlinux build failed" >&2; exit 6; }
fi
fi  # CACHED=0

EXPECTED="5.4.274-qgki-30957850-abG998USQSJHZB1"
RELEASE=$(make -s -C "$KERNEL_DIR" O="$OUT" kernelrelease LOCALVERSION="$MAKE_LOCALVERSION")
echo "kernel.release = $RELEASE"
[ "$RELEASE" = "$EXPECTED" ] || { echo "ERROR: expected $EXPECTED, got $RELEASE" >&2; exit 4; }

# ---------------------------------------------------------------- symbol check (resolver)
log "Check resolver symbols against the generated System.map"
python3 - <<'PY'
import re, os
src = open("kernel-ksu/infra/symbol_resolver.c").read()
optional = str(src[src.find("static const int optional[]"):src.find("};", src.find("static const int optional[]"))])
optional_names = set(re.findall(r'KSU_([A-Z0-9_]+)', optional))
# map enum id -> name
enum_ids = re.findall(r'\[KSU_([A-Z0-9_]+)\]\s*=\s*"([a-z_A-Z0-9]+)"', src)
mapfile = os.environ.get("KSU_SYSTEM_MAP", "out/ci-prepare/System.map")
if not os.path.exists(mapfile):
    print("System.map unavailable; external-module modpost remains the import check")
    raise SystemExit(0)
have = set()
for line in open(mapfile, errors="ignore"):
    p = line.split()
    if len(p) >= 3:
        have.add(p[-1])
print(f"System.map: {len(have)} symbols loaded")
missing_core, missing_opt = [], []
for eid, name in enum_ids:
    (missing_core, missing_opt) = (missing_core, missing_opt + [f"{name} (opcional: KSU_{eid})"]) if f"KSU_{eid}" in optional_names else (missing_core + [name], missing_opt)
print(f"symbols del resolver: {len(enum_ids)}; core missing: {len(missing_core)}; optional missing: {len(missing_opt)}")
if missing_core:
    print("CORE MISSING (abortan el insmod):", ",".join(missing_core))
if missing_opt:
    print("OPTIONAL MISSING (degradan con warning):", ",".join(missing_opt))
PY

# ---------------------------------------------------------------- KernelSU LKM
log "Build KernelSU for Samsung 5.4"
KKSU="$REPO_ROOT/kernel-ksu"
[ -f "$KKSU/Kbuild" ] || { echo "ERROR: missing kernel-ksu/Kbuild" >&2; exit 5; }
rm -f "$KKSU/kernelsu.ko"
make -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
  CROSS_COMPILE="$GCC_A64_BIN/aarch64-linux-android-" \
  CROSS_COMPILE_COMPAT="$GCC_ARM_BIN/arm-linux-androideabi-" \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  LOCALVERSION="$MAKE_LOCALVERSION" \
  M="$KKSU" src="$KKSU" \
  CONFIG_KSU=m CONFIG_KSU_S21_54=y \
  CONFIG_KSU_SAMSUNG_KDP=y CONFIG_KSU_SAMSUNG_RKP=y \
  CONFIG_KSU_SAMSUNG_DEFEX=y CONFIG_KSU_SAMSUNG_NO_PATCH_TEXT=y \
  modules

KOCKO="$KKSU/kernelsu.ko"
[ -s "$KOCKO" ] || { echo "ERROR: KernelSU build did not produce $KOCKO" >&2; exit 5; }
LLVM_STRIP=$(find "$(dirname "$CLANG_BIN")" -name llvm-strip -type f 2>/dev/null | head -1 || true)
if [ -n "$LLVM_STRIP" ]; then "$LLVM_STRIP" --strip-unneeded "$KOCKO"; fi
cp "$KOCKO" "$REPO_ROOT/app/src/main/assets/kko"
strings "$KOCKO" | grep -F "$EXPECTED" >/dev/null || { echo "ERROR: kko vermagic mismatch" >&2; exit 5; }

# ---------------------------------------------------------------- DirtyFrag second-stage LKM
log "Build df_self for HZB1"
DFMOD="$REPO_ROOT/dfmod"
[ -f "$DFMOD/Kbuild" ] || { echo "ERROR: missing dfmod/Kbuild" >&2; exit 6; }
rm -f "$DFMOD/df_self.ko"
make -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
  CROSS_COMPILE="$GCC_A64_BIN/aarch64-linux-android-" \
  CROSS_COMPILE_COMPAT="$GCC_ARM_BIN/arm-linux-androideabi-" \
  CLANG_TRIPLE=aarch64-linux-gnu- LOCALVERSION="$MAKE_LOCALVERSION" \
  M="$DFMOD" src="$DFMOD" modules
DFSELF="$DFMOD/df_self.ko"
[ -s "$DFSELF" ] || { echo "ERROR: dfmod build did not produce $DFSELF" >&2; exit 6; }
if [ -n "$LLVM_STRIP" ]; then "$LLVM_STRIP" --strip-unneeded "$DFSELF"; fi
DFROOT_KO="$REPO_ROOT/app/src/main/jni/ko/dirtyfrag-android15-5.4.ko"
mkdir -p "$(dirname "$DFROOT_KO")"
cp "$DFSELF" "$DFROOT_KO"
strings "$DFROOT_KO" | grep -F "$EXPECTED" >/dev/null || { echo "ERROR: df_self vermagic mismatch" >&2; exit 6; }

# ---------------------------------------------------------------- APK
log "Package G998U debug APK"
./gradlew :app:assembleDebug --no-daemon
APK=$(find app/build/outputs/apk/debug -maxdepth 1 -type f -name '*.apk' -print -quit)
[ -n "$APK" ] && [ -s "$APK" ] || { echo "ERROR: debug APK not found" >&2; exit 7; }
cp "$APK" "$REPO_ROOT/dirtyfrag-g998u-debug.apk"

log "G998U build complete: kernel release $RELEASE"
