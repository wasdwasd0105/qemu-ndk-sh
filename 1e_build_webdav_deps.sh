#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Build WebDAV / folder-sharing dependencies for Android
# (libxml2, libpsl, libsoup-3.0, libphodav-3.0)
#
# These enable spice-gtk's webdav channel (SpiceSession "shared-dir"):
#   spice-gtk webdav → libphodav-3.0 → libsoup-3.0 + libxml2 + libpsl
#
# Run AFTER 1_build_deps_android.sh (needs glib).
# Run BEFORE re-running 1c with -Dwebdav=enabled.
# ==================================================


# Macos path
#NDK_PATH="${NDK_PATH:-$HOME/AndroidNDKr29.app/Contents/NDK}"

# Linux path
NDK_PATH="${NDK_PATH:-$HOME/android-ndk-r29}"


### ========= CONFIG =========
API_LEVEL="${API_LEVEL:-31}"
APP_ABI="${APP_ABI:-arm64-v8a}"
BUILD_ROOT="${BUILD_ROOT:-$(pwd)/build}"
PREFIX="${PREFIX:-$BUILD_ROOT/sysroot-${APP_ABI}}"

LIBXML2_VER="${LIBXML2_VER:-2.12.9}"
LIBPSL_VER="${LIBPSL_VER:-0.21.5}"
LIBSOUP_VER="${LIBSOUP_VER:-3.4.4}"
PHODAV_VER="${PHODAV_VER:-3.0}"

SRC_DIR="${SRC_DIR:-$BUILD_ROOT/_src}"
BUILD_DIR="${BUILD_DIR:-$BUILD_ROOT/_build_${APP_ABI}}"

mkdir -p "$PREFIX" "$SRC_DIR" "$BUILD_DIR"

### ========= TOOLCHAIN =========
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$HOST_OS" in
  linux)   HOST_TAG="linux-x86_64" ;;
  darwin)  HOST_TAG="darwin-x86_64" ;;
  *) echo "Unsupported host OS: $HOST_OS" >&2; exit 1 ;;
esac
TOOLCHAIN="$NDK_PATH/toolchains/llvm/prebuilt/$HOST_TAG"

case "$APP_ABI" in
  arm64-v8a)   TARGET_TRIPLE=aarch64-linux-android;   MESON_CPU=aarch64 ;;
  armeabi-v7a) TARGET_TRIPLE=armv7a-linux-androideabi; MESON_CPU=arm ;;
  x86)         TARGET_TRIPLE=i686-linux-android;       MESON_CPU=x86 ;;
  x86_64)      TARGET_TRIPLE=x86_64-linux-android;     MESON_CPU=x86_64 ;;
  *) echo "Unsupported APP_ABI: $APP_ABI" >&2; exit 1 ;;
esac

export CC="$TOOLCHAIN/bin/${TARGET_TRIPLE}${API_LEVEL}-clang"
export CXX="$TOOLCHAIN/bin/${TARGET_TRIPLE}${API_LEVEL}-clang++"
export AR="$TOOLCHAIN/bin/llvm-ar"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export CFLAGS="-fPIC -fPIE -ftls-model=global-dynamic"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-pie"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

# brew bison for any parser generation
if [ -x /opt/homebrew/opt/bison/bin/bison ]; then
  export PATH="/opt/homebrew/opt/bison/bin:$PATH"
fi

fetch() {
  local url="$1" out="$2"
  if [ ! -f "$out" ]; then echo "==> Download $url"; curl -L --fail -o "$out" "$url"; fi
}

### ========= precheck =========
echo "==> Verifying glib present..."
pkg-config --exists glib-2.0 || { echo "ERROR: run 1_build_deps_android.sh first" >&2; exit 1; }

### Shared meson cross-file
MESON_CROSS="$BUILD_DIR/webdav.cross"
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

### ========= 1) libxml2 (phodav WebDAV XML) =========
# libxml2 ships CMake + autotools (no meson) — use CMake with the NDK
# toolchain file, same as libjpeg-turbo in 1b.
if pkg-config --exists libxml-2.0; then
  echo "==> libxml2 already installed ($(pkg-config --modversion libxml-2.0)), skipping."
