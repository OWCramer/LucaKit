#!/bin/sh
# This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
# If a copy of the MPL was not distributed with this file, You can obtain one at
# https://mozilla.org/MPL/2.0/.
#
# Fetches libvpx (BSD, Google's VP8/VP9 codec) and nestegg (ISC, Mozilla's WebM demuxer) into
# Vendor/, pinned. Summer Pockets REFLECTION BLUE's movies and animated effects are VP9 WebM,
# which iOS's own players don't play. Then run Scripts/luca/build-ios-vpx.sh.
set -eu
cd "$(dirname "$0")/../.."
VPX_TAG=v1.15.2
NESTEGG_COMMIT=767aab25013acefbdcc6d68a2a7a2c9081303e3f
mkdir -p Vendor
if [ ! -d Vendor/libvpx ]; then
  git clone --quiet --depth 1 --branch "$VPX_TAG" https://chromium.googlesource.com/webm/libvpx Vendor/libvpx
fi
if [ ! -d Vendor/nestegg ]; then
  git clone --quiet https://github.com/mozilla/nestegg.git Vendor/nestegg
  git -C Vendor/nestegg checkout --quiet "$NESTEGG_COMMIT"
fi
echo "==> Vendor/libvpx ($VPX_TAG), Vendor/nestegg ($NESTEGG_COMMIT)"
