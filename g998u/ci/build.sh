#!/usr/bin/env bash
# CI build for the G998U port (Ubuntu runner).
# Mirrors scripts/kernel-make.sh + scripts/build-kernelsu.sh, but:
#  - downloads toolchains from android.googlesource.com (+archive tarballs)
#  - uses apt host tools instead of the author's local host-tools sysroot
#  - takes the kernel tree from CI (mirror p3q or official OSRC drop)
#  - pins vermagic to the real device: 5.4.274-qgki-30957850-abG998USQSJHZB1
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# ---------------------------------------------------------------- parameters
KERNEL_TREE_NAME="kernel-G998USQSJHZB1"
KERNEL_TREE_SRC="${KERNEL_TREE_SRC:-}"            # path to an already-extracted OSRC drop (Kernel/ dir)
MIRROR_URL="${MIRROR_URL:-https://github.com/yanzihan/android_kernel_samsung_sm8350-p3q}"
MIRROR_COMMIT="${MIRROR_COMMIT:-df919463cb7a3b1e6ee6d593efef1677e6000756}"  # 5.4.274 base
MIRROR_BRANCH="${MIRROR_BRANCH:-}"                # optional branch fallback
KSU_TAG="${KSU_TAG:-v3.2.5}"
KSU_URL="${KSU_URL:-https://github.com/tiann/KernelSU.git}"
# Real device vermagic split:
#   5.4.274-qgki-30957850-abG998USQSJHZB1
#   = kernel.release(5.4.274) + CONFIG_LOCALVERSION("-qgki") + MAKE LOCALVERSION below
MAKE_LOCALVERSION="${MAKE_LOCALVERSION:--30957850-abG998USQSJHZB1}"
OUT="$REPO_ROOT/out/ci-prepare"
TC="$REPO_ROOT/toolchains"
CONFIG_SRC="$REPO_ROOT/g998u/kernel-config/g998u-hzb1-resolved.config"   # resuelta (7522 líneas, olddefconfig-estable contra árbol OSRC HZB1)

TC_CLANG_DIR="clang-r383902"     # repo scripts expect clang-r383902/bin
CLANG_REFS=( "${CLANG_REF:-}" refs/heads/main refs/tags/android-13.0.0_r67 refs/tags/android-13.0.0_r1 )
GCC_A64_URL="${GCC_A64_URL:-https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/host/aarch64-linux-android-4.9/+archive/refs/heads/main.tar.gz}"
GCC_ARM_URL="${GCC_ARM_URL:-https://android.googlesource.com/platform/prebuilts/gcc/linux-x86/host/arm-linux-androideabi-4.9/+archive/refs/heads/main.tar.gz}"

log() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
mkdir -p "$TC" "$OUT"

# ---------------------------------------------------------------- host tools
log "apt host tools (reemplaza el sysroot host-tools del autor)"
sudo apt-get -y update >/dev/null 2>&1 || true
sudo apt-get -y install bc bison flex libncurses5-dev libssl-dev cpio python3 git curl xz-utils >/dev/null

# ---------------------------------------------------------------- toolchains
CLANG_BIN=$(ls -d "$TC"/clang-r383902*/bin 2>/dev/null | head -1 || true)
if [ -z "$CLANG_BIN" ]; then
  log "clang r383902 (mirror GitHub — device usa r383902b1/clang-11; ThinLTO+CFI requieren clang-11 de la misma línea)"
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
    echo "  mirror no disponible: $mirror"
  done
  [ "$HAVE_CLANG" = 1 ] || { echo "ERROR: clang r383902 no descargado (mirrors caídos)" >&2; exit 2; }
  CLANG_BIN="$TC/clang-r383902/bin"
fi

GCC_A64_BIN=$(ls -d "$TC"/aarch64-linux-android-4.9*/bin 2>/dev/null | head -1 || true)
if [ -z "$GCC_A64_BIN" ]; then
  log "gcc-4.9 aarch64 (cross) — fallback apt: symlinks aarch64-linux-gnu-* con prefix android"
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
  log "gcc arm32 compat — apt gcc-arm-linux-gnueabihf con prefix androideabi"
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
# Fuente oficial Samsung OSRC HZB1 (Kernel.tar.gz como release asset público).
KERNEL_TARBALL_URL="${KERNEL_TARBALL_URL:-}"
if [ -d "$REPO_ROOT/$KERNEL_TREE_NAME" ] && [ -f "$REPO_ROOT/$KERNEL_TREE_NAME/Makefile" ]; then
  KERNEL_DIR="$REPO_ROOT/$KERNEL_TREE_NAME"