else
  cd "$SRC_DIR"
  fetch "https://download.gnome.org/sources/libxml2/${LIBXML2_VER%.*}/libxml2-${LIBXML2_VER}.tar.xz" "libxml2-${LIBXML2_VER}.tar.xz"
  [ -d "libxml2-${LIBXML2_VER}" ] || tar xf "libxml2-${LIBXML2_VER}.tar.xz"
  rm -rf "$BUILD_DIR/libxml2"; mkdir -p "$BUILD_DIR/libxml2"; cd "$BUILD_DIR/libxml2"
  echo "==> Configuring libxml2 ${LIBXML2_VER} (cmake)"
  cmake -G Ninja "$SRC_DIR/libxml2-${LIBXML2_VER}" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$APP_ABI" \
    -DANDROID_PLATFORM="android-${API_LEVEL}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-ftls-model=global-dynamic" \
    -DBUILD_SHARED_LIBS=ON \
    -DLIBXML2_WITH_PYTHON=OFF -DLIBXML2_WITH_LZMA=OFF -DLIBXML2_WITH_ZLIB=OFF \
    -DLIBXML2_WITH_HTTP=OFF -DLIBXML2_WITH_PROGRAMS=OFF \
    -DLIBXML2_WITH_TESTS=OFF -DLIBXML2_WITH_ICONV=OFF
  cmake --build . -j"$JOBS"
  cmake --install .
fi

### ========= 2) libpsl (libsoup cookie domain checks) =========
# Built with no PSL data source (runtime=no, builtin=false) — fine for our
# local WebDAV use; libsoup links and treats every domain as non-public.
if pkg-config --exists libpsl; then
  echo "==> libpsl already installed ($(pkg-config --modversion libpsl)), skipping."
else
  cd "$SRC_DIR"
  fetch "https://github.com/rockdaboot/libpsl/releases/download/${LIBPSL_VER}/libpsl-${LIBPSL_VER}.tar.gz" "libpsl-${LIBPSL_VER}.tar.gz"
  [ -d "libpsl-${LIBPSL_VER}" ] || tar xf "libpsl-${LIBPSL_VER}.tar.gz"
  rm -rf "$BUILD_DIR/libpsl"; mkdir -p "$BUILD_DIR/libpsl"; cd "$BUILD_DIR/libpsl"
  echo "==> Configuring libpsl ${LIBPSL_VER}"
  meson setup . "$SRC_DIR/libpsl-${LIBPSL_VER}" \
    --cross-file "$MESON_CROSS" --prefix "$PREFIX" \
    -Ddefault_library=shared \
    -Druntime=no -Dbuiltin=false -Dtests=false
  meson compile -j"$JOBS"
  meson install
fi

### ========= 2b) libnghttp2 (hard dep of libsoup 3.4) =========
# WebDAV is HTTP/1.1, but libsoup 3.4 requires nghttp2 unconditionally.
# Library-only cmake build, no apps/tests.
NGHTTP2_VER="${NGHTTP2_VER:-1.64.0}"
if pkg-config --exists libnghttp2; then
  echo "==> libnghttp2 already installed ($(pkg-config --modversion libnghttp2)), skipping."
else
  cd "$SRC_DIR"
  fetch "https://github.com/nghttp2/nghttp2/releases/download/v${NGHTTP2_VER}/nghttp2-${NGHTTP2_VER}.tar.xz" "nghttp2-${NGHTTP2_VER}.tar.xz"
  [ -d "nghttp2-${NGHTTP2_VER}" ] || tar xf "nghttp2-${NGHTTP2_VER}.tar.xz"
  rm -rf "$BUILD_DIR/nghttp2"; mkdir -p "$BUILD_DIR/nghttp2"; cd "$BUILD_DIR/nghttp2"
  echo "==> Configuring libnghttp2 ${NGHTTP2_VER} (cmake, lib-only)"
  cmake -G Ninja "$SRC_DIR/nghttp2-${NGHTTP2_VER}" \
    -DCMAKE_TOOLCHAIN_FILE="$NDK_PATH/build/cmake/android.toolchain.cmake" \
    -DANDROID_ABI="$APP_ABI" \
    -DANDROID_PLATFORM="android-${API_LEVEL}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_C_FLAGS="-ftls-model=global-dynamic" \
    -DENABLE_LIB_ONLY=ON -DENABLE_DOC=OFF -DBUILD_TESTING=OFF \
    -DBUILD_SHARED_LIBS=ON
  cmake --build . -j"$JOBS"
  cmake --install .
fi

### ========= 2c) sqlite3 (hard dep of libsoup 3.4 — HSTS/cookie store) =========
SQLITE_VER="${SQLITE_VER:-3460100}"
if pkg-config --exists sqlite3; then
  echo "==> sqlite3 already installed ($(pkg-config --modversion sqlite3)), skipping."
