#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# Build minimal GStreamer for Android
# (gstreamer core + gst-plugins-base — libraries only, no plugins)
#
# spice-gtk hard-requires the following pkg-config packages:
#   gstreamer-1.0, gstreamer-base-1.0, gstreamer-app-1.0,
#   gstreamer-audio-1.0, gstreamer-video-1.0
#
# gstreamer core provides:           gstreamer-1.0, gstreamer-base-1.0
# gst-plugins-base provides:         gstreamer-app-1.0, gstreamer-audio-1.0,
#                                    gstreamer-video-1.0
#
# We build with -Dauto_features=disabled to skip every plugin/codec —
# spice-gtk only needs the *libraries* to link against, not actual runtime
# decoders (Phase 2 will add codec plugins). Build is small (~5-10 MB total
# .so files) compared to a full GStreamer Android distribution.
#
# Run AFTER 1_build_deps_android.sh.
# Run BEFORE 1c_build_spice_client_deps.sh.
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

# Single version covers both gstreamer core and gst-plugins-base.
GSTREAMER_VER="${GSTREAMER_VER:-1.24.10}"

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
  arm64-v8a)   TARGET_TRIPLE=aarch64-linux-android;   MESON_CPU=aarch64 ;;
  armeabi-v7a) TARGET_TRIPLE=armv7a-linux-androideabi; MESON_CPU=arm ;;
  x86)         TARGET_TRIPLE=i686-linux-android;       MESON_CPU=x86 ;;
  x86_64)      TARGET_TRIPLE=x86_64-linux-android;     MESON_CPU=x86_64 ;;
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

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

export CFLAGS="-fPIC -fPIE -ftls-model=global-dynamic"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-pie"

JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu)}"

# macOS ships bison 2.3 (GPLv2 — Apple won't upgrade); GStreamer's gst_parse
# needs >= 2.4. Prefer brew's keg-only newer bison if present.
if [ -x /opt/homebrew/opt/bison/bin/bison ]; then
  export PATH="/opt/homebrew/opt/bison/bin:$PATH"
fi

### ========= HELPERS =========
fetch() {
  local url="$1" out="$2"
  if [ ! -f "$out" ]; then
    echo "==> Download $url"
    curl -L --fail -o "$out" "$url"
  fi
}

### ========= PRECHECK =========
echo "==> Verifying script-1 deps are present..."
for dep in glib-2.0 gio-2.0 gobject-2.0; do
  if ! pkg-config --exists "$dep"; then
    echo "ERROR: '$dep' not found. Run 1_build_deps_android.sh first." >&2
    exit 1
  fi
  echo "       $dep: $(pkg-config --modversion $dep)"
done

### Shared meson cross-file.
MESON_CROSS="$BUILD_DIR/gstreamer.cross"
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

### ========= 1) gstreamer core =========
# Provides: libgstreamer-1.0.so, libgstbase-1.0.so, libgstcontroller-1.0.so,
#           libgstnet-1.0.so (and the corresponding .pc files).
if pkg-config --exists gstreamer-1.0 && pkg-config --exists gstreamer-base-1.0; then
  echo "==> gstreamer core already installed ($(pkg-config --modversion gstreamer-1.0)), skipping."
else
  cd "$SRC_DIR"
  fetch "https://gstreamer.freedesktop.org/src/gstreamer/gstreamer-${GSTREAMER_VER}.tar.xz" "gstreamer-${GSTREAMER_VER}.tar.xz"
  [ -d "gstreamer-${GSTREAMER_VER}" ] || tar xf "gstreamer-${GSTREAMER_VER}.tar.xz"

  rm -rf "$BUILD_DIR/gstreamer"
  mkdir -p "$BUILD_DIR/gstreamer"
  cd "$BUILD_DIR/gstreamer"

  echo "==> Configuring gstreamer core ${GSTREAMER_VER}"
  # -Dauto_features=disabled: skip everything optional (plugins, gobject
  # introspection, doc gen, tracing helpers). We get the bare libs.
  # -Dtools=disabled: skip gst-launch, gst-inspect — they're not useful on
  # Android and pull in extra deps.
  # -Dgst_debug=true: keep GST_DEBUG support; spice-gtk's debug output relies
  # on it and the cost is small.
  meson setup . "$SRC_DIR/gstreamer-${GSTREAMER_VER}" \
    --cross-file "$MESON_CROSS" \
    --prefix "$PREFIX" \
    -Ddefault_library=shared \
    -Dauto_features=disabled \
    -Dtests=disabled \
    -Dexamples=disabled \
    -Dbenchmarks=disabled \
    -Dtools=disabled \
    -Ddoc=disabled \
    -Dintrospection=disabled \
    -Dnls=disabled \
    -Dgst_debug=true \
    -Dgst_parse=true

  echo "==> Building gstreamer core"
  meson compile -j"$JOBS"
  meson install
fi

### ========= 2) gst-plugins-base =========
# Provides: libgstapp-1.0.so, libgstaudio-1.0.so, libgstvideo-1.0.so
# (plus libgsttag, libgstpbutils, libgstrtp, libgstrtsp, libgstsdp, libgstfft,
#  libgstriff — but we only need app/audio/video for spice-gtk).
if pkg-config --exists gstreamer-app-1.0 && pkg-config --exists gstreamer-audio-1.0 && pkg-config --exists gstreamer-video-1.0; then
  echo "==> gst-plugins-base already installed, skipping."
else
  cd "$SRC_DIR"
  fetch "https://gstreamer.freedesktop.org/src/gst-plugins-base/gst-plugins-base-${GSTREAMER_VER}.tar.xz" "gst-plugins-base-${GSTREAMER_VER}.tar.xz"
  [ -d "gst-plugins-base-${GSTREAMER_VER}" ] || tar xf "gst-plugins-base-${GSTREAMER_VER}.tar.xz"

  rm -rf "$BUILD_DIR/gst-plugins-base"
  mkdir -p "$BUILD_DIR/gst-plugins-base"
  cd "$BUILD_DIR/gst-plugins-base"

  echo "==> Configuring gst-plugins-base ${GSTREAMER_VER}"
  # Same story as core: disable everything we don't need. The plugins (alsa,
  # ogg, vorbis, theora, etc.) all get skipped via -Dauto_features=disabled;
  # the .so *libraries* are still built and installed unconditionally.
  meson setup . "$SRC_DIR/gst-plugins-base-${GSTREAMER_VER}" \
    --cross-file "$MESON_CROSS" \
    --prefix "$PREFIX" \
    -Ddefault_library=shared \
    -Dauto_features=disabled \
    -Dtests=disabled \
    -Dexamples=disabled \
    -Ddoc=disabled \
    -Dintrospection=disabled \
    -Dnls=disabled \
    -Dorc=disabled \
    -Dtools=disabled

  echo "==> Building gst-plugins-base"
  meson compile -j"$JOBS"
  meson install
fi

### ========= DONE =========
echo
echo "=================================================="
echo "✅ Finished building GStreamer for Android (${APP_ABI})"
echo
echo "  versions:"
for pc in gstreamer-1.0 gstreamer-base-1.0 gstreamer-app-1.0 gstreamer-audio-1.0 gstreamer-video-1.0; do
  echo "    ${pc}: $(pkg-config --modversion $pc 2>/dev/null || echo 'NOT FOUND')"
done
echo
echo "  Output .so files:"
ls -l "$PREFIX/lib/"libgst*.so 2>/dev/null | head -20
echo "=================================================="
