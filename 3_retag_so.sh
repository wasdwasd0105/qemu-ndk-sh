#!/usr/bin/env bash
set -euo pipefail

# Purpose: collect only QEMU system executables and their deps into opt/qemu/<abi>/{bin,libs}.
# All build/middleware outputs already live under ./build via scripts 1/2.

# Macos path
#NDK_PATH="${NDK_PATH:-$HOME/AndroidNDKr29.app/Contents/NDK}"

# Linux path
NDK_PATH="${NDK_PATH:-$HOME/android-ndk-r29}"


ABI="${APP_ABI:-arm64-v8a}"
QEMU_VERSION="${QEMU_VERSION:-10.0.2}"
BUILD_ROOT="${BUILD_ROOT:-$(pwd)/build}"
SYSROOT="${SYSROOT:-$BUILD_ROOT/sysroot-${ABI}}"
SYS_LIB="$SYSROOT/lib"
SYS_BIN="$SYSROOT/bin"
JNI_LIB_DIR="$SYSROOT/jniLibs/$ABI"
# (removed single-arch variable — all arches staged below)

DEST_ROOT="./opt/qemu/${ABI}"
BIN_OUT="$DEST_ROOT/bin"
LIB_OUT="$DEST_ROOT/libs"
PCBIOS_SRC="$SYSROOT/share/qemu"
PCBIOS_ZIP="./opt/qemu/pc-bios.zip"
VERSION_JSON="./opt/qemu/version.json"
SUB_VERSION=1

# Use readelf from the NDK toolchain
HOST_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
case "$HOST_OS" in
  linux)   HOST_TAG="linux-x86_64" ;;
  darwin)  HOST_TAG="darwin-x86_64" ;;
  *) echo "Unsupported host OS: $HOST_OS" >&2; exit 1 ;;
esac
READELF="$NDK_PATH/toolchains/llvm/prebuilt/$HOST_TAG/bin/llvm-readelf"


mkdir -p "$BIN_OUT" "$LIB_OUT"

command -v patchelf >/dev/null 2>&1 || { echo "patchelf is required" >&2; exit 1; }

need() { [ -f "$1" ] || { echo "Missing: $1" >&2; exit 1; }; }
retag_soname() { [ -f "$1" ] && patchelf --set-soname "$(basename "$1")" "$1"; }
rn() { patchelf --replace-needed "$1" "$2" "$3" 2>/dev/null || true; }
copy_lib() { local src="$1" dst="$2"; need "$src"; cp -Lf "$src" "$dst"; }

QEMU_ARCHES="aarch64 i386 x86_64 ppc"
QEMU_TOOLS="qemu-img"

# 1) Copy GLib stack + slirp (+ pixman if present) into libs with unversioned names
copy_lib "$SYS_LIB/libgio-2.0.so.0"     "$LIB_OUT/libgio-2.0.so"
copy_lib "$SYS_LIB/libgobject-2.0.so.0" "$LIB_OUT/libgobject-2.0.so"
copy_lib "$SYS_LIB/libglib-2.0.so.0"    "$LIB_OUT/libglib-2.0.so"
copy_lib "$SYS_LIB/libgmodule-2.0.so.0" "$LIB_OUT/libgmodule-2.0.so"
copy_lib "$SYS_LIB/libintl.so.8"        "$LIB_OUT/libintl.so"
copy_lib "$SYS_LIB/libpcre2-8.so"       "$LIB_OUT/libpcre2-8.so"
copy_lib "$SYS_LIB/libslirp.so.0"       "$LIB_OUT/libslirp.so"
copy_lib "$SYS_LIB/libpixman-1.so"      "$LIB_OUT/libpixman-1.so"
[ -f "$SYS_LIB/libgthread-2.0.so.0" ] && copy_lib "$SYS_LIB/libgthread-2.0.so.0" "$LIB_OUT/libgthread-2.0.so"
[ -f "$SYS_LIB/libffi.so" ]           && copy_lib "$SYS_LIB/libffi.so"           "$LIB_OUT/libffi.so"
[ -f "$SYS_LIB/libusb-1.0.so" ]      && copy_lib "$SYS_LIB/libusb-1.0.so"      "$LIB_OUT/libusb-1.0.so"

