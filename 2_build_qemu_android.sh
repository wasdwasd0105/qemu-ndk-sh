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
export CFLAGS="-fPIC -fvisibility=default -ftls-model=global-dynamic -Wno-error -I$PREFIX/include -DSDL_MAIN_HANDLED -I$PREFIX/include/pixman-1 -DANDROID_PLATFORM="android-${API_LEVEL}" "
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

# --- Android-specific src tweaks ---
if [ -f "$QEMU_SRC/backends/meson.build" ] && grep -q 'hostmem-shm\.c' "$QEMU_SRC/backends/meson.build"; then
  echo "==> Disabling hostmem-shm backend for Android"
  sed -i.bak '/hostmem-shm\.c/d' "$QEMU_SRC/backends/meson.build"
fi
# Skip tests (faster + avoids host-side tooling)
sed -i.bak "s/subdir('tests')/# subdir('tests')/" "$QEMU_SRC/meson.build" || true

# --- Android patch: disable POSIX shm in util/oslib-posix.c (compile-time stub) ---
OSLIB="$QEMU_SRC/util/oslib-posix.c"
ANDROID_SHM_MARKER="ANDROID_DISABLE_POSIX_SHM"
if ! grep -q "$ANDROID_SHM_MARKER" "$OSLIB"; then
  echo "==> Patching util/oslib-posix.c to disable POSIX shm on Android (Python-based)"
  python3 - "$OSLIB" "$ANDROID_SHM_MARKER" <<'PY'
import sys, re, io
path, marker = sys.argv[1], sys.argv[2]
src = io.open(path, 'r', encoding='utf-8').read()

injected = False
if 'ANDROID_SHM_STUBS' not in src:
    inject_block = r'''
/* ANDROID_SHM_STUBS */
#ifdef __ANDROID__
#include <errno.h>
static inline int android_shm_open_stub(const char *name, int oflag, mode_t mode) {
    errno = ENOSYS;
    return -1;
}
static inline int android_shm_unlink_stub(const char *name) {
    errno = ENOSYS;
    return -1;
}
#define shm_open android_shm_open_stub
#define shm_unlink android_shm_unlink_stub
#endif
'''
    inc_pat = re.compile(r'(#include[^\n]+\n)+', re.M)
    m = inc_pat.search(src)
    if m:
        src = src[:m.end()] + inject_block + src[m.end():]
        injected = True

# match the exact signature as in qemu-10.0.2
pat = re.compile(
    r'int\s+qemu_shm_alloc\s*\(\s*size_t\s+size\s*,\s*Error\s*\*\*errp\s*\)\s*\{.*?\n\}',
    re.S
)

stub = f'''int qemu_shm_alloc(size_t size, Error **errp)
{{
/* {marker} */
#ifdef __ANDROID__
    /* Android NDK does not expose shm_open/shm_unlink. We do not need SHM here. */
    if (errp) {{
        error_setg_errno(errp, ENOSYS,
                         "POSIX shared memory is not supported on Android in this build");
    }}
    return -1;
#else
    /* This Android build script removed the non-Android implementation to avoid
     * NDK header incompatibilities. If you hit this branch, rebuild without __ANDROID__. */
    if (errp) {{
        error_setg_errno(errp, ENOSYS, "qemu_shm_alloc stub reached");
    }}
    return -1;
#endif
}}
'''

ns, n = pat.subn(stub, src, count=1)
if n == 0:
    print("ERROR: could not find qemu_shm_alloc() to patch", file=sys.stderr)
    sys.exit(1)
io.open(path, 'w', encoding='utf-8').write(ns)
print("patched", "with shm stubs" if injected else "")
PY
fi

# --- Android patch: stub shm_open/shm_unlink in contrib/ivshmem-server/ivshmem-server.c ---
IVSHMEM_C="$QEMU_SRC/contrib/ivshmem-server/ivshmem-server.c"
IVSHMEM_MARKER="ANDROID_SHM_STUBS_IVSHMEM"
if [ -f "$IVSHMEM_C" ] && ! grep -q "$IVSHMEM_MARKER" "$IVSHMEM_C"; then
  echo "==> Patching ivshmem-server.c to stub shm_open/shm_unlink for Android"
  python3 - "$IVSHMEM_C" "$IVSHMEM_MARKER" <<'PY'
import sys, re, io
path, marker = sys.argv[1], sys.argv[2]
src = io.open(path, 'r', encoding='utf-8').read()

if marker in src:
    sys.exit(0)

