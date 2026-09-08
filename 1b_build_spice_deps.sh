#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Build SPICE dependencies for Android
# (opus, openssl, libjpeg-turbo, spice-protocol, spice-server)
#
# Run AFTER 1_build_deps_android.sh — relies on that script's
# glib + pixman in $PREFIX. Outputs land in the same sysroot so
# 2_build_qemu_android.sh's pkg-config picks everything up.
# ==================================================


# Macos path
#NDK_PATH="${NDK_PATH:-$HOME/AndroidNDKr29.app/Contents/NDK}"

# Linux path
NDK_PATH="${NDK_PATH:-$HOME/android-ndk-r29}"


### ========= CONFIG =========
API_LEVEL="${API_LEVEL:-31}"
APP_ABI="${APP_ABI:-arm64-v8a}"              # arm64-v8a | armeabi-v7a | x86 | x86_64
BUILD_ROOT="${BUILD_ROOT:-$(pwd)/build}"
PREFIX="${PREFIX:-$BUILD_ROOT/sysroot-${APP_ABI}}"

# Versions (stable picks)
OPUS_VER="${OPUS_VER:-1.5.2}"
OPENSSL_VER="${OPENSSL_VER:-3.0.14}"
JPEG_TURBO_VER="${JPEG_TURBO_VER:-3.0.4}"
SPICE_PROTOCOL_VER="${SPICE_PROTOCOL_VER:-0.14.4}"
SPICE_SERVER_VER="${SPICE_SERVER_VER:-0.15.2}"

SRC_DIR="${SRC_DIR:-$BUILD_ROOT/_src}"
BUILD_DIR="${BUILD_DIR:-$BUILD_ROOT/_build_${APP_ABI}}"

mkdir -p "$PREFIX" "$SRC_DIR" "$BUILD_DIR"

### ========= TOOLCHAIN / TARGET TRIPLES =========
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$HOST_OS" in
  linux)   HOST_TAG="linux-x86_64" ;;
  darwin)  HOST_TAG="darwin-x86_64" ;;
  *) echo "Unsupported host OS: $HOST_OS" >&2; exit 1 ;;
esac

TOOLCHAIN="$NDK_PATH/toolchains/llvm/prebuilt/$HOST_TAG"

case "$APP_ABI" in
  arm64-v8a)   TARGET_TRIPLE=aarch64-linux-android;   MESON_CPU=aarch64;  CMAKE_ABI="arm64-v8a";   OPENSSL_TARGET=android-arm64 ;;
  armeabi-v7a) TARGET_TRIPLE=armv7a-linux-androideabi; MESON_CPU=arm;     CMAKE_ABI="armeabi-v7a"; OPENSSL_TARGET=android-arm ;;
  x86)         TARGET_TRIPLE=i686-linux-android;       MESON_CPU=x86;     CMAKE_ABI="x86";         OPENSSL_TARGET=android-x86 ;;
  x86_64)      TARGET_TRIPLE=x86_64-linux-android;     MESON_CPU=x86_64;  CMAKE_ABI="x86_64";      OPENSSL_TARGET=android-x86_64 ;;
  *) echo "Unsupported APP_ABI: $APP_ABI" >&2; exit 1 ;;
esac

export CC="$TOOLCHAIN/bin/${TARGET_TRIPLE}${API_LEVEL}-clang"
export CXX="$TOOLCHAIN/bin/${TARGET_TRIPLE}${API_LEVEL}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export NM="$TOOLCHAIN/bin/llvm-nm"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export LD="$TOOLCHAIN/bin/ld"
export OBJCOPY="$TOOLCHAIN/bin/llvm-objcopy"

# pkg-config: have it look inside our PREFIX for target .pc files.
# Includes share/pkgconfig because meson installs noarch packages (like
# spice-protocol — headers only) there by convention.
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# Same TLS-model + PIC/PIE story as script 1. Critical when QEMU loads as a
# .so via JNI dlopen — initial-exec TLS would crash.
export CFLAGS="-fPIC -fPIE -ftls-model=global-dynamic"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-pie"

# Parallelism
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

### ========= HELPERS =========
fetch() {
  local url="$1" out="$2"
  if [ ! -f "$out" ]; then
    echo "==> Download $url"
    curl -L --fail -o "$out" "$url"
  fi
}

