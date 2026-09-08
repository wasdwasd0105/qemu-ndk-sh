#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Build SPICE CLIENT dependencies for Android
# (json-glib, spice-gtk → libspice-client-glib-2.0.so)
#
# This is the Android-app side of SPICE — the lib our JNI bridges
# will link against to connect TO a SPICE server (the one we built
# into QEMU in 1b).
#
# Run AFTER 1_build_deps_android.sh AND 1b_build_spice_deps.sh.
# Outputs land in the same sysroot for 3_retag_so.sh to stage.
#
# Phase 1 scope: display + mouse + keyboard only.
#   - No GTK widget (we render with our own Android SurfaceView)
#   - No GStreamer (audio/video) — Phase 2
#   - No usbredir — Phase 3
#   - No smartcard / phodav / webdav / polkit
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
JSON_GLIB_VER="${JSON_GLIB_VER:-1.10.0}"
SPICE_GTK_VER="${SPICE_GTK_VER:-0.42}"

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

# Include share/pkgconfig for noarch packages (spice-protocol lives there).
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

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

### ========= PRECHECK =========
echo "==> Verifying upstream deps are present..."
for dep in glib-2.0 gio-2.0 gobject-2.0 pixman-1 openssl libjpeg opus spice-protocol; do
  if ! pkg-config --exists "$dep"; then
    echo "ERROR: '$dep' not found. Run 1_build_deps_android.sh + 1b_build_spice_deps.sh first." >&2
    exit 1
  fi
  echo "       $dep: $(pkg-config --modversion $dep)"
done

### Shared meson cross-file (used by all meson builds below).
MESON_CROSS="$BUILD_DIR/spice-client.cross"
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

### ========= 1) json-glib =========
if pkg-config --exists json-glib-1.0; then
  echo "==> json-glib already installed ($(pkg-config --modversion json-glib-1.0)), skipping."
else
  cd "$SRC_DIR"
  fetch "https://download.gnome.org/sources/json-glib/${JSON_GLIB_VER%.*}/json-glib-${JSON_GLIB_VER}.tar.xz" "json-glib-${JSON_GLIB_VER}.tar.xz"
  [ -d "json-glib-${JSON_GLIB_VER}" ] || tar xf "json-glib-${JSON_GLIB_VER}.tar.xz"

  rm -rf "$BUILD_DIR/json-glib"
  mkdir -p "$BUILD_DIR/json-glib"
  cd "$BUILD_DIR/json-glib"

  echo "==> Configuring json-glib ${JSON_GLIB_VER}"
  meson setup . "$SRC_DIR/json-glib-${JSON_GLIB_VER}" \
    --cross-file "$MESON_CROSS" \
    --prefix "$PREFIX" \
    -Ddefault_library=shared \
    -Dtests=false \
    -Ddocumentation=disabled \
    -Dintrospection=disabled \
    -Dman=false \
    -Dnls=disabled

  echo "==> Building json-glib"
  meson compile -j"$JOBS"
  meson install
fi

### ========= 2) spice-gtk (the client lib — libspice-client-glib-2.0.so) =========
if [ -f "$PREFIX/lib/libspice-client-glib-2.0.so" ]; then
  echo "==> spice-client-glib already installed, skipping."