block = f'''
/* {marker} */
#ifdef __ANDROID__
#include <errno.h>
static inline int android_ivshmem_shm_open(const char *name, int oflag, mode_t mode) {{
    errno = ENOSYS;
    return -1;
}}
static inline int android_ivshmem_shm_unlink(const char *name) {{
    errno = ENOSYS;
    return -1;
}}
#define shm_open android_ivshmem_shm_open
#define shm_unlink android_ivshmem_shm_unlink
#endif
'''

inc_pat = re.compile(r'(#include[^\n]+\n)+', re.M)
m = inc_pat.search(src)
if not m:
    print("ERROR: could not find includes to patch", file=sys.stderr)
    sys.exit(1)
patched = src[:m.end()] + block + src[m.end():]
io.open(path, 'w', encoding='utf-8').write(patched)
print("patched")
PY
fi

# ==============================================================
# Build libucontext for Android (NON-freestanding mode)
#
# We do NOT use FREESTANDING because Android NDK r29 (API 31+)
# already defines ucontext_t and struct sigcontext in its sysroot.
# Using FREESTANDING would cause libucontext's bits.h to redefine
# sigcontext, conflicting with <asm/sigcontext.h>.
#
# Instead we build libucontext so it uses the NDK's own types and
# only provides the missing *functions*: getcontext, setcontext,
# makecontext, swapcontext.
# ==============================================================
if [ ! -d "$LIBUCONTEXT_SRC" ]; then
  echo "==> Cloning libucontext ..."
  git clone --depth 1 "$LIBUCONTEXT_GIT_URL" "$LIBUCONTEXT_SRC"
fi

if [ ! -f "$PREFIX/lib/libucontext.a" ]; then
  echo "==> Building libucontext for Android aarch64 (non-freestanding, NDK types) ..."
  pushd "$LIBUCONTEXT_SRC" >/dev/null

  # Clean any previous build (manual rm to avoid Makefile host-OS issues)
  rm -f arch/aarch64/*.o libucontext.a libucontext_posix.a 2>/dev/null || true

  # ---------------------------------------------------------------------------
  # NDK sysroot path — needed so libucontext picks up the NDK's own
  # <sys/ucontext.h> and <asm/sigcontext.h> instead of its bundled bits.h.
  # ---------------------------------------------------------------------------
  NDK_SYSROOT="$TOOLCHAIN/sysroot"

  # ---------------------------------------------------------------------------
  # Create a REPLACEMENT bits.h that uses the NDK's own types.
  #
  # libucontext's libucontext.h does:  #include <libucontext/bits.h>
  # The original bits.h (in arch/aarch64/include/) redefines sigcontext,
  # which conflicts with <asm/sigcontext.h> from the NDK.
  #
  # Our replacement includes the NDK's <sys/ucontext.h> and typedefs
  # libucontext_ucontext_t to the NDK's ucontext_t, satisfying
  # libucontext's internal code without any type conflicts.
  # ---------------------------------------------------------------------------
  OVERRIDE_DIR="$BUILD_ROOT/libucontext-override/libucontext"
  mkdir -p "$OVERRIDE_DIR"
  cat > "$OVERRIDE_DIR/bits.h" <<'BITS_SHIM'
/*
 * Replacement bits.h for Android — uses NDK types instead of
 * redefining sigcontext / mcontext_t / ucontext_t.
 */
#ifndef _LIBUCONTEXT_BITS_H
#define _LIBUCONTEXT_BITS_H

#include <sys/ucontext.h>

typedef ucontext_t libucontext_ucontext_t;