### ========= PRECHECK: deps from script 1 =========
echo "==> Verifying script-1 deps are present..."
for dep in glib-2.0 pixman-1; do
  if ! pkg-config --exists "$dep"; then
    echo "ERROR: '$dep' not found in $PKG_CONFIG_LIBDIR." >&2
    echo "       Run ./1_build_deps_android.sh first." >&2
    exit 1
  fi
  echo "       $dep: $(pkg-config --modversion $dep)"
done

### ========= 1) opus (audio codec for SPICE playback/record channels) =========
if [ -f "$PREFIX/lib/libopus.so" ]; then
  echo "==> opus already installed, skipping."
else
  cd "$SRC_DIR"
  fetch "https://downloads.xiph.org/releases/opus/opus-${OPUS_VER}.tar.gz" "opus-${OPUS_VER}.tar.gz"
  [ -d "opus-${OPUS_VER}" ] || tar xf "opus-${OPUS_VER}.tar.gz"

  rm -rf "$BUILD_DIR/opus"
  mkdir -p "$BUILD_DIR/opus"
  cd "$BUILD_DIR/opus"

  echo "==> Configuring opus ${OPUS_VER}"
  "$SRC_DIR/opus-${OPUS_VER}/configure" \
    --host="${TARGET_TRIPLE}" \
    --prefix="$PREFIX" \
    --enable-shared \
    --disable-static \
    --disable-doc \
    --disable-extra-programs

  echo "==> Building opus"
  make -j"$JOBS"
  make install
fi

### ========= 2) OpenSSL (hard dep of spice-server, even if we never use TLS) =========
# spice-server's meson unconditionally requires openssl. Their existing GnuTLS
# stack from script 1 satisfies QEMU's --enable-gnutls (for VNC TLS) but isn't
# what spice-server links against. Both end up in the QEMU binary.
if [ -f "$PREFIX/lib/libssl.so" ] && [ -f "$PREFIX/lib/libcrypto.so" ]; then
  echo "==> OpenSSL already installed, skipping."
else
  cd "$SRC_DIR"
  fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VER}/openssl-${OPENSSL_VER}.tar.gz" "openssl-${OPENSSL_VER}.tar.gz"
  [ -d "openssl-${OPENSSL_VER}" ] || tar xf "openssl-${OPENSSL_VER}.tar.gz"

  cd "$SRC_DIR/openssl-${OPENSSL_VER}"
  make distclean 2>/dev/null || true

  echo "==> Configuring OpenSSL ${OPENSSL_VER} (target=${OPENSSL_TARGET})"
  # OpenSSL's Configure picks up ANDROID_NDK_ROOT and the matching clang from PATH.
  # --libdir=lib forces lib/ instead of lib64/ on 64-bit ABIs so our .pc-file
  # path stays stable.
  ANDROID_NDK_ROOT="$NDK_PATH" PATH="$TOOLCHAIN/bin:$PATH" \
    ./Configure "$OPENSSL_TARGET" \
      -D__ANDROID_API__="$API_LEVEL" \
      --prefix="$PREFIX" \
      --openssldir="$PREFIX/etc/ssl" \
      --libdir=lib \
      shared \
      no-tests no-engine no-legacy

  echo "==> Building OpenSSL"
  ANDROID_NDK_ROOT="$NDK_PATH" PATH="$TOOLCHAIN/bin:$PATH" \
    make -j"$JOBS"
  # install_sw skips man pages and HTML docs.
  ANDROID_NDK_ROOT="$NDK_PATH" PATH="$TOOLCHAIN/bin:$PATH" \
    make install_sw
fi

### ========= 3) libjpeg-turbo (image encoding for SPICE display channel) =========
if [ -f "$PREFIX/lib/libjpeg.so" ]; then
  echo "==> libjpeg-turbo already installed, skipping."
