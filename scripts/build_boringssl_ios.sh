#!/usr/bin/env bash
# Build the exact BoringSSL TLS stack used by the free-tier profile.
# Bun's ClientHello is BoringSSL's default list plus OCSP + SCT; the
# transport is what Console checks before it looks at HTTP headers.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/Vendor/boringssl"
OUT="$ROOT/Vendor/BoringSSL"
FRAMEWORKS="$ROOT/Vendor/BoringSSL-build"
COMMIT="629a0ef2e705964bde48ff804ea286a1fd677169"

if [ ! -d "$SRC/.git" ]; then
  git clone https://boringssl.googlesource.com/boringssl "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$COMMIT"
git -C "$SRC" checkout --force "$COMMIT"

build_slice() {
  local name="$1" sysroot="$2" arch="$3"
  local build="$FRAMEWORKS/build-$name"
  rm -rf "$build"
  cmake -S "$SRC" -B "$build" -G Ninja \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT="$sysroot" \
    -DCMAKE_OSX_ARCHITECTURES="$arch" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF
  cmake --build "$build" --target ssl crypto --parallel 2

  local fw="$FRAMEWORKS/$name/BoringSSL.framework"
  rm -rf "$FRAMEWORKS/$name"
  mkdir -p "$fw/Headers"
  # Static archive: Xcode links it and does not embed another dylib.
  libtool -static -o "$fw/BoringSSL" "$build/libssl.a" "$build/libcrypto.a"
  cp -R "$SRC/include/openssl" "$fw/Headers/openssl"
  cp "$ROOT/scripts/BoringSSL-Info.plist" "$fw/Info.plist"
}

rm -rf "$OUT" "$FRAMEWORKS"
build_slice device iphoneos arm64
build_slice simulator iphonesimulator x86_64

"$ROOT/scripts/make_xcframework.sh" "$FRAMEWORKS/device/BoringSSL.framework" "$FRAMEWORKS/simulator/BoringSSL.framework" "$ROOT/Vendor/BoringSSL.xcframework"

# Plain headers for the Objective-C bridge.
rm -rf "$OUT"
mkdir -p "$OUT/include"
cp -R "$SRC/include/openssl" "$OUT/include/openssl"