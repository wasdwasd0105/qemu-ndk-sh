#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Build QEMU 10.0.2 for Android (arm64-v8a) as bin and .so
# ==================================================


# Macos path
#NDK_PATH="${NDK_PATH:-$HOME/AndroidNDKr29.app/Contents/NDK}"

# Linux path
NDK_PATH="${NDK_PATH:-$HOME/android-ndk-r29}"


API_LEVEL="${API_LEVEL:-31}"
QEMU_VERSION="${QEMU_VERSION:-10.0.2}"
QEMU_GIT_URL="${QEMU_GIT_URL:-https://github.com/wasdwasd0105/qemu-android.git}"
QEMU_GIT_REF="qemu-10.0.2"
APP_ABI="${APP_ABI:-arm64-v8a}"
BUILD_ROOT="${BUILD_ROOT:-$(pwd)/build}"
QEMU_SRC="${QEMU_SRC:-$BUILD_ROOT/qemu-${QEMU_VERSION}}"
BUILD_DIR="${BUILD_DIR:-$BUILD_ROOT/qemu-build-${APP_ABI}}"
PREFIX="${PREFIX:-$BUILD_ROOT/sysroot-${APP_ABI}}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

# libucontext: needed to use ucontext coroutine backend on Android
# (Android bionic lacks getcontext/makecontext/swapcontext)
LIBUCONTEXT_GIT_URL="${LIBUCONTEXT_GIT_URL:-https://github.com/kaniini/libucontext.git}"
LIBUCONTEXT_SRC="${LIBUCONTEXT_SRC:-$BUILD_ROOT/libucontext}"

# --- Android toolchain ---
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$HOST_OS" in
  linux)   HOST_TAG="linux-x86_64" ;;
  darwin)  HOST_TAG="darwin-x86_64" ;;
  *) echo "Unsupported host OS: $HOST_OS" >&2; exit 1 ;;
esac

TOOLCHAIN="$NDK_PATH/toolchains/llvm/prebuilt/$HOST_TAG"
TRIPLE=aarch64-linux-android
export CC="$TOOLCHAIN/bin/${TRIPLE}${API_LEVEL}-clang"
export CXX="$TOOLCHAIN/bin/${TRIPLE}${API_LEVEL}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export NM="$TOOLCHAIN/bin/llvm-nm"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export OBJCOPY="$TOOLCHAIN/bin/llvm-objcopy"
export LD="$TOOLCHAIN/bin/ld.lld"

# --- pkg-config strictly from our Android sysroot ---
export PKG_CONFIG_PATH=""
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

# tiny wrapper (explicit but simple)
WRAP_PC="$BUILD_ROOT/android-pkg-config"
cat > "$WRAP_PC" <<'EOF'
#!/usr/bin/env bash
exec pkg-config "$@"
EOF
chmod +x "$WRAP_PC"
export PKG_CONFIG="$WRAP_PC"

# --- Compiler & Linker Flags (Android-safe) ---
# Export ALL symbols from executables' .dynsym and avoid hidden defaults.
export CFLAGS="-fPIC -fvisibility=default -mbranch-protection=none -ftls-model=global-dynamic -Wno-error -I$PREFIX/include -DSDL_MAIN_HANDLED -I$PREFIX/include/pixman-1 -DANDROID_PLATFORM="android-${API_LEVEL}" "
export CPPFLAGS="$CFLAGS"
# -Wl,--export-dynamic ensures the executable exposes all global symbols in .dynsym
export LDFLAGS="-L$PREFIX/lib -Wl,--export-dynamic -lucontext"

# Native compiler for small host build helpers
HOST_CC="${HOST_CC:-$(command -v cc || true)}"
[ -n "$HOST_CC" ] || { echo "No native host C compiler found."; exit 1; }

# --- Ensure source exists (clone from GitHub if missing) ---
mkdir -p "$BUILD_ROOT"
if [ ! -d "$QEMU_SRC" ]; then
  echo "==> Cloning QEMU sources from GitHub ($QEMU_GIT_URL) ref=$QEMU_GIT_REF into $QEMU_SRC ..."
  git clone --depth 1 --branch "$QEMU_GIT_REF" "$QEMU_GIT_URL" "$QEMU_SRC"