elif [ -n "$KERNEL_TARBALL_URL" ]; then
  log "descargando árbol oficial OSRC (Kernel.tar.gz)"
  mkdir -p "$REPO_ROOT/.ci" "$REPO_ROOT/$KERNEL_TREE_NAME"
  curl -fsSL --retry 2 "$KERNEL_TARBALL_URL" -o "$REPO_ROOT/.ci/kernel.tar.gz"
  tar -xzf "$REPO_ROOT/.ci/kernel.tar.gz" -C "$REPO_ROOT/$KERNEL_TREE_NAME"
  KERNEL_DIR="$REPO_ROOT/$KERNEL_TREE_NAME"
else
  echo "ERROR: sin KERNEL_TARBALL_URL ni árbol preextraído" >&2; exit 3
fi
[ -f "$KERNEL_DIR/Makefile" ] || { echo "ERROR: árbol kernel sin Makefile: $KERNEL_DIR" >&2; exit 3; }

KL_VER=$(python3 -c "
import re,sys
mk=open(sys.argv[1]).read()
def g(p):
    m=re.search(rf'^{p} *= *(\d+)$',mk,re.M); return m.group(1)
print(f\"{g('VERSION')}.{g('PATCHLEVEL')}.{g('SUBLEVEL')}\")
" "$KERNEL_DIR/Makefile")
echo "kernel tree: VERSION $KL_VER (device real: 5.4.274)"
[ "$KL_VER" = "5.4.274" ] || echo "  WARN: sublevel distinto del device — verificar parches extra antes de insmod"

# ---------------------------------------------------------------- config
log "config: resolved HZB1 (olddefconfig ya validada contra este árbol)"
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

RELEASE=$(make -s -C "$KERNEL_DIR" O="$OUT" kernelrelease \
  LOCALVERSION="$MAKE_LOCALVERSION" 2>/dev/null || cat "$OUT/include/config/kernel.release")
echo "kernel.release = $RELEASE"
EXPECTED="5.4.274-qgki-30957850-abG998USQSJHZB1"
if [ "$RELEASE" = "$EXPECTED" ]; then
  echo "VERMAGIC OK"
else
  echo "  WARN vermagic difiere del objetivo ($EXPECTED) — el insmod en device fallaría; revisar LOCALVERSION/AUTO"
fi

# MODVERSIONS=y → los CRC de los símbolos importados por los LKM vienen del
# Module.symvers que se genera al compilar el vmlinux (y de paso System.map).
if grep -q "^CONFIG_MODVERSIONS=y" "$OUT/.config"; then
  log "vmlinux -j$(nproc) — genera Module.symvers (CRCs MODVERSIONS) + System.map"
  make -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
    CROSS_COMPILE="$GCC_A64_BIN/aarch64-linux-android-" \
    CROSS_COMPILE_COMPAT="$GCC_ARM_BIN/arm-linux-androideabi-" \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    LOCALVERSION="$MAKE_LOCALVERSION" \
    -j"$(nproc)" vmlinux || { echo "ERROR: build de vmlinux falló (auditado: árbol ≡ firmware)" >&2; exit 6; }
fi

# ---------------------------------------------------------------- symbol check (resolver)
log "check de símbolos del resolver contra System.map generado"
python3 - <<'PY' || true
import re, os
src = open("kernel-ksu/infra/symbol_resolver.c").read()
names = re.findall(r'\[KSU_[A-Z0-9_]+\]\s*=\s*"([a-z_A-Z0-9]+)"', src)
lines = src.splitlines()
for i, l in enumerate(lines):
    if re.match(r'\s*\[KSU_[A-Z0-9_]+\]\s*$', l) and i + 1 < len(lines):
        m = re.match(r'^\s*"([a-z_A-Z0-9]+)"', lines[i + 1])
        if m:
            names.append(m.group(1))
names = sorted(set(names))
optional = str(src[src.find("static const int optional[]"):src.find("};", src.find("static const int optional[]"))])
optional_names = set(re.findall(r'KSU_([A-Z0-9_]+)', optional))
# map enum id -> name
enum_ids = re.findall(r'\[KSU_([A-Z0-9_]+)\]\s*=\s*"([a-z_A-Z0-9]+)"', src)
mapfile = os.environ.get("KSU_SYSTEM_MAP", "out/ci-prepare/System.map")
if not os.path.exists(mapfile):
    print("System.map no disponible tras modules_prepare (se genera en el enlace final); check diferido al modpost del build real")
    raise SystemExit(0)
have = set()
for line in open(mapfile, errors="ignore"):
    p = line.split()
    if len(p) >= 3:
        have.add(p[-1])
print(f"System.map: {len(have)} nombres leídos (primeras líneas: {open(mapfile, errors='ignore').readline()[:60]!r})")
missing_core, missing_opt = [], []
for eid, name in enum_ids:
    (missing_core, missing_opt) = (missing_core, missing_opt + [f"{name} (opcional: KSU_{eid})"]) if f"KSU_{eid}" in optional_names else (missing_core + [name], missing_opt)
print(f"symbols del resolver: {len(enum_ids)}; core missing: {len(missing_core)}; optional missing: {len(missing_opt)}")
if missing_core:
    print("CORE MISSING (abortan el insmod):", ",".join(missing_core))
if missing_opt:
    print("OPTIONAL MISSING (degradan con warning):", ",".join(missing_opt))
PY

# ---------------------------------------------------------------- KernelSU LKM (kko)
# ---------------------------------------------------------------- KernelSU LKM (kko)
log "KernelSU LKM (kko) — árbol vendido kernel-ksu (patcheado para 5.4 + samsung)"
KKSU="$REPO_ROOT/kernel-ksu"
[ -f "$KKSU/Kbuild" ] || { echo "ERROR: kernel-ksu/Kbuild ausente" >&2; exit 5; }
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

KOCKO=$(find "$OUT" "$KKSU" -name '*.ko' -newer "$OUT/.config" 2>/dev/null | head -1 || true)
[ -n "$KOCKO" ] || KOCKO=$(find "$OUT" "$KKSU" -name 'kernelsu*.ko' -o -name 'kko*.ko' 2>/dev/null | head -1 || true)
if [ -n "${KOCKO:-}" ]; then
  cp "$KOCKO" "$REPO_ROOT/app/src/main/assets/kko"
  echo "kko → $REPO_ROOT/app/src/main/assets/kko ($(stat -c%s "$KOCKO") bytes)"
else
  echo "  WARN: no se encontró el .ko de KernelSU en out/ — revisar build del módulo KSU" >&2
fi

# ---------------------------------------------------------------- dfmod (df_self / dirtyfrag 5.4)
log "dfmod: df_self (dirtyfrag ko embebido) para HZB1"
if [ -f "dfmod/Makefile" ]; then
  make -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
    CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
    CROSS_COMPILE="$GCC_A64_BIN/aarch64-linux-android-" \
    CROSS_COMPILE_COMPAT="$GCC_ARM_BIN/arm-linux-androideabi-" \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    LOCALVERSION="$MAKE_LOCALVERSION" \
    M="$REPO_ROOT/dfmod" src="$REPO_ROOT/dfmod" modules
  # el embebido en exp.c {15,5,4} es df_self (df_stager NO es parte de la cadena)
  if [ -f dfmod/df_self.ko ]; then
    cp dfmod/df_self.ko "app/src/main/jni/ko/dirtyfrag-android15-5.4.ko"
    echo "df_ko → app/src/main/jni/ko/dirtyfrag-android15-5.4.ko ($(stat -c%s dfmod/df_self.ko) bytes)"
  else
    echo "  WARN: df_self.ko no generado — queda el G991B embebido en el APK" >&2
  fi
else
  echo "  WARN: dfmod sin Makefile — el df_ko se reconstruye fuera de CI (ver PLAN §3); queda el G991B dentro del APK"
fi

# ---------------------------------------------------------------- APK
log "APK (gradle assembleDebug, re-empaqueta los assets)"
./gradlew :app:assembleDebug --no-daemon

MIX=$(find app/build -name '*.apk' -type f 2>/dev/null | head -1)
if [ -n "${MIX:-}" ]; then
  cp "$MIX" ./dirtyfrag-g998u-debug.apk && echo "APK → ./dirtyfrag-g998u-debug.apk (desde $MIX)"
else
  echo "ERROR: gradle no produjo .apk — revisar app/build outputs:" >&2
  find app/build -name '*.apk*' 2>/dev/null >&2 || true
  exit 7
fi

log "FIN CI-build — artifacts: kko, dirtyfrag .ko, APK. VERMAGIC $RELEASE"
