#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.
#
# Builds libvpx's VP9 decoder for iOS and tvOS as Vendor/ShioriVPX.xcframework (static, with a
# CVPX module map): devices with NEON, simulators in plain C (libvpx has no arm64 simulator
# target).
# Run Scripts/luca/fetch-vpx.sh first.
set -eu
cd "$(dirname "$0")/../.."
ROOT=$PWD
SRC=$ROOT/Vendor/libvpx
WORK=$ROOT/build/vpx
OUT=$ROOT/Vendor/ShioriVPX.xcframework
MIN=18.0
COMMON="--disable-examples --disable-tools --disable-docs --disable-unit-tests \
  --disable-vp8 --enable-vp9-decoder --disable-vp9-encoder --enable-multithread --enable-pic \
  --disable-shared --enable-static --disable-install-bins --disable-webm-io --disable-libyuv --disable-vp9-highbitdepth"

build() { # name sdk configure-args...
  name=$1; sdk=$2; shift 2
  dir=$WORK/$name
  rm -rf "$dir"; mkdir -p "$dir"
  sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
  echo "==> libvpx $name"
  (cd "$dir" && "$@" $COMMON --prefix="$dir/install" >/dev/null && make -j"$(sysctl -n hw.ncpu)" >/dev/null && make install >/dev/null)
  mkdir -p "$dir/install/include/vpx"
  cat > "$dir/install/include/module.modulemap" <<MAP
module CVPX {
    header "vpx/vpx_decoder.h"
    header "vpx/vp8dx.h"
    link "vpx"
    export *
}
MAP
}

rm -rf "$WORK" "$OUT"
DEV_SYSROOT=$(xcrun --sdk iphoneos --show-sdk-path)
SIM_SYSROOT=$(xcrun --sdk iphonesimulator --show-sdk-path)
build device iphoneos env CC="xcrun -sdk iphoneos clang" CXX="xcrun -sdk iphoneos clang++" \
  "$SRC/configure" --target=arm64-darwin-gcc --libc="$DEV_SYSROOT" \
  --extra-cflags="-miphoneos-version-min=$MIN" --extra-cxxflags="-miphoneos-version-min=$MIN"
build simulator iphonesimulator env CC="xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=$MIN -isysroot $SIM_SYSROOT" \
  CXX="xcrun -sdk iphonesimulator clang++ -arch arm64 -mios-simulator-version-min=$MIN -isysroot $SIM_SYSROOT" \
  LD="xcrun -sdk iphonesimulator clang -arch arm64 -mios-simulator-version-min=$MIN -isysroot $SIM_SYSROOT" \
  AR="xcrun ar" \
  "$SRC/configure" --target=generic-gnu
TV_SYSROOT=$(xcrun --sdk appletvos --show-sdk-path)
TVSIM_SYSROOT=$(xcrun --sdk appletvsimulator --show-sdk-path)
build tvdevice appletvos env CC="xcrun -sdk appletvos clang -arch arm64 -mtvos-version-min=$MIN -isysroot $TV_SYSROOT" \
  CXX="xcrun -sdk appletvos clang++ -arch arm64 -mtvos-version-min=$MIN -isysroot $TV_SYSROOT" \
  LD="xcrun -sdk appletvos clang -arch arm64 -mtvos-version-min=$MIN -isysroot $TV_SYSROOT" \
  AR="xcrun ar" AS="xcrun -sdk appletvos clang -arch arm64 -mtvos-version-min=$MIN -isysroot $TV_SYSROOT" \
  "$SRC/configure" --target=arm64-linux-gcc
build tvsimulator appletvsimulator env CC="xcrun -sdk appletvsimulator clang -arch arm64 -mtvos-simulator-version-min=$MIN -isysroot $TVSIM_SYSROOT" \
  CXX="xcrun -sdk appletvsimulator clang++ -arch arm64 -mtvos-simulator-version-min=$MIN -isysroot $TVSIM_SYSROOT" \
  LD="xcrun -sdk appletvsimulator clang -arch arm64 -mtvos-simulator-version-min=$MIN -isysroot $TVSIM_SYSROOT" \
  AR="xcrun ar" \
  "$SRC/configure" --target=generic-gnu

xcodebuild -create-xcframework \
  -library "$WORK/device/install/lib/libvpx.a" -headers "$WORK/device/install/include" \
  -library "$WORK/simulator/install/lib/libvpx.a" -headers "$WORK/simulator/install/include" \
  -library "$WORK/tvdevice/install/lib/libvpx.a" -headers "$WORK/tvdevice/install/include" \
  -library "$WORK/tvsimulator/install/lib/libvpx.a" -headers "$WORK/tvsimulator/install/include" \
  -output "$OUT" >/dev/null
echo "==> $OUT"