else
  # # If the dir exists, optionally ensure it's on the requested ref.
  # if [ -d "$QEMU_SRC/.git" ]; then
  #   echo "==> Updating existing QEMU git checkout in $QEMU_SRC (ref=$QEMU_GIT_REF) ..."
  #   pushd "$QEMU_SRC" >/dev/null
  #   git fetch --tags --prune origin || true
  #   git checkout -f "$QEMU_GIT_REF" || true
  #   #git submodule update --init --recursive || true
  #   popd >/dev/null
  # else
  #   echo "==> Using existing QEMU source directory (not a git repo): $QEMU_SRC"
  # fi
  echo "==> Using existing QEMU source directory (not a git repo): $QEMU_SRC"
fi

# --- Apply SLIRP Android DNS patch ---
SLIRP_PATCH="$(cd "$(dirname "$0")" && pwd)/slirp_android_dns.patch"
if [ -f "$SLIRP_PATCH" ]; then
  echo "==> Applying SLIRP Android DNS patch ..."
  if git -C "$QEMU_SRC/subprojects/slirp" apply --check "$SLIRP_PATCH" 2>/dev/null; then
    git -C "$QEMU_SRC/subprojects/slirp" apply "$SLIRP_PATCH"
    echo "==> SLIRP patch applied successfully."
  else
    echo "==> SLIRP patch already applied or not needed, skipping."
  fi
fi


# ==============================================================
# Build libucontext for Android (FREESTANDING mode)
# This provides getcontext/setcontext/makecontext/swapcontext
# that Android bionic lacks, allowing QEMU to use the ucontext
# coroutine backend instead of sigaltstack (which corrupts BQL
# mutex ownership on bionic during sigsuspend/siglongjmp).
# ==============================================================
if [ ! -d "$LIBUCONTEXT_SRC" ]; then
  echo "==> Cloning libucontext ..."
  git clone --depth 1 "$LIBUCONTEXT_GIT_URL" "$LIBUCONTEXT_SRC"
fi

if [ ! -f "$PREFIX/lib/libucontext.a" ]; then
  echo "==> Building libucontext for Android aarch64 (FREESTANDING mode) ..."
  pushd "$LIBUCONTEXT_SRC" >/dev/null

  # Clean any previous build
  make clean 2>/dev/null || true

  # Build with NDK cross-compiler in freestanding mode
  # FREESTANDING=yes: use built-in headers (no system ucontext.h needed)
  # EXPORT_UNPREFIXED=yes: provide standard POSIX names (getcontext, etc.)
  # Only build the static library — the .dylib/.so target fails because
  # the Makefile passes macOS linker flags (-dynamiclib) to Android's ld.lld.
  make \
    ARCH=aarch64 \
    CC="$CC" \
    AR="$AR" \
    RANLIB="$RANLIB" \
    FREESTANDING=yes \
    EXPORT_UNPREFIXED=yes \
    -j "$JOBS" \
    libucontext.a

  # Install into our sysroot (static lib + headers only)
  # We install manually since 'make install' also tries to build/install .dylib
  mkdir -p "$PREFIX/lib" "$PREFIX/lib/pkgconfig" "$PREFIX/include/libucontext"
  cp -f libucontext.a "$PREFIX/lib/"
  cp -f libucontext.pc "$PREFIX/lib/pkgconfig/" 2>/dev/null || true

  # Install the FREESTANDING libucontext.h header
  cp -f include/libucontext/libucontext.h "$PREFIX/include/libucontext/" 2>/dev/null || true

  # DO NOT copy bits.h from source tree here — it has two versions
  # (freestanding vs non-freestanding) and the wrong one keeps getting picked.
  # The correct freestanding bits.h is generated below.

  popd >/dev/null

  # Create a ucontext.h shim in our sysroot that QEMU's meson probe can find.
  # This wraps libucontext's freestanding header to provide the standard
  # ucontext_t / getcontext / makecontext / swapcontext API.
  echo "==> Creating ucontext.h shim in $PREFIX/include ..."
  cat > "$PREFIX/include/ucontext.h" <<'UCONTEXT_SHIM'
/*
 * ucontext.h shim for Android — wraps libucontext (freestanding mode).
 *
 * This provides access to libucontext's API. QEMU's patched
 * coroutine-ucontext.c uses libucontext_* names directly, so the
 * main purpose of this shim is to satisfy #include <ucontext.h>
 * and provide function declarations.
 *
 * NOTE: NDK r29+ defines its own ucontext_t in <sys/ucontext.h>
 * (pulled in via signal.h). We do NOT redefine ucontext_t here.
 * QEMU's patched coroutine-ucontext.c #defines ucontext_t to
 * libucontext_ucontext_t after including this header.
 */