else
  cd "$SRC_DIR"
  fetch "https://www.sqlite.org/2024/sqlite-autoconf-${SQLITE_VER}.tar.gz" "sqlite-autoconf-${SQLITE_VER}.tar.gz"
  [ -d "sqlite-autoconf-${SQLITE_VER}" ] || tar xf "sqlite-autoconf-${SQLITE_VER}.tar.gz"
  rm -rf "$BUILD_DIR/sqlite3"; mkdir -p "$BUILD_DIR/sqlite3"; cd "$BUILD_DIR/sqlite3"
  echo "==> Configuring sqlite3 ${SQLITE_VER} (autotools)"
  "$SRC_DIR/sqlite-autoconf-${SQLITE_VER}/configure" \
    --host="${TARGET_TRIPLE}" --prefix="$PREFIX" \
    --enable-shared --disable-static
  make -j"$JOBS"
  make install
fi

### ========= 3) libsoup-3.0 (HTTP server lib phodav builds on) =========
if pkg-config --exists libsoup-3.0; then
  echo "==> libsoup-3.0 already installed ($(pkg-config --modversion libsoup-3.0)), skipping."
else
  cd "$SRC_DIR"
  fetch "https://download.gnome.org/sources/libsoup/${LIBSOUP_VER%.*}/libsoup-${LIBSOUP_VER}.tar.xz" "libsoup-${LIBSOUP_VER}.tar.xz"
  [ -d "libsoup-${LIBSOUP_VER}" ] || tar xf "libsoup-${LIBSOUP_VER}.tar.xz"
  rm -rf "$BUILD_DIR/libsoup"; mkdir -p "$BUILD_DIR/libsoup"; cd "$BUILD_DIR/libsoup"
  echo "==> Configuring libsoup ${LIBSOUP_VER}"
  meson setup . "$SRC_DIR/libsoup-${LIBSOUP_VER}" \
    --cross-file "$MESON_CROSS" --prefix "$PREFIX" \
    -Ddefault_library=shared \
    -Dgssapi=disabled -Dntlm=disabled -Dbrotli=disabled \
    -Dtls_check=false -Dintrospection=disabled -Dvapi=disabled \
    -Ddocs=disabled -Dtests=false -Dsysprof=disabled
  meson compile -j"$JOBS"
  meson install
fi

### ========= 4) libphodav-3.0 (WebDAV server used by spice-gtk) =========
if pkg-config --exists libphodav-3.0; then
  echo "==> libphodav-3.0 already installed, skipping."
else
  cd "$SRC_DIR"
  fetch "https://download.gnome.org/sources/phodav/${PHODAV_VER}/phodav-${PHODAV_VER}.tar.xz" "phodav-${PHODAV_VER}.tar.xz"
  [ -d "phodav-${PHODAV_VER}" ] || tar xf "phodav-${PHODAV_VER}.tar.xz"
  rm -rf "$BUILD_DIR/phodav"; mkdir -p "$BUILD_DIR/phodav"; cd "$BUILD_DIR/phodav"
  echo "==> Configuring phodav ${PHODAV_VER}"
  # We only need the library; skip the spice-webdavd daemon (guest-side) and
  # the gtk-doc/tests. udev/avahi are Linux desktop bits we don't have.
  meson setup . "$SRC_DIR/phodav-${PHODAV_VER}" \
    --cross-file "$MESON_CROSS" --prefix "$PREFIX" \
    -Ddefault_library=shared \
    -Dgtk_doc=disabled -Dintrospection=disabled \
    -Dsystemd=disabled -Dudev=disabled -Davahi=disabled \
    -Dspice=disabled -Dtests=disabled || \
  meson setup . "$SRC_DIR/phodav-${PHODAV_VER}" \
    --cross-file "$MESON_CROSS" --prefix "$PREFIX" \
    -Ddefault_library=shared
  meson compile -j"$JOBS"
  meson install
fi

### ========= DONE =========
echo
echo "=================================================="
echo "✅ Finished building WebDAV deps for Android (${APP_ABI})"
for pc in libxml-2.0 libpsl libsoup-3.0 libphodav-3.0; do
  echo "    ${pc}: $(pkg-config --modversion $pc 2>/dev/null || echo 'NOT FOUND')"
done
echo "Now re-run 1c with -Dwebdav=enabled (rm the old spice-gtk artifacts first)."
echo "=================================================="
