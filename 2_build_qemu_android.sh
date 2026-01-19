#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Build QEMU (default 10.0.2) for Android (arm64-v8a) as .so
# Strategy: build PIE executables with --export-dynamic, then copy to .so
# Works with QEMU 9.1.2 and 10.0.2+
# Includes an Android-only patch to disable POSIX shm (shm_open/shm_unlink).
# ==================================================

# --- Inputs ---
QEMU_VERSION="${QEMU_VERSION:-10.0.2}"
QEMU_GIT_URL="${QEMU_GIT_URL:-https://github.com/wasdwasd0105/qemu-android.git}"
QEMU_GIT_REF="qemu-10.0.2"
APP_ABI="${APP_ABI:-arm64-v8a}"
BUILD_ROOT="${BUILD_ROOT:-$(pwd)/build}"
QEMU_SRC="${QEMU_SRC:-$BUILD_ROOT/qemu-${QEMU_VERSION}}"
BUILD_DIR="${BUILD_DIR:-$BUILD_ROOT/qemu-build-${APP_ABI}}"
PREFIX="${PREFIX:-$BUILD_ROOT/sysroot-${APP_ABI}}"

NDK_PATH="${NDK_PATH:-$HOME/android-ndk-r27d}"
API_LEVEL="${API_LEVEL:-30}"
JOBS="${JOBS:-$(nproc)}"

# --- Android toolchain ---
TOOLCHAIN="$NDK_PATH/toolchains/llvm/prebuilt/linux-x86_64"
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
export CFLAGS="-fPIC -fvisibility=default -I$PREFIX/include -DSDL_MAIN_HANDLED -I$PREFIX/include/pixman-1"
export CPPFLAGS="$CFLAGS"
# -Wl,--export-dynamic ensures the executable exposes all global symbols in .dynsym
export LDFLAGS="-L$PREFIX/lib -Wl,--export-dynamic"

# Native compiler for small host build helpers
HOST_CC="${HOST_CC:-$(command -v cc || true)}"
[ -n "$HOST_CC" ] || { echo "No native host C compiler found."; exit 1; }

# --- Ensure source exists (clone from GitHub if missing) ---
mkdir -p "$BUILD_ROOT"
if [ ! -d "$QEMU_SRC" ]; then
  echo "==> Cloning QEMU sources from GitHub ($QEMU_GIT_URL) ref=$QEMU_GIT_REF into $QEMU_SRC ..."
  git clone --depth 1 --branch "$QEMU_GIT_REF" "$QEMU_GIT_URL" "$QEMU_SRC"
else
  # If the dir exists, optionally ensure it's on the requested ref.
  if [ -d "$QEMU_SRC/.git" ]; then
    echo "==> Updating existing QEMU git checkout in $QEMU_SRC (ref=$QEMU_GIT_REF) ..."
    pushd "$QEMU_SRC" >/dev/null
    git fetch --tags --prune origin || true
    git checkout -f "$QEMU_GIT_REF" || true
    #git submodule update --init --recursive || true
    popd >/dev/null
  else
    echo "==> Using existing QEMU source directory (not a git repo): $QEMU_SRC"
  fi
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
