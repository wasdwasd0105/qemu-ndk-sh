#!/usr/bin/env bash
set -euo pipefail


# Macos path
#NDK_PATH="${NDK_PATH:-$HOME/AndroidNDKr29.app/Contents/NDK}"

# Linux path
NDK_PATH="${NDK_PATH:-$HOME/android-ndk-r29}"


### ========= CONFIG =========
# Default NDK path you asked for
API_LEVEL="${API_LEVEL:-31}"
APP_ABI="${APP_ABI:-arm64-v8a}"              # arm64-v8a | armeabi-v7a | x86 | x86_64
BUILD_ROOT="${BUILD_ROOT:-$(pwd)/build}"
PREFIX="${PREFIX:-$BUILD_ROOT/sysroot-${APP_ABI}}"

# Versions (stable picks)
LIBFFI_VER="${LIBFFI_VER:-3.4.4}"
PCRE2_VER="${PCRE2_VER:-10.44}"
GLIB_VER="${GLIB_VER:-2.83.0}"
PIXMAN_VER="${PIXMAN_VER:-0.42.2}"
SDL2_VER="${SDL2_VER:-2.32.10}"
GMP_VER="${GMP_VER:-6.3.0}"
NETTLE_VER="${NETTLE_VER:-3.10}"
GNUTLS_VER="${GNUTLS_VER:-3.8.7}"
GNUTLS_MAJMIN="${GNUTLS_VER%.*}"   # e.g. 3.8

# Also build pixman? (1=yes, 0=no)
BUILD_PIXMAN="${BUILD_PIXMAN:-1}"

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
  arm64-v8a)   TARGET_TRIPLE=aarch64-linux-android;   MESON_CPU=aarch64;  CMAKE_ABI="arm64-v8a" ;;
  armeabi-v7a) TARGET_TRIPLE=armv7a-linux-androideabi; MESON_CPU=arm;     CMAKE_ABI="armeabi-v7a" ;;
  x86)         TARGET_TRIPLE=i686-linux-android;       MESON_CPU=x86;     CMAKE_ABI="x86" ;;
  x86_64)      TARGET_TRIPLE=x86_64-linux-android;     MESON_CPU=x86_64;  CMAKE_ABI="x86_64" ;;
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

# pkg-config: have it look inside our PREFIX for target .pc files
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

# Android-safe flags (NDK already defines __ANDROID_API__)
# CRITICAL: -ftls-model=global-dynamic is required when QEMU runs as a .so via JNI.
# Without it, __thread variables use "initial-exec" TLS which breaks under dlopen().
# This must be applied to ALL deps, not just QEMU itself.
# NOTE: do NOT add -I$PREFIX/include / -L$PREFIX/lib globally here — GLib
# fails its `libintl.type_name() == 'internal'` assert if it discovers an
# external libintl from a previous build. Deps that need cross-references
# (nettle->gmp, gnutls->nettle/hogweed/gmp) set their own --with-*-path
# flags or pass *_CFLAGS/*_LIBS env vars at configure time.
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

### ========= 1) libffi =========
cd "$SRC_DIR"
fetch "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VER}/libffi-${LIBFFI_VER}.tar.gz" "libffi-${LIBFFI_VER}.tar.gz"
[ -d "libffi-${LIBFFI_VER}" ] || tar xf "libffi-${LIBFFI_VER}.tar.gz"

mkdir -p "$BUILD_DIR/libffi"
cd "$BUILD_DIR/libffi"
# Clean if re-running
[ -f Makefile ] && make distclean || true

echo "==> Configuring libffi ${LIBFFI_VER}"
"$SRC_DIR/libffi-${LIBFFI_VER}/configure" \
  --host="${TARGET_TRIPLE}" \
  --prefix="$PREFIX" \
  --enable-shared \
  --disable-static \
  --disable-exec-static-tramp

echo "==> Building libffi"
make -j"$JOBS"
make install

### ========= 2) PCRE2 (for GLib) =========
cd "$SRC_DIR"
fetch "https://github.com/PhilipHazel/pcre2/releases/download/pcre2-${PCRE2_VER}/pcre2-${PCRE2_VER}.tar.bz2" "pcre2-${PCRE2_VER}.tar.bz2"
[ -d "pcre2-${PCRE2_VER}" ] || tar xf "pcre2-${PCRE2_VER}.tar.bz2"