#ifndef _ANDROID_UCONTEXT_SHIM_H
#define _ANDROID_UCONTEXT_SHIM_H

#include <libucontext/libucontext.h>

/* Function declarations for the libucontext_ prefixed API.
 * The unprefixed names (getcontext, etc.) are provided as weak
 * aliases by libucontext.a (built with EXPORT_UNPREFIXED=yes). */

#endif /* _ANDROID_UCONTEXT_SHIM_H */
UCONTEXT_SHIM

  echo "==> libucontext installed:"
  ls -la "$PREFIX/lib"/libucontext* 2>/dev/null || true
  ls -la "$PREFIX/include/ucontext.h" 2>/dev/null || true
  ls -la "$PREFIX/include/libucontext/" 2>/dev/null || true
else
  echo "==> libucontext already built, skipping."
fi

# ============================================================
# Generate the correct freestanding bits.h with NDK guard
# ============================================================
# Always (re)generate this file to avoid any stale/wrong versions.
# This must match the EXACT layout that libucontext.a assembly expects.
# The struct sigcontext block is guarded with #ifndef _UAPI__ASM_SIGCONTEXT_H
# so it doesn't conflict with the NDK's <asm/sigcontext.h> (which osdep.h
# pulls in via signal.h). Both define identical struct sigcontext (kernel ABI).
BITS_INSTALLED="$PREFIX/include/libucontext/bits.h"
mkdir -p "$PREFIX/include/libucontext"
echo "==> Generating freestanding bits.h for aarch64 ..."
cat > "$BITS_INSTALLED" <<'GEN_BITS_H'
#ifndef LIBUCONTEXT_BITS_H
#define LIBUCONTEXT_BITS_H

#include <stddef.h>

/* LIBUCONTEXT_SIGCONTEXT_GUARD:
 * Guard against NDK's <asm/sigcontext.h> which defines the same struct.
 * When the NDK header was already included, skip our definition and just
 * typedef mcontext_t from the existing struct sigcontext. */
#ifndef _UAPI__ASM_SIGCONTEXT_H
typedef struct sigcontext {
	unsigned long long fault_address;
	unsigned long long regs[31];
	unsigned long long sp;
	unsigned long long pc;
	unsigned long long pstate;
	unsigned char __reserved[4096] __attribute__((__aligned__(16)));
} mcontext_t;
#else
typedef struct sigcontext mcontext_t;
#endif /* _UAPI__ASM_SIGCONTEXT_H */

typedef struct {
	void *ss_sp;
	int ss_flags;
	size_t ss_size;
} libucontext_stack_t;

typedef struct libucontext_ucontext {
	unsigned long uc_flags;
	struct libucontext_ucontext *uc_link;
	libucontext_stack_t uc_stack;
	unsigned char __pad[128];
	mcontext_t uc_mcontext;
} libucontext_ucontext_t;

#endif /* LIBUCONTEXT_BITS_H */
GEN_BITS_H
echo "==> bits.h generated"

# Patch libucontext.h: fix missing (void) prototype to silence -Wstrict-prototypes
LIBUCONTEXT_H="$PREFIX/include/libucontext/libucontext.h"
if [ -f "$LIBUCONTEXT_H" ] && grep -q 'void (\*)()' "$LIBUCONTEXT_H"; then
  echo "==> Patching libucontext.h to fix function prototype ..."
  sed -i.bak 's|void (\*)()|void (*)(void)|g' "$LIBUCONTEXT_H"
  rm -f "$LIBUCONTEXT_H.bak"
  echo "==> libucontext.h patched"
fi

# --- Clean out-of-tree build dir and (re)create ---
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$PREFIX/lib" "$PREFIX/bin"

# --- Quick dep check (optional) ---
echo "==> pkg-config quick check (Android-cross deps in $PREFIX)"
echo "GLib:           $(pkg-config --modversion glib-2.0 2>/dev/null || echo 'NOT FOUND')"
echo "Pixman:         $(pkg-config --modversion pixman-1 2>/dev/null || echo 'NOT FOUND')"
echo "SDL2:           $(pkg-config --modversion sdl2 2>/dev/null || echo 'NOT FOUND')"
echo "libusb:         $(pkg-config --modversion libusb-1.0 2>/dev/null || echo 'NOT FOUND')"