else
  SPICE_GTK_SRC="$SRC_DIR/spice-gtk-${SPICE_GTK_VER}"
  if [ ! -d "$SPICE_GTK_SRC" ]; then
    echo "==> Cloning spice-gtk v${SPICE_GTK_VER} from gitlab.freedesktop.org"
    # spice-space.org is unreliable; use gitlab. --recurse-submodules pulls
    # the spice-common submodule.
    git clone --depth 1 --branch "v${SPICE_GTK_VER}" --recurse-submodules \
      https://gitlab.freedesktop.org/spice/spice-gtk.git \
      "$SPICE_GTK_SRC"
  fi

  # Android-specific patches. Each step is grep-guarded so it's idempotent.
  echo "==> Applying Android patches to spice-gtk (idempotent)"
  # 1. librt — bionic folds rt symbols into libc, so library 'rt' isn't there.
  if grep -q "find_library('rt')" "$SPICE_GTK_SRC/meson.build" 2>/dev/null; then
    echo "    patching meson.build: librt required: false"
    sed -i.bak "s/find_library('rt')/find_library('rt', required: false)/g" "$SPICE_GTK_SRC/meson.build"
  fi
  # 2. -export-symbols is a libtool-only flag; clang's linker driver rejects it.
  # Dropping it means libspice-client-glib exports all its own symbols (larger
  # symbol table but no functional difference for our use).
  if grep -q "spice_gtk_version_script = \['-export-symbols'" "$SPICE_GTK_SRC/src/meson.build" 2>/dev/null; then
    echo "    patching src/meson.build: drop -export-symbols"
    sed -i.bak "s|spice_gtk_version_script = \['-export-symbols', spice_client_glib_syms_path\]|spice_gtk_version_script = []|" "$SPICE_GTK_SRC/src/meson.build"
  fi

  rm -rf "$BUILD_DIR/spice-gtk"
  mkdir -p "$BUILD_DIR/spice-gtk"
  cd "$BUILD_DIR/spice-gtk"

  echo "==> Configuring spice-gtk ${SPICE_GTK_VER} (client lib only)"
  # Disabled (each removes a dep we don't want to ship):
  #   gtk          — we render the framebuffer with our own Android SurfaceView
  #   gtk_doc, vapi, introspection  — bindings/docs we don't need
  #   smartcard, polkit             — no smartcard passthrough on Android
  #   usbredir                      — Phase 3
  #   libcap-ng, webdav             — host-side features we don't need
  #   sasl, lz4                     — keep deps minimal; SPICE works without
  #   egl                           — no EGL/OpenGL surface on the client lib
  # Enabled:
  #   coroutine=gthread             — pthreads-based coroutines (simplest on Android)
  #   builtin-mjpeg                 — MJPEG video streams without GStreamer
  #   opus                          — opus audio codec (we built libopus already)
  # NOTE: pulse / gstaudio / gstvideo / libphodav are NOT explicit options in
  # spice-gtk 0.42 — they're auto-detected from pkg-config presence. Since we
  # don't ship gstreamer or libpulse in the sysroot, they're skipped automatically.
  meson setup . "$SPICE_GTK_SRC" \
    --cross-file "$MESON_CROSS" \
    --prefix "$PREFIX" \
    -Ddefault_library=shared \
    -Dgtk=disabled \
    -Dgtk_doc=disabled \
    -Dvapi=disabled \
    -Dintrospection=disabled \
    -Dsmartcard=disabled \
    -Dpolkit=disabled \
    -Dusbredir=disabled \
    -Dlibcap-ng=disabled \
    -Dwebdav=enabled \
    -Dsasl=disabled \
    -Dlz4=disabled \
    -Degl=disabled \
    -Dcoroutine=gthread \
    -Dbuiltin-mjpeg=true \
    -Dopus=enabled

  echo "==> Building spice-gtk"
  meson compile -j"$JOBS"
  meson install
fi

### ========= DONE =========
echo
echo "=================================================="
echo "✅ Finished building SPICE client deps for Android (${APP_ABI})"
echo "Installed to:   $PREFIX"
echo
echo "  json-glib            .pc: $(ls -1 $PREFIX/lib/pkgconfig/json-glib-1.0.pc 2>/dev/null || echo 'not found')"
echo "  spice-client-glib    .pc: $(ls -1 $PREFIX/lib/pkgconfig/spice-client-glib-2.0.pc 2>/dev/null || echo 'not found')"
echo
echo "  versions:"
echo "    json-glib:         $(pkg-config --modversion json-glib-1.0 2>/dev/null || echo 'NOT FOUND')"
echo "    spice-client-glib: $(pkg-config --modversion spice-client-glib-2.0 2>/dev/null || echo 'NOT FOUND')"
echo
echo "  Output .so files:"
ls -l "$PREFIX/lib/"libjson-glib* "$PREFIX/lib/"libspice-client-glib* 2>/dev/null || true
echo "=================================================="