# SPICE stack (built by 1b_build_spice_deps.sh). Optional — copied only if present.
# spice-server pulls openssl, libjpeg-turbo, and opus; ship them all as unversioned .so.
[ -f "$SYS_LIB/libspice-server.so" ] && copy_lib "$SYS_LIB/libspice-server.so" "$LIB_OUT/libspice-server.so"
[ -f "$SYS_LIB/libssl.so" ]          && copy_lib "$SYS_LIB/libssl.so"          "$LIB_OUT/libssl.so"
[ -f "$SYS_LIB/libcrypto.so" ]       && copy_lib "$SYS_LIB/libcrypto.so"       "$LIB_OUT/libcrypto.so"
[ -f "$SYS_LIB/libjpeg.so" ]         && copy_lib "$SYS_LIB/libjpeg.so"         "$LIB_OUT/libjpeg.so"
[ -f "$SYS_LIB/libopus.so" ]         && copy_lib "$SYS_LIB/libopus.so"         "$LIB_OUT/libopus.so"

# SPICE CLIENT stack (built by 1c_build_spice_client_deps.sh). Optional.
# The Android app loads libspice-client-glib-2.0.so via JNI to connect to
# QEMU's spice-server. json-glib is its only new dep we don't already ship.
[ -f "$SYS_LIB/libspice-client-glib-2.0.so" ] && copy_lib "$SYS_LIB/libspice-client-glib-2.0.so" "$LIB_OUT/libspice-client-glib-2.0.so"
[ -f "$SYS_LIB/libjson-glib-1.0.so" ]         && copy_lib "$SYS_LIB/libjson-glib-1.0.so"         "$LIB_OUT/libjson-glib-1.0.so"

# WebDAV / folder-sharing stack (1e_build_webdav_deps.sh). Optional. Pulled in
# by spice-gtk's webdav channel: spice-client-glib → libphodav → libsoup-3
# → libxml2 / libpsl / libnghttp2 / libsqlite3.
for wl in libphodav-3.0 libsoup-3.0 libxml2 libpsl libnghttp2 libsqlite3; do
  [ -f "$SYS_LIB/$wl.so" ] && copy_lib "$SYS_LIB/$wl.so" "$LIB_OUT/$wl.so"
done

# GStreamer stack (built by 1d_build_gstreamer_for_android.sh). Optional.
# gst-plugins-base installs multiple libs (app/audio/video/tag/pbutils/rtp/
# rtsp/sdp/fft/riff) — copy any we find with the libgst*.so glob.
for gst_so in "$SYS_LIB"/libgst*.so; do
  [ -f "$gst_so" ] || continue
  copy_lib "$gst_so" "$LIB_OUT/$(basename "$gst_so")"
done

# libc++_shared.so — spice-server has C++ code (red::shared_ptr_counted etc.)
# and links against the NDK's shared libc++. Ship it from the NDK sysroot so
# the dynamic loader can resolve it inside the APK.
case "$ABI" in
  arm64-v8a)   NDK_TRIPLE=aarch64-linux-android ;;
  armeabi-v7a) NDK_TRIPLE=arm-linux-androideabi ;;
  x86)         NDK_TRIPLE=i686-linux-android ;;
  x86_64)      NDK_TRIPLE=x86_64-linux-android ;;
esac
NDK_HOST_TAG="$(uname -s | tr '[:upper:]' '[:lower:]')-x86_64"
NDK_LIBCXX="$NDK_PATH/toolchains/llvm/prebuilt/$NDK_HOST_TAG/sysroot/usr/lib/$NDK_TRIPLE/libc++_shared.so"
[ -f "$NDK_LIBCXX" ] && copy_lib "$NDK_LIBCXX" "$LIB_OUT/libc++_shared.so"

