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
LSU_URL="${KSU_URL:-https://github.com/tiann/KernelSU.git}"
# Real device vermagic split:
#   5.4.274-qgki-30957850-abG998USQSJHZB1
#   = kernel.release(5.4.274) + CONFIG_LOCALVERSION("-qgki") + MAKE LOCALVERSION below
MAKE_LOCALVERSION="${MAKE_LOCALVERSION:--30957850-abG998USQSJHZB1}"
OUT="$REPO_ROOT/out/ci-prepare"
TC="$REPO_ROOT/toolchains"
CONFIG_SRC="$REPO_ROOT/g998u/kernel-config/g998u-hzb1.config"

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
  log "clang r383902b1"
  HAVE_CLANG=0
  for ref in "${CLANG_REFS[@]}"; do
    [ -z "$ref" ] && continue
    url="https://android.googlesource.com/platform/prebuilts/clang/host/linux-x86/+archive/${ref}/${TC_CLANG_DIR}.tar.gz"
    if curl -fsSL --retry 2 "$url" -o "$TC/clang.tgz"; then mkdir -p "$TC/$TC_CLANG_DIR"; tar -xzf "$TC/clang.tgz" -C "$TC/$TC_CLANG_DIR"; HAVE_CLANG=1; break; fi
    echo "  no disponible en $ref (intento siguiente)"
  done
  [ "$HAVE_CLANG" = 1 ] || { echo "ERROR: clang r383902b1 no descargado; exporta CLANG_REF con un ref válido" >&2; exit 2; }
  CLANG_BIN="$TC/$TC_CLANG_DIR/bin"
fi

GCC_A64_BIN=$(ls -d "$TC"/aarch64-linux-android-4.9*/bin 2>/dev/null | head -1 || true)
if [ -z "$GCC_A64_BIN" ]; then
  log "gcc-4.9 aarch64 (cross)"
  mkdir -p "$TC/aarch64-linux-android-4.9"
  curl -fsSL --retry 2 "$GCC_A64_URL" -o "$TC/gcc64.tgz" \
    && tar -xzf "$TC/gcc64.tgz" -C "$TC/aarch64-linux-android-4.9" \
    || { echo "  WARN: +archive falló; fallback apt gcc-aarch64-linux-gnu" >&2;
         sudo apt-get -y install gcc-aarch64-linux-gnu >/dev/null;
         mkdir -p "$TC/apt-a64"; ln -sf "$(command -v aarch64-linux-gnu-gcc -h 2>/dev/null || echo /usr/bin/aarch64-linux-gnu-gcc)" "$TC/apt-a64/aarch64-linux-android-gcc" || true;
         GCC_A64_BIN="/usr/bin"; }
fi
GCC_A64_BIN=$(ls -d "$TC"/aarch64-linux-android-4.9*/bin 2>/dev/null | head -1 || echo /usr/bin)

GCC_ARM_BIN=$(ls -d "$TC"/arm-linux-androideabi-4.9*/bin 2>/dev/null | head -1 || true)
if [ -z "$GCC_ARM_BIN" ]; then
  log "gcc-4.9 arm (cross compat)"
  mkdir -p "$TC/arm-linux-androideabi-4.9"
  curl -fsSL --retry 2 "$GCC_ARM_URL" -o "$TC/gcc32.tgz" \
    && tar -xzf "$TC/gcc32.tgz" -C "$TC/arm-linux-androideabi-4.9" || \
    echo "  WARN: +archive falló; se usa el binhost simplemente para vdso/compat si aplica" >&2
fi
GCC_ARM_BIN=$(ls -d "$TC"/arm-linux-androideabi-4.9*/bin 2>/dev/null | head -1 || echo /usr/bin)

export PATH="$CLANG_BIN:$GCC_A64_BIN:$GCC_ARM_BIN:$PATH"
export BISON_PKGDATADIR="${BISON_PKGDATADIR:-/usr/share/bison}"
export PLATFORM_VERSION=11
export ANDROID_MAJOR_VERSION=r
# Samsung GPU Kconfig evaluates this numeric environment variable.
export SEC_BUILD_CONF_VENDOR_BUILD_OS=15

# ---------------------------------------------------------------- kernel tree
if [ -d "$REPO_ROOT/$KERNEL_TREE_NAME/Kernel" ]; then
  KERNEL_DIR="$REPO_ROOT/$KERNEL_TREE_NAME/Kernel"
elif [ -d "$REPO_ROOT/$KERNEL_TREE_NAME" ] && [ -f "$REPO_ROOT/$KERNEL_TREE_NAME/Makefile" ]; then
  KERNEL_DIR="$REPO_ROOT/$KERNEL_TREE_NAME"
elif [ -n "$KERNEL_TREE_SRC" ]; then
  KERNEL_DIR="$(cd "$KERNEL_TREE_SRC" && pwd)"
else
  log "kernel tree desde mirror p3q p3q @ $MIRROR_COMMIT"
  MIRROR="$REPO_ROOT/.ci/mirror-p3q"
  mkdir -p .ci
  if [ ! -d "$MIRROR/.git" ]; then
    git clone "$MIRROR_URL" "$MIRROR"
  fi
  git -C "$MIRROR" checkout -q "$MIRROR_COMMIT" 2>/dev/null \
    || { git -C "$MIRROR" fetch -q origin "$MIRROR_BRANCH:$MIRROR_COMMIT" 2>/dev/null || git -C "$MIRROR" fetch -q origin; git -C "$MIRROR" checkout -q "$MIRROR_COMMIT"; }
  # base import sin KernelSU integrado (branch sixteen la integra built-in — NO sirve para LKM)
  ln -sfn "$MIRROR" "$REPO_ROOT/$KERNEL_TREE_NAME"
  KERNEL_DIR="$MIRROR"