else
  cd "$SRC_DIR"
  fetch "https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/${JPEG_TURBO_VER}/libjpeg-turbo-${JPEG_TURBO_VER}.tar.gz" "libjpeg-turbo-${JPEG_TURBO_VER}.tar.gz"
  [ -d "libjpeg-turbo-${JPEG_TURBO_VER}" ] || tar xf "libjpeg-turbo-${JPEG_TURBO_VER}.tar.gz"

  rm -rf "$BUILD_DIR/jpeg-turbo"
  mkdir -p "$BUILD_DIR/jpeg-turbo"
  cd "$BUILD_DIR/jpeg-turbo"

  echo "==> Configuring libjpeg-turbo ${JPEG_TURBO_VER}"
  cmake -G Ninja "$SRC_DIR/libjpeg-turbo-${JPEG_TURBO_VER}" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$CMAKE_ABI" \
    -DANDROID_PLATFORM="android-${API_LEVEL}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-ftls-model=global-dynamic" \
    -DENABLE_SHARED=ON \
    -DENABLE_STATIC=OFF \
    -DWITH_TURBOJPEG=OFF

  echo "==> Building libjpeg-turbo"
  cmake --build . -j"$JOBS"
  cmake --install .
fi

### Shared meson cross-file (used by spice-protocol AND spice-server below).
### Write unconditionally so re-runs that skip spice-protocol still have it.
MESON_CROSS="$BUILD_DIR/spice.cross"
cat > "$MESON_CROSS" <<EOF
[binaries]
c = '${CC}'
cpp = '${CXX}'
ar = '${AR}'
strip = '${STRIP}'
pkg-config = 'pkg-config'

[built-in options]
c_args = ['-fPIC','-fPIE','-ftls-model=global-dynamic']
c_link_args = ['-pie']

[host_machine]
system = 'linux'
cpu_family = '${MESON_CPU}'
cpu = '${MESON_CPU}'
endian = 'little'
EOF

### ========= 4) spice-protocol (headers + pkg-config only) =========
# NOTE: spice-space.org is unreliable — switched to gitlab.freedesktop.org git clone.
if pkg-config --exists spice-protocol; then
  echo "==> spice-protocol already installed ($(pkg-config --modversion spice-protocol)), skipping."
else
  SPICE_PROTOCOL_SRC="$SRC_DIR/spice-protocol-${SPICE_PROTOCOL_VER}"
  if [ ! -d "$SPICE_PROTOCOL_SRC" ]; then
    echo "==> Cloning spice-protocol v${SPICE_PROTOCOL_VER} from gitlab.freedesktop.org"
    git clone --depth 1 --branch "v${SPICE_PROTOCOL_VER}" \
      https://gitlab.freedesktop.org/spice/spice-protocol.git \
      "$SPICE_PROTOCOL_SRC"
  fi

  rm -rf "$BUILD_DIR/spice-protocol"
  mkdir -p "$BUILD_DIR/spice-protocol"
  cd "$BUILD_DIR/spice-protocol"

  echo "==> Configuring spice-protocol ${SPICE_PROTOCOL_VER}"
  meson setup . "$SPICE_PROTOCOL_SRC" \
    --cross-file "$MESON_CROSS" \
    --prefix "$PREFIX"

  meson install
fi

### ========= 5) spice-server =========
if [ -f "$PREFIX/lib/libspice-server.so" ]; then
  echo "==> spice-server already installed, skipping."
else
  SPICE_SERVER_SRC="$SRC_DIR/spice-${SPICE_SERVER_VER}"
  if [ ! -d "$SPICE_SERVER_SRC" ]; then
    echo "==> Cloning spice v${SPICE_SERVER_VER} from gitlab.freedesktop.org (recursive for spice-common submodule)"
    git clone --depth 1 --branch "v${SPICE_SERVER_VER}" --recurse-submodules \
      https://gitlab.freedesktop.org/spice/spice.git \
      "$SPICE_SERVER_SRC"
  fi

  # Android-specific patches to spice-server meson.build. Idempotent via marker.
  #   1. Drop librt from the required deps list. Android bionic folds librt's
  #      functions (clock_gettime, timer_*, etc.) into libc, so libpthread/libm
  #      is enough.
  #   2. Skip the tools/ subdir. tools/reds_stat.c uses shm_open/shm_unlink
  #      which Android NDK doesn't expose. The other files (bitmap_to_c,
  #      icon_to_c) are unused standalone utilities. libspice-server.so doesn't
  #      depend on anything in tools/.
  PATCH_MARKER="$SPICE_SERVER_SRC/.android-patches-applied"
  if [ ! -f "$PATCH_MARKER" ]; then
    echo "==> Patching spice-server for Android (drop librt, skip tools/, stub shm_open)"
    sed -i.bak "s/foreach dep : \['rt', 'm'\]/foreach dep : ['m']/" "$SPICE_SERVER_SRC/meson.build"
    sed -i.bak "s|^subdir('tools')|#subdir('tools') # disabled for Android — uses shm_open|" "$SPICE_SERVER_SRC/meson.build"
    # server/stat-file.c uses shm_open/shm_unlink which Android NDK doesn't
    # expose. The functions are only called at runtime when -Dstatistics=true
    # (we don't enable it — both callers in reds.cpp are gated by #ifdef
    # RED_STATISTICS). Add static no-op stubs so the file links.
    python3 - "$SPICE_SERVER_SRC/server/stat-file.c" <<'PYEOF'
import sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
if '__ANDROID__' in content:
    print('==> stat-file.c already patched')
    sys.exit(0)
marker = '#include "stat-file.h"'
shim = '''#ifdef __ANDROID__
/* Android NDK does not expose shm_open/shm_unlink. Stats are off by default
 * (-Dstatistics=false) so these are never called — stub them to satisfy
 * the linker. */
#include <errno.h>
static inline int shm_open(const char *n, int o, mode_t m) { (void)n; (void)o; (void)m; errno = ENOSYS; return -1; }
static inline int shm_unlink(const char *n) { (void)n; errno = ENOSYS; return -1; }
#endif

''' + marker
with open(path, 'w') as f:
    f.write(content.replace(marker, shim, 1))
print('==> patched stat-file.c')
PYEOF
    touch "$PATCH_MARKER"
  fi

  rm -rf "$BUILD_DIR/spice-server"
  mkdir -p "$BUILD_DIR/spice-server"
  cd "$BUILD_DIR/spice-server"

  echo "==> Configuring spice-server ${SPICE_SERVER_VER}"
  # Disabled features (each gives back binary size or removes a dep):
  #   gstreamer  — we route audio via QEMU's aaudio backend; no GStreamer pipeline.
  #   lz4        — LZ4 image codec; SPICE falls back to QUIC/zlib without it.
  #   sasl       — SASL auth; spice ticket auth still works.
  #   smartcard  — needs libcacard; no smartcard passthrough on Android anyway.
  #   tests      — would try to run on the build host, breaks cross-compile.
  #   manual     — docbook-xsl pipeline we don't need.
  meson setup . "$SPICE_SERVER_SRC" \
    --cross-file "$MESON_CROSS" \
    --prefix "$PREFIX" \
    -Ddefault_library=shared \
    -Dgstreamer=no \
    -Dlz4=false \
    -Dsasl=false \
    -Dsmartcard=disabled \
    -Dtests=false \
    -Dmanual=false \
    -Dopus=enabled

  echo "==> Building spice-server"
  meson compile -j"$JOBS"
  meson install
fi

### ========= DONE =========
echo
echo "=================================================="
echo "✅ Finished building SPICE deps for Android (${APP_ABI})"
echo "Installed to:   $PREFIX"
echo
echo "  opus           .pc: $(ls -1 $PREFIX/lib/pkgconfig/opus.pc 2>/dev/null || echo 'not found')"
echo "  openssl        .pc: $(ls -1 $PREFIX/lib/pkgconfig/openssl.pc 2>/dev/null || echo 'not found')"
echo "  libjpeg        .pc: $(ls -1 $PREFIX/lib/pkgconfig/libjpeg.pc 2>/dev/null || echo 'not found')"
echo "  spice-protocol .pc: $(ls -1 $PREFIX/lib/pkgconfig/spice-protocol.pc 2>/dev/null || echo 'not found')"
echo "  spice-server   .pc: $(ls -1 $PREFIX/lib/pkgconfig/spice-server.pc 2>/dev/null || echo 'not found')"
echo
echo "  versions:"
echo "    opus:           $(pkg-config --modversion opus 2>/dev/null || echo 'NOT FOUND')"
echo "    openssl:        $(pkg-config --modversion openssl 2>/dev/null || echo 'NOT FOUND')"
echo "    libjpeg:        $(pkg-config --modversion libjpeg 2>/dev/null || echo 'NOT FOUND')"
echo "    spice-protocol: $(pkg-config --modversion spice-protocol 2>/dev/null || echo 'NOT FOUND')"
echo "    spice-server:   $(pkg-config --modversion spice-server 2>/dev/null || echo 'NOT FOUND')"
echo "=================================================="