# GnuTLS stack (for VNC TLS x509 credentials). Optional — copied only if present.
[ -f "$SYS_LIB/libgnutls.so" ]  && copy_lib "$SYS_LIB/libgnutls.so"  "$LIB_OUT/libgnutls.so"
[ -f "$SYS_LIB/libnettle.so" ]  && copy_lib "$SYS_LIB/libnettle.so"  "$LIB_OUT/libnettle.so"
[ -f "$SYS_LIB/libhogweed.so" ] && copy_lib "$SYS_LIB/libhogweed.so" "$LIB_OUT/libhogweed.so"
[ -f "$SYS_LIB/libgmp.so" ]     && copy_lib "$SYS_LIB/libgmp.so"     "$LIB_OUT/libgmp.so"

# 2) Stage libqemu-system-*.so from sysroot jniLibs into libs (all arches)
for arch in $QEMU_ARCHES; do
  so_src="$JNI_LIB_DIR/libqemu-system-${arch}.so"
  if [ -f "$so_src" ]; then
    copy_lib "$so_src" "$LIB_OUT/libqemu-system-${arch}.so"
  else
    echo "Skip missing $so_src"
  fi
done

# qemu-img as a JNI-loadable .so (PIE renamed by 2_build_qemu_android.sh)
if [ -f "$JNI_LIB_DIR/libqemu-img.so" ]; then
  copy_lib "$JNI_LIB_DIR/libqemu-img.so" "$LIB_OUT/libqemu-img.so"
else
  echo "Skip missing $JNI_LIB_DIR/libqemu-img.so"
fi

for arch in $QEMU_ARCHES; do
  exe="$SYS_BIN/qemu-system-$arch"
  if [ -f "$exe" ]; then
    cp -Lf "$exe" "$BIN_OUT/"
  else
    echo "Skip missing $exe"
  fi
done
for tool in $QEMU_TOOLS; do
  exe="$SYS_BIN/$tool"
  if [ -f "$exe" ]; then
    cp -Lf "$exe" "$BIN_OUT/"
  else
    echo "Skip missing $exe"
  fi
done