fi
[ -f "$KERNEL_DIR/Makefile" ] || { echo "ERROR: árbol kernel sin Makefile: $KERNEL_DIR" >&2; exit 3; }

KL_VER=$(python3 - <<'PY'
import re
mk=open("Makefile").read()
def g(p):
    m=re.search(rf"^{p} *= *(\d+)$",mk,re.M); return m.group(1)
print(f"{g('VERSION')}.{g('PATCHLEVEL')}.{g('SUBLEVEL')}")
PY
)
echo "kernel tree: VERSION $KL_VER (device real: 5.4.274)"
[ "$KL_VER" = "5.4.274" ] || echo "  WARN: sublevel distinto del device — verificar parches extra antes de insmod"

# ---------------------------------------------------------------- config
log "config: nuestra config HZB1 real + olddefconfig"
# AUTO=y (git describe del mirror) rompería el vermagic → forzar off
sed -i 's/^CONFIG_LOCALVERSION_AUTO=y/# CONFIG_LOCALVERSION_AUTO is not set/' "$CONFIG_SRC"
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

# ---------------------------------------------------------------- symbol check (78 del resolver)
log "check de símbolos del resolver contra System.map generado"
python3 - <<'PY' || true
import re,sys
src=open("kernel-ksu/infra/symbol_resolver.h").read()
# enum KSU_NSYMS de nombres: extrae identificadores después de NITEM(...)
pat=re.compile(r'\bX\s*\(\s*(?:KSU_SYM_)?[A-Za-z0-9_]*,\s*([A-Za-z_]\w*)')
names=set(re.findall(r'X\("([A-Za-z_]\w*)',src)) | set(re.findall(r'\bX\(\s*KSU_SYM_\w+,\s*"?\s*([A-Za-z_]\w*)"?',src))
if not names:
    names=set(re.findall(r'\"([A-Za-z_]\w*)\"',src))
mapfile="out/ci-prepare/System.map"
have=set()
for line in open(mapfile,errors="ignore"):
    p=line.split()
    if len(p)>=3: have.add(p[-1])
missing=sorted(n for n in names if n not in have)
print(f"symbols requeridos ~{len(names)}; missing {len(missing)}")
if missing: print("MISSING:", "\n".join(missing))
PY

# ---------------------------------------------------------------- KernelSU LKM (kko)
log "KernelSU LKM (kko) — build-kernelsu equivalente"
KSUM="$REPO_ROOT/work/KernelSU-v3.2.5/kernel"
if [ ! -d "$KSUM" ]; then mkdir -p "$(dirname "$KSUM")"
  git clone -q "$LSU_URL" "$KSUM" \
    && { git -C "$KSUM" checkout -q "$KSU_TAG" 2>/dev/null || echo "  WARN: tag $KSU_TAG no existe, usando default branch"; } \
    || { git -C "$KSUM" checkout -q "work/KernelSU-v3.2.5" 2>/dev/null || rm -rf "$KSUM"; }
fi
make -C "$KERNEL_DIR" O="$OUT" ARCH=arm64 LLVM=1 LLVM_IAS=1 \
  CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
  CROSS_COMPILE="$GCC_A64_BIN/aarch64-linux-android-" \
  CROSS_COMPILE_COMPAT="$GCC_ARM_BIN/arm-linux-androideabi-" \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  LOCALVERSION="$MAKE_LOCALVERSION" \
  M="$KSUM" src="$KSUM" \
  CONFIG_KSU=m CONFIG_KSU_S21_54=y \
  CONFIG_KSU_SAMSUNG_KDP=y CONFIG_KSU_SAMSUNG_RKP=y \
  CONFIG_KSU_SAMSUNG_DEFEX=y CONFIG_KSU_SAMSUNG_NO_PATCH_TEXT=y \
  modules

KOCKO=$(find "$OUT" "$KSUM" -name '*.ko' -newer "$OUT/.config" 2>/dev/null | head -1 || true)
[ -n "$KOCKO" ] || KOCKO=$(find "$OUT" "$KSUM" -name 'kko*.ko' -o -name 'KernelSU*.ko' 2>/dev/null | head -1 || true)
if [ -n "${KOCKO:-}" ]; then
  cp "$KOCKO" "$REPO_ROOT/app/src/main/assets/kko"
  echo "kko → $REPO_ROOT/app/src/main/assets/kko ($(stat -c%s "$KOCKO") bytes)"
else
  echo "  WARN: no se encontró el .ko de KernelSU en out/ — revisar build del módulo KSU" >&2
fi

# ---------------------------------------------------------------- dfmod (df_self / dirtyfrag 5.4)
log "dfmod: df_self (dirtyfrag ko) para HZB1"
if [ -f "dfmod/Makefile" ]; then
  make -C dfmod O="$OUT" || true
  for k in dfmod/*.ko; do [ -e "$k" ] && cp "$k" "app/src/main/jni/ko/dirtyfrag-android15-5.4.ko" && echo "df_ko → app/src/main/jni/ko/dirtyfrag-android15-5.4.ko"; done
else
  echo "  WARN: dfmod sin Makefile — el df_ko se reconstruye fuera de CI (ver PLAN §3); queda el G991B dentro del APK"
fi

# ---------------------------------------------------------------- APK
log "APK (gradle assembleDebug, re-empaqueta los assets)"
./gradlew :app:assembleDebug --no-daemon

MIX="app/build/outputs/apk/debug/app-debug.apk"
[ -f "$MIX" ] && cp "$MIX" ./dirtyfrag-g998u-debug.apk && echo "APK → ./dirtyfrag-g998u-debug.apk"

log "FIN CI-build — artifacts: kko, dirtyfrag .ko, APK. VERMAGIC $RELEASE"