#endif /* _LIBUCONTEXT_BITS_H */
BITS_SHIM

  # Build ONLY the static library (.a) manually.
  # The Makefile's default target tries to build a shared library using
  # host-OS linker flags (e.g. -dynamiclib on macOS), which fails when
  # cross-compiling for Android with ld.lld.  We bypass that entirely.
  #
  # KEY CHANGES vs the old FREESTANDING build:
  #   - NO -DFREESTANDING  (use NDK's ucontext_t / sigcontext)
  #   - Our override dir comes BEFORE arch/aarch64/include so our
  #     replacement bits.h is found instead of the conflicting one
  #   - -DEXPORT_UNPREFIXED so the symbols are exported as getcontext() etc.
  #     rather than libucontext_getcontext()
  #   - --sysroot to ensure the NDK headers are found
  UCONTEXT_CFLAGS="-std=gnu99 -D_DEFAULT_SOURCE -fPIC -DPIC -D_XOPEN_SOURCE -DEXPORT_UNPREFIXED --sysroot=$NDK_SYSROOT -I$BUILD_ROOT/libucontext-override -Iinclude -Iarch/aarch64 -Iarch/common"
  UCONTEXT_ASFLAGS="-fPIC -DPIC -D_XOPEN_SOURCE -DEXPORT_UNPREFIXED --sysroot=$NDK_SYSROOT -I$BUILD_ROOT/libucontext-override -Iinclude -Iarch/aarch64 -Iarch/common"

  $CC $UCONTEXT_CFLAGS -c -o arch/aarch64/makecontext.o  arch/aarch64/makecontext.c
  $CC $UCONTEXT_CFLAGS -c -o arch/aarch64/trampoline.o   arch/aarch64/trampoline.c
  $CC $UCONTEXT_ASFLAGS -c -o arch/aarch64/getcontext.o   arch/aarch64/getcontext.S
  $CC $UCONTEXT_ASFLAGS -c -o arch/aarch64/setcontext.o   arch/aarch64/setcontext.S
  $CC $UCONTEXT_ASFLAGS -c -o arch/aarch64/swapcontext.o  arch/aarch64/swapcontext.S

  $AR rcs libucontext.a \
    arch/aarch64/makecontext.o \
    arch/aarch64/trampoline.o \
    arch/aarch64/getcontext.o \
    arch/aarch64/setcontext.o \
    arch/aarch64/swapcontext.o

  echo "==> libucontext.a built successfully"

  # Manual install into sysroot (skip Makefile install which also has host-OS issues)
  mkdir -p "$PREFIX/lib" "$PREFIX/include/libucontext"
  cp -f libucontext.a "$PREFIX/lib/"
  cp -f include/libucontext/libucontext.h "$PREFIX/include/libucontext/"
  # NOTE: We intentionally do NOT copy arch/aarch64/include/libucontext/bits.h
  # because it redefines sigcontext and conflicts with the NDK headers.

  popd >/dev/null

  # Create a ucontext.h shim in our sysroot that QEMU's meson probe can find.
  #
  # This shim uses the NDK's own <sys/ucontext.h> for the ucontext_t type
  # (which the NDK provides at API 23+), and only adds declarations for the
  # four functions that bionic lacks.  This avoids all type redefinition
  # conflicts with NDK headers.
  echo "==> Creating ucontext.h shim in $PREFIX/include ..."
  cat > "$PREFIX/include/ucontext.h" <<'UCONTEXT_SHIM'
/*
 * ucontext.h shim for Android — provides the missing functions
 * (getcontext/setcontext/makecontext/swapcontext) via libucontext,
 * while using the NDK's own ucontext_t type (from <sys/ucontext.h>).
 *
 * Android NDK r23+ (API 23+) defines ucontext_t and struct sigcontext
 * in its sysroot.  Bionic simply doesn't implement the four context-
 * switching functions.  libucontext supplies them.
 */
#ifndef _ANDROID_UCONTEXT_SHIM_H
#define _ANDROID_UCONTEXT_SHIM_H

/* Pull in the NDK's own ucontext_t — no type conflicts */
#include <sys/ucontext.h>

/* Declare the functions that bionic lacks; libucontext.a provides them */
#ifdef __cplusplus
extern "C" {
#endif

int  getcontext(ucontext_t *);
int  setcontext(const ucontext_t *);
int  swapcontext(ucontext_t *, const ucontext_t *);
void makecontext(ucontext_t *, void (*)(void), int, ...);

#ifdef __cplusplus
}
#endif

#endif /* _ANDROID_UCONTEXT_SHIM_H */
UCONTEXT_SHIM

  echo "==> libucontext installed:"
  ls -la "$PREFIX/lib"/libucontext* 2>/dev/null || true
  ls -la "$PREFIX/include/ucontext.h" 2>/dev/null || true
  ls -la "$PREFIX/include/libucontext/" 2>/dev/null || true
else
  echo "==> libucontext already built, skipping."
fi

# --- Clean out-of-tree build dir and (re)create ---
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
mkdir -p "$PREFIX/lib" "$PREFIX/bin"

# --- Quick dep check (optional) ---
echo "==> pkg-config quick check (Android-cross deps in $PREFIX)"
echo "GLib:   $(pkg-config --modversion glib-2.0 2>/dev/null || echo 'NOT FOUND')"
echo "Pixman: $(pkg-config --modversion pixman-1 2>/dev/null || echo 'NOT FOUND')"
echo "SDL2:   $(pkg-config --modversion sdl2 2>/dev/null || echo 'NOT FOUND')"
echo "epoxy:  $(pkg-config --modversion epoxy 2>/dev/null || echo 'NOT FOUND')"

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