mkdir -p "$BUILD_DIR/pcre2"
cd "$BUILD_DIR/pcre2"

echo "==> Configuring PCRE2 ${PCRE2_VER} (CMake + NDK toolchain)"
cmake -G Ninja "$SRC_DIR/pcre2-${PCRE2_VER}" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI="$CMAKE_ABI" \
  -DANDROID_PLATFORM="android-${API_LEVEL}" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_C_FLAGS="-ftls-model=global-dynamic" \
  -DBUILD_SHARED_LIBS=ON \
  -DPCRE2_BUILD_PCRE2_8=ON \
  -DPCRE2_BUILD_PCRE2_16=OFF \
  -DPCRE2_BUILD_PCRE2_32=OFF \
  -DPCRE2_SUPPORT_JIT=OFF

echo "==> Building PCRE2"
cmake --build . -j"$JOBS"
cmake --install .

### ========= 3) GLib =========
cd "$SRC_DIR"
fetch "https://download.gnome.org/sources/glib/${GLIB_VER%.*}/glib-${GLIB_VER}.tar.xz" "glib-${GLIB_VER}.tar.xz"
[ -d "glib-${GLIB_VER}" ] || tar xf "glib-${GLIB_VER}.tar.xz"

MESON_CROSS="$BUILD_DIR/glib.cross"
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

