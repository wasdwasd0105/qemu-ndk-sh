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

# 2) Stage libqemu-system-*.so from sysroot jniLibs into libs (all arches)
for arch in $QEMU_ARCHES; do
  so_src="$JNI_LIB_DIR/libqemu-system-${arch}.so"
  if [ -f "$so_src" ]; then
    copy_lib "$so_src" "$LIB_OUT/libqemu-system-${arch}.so"
  else
    echo "Skip missing $so_src"
  fi
done

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
done

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
  rn libusb-1.0.so.0       libusb-1.0.so       "$so"
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