# 3) SONAME retagging for libs
for so in "$LIB_OUT"/*.so; do
  retag_soname "$so"
done

# 4) Rewrite NEEDED on GLib stack and slirp to unversioned names
rn libglib-2.0.so.0    libglib-2.0.so    "$LIB_OUT/libgio-2.0.so"
rn libgobject-2.0.so.0 libgobject-2.0.so "$LIB_OUT/libgio-2.0.so"
rn libgmodule-2.0.so.0 libgmodule-2.0.so "$LIB_OUT/libgio-2.0.so"
rn libintl.so.8        libintl.so        "$LIB_OUT/libgio-2.0.so"

rn libglib-2.0.so.0    libglib-2.0.so    "$LIB_OUT/libgobject-2.0.so"
rn libintl.so.8        libintl.so        "$LIB_OUT/libgobject-2.0.so"

rn libglib-2.0.so.0    libglib-2.0.so    "$LIB_OUT/libgmodule-2.0.so"
rn libintl.so.8        libintl.so        "$LIB_OUT/libglib-2.0.so"

rn libglib-2.0.so.0    libglib-2.0.so    "$LIB_OUT/libslirp.so"
rn libintl.so.8        libintl.so        "$LIB_OUT/libslirp.so"

# GnuTLS stack: rewrite versioned NEEDED entries inside the libs themselves
# so that libgnutls.so finds the unversioned libnettle.so / libhogweed.so / libgmp.so
# we ship next to it, instead of looking for libnettle.so.8 etc. on the device.
rn libnettle.so.8      libnettle.so      "$LIB_OUT/libgnutls.so"
rn libhogweed.so.6     libhogweed.so     "$LIB_OUT/libgnutls.so"
rn libgmp.so.10        libgmp.so         "$LIB_OUT/libgnutls.so"

rn libnettle.so.8      libnettle.so      "$LIB_OUT/libhogweed.so"
rn libgmp.so.10        libgmp.so         "$LIB_OUT/libhogweed.so"

# SPICE stack: rewrite versioned NEEDED entries inside libspice-server.so so it
# resolves the unversioned .so files we ship next to it. openssl 3.x SONAMEs
# are libssl.so.3 / libcrypto.so.3; libjpeg-turbo's is libjpeg.so.62; opus's
# is libopus.so.0; pixman's is libpixman-1.so.0.
if [ -f "$LIB_OUT/libspice-server.so" ]; then
  rn libssl.so.3         libssl.so         "$LIB_OUT/libspice-server.so"
  rn libcrypto.so.3      libcrypto.so      "$LIB_OUT/libspice-server.so"
  rn libjpeg.so.62       libjpeg.so        "$LIB_OUT/libspice-server.so"
  rn libopus.so.0        libopus.so        "$LIB_OUT/libspice-server.so"
  rn libglib-2.0.so.0    libglib-2.0.so    "$LIB_OUT/libspice-server.so"
  rn libgio-2.0.so.0     libgio-2.0.so     "$LIB_OUT/libspice-server.so"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$LIB_OUT/libspice-server.so"
  rn libpixman-1.so.0    libpixman-1.so    "$LIB_OUT/libspice-server.so"
fi
# libssl depends on libcrypto via versioned soname.
[ -f "$LIB_OUT/libssl.so" ] && rn libcrypto.so.3 libcrypto.so "$LIB_OUT/libssl.so"

# SPICE client: rewrite versioned NEEDED inside libspice-client-glib-2.0.so
# and libjson-glib-1.0.so. Same pattern as libspice-server.so above.
if [ -f "$LIB_OUT/libspice-client-glib-2.0.so" ]; then
  rn libjson-glib-1.0.so.0 libjson-glib-1.0.so "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libglib-2.0.so.0      libglib-2.0.so      "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libgio-2.0.so.0       libgio-2.0.so       "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libgobject-2.0.so.0   libgobject-2.0.so   "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libpixman-1.so.0      libpixman-1.so      "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libssl.so.3           libssl.so           "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libcrypto.so.3        libcrypto.so        "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libjpeg.so.62         libjpeg.so          "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libopus.so.0          libopus.so          "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libintl.so.8          libintl.so          "$LIB_OUT/libspice-client-glib-2.0.so"
fi
if [ -f "$LIB_OUT/libjson-glib-1.0.so" ]; then
  rn libglib-2.0.so.0    libglib-2.0.so    "$LIB_OUT/libjson-glib-1.0.so"
  rn libgio-2.0.so.0     libgio-2.0.so     "$LIB_OUT/libjson-glib-1.0.so"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$LIB_OUT/libjson-glib-1.0.so"
fi

# WebDAV stack: rewrite versioned NEEDED to the unversioned .so we ship.
# (Rewrites for already-unversioned entries are harmless no-ops.)
if [ -f "$LIB_OUT/libspice-client-glib-2.0.so" ]; then
  rn libphodav-3.0.so.0  libphodav-3.0.so  "$LIB_OUT/libspice-client-glib-2.0.so"
  rn libsoup-3.0.so.0    libsoup-3.0.so    "$LIB_OUT/libspice-client-glib-2.0.so"
fi
if [ -f "$LIB_OUT/libphodav-3.0.so" ]; then
  rn libsoup-3.0.so.0    libsoup-3.0.so    "$LIB_OUT/libphodav-3.0.so"
  rn libxml2.so.2        libxml2.so        "$LIB_OUT/libphodav-3.0.so"
  rn libglib-2.0.so.0    libglib-2.0.so    "$LIB_OUT/libphodav-3.0.so"
  rn libgio-2.0.so.0     libgio-2.0.so     "$LIB_OUT/libphodav-3.0.so"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$LIB_OUT/libphodav-3.0.so"
fi
if [ -f "$LIB_OUT/libsoup-3.0.so" ]; then
  rn libintl.so.8        libintl.so        "$LIB_OUT/libsoup-3.0.so"
  rn libpsl.so.5         libpsl.so         "$LIB_OUT/libsoup-3.0.so"
  rn libsqlite3.so.0     libsqlite3.so     "$LIB_OUT/libsoup-3.0.so"
  rn libnghttp2.so.14    libnghttp2.so     "$LIB_OUT/libsoup-3.0.so"
  rn libglib-2.0.so.0    libglib-2.0.so    "$LIB_OUT/libsoup-3.0.so"
  rn libgio-2.0.so.0     libgio-2.0.so     "$LIB_OUT/libsoup-3.0.so"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$LIB_OUT/libsoup-3.0.so"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$LIB_OUT/libsoup-3.0.so"
fi
if [ -f "$LIB_OUT/libpsl.so" ]; then
  rn libintl.so.8        libintl.so        "$LIB_OUT/libpsl.so"
fi
if [ -f "$LIB_OUT/libxml2.so" ]; then
  rn libintl.so.8        libintl.so        "$LIB_OUT/libxml2.so"
fi

# GStreamer libs cross-link with each other via versioned SONAMEs
# (libgstreamer-1.0.so.0, etc). Rewrite to unversioned in every libgst*.so
# and in libspice-client-glib (which links against gstreamer-{1.0,base,app,
# audio,video}).
GST_VERSIONED_LIBS="libgstreamer-1.0 libgstbase-1.0 libgstcontroller-1.0 \
                   libgstnet-1.0 libgstapp-1.0 libgstaudio-1.0 libgstvideo-1.0 \
                   libgsttag-1.0 libgstpbutils-1.0 libgstrtp-1.0 \
                   libgstrtsp-1.0 libgstsdp-1.0 libgstfft-1.0 libgstriff-1.0"
for gst_so in "$LIB_OUT"/libgst*.so; do
  [ -f "$gst_so" ] || continue
  for verlib in $GST_VERSIONED_LIBS; do
    rn "${verlib}.so.0" "${verlib}.so" "$gst_so"
  done
  rn libglib-2.0.so.0    libglib-2.0.so    "$gst_so"
  rn libgio-2.0.so.0     libgio-2.0.so     "$gst_so"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$gst_so"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$gst_so"
  # gst-plugins-base's audio/pbutils/tag pull libintl directly; rewrite to
  # match the unversioned libintl.so we ship.
  rn libintl.so.8        libintl.so        "$gst_so"
done
if [ -f "$LIB_OUT/libspice-client-glib-2.0.so" ]; then
  for verlib in libgstreamer-1.0 libgstbase-1.0 libgstapp-1.0 libgstaudio-1.0 libgstvideo-1.0; do
    rn "${verlib}.so.0" "${verlib}.so" "$LIB_OUT/libspice-client-glib-2.0.so"
  done
fi

# 4a) Rewrite NEEDED on all libqemu-system-*.so to unversioned names
for arch in $QEMU_ARCHES; do
  so="$LIB_OUT/libqemu-system-${arch}.so"
  [ -f "$so" ] || continue
  echo "Patching NEEDED entries in $(basename "$so")"
  rn libslirp.so.0         libslirp.so         "$so"
  rn libgio-2.0.so.0       libgio-2.0.so       "$so"
  rn libgobject-2.0.so.0   libgobject-2.0.so   "$so"
  rn libglib-2.0.so.0      libglib-2.0.so      "$so"
  rn libgmodule-2.0.so.0   libgmodule-2.0.so   "$so"
  rn libintl.so.8          libintl.so          "$so"
  rn libusb-1.0.so.0       libusb-1.0.so       "$so"
  rn libgnutls.so.30       libgnutls.so        "$so"
  rn libspice-server.so.1  libspice-server.so  "$so"
done

# 4b) Same for libqemu-img.so (NEEDED: z, gnutls, glib, m, c)
if [ -f "$LIB_OUT/libqemu-img.so" ]; then
  echo "Patching NEEDED entries in libqemu-img.so"
  rn libglib-2.0.so.0 libglib-2.0.so "$LIB_OUT/libqemu-img.so"
  rn libintl.so.8     libintl.so     "$LIB_OUT/libqemu-img.so"
  rn libgnutls.so.30  libgnutls.so   "$LIB_OUT/libqemu-img.so"
fi

# 5) Rewrite NEEDED on each QEMU executable/tool to point at unversioned libs
for arch in $QEMU_ARCHES; do
  exe="$BIN_OUT/qemu-system-$arch"
  [ -f "$exe" ] || continue
  echo "Patching NEEDED entries in $(basename "$exe")"
  rn libslirp.so.0       libslirp.so       "$exe"
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
  rn libusb-1.0.so.0       libusb-1.0.so       "$exe"
  rn libgnutls.so.30       libgnutls.so        "$exe"
  rn libspice-server.so.1  libspice-server.so  "$exe"
done
for tool in $QEMU_TOOLS; do
  exe="$BIN_OUT/$tool"
  [ -f "$exe" ] || continue
  echo "Patching NEEDED entries in $(basename "$exe")"
  rn libgio-2.0.so.0     libgio-2.0.so     "$exe"
  rn libgobject-2.0.so.0 libgobject-2.0.so "$exe"
  rn libglib-2.0.so.0    libglib-2.0.so    "$exe"
  rn libgmodule-2.0.so.0 libgmodule-2.0.so "$exe"
  rn libintl.so.8        libintl.so        "$exe"
done

# 6) Show final SONAME/NEEDED for quick verification
for so in "$LIB_OUT"/*.so; do
  echo "---- $(basename "$so")"
  $READELF -d "$so" | grep -E 'SONAME|NEEDED' || true
done

# (libqemu-system-*.so are already covered by the *.so glob above)

for exe in "$BIN_OUT"/qemu-system-* "$BIN_OUT"/qemu-img; do
  [ -f "$exe" ] || continue
  echo "---- $(basename "$exe")"
  $READELF -d "$exe" | grep -E 'NEEDED' || true
done

# 7) Zip pc-bios into ./opt/qemu/pc-bios.zip (contents root is pc-bios/)
if [ -d "$PCBIOS_SRC" ]; then
  echo "==> Archiving pc-bios from $PCBIOS_SRC to $PCBIOS_ZIP"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' EXIT
  cp -a "$PCBIOS_SRC" "$tmpdir/pc-bios"
  mkdir -p "$(dirname "$PCBIOS_ZIP")"
  zip_dest="$(cd "$(dirname "$PCBIOS_ZIP")" && pwd)/$(basename "$PCBIOS_ZIP")"
  (cd "$tmpdir" && zip -rq "$zip_dest" pc-bios)
  echo "pc-bios archived at $PCBIOS_ZIP"
else
  echo "pc-bios directory not found at $PCBIOS_SRC; skipping archive"
fi

# 8) Write version.json into ./opt/qemu
mkdir -p "$(dirname "$VERSION_JSON")"
build_date="$(date +%Y-%m-%d)"
cat > "$VERSION_JSON" <<EOF
{"schema_version":1,"qemu_version":"${QEMU_VERSION}","sub_version":${SUB_VERSION},"build_date":"${build_date}"}
EOF
echo "version.json written to $VERSION_JSON"

echo "✅ Binaries and deps staged under $DEST_ROOT"