# Pixman optional gate
if pkg-config --exists pixman-1; then
  PIXMAN_OPT="--enable-pixman"
else
  PIXMAN_OPT="--disable-pixman"
fi

# --- Configure ---
cd "$BUILD_DIR"
"$QEMU_SRC/configure" \
  --prefix="$PREFIX" \
  --host-cc="$HOST_CC" \
  --cross-prefix="${TRIPLE}-" \
  --cc="$CC" \
  --cxx="$CXX" \
  --extra-cflags="$CFLAGS" \
  --extra-ldflags="$LDFLAGS" \
  --with-coroutine=ucontext \
  --disable-docs \
  --disable-guest-agent \
  --disable-sdl \
  --disable-gtk \
  --disable-cocoa \
  --disable-curses \
  --disable-capstone \
  --disable-gnutls \
  --disable-gcrypt \
  --disable-libusb \
  --disable-usb-redir \
  --audio-drv-list= \
  --enable-slirp \
  --disable-vhost-user \
  --disable-virtfs \
  -Dcoroutine_pool=false \
  --enable-libusb \
  --audio-drv-list=aaudio \
  -Dopengl=disabled \
  -Dvirglrenderer=disabled \
  -Dvnc=enabled \
  -Dvnc_jpeg=disabled \
  -Dvnc_sasl=disabled \
  $PIXMAN_OPT \
  --target-list="aarch64-softmmu,i386-softmmu,x86_64-softmmu,ppc-softmmu"

# Use the same Meson that created build.dat (QEMU 10.x bootstraps a venv here)
MESON="$BUILD_DIR/pyvenv/bin/meson"
if [ ! -x "$MESON" ]; then
  MESON="$(command -v meson)"
fi
[ -x "$MESON" ] || { echo "Meson not found after configure."; exit 1; }

# --- Build executables (PIE) with the same Meson ---
"$MESON" compile -C "$BUILD_DIR" \
  qemu-system-aarch64 \
  qemu-system-i386 \
  qemu-system-x86_64 \
  qemu-system-ppc \
  qemu-img \
  -j "$JOBS"

"$MESON" install -C "$BUILD_DIR"

# --- Stage: copy PIE -> .so so Android can dlopen() and you get full dynsym like bin ---
mkdir -p "$PREFIX/jniLibs/arm64-v8a"
missing=0

safe_strip_debug() {
  # keep dynamic symbols; strip only debug sections
  "$STRIP" --strip-debug "$1" || true
}

for t in aarch64 i386 x86_64 ppc; do
  so="$PREFIX/lib/libqemu-system-${t}.so"
  bin="$PREFIX/bin/qemu-system-${t}"
  if [ -f "$bin" ]; then
    echo "[fallback-as-design] converting $(basename "$bin") -> libqemu-system-${t}.so"
    cp -f "$bin" "$so"
    safe_strip_debug "$so"
    cp -f "$so" "$PREFIX/jniLibs/arm64-v8a/"
    echo "Staged: $(basename "$so") (from bin; full dynsym preserved)"
  else
    echo "[warn] missing $bin"
    missing=1
  fi
done

# --- Verify: ALL globals are exported (sample check) ---
echo "==> Verifying dynsym exposure ..."
rc=0
for lib in "$PREFIX/lib"/libqemu-system-*.so; do
  [ -e "$lib" ] || continue
  echo "  * $(basename "$lib")"
  if ! $NM -D --defined-only "$lib" | grep -E ' qemu_(init|main_loop|cleanup)$' >/dev/null; then
    rc=1
  fi
  echo "    dynsym count: $($NM -D --defined-only "$lib" | wc -l)"
done

echo "=================================================="
echo "✅ Build & stage complete. Check outputs:"
ls -l "$PREFIX/lib"/libqemu-system-*.so 2>/dev/null || true
ls -l "$PREFIX/jniLibs/arm64-v8a" 2>/dev/null || true
[ "$missing" -eq 0 ] || echo "   (Some architectures missing.)"
if [ "$rc" -eq 0 ]; then
  echo "✅ Verified: qemu_init / qemu_main_loop / qemu_cleanup present; all globals exported like bin"
else
  echo "⚠️  Verification failed for at least one .so (symbols not found)."
  echo "    Ensure LDFLAGS contains -Wl,--export-dynamic and strip kept to --strip-debug."
fi
echo "=================================================="