mkdir -p "$BUILD_DIR/glib"
cd "$BUILD_DIR/glib"
# If re-running:
[ -f build.ninja ] && rm -rf ./*

echo "==> Configuring GLib ${GLIB_VER} (Meson)"
meson setup . "$SRC_DIR/glib-${GLIB_VER}" \
  --cross-file "$MESON_CROSS" \
  --prefix "$PREFIX" \
  -Ddefault_library=shared \
  -Doptimization=2 \
  -Ddebug=false \
  -Dglib_debug=disabled \
  -Dtests=false \
  -Dman=false \
  -Dgtk_doc=false \
  -Dselinux=disabled \
  -Dlibmount=disabled \
  -Dnls=disabled \

echo "==> Building GLib"
meson compile -j"$JOBS"
meson install

### ========= 4) (Optional) pixman =========
if [ "$BUILD_PIXMAN" = "1" ]; then
  cd "$SRC_DIR"
  fetch "https://www.cairographics.org/releases/pixman-${PIXMAN_VER}.tar.gz" "pixman-${PIXMAN_VER}.tar.gz"
  [ -d "pixman-${PIXMAN_VER}" ] || tar xf "pixman-${PIXMAN_VER}.tar.gz"

  mkdir -p "$BUILD_DIR/pixman"
  cd "$BUILD_DIR/pixman"
  [ -f Makefile ] && make distclean || true

  echo "==> Configuring pixman ${PIXMAN_VER}"
  "$SRC_DIR/pixman-${PIXMAN_VER}/configure" \
    --host="${TARGET_TRIPLE}" \
    --prefix="$PREFIX" \
    --disable-static \
    --disable-arm-a64-neon

  echo "==> Building pixman"
  make -j"$JOBS"
  make install
fi

### ========= 4b) libusb (for USB host passthrough) =========
LIBUSB_VER="${LIBUSB_VER:-1.0.27}"
cd "$SRC_DIR"
fetch "https://github.com/libusb/libusb/releases/download/v${LIBUSB_VER}/libusb-${LIBUSB_VER}.tar.bz2" "libusb-${LIBUSB_VER}.tar.bz2"
[ -d "libusb-${LIBUSB_VER}" ] || tar xf "libusb-${LIBUSB_VER}.tar.bz2"

mkdir -p "$BUILD_DIR/libusb"
cd "$BUILD_DIR/libusb"
[ -f Makefile ] && make distclean || true

echo "==> Configuring libusb ${LIBUSB_VER}"
"$SRC_DIR/libusb-${LIBUSB_VER}/configure" \
  --host="${TARGET_TRIPLE}" \
  --prefix="$PREFIX" \
  --enable-shared \
  --disable-static \
  --disable-udev

echo "==> Building libusb"
make -j"$JOBS"
make install

echo "libusb .pc: $(ls -1 $PREFIX/lib/pkgconfig/libusb-1.0.pc 2>/dev/null || echo 'not found')"

### ========= DONE =========
echo
echo "=================================================="
echo "✅ Finished building deps for Android (${APP_ABI})"
echo "Installed to:   $PREFIX"
echo
echo "Environment for QEMU build:"
echo "  export PKG_CONFIG_PATH=\"$PREFIX/lib/pkgconfig\""
echo "  export PKG_CONFIG_LIBDIR=\"$PREFIX/lib/pkgconfig\""
echo
echo "GLib .pc:   $(ls -1 $PREFIX/lib/pkgconfig/glib-2.0.pc 2>/dev/null || echo 'not found')"
echo "PCRE2 .pc:  $(ls -1 $PREFIX/lib/pkgconfig/libpcre2-8.pc 2>/dev/null || echo 'not found')"
if [ "$BUILD_PIXMAN" = "1" ]; then
  echo "pixman .pc: $(ls -1 $PREFIX/lib/pkgconfig/pixman-1.pc 2>/dev/null || echo 'not found')"
fi
echo "=================================================="


### ========= 5) SDL2 (2.0.8) for Android via ndk-build =========
cd "$SRC_DIR"
SDL_TGZ="SDL2-${SDL2_VER}.tar.gz"
SDL_URL="https://www.libsdl.org/release/${SDL_TGZ}"
# Mirrors if the main URL is slow:
# SDL_URL="https://www.libsdl.org/release-2.0/${SDL_TGZ}"

fetch "$SDL_URL" "$SDL_TGZ"
[ -d "SDL2-${SDL2_VER}" ] || tar xf "$SDL_TGZ"

# Build with NDK using SDL's Android.mk (no app project needed)
mkdir -p "$BUILD_DIR/sdl2"
pushd "$SRC_DIR/SDL2-${SDL2_VER}"

# Clean prior outputs if re-running
rm -rf "$BUILD_DIR/sdl2/obj" "$BUILD_DIR/sdl2/libs"

# Map APP_ABI to NDK ABI (you already computed $CMAKE_ABI)
ANDROID_ABI="$CMAKE_ABI"
ANDROID_PLATFORM="android-${API_LEVEL}"

echo "==> Building SDL2 ${SDL2_VER} for ${ANDROID_ABI} (${ANDROID_PLATFORM}) via ndk-build"
"$NDK_PATH/ndk-build" \
  NDK_PROJECT_PATH=. \
  APP_BUILD_SCRIPT=Android.mk \
  APP_ABI="$ANDROID_ABI" \
  APP_PLATFORM="$ANDROID_PLATFORM" \
  APP_CFLAGS="-ftls-model=global-dynamic" \
  NDK_LIBS_OUT="$BUILD_DIR/sdl2/libs" \
  NDK_OUT="$BUILD_DIR/sdl2/obj" \
  V=0

# Install headers
echo "==> Installing SDL2 headers to $PREFIX/include/SDL2"
mkdir -p "$PREFIX/include/SDL2"
# Copy the public headers
cp -af include/*.h "$PREFIX/include/SDL2/"

# Install library
echo "==> Installing libSDL2.so to $PREFIX/lib"
mkdir -p "$PREFIX/lib"
cp -af "$BUILD_DIR/sdl2/libs/$ANDROID_ABI/libSDL2.so" "$PREFIX/lib/"

popd

# Create a minimal pkg-config file so QEMU can discover SDL2
echo "==> Generating $PREFIX/lib/pkgconfig/sdl2.pc"
mkdir -p "$PREFIX/lib/pkgconfig"
cat > "$PREFIX/lib/pkgconfig/sdl2.pc" <<EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include/SDL2

Name: sdl2
Description: Simple DirectMedia Layer 2 (Android)
Version: ${SDL2_VER}
Libs: -L\${libdir} -lSDL2 -landroid -llog
Cflags: -I\${includedir}
EOF

echo "SDL2 .pc:  $PREFIX/lib/pkgconfig/sdl2.pc"


### ========= 6) GMP =========
# Used by Nettle (which uses it for big-int math) and ultimately by GnuTLS.
# Idempotent: skips if already installed.
if [ -f "$PREFIX/lib/libgmp.so" ]; then
  echo "==> libgmp.so already installed, skipping GMP build."
else
  cd "$SRC_DIR"
  fetch "https://gmplib.org/download/gmp/gmp-${GMP_VER}.tar.xz" "gmp-${GMP_VER}.tar.xz"
  [ -d "gmp-${GMP_VER}" ] || tar xf "gmp-${GMP_VER}.tar.xz"

  mkdir -p "$BUILD_DIR/gmp"
  cd "$BUILD_DIR/gmp"
  [ -f Makefile ] && make distclean || true

  echo "==> Configuring GMP ${GMP_VER}"
  # --disable-assembly: GMP's hand-written aarch64 asm trips on NDK clang in
  # some configurations; the C fallback works and is plenty fast for TLS.
  "$SRC_DIR/gmp-${GMP_VER}/configure" \
    --host="${TARGET_TRIPLE}" \
    --prefix="$PREFIX" \
    --enable-shared \
    --disable-static \
    --disable-assembly

  echo "==> Building GMP"
  make -j"$JOBS"
  make install
fi

### ========= 7) Nettle (+ Hogweed) =========
if [ -f "$PREFIX/lib/libnettle.so" ] && [ -f "$PREFIX/lib/libhogweed.so" ]; then
  echo "==> libnettle / libhogweed already installed, skipping Nettle build."
else
  cd "$SRC_DIR"
  fetch "https://ftp.gnu.org/gnu/nettle/nettle-${NETTLE_VER}.tar.gz" "nettle-${NETTLE_VER}.tar.gz"
  [ -d "nettle-${NETTLE_VER}" ] || tar xf "nettle-${NETTLE_VER}.tar.gz"

  mkdir -p "$BUILD_DIR/nettle"
  cd "$BUILD_DIR/nettle"
  [ -f Makefile ] && make distclean || true

  echo "==> Configuring Nettle ${NETTLE_VER}"
  "$SRC_DIR/nettle-${NETTLE_VER}/configure" \
    --host="${TARGET_TRIPLE}" \
    --prefix="$PREFIX" \
    --enable-shared \
    --disable-static \
    --disable-documentation \
    --disable-openssl \
    --with-include-path="$PREFIX/include" \
    --with-lib-path="$PREFIX/lib"

  echo "==> Building Nettle"
  make -j"$JOBS"
  make install
fi

### ========= 8) GnuTLS =========
# Required by QEMU for VNC TLS x509 credentials (--enable-gnutls).
if [ -f "$PREFIX/lib/libgnutls.so" ]; then
  echo "==> libgnutls.so already installed, skipping GnuTLS build."
else
  cd "$SRC_DIR"
  fetch "https://www.gnupg.org/ftp/gcrypt/gnutls/v${GNUTLS_MAJMIN}/gnutls-${GNUTLS_VER}.tar.xz" "gnutls-${GNUTLS_VER}.tar.xz"
  [ -d "gnutls-${GNUTLS_VER}" ] || tar xf "gnutls-${GNUTLS_VER}.tar.xz"

  # GnuTLS 3.8.x always compiles its dlwrap shims for zstd/brotli, even with
  # --without-zstd / --without-brotli. The shims #include the system headers
  # unconditionally, but only reference real symbols when the matching
  # GNUTLS_*_ENABLE_DLOPEN macro is set (which it isn't, since we disable
  # both). Provide empty stub headers so the unconditional includes resolve.
  GNUTLS_STUBS="$BUILD_DIR/gnutls-stubs"
  mkdir -p "$GNUTLS_STUBS/brotli"
  : > "$GNUTLS_STUBS/zstd.h"
  : > "$GNUTLS_STUBS/brotli/encode.h"
  : > "$GNUTLS_STUBS/brotli/decode.h"

  # Android NDK r29 defines timezone_t in <time.h> but only declares the
  # functions tzalloc/tzfree/mktime_z/localtime_rz at API >= 35. We target
  # API 31, so gnulib's src/gl/ helper code (used only by gnutls's CLI
  # tools, which we --disable-tools) fails to compile. Provide a wrapper
  # <time.h> on the include path that chains to the NDK's via
  # #include_next and then adds weak prototypes. With -I$GNUTLS_STUBS in
  # CFLAGS this wrapper is found first; nothing actually links these
  # symbols since --disable-tools means the convenience archive is unused.
  cat > "$GNUTLS_STUBS/time.h" <<'TZSTUBS'
#ifndef _GNUTLS_ANDROID_TIME_WRAPPER_H
#define _GNUTLS_ANDROID_TIME_WRAPPER_H
#include_next <time.h>
extern timezone_t tzalloc(const char *zone) __attribute__((weak));
extern void tzfree(timezone_t tz) __attribute__((weak));
extern struct tm *localtime_rz(timezone_t tz, const time_t *t, struct tm *tmp) __attribute__((weak));
extern time_t mktime_z(timezone_t tz, struct tm *tm) __attribute__((weak));
#endif
TZSTUBS

  rm -rf "$BUILD_DIR/gnutls"
  mkdir -p "$BUILD_DIR/gnutls"
  cd "$BUILD_DIR/gnutls"

  echo "==> Configuring GnuTLS ${GNUTLS_VER}"
  # --with-included-libtasn1 + --with-included-unistring: avoid pulling
  #   in extra deps; these are tiny and ship with gnutls.
  # --without-p11-kit / --without-tpm / --without-tpm2: skip optional features.
  # --disable-doc/tools/tests/cxx/guile/libdane/nls: we only need the lib.
  # --disable-hardware-acceleration: avoid CPU-feature autodetect issues
  #   under NDK clang for cross builds.
  GMP_CFLAGS="-I$PREFIX/include" \
  GMP_LIBS="-L$PREFIX/lib -lgmp" \
  NETTLE_CFLAGS="-I$PREFIX/include" \
  NETTLE_LIBS="-L$PREFIX/lib -lnettle" \
  HOGWEED_CFLAGS="-I$PREFIX/include" \
  HOGWEED_LIBS="-L$PREFIX/lib -lhogweed -lnettle -lgmp" \
  CFLAGS="$CFLAGS -I$GNUTLS_STUBS" \
  CPPFLAGS="${CPPFLAGS:-} -I$GNUTLS_STUBS" \
  gl_cv_func_gettimeofday_clobber=no \
  "$SRC_DIR/gnutls-${GNUTLS_VER}/configure" \
    --host="${TARGET_TRIPLE}" \
    --prefix="$PREFIX" \
    --enable-shared \
    --disable-static \
    --with-included-libtasn1 \
    --with-included-unistring \
    --without-p11-kit \
    --without-tpm \
    --without-tpm2 \
    --without-libidn2 \
    --without-zlib \
    --without-brotli \
    --without-zstd \
    --disable-doc \
    --disable-tools \
    --disable-tests \
    --disable-cxx \
    --disable-guile \
    --disable-libdane \
    --disable-nls \
    --disable-hardware-acceleration \
    --disable-rpath

  echo "==> Building GnuTLS"
  make -j"$JOBS"
  make install
fi

echo
echo "=================================================="
echo "✅ GnuTLS stack installed for Android (${APP_ABI})"
echo "  GMP     .pc: $(ls -1 $PREFIX/lib/pkgconfig/gmp.pc 2>/dev/null || echo '(no pc file — uncommon for GMP)')"
echo "  Nettle  .pc: $(ls -1 $PREFIX/lib/pkgconfig/nettle.pc 2>/dev/null || echo 'not found')"
echo "  Hogweed .pc: $(ls -1 $PREFIX/lib/pkgconfig/hogweed.pc 2>/dev/null || echo 'not found')"
echo "  GnuTLS  .pc: $(ls -1 $PREFIX/lib/pkgconfig/gnutls.pc 2>/dev/null || echo 'not found')"
echo "  GnuTLS version: $(pkg-config --modversion gnutls 2>/dev/null || echo 'pkg-config not configured')"
ls -l "$PREFIX/lib/"libgmp* "$PREFIX/lib/"libnettle* "$PREFIX/lib/"libhogweed* "$PREFIX/lib/"libgnutls* 2>/dev/null || true
echo "=================================================="
