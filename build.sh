#!/bin/sh
set -eu
cd "$(dirname "$0")"
mkdir -p build
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT HUP INT TERM
cat src/hidpi-service.swift src/hidpi.swift > "$scratch/main.swift"
xcrun swiftc -O -module-cache-path "$scratch/cache" "$scratch/main.swift" -o "$scratch/hidpi"
xcrun clang -O2 -Wall -Wextra -Werror -fobjc-arc -framework AppKit -framework CoreGraphics src/hidpi-test.m -o "$scratch/hidpi-test"
mv "$scratch/hidpi" build/hidpi
mv "$scratch/hidpi-test" build/hidpi-test
cp licenses/hidpi-mirror-MIT.txt build/hidpi-test-LICENSE.txt
cp LICENSE THIRD_PARTY_NOTICES.md build/
printf 'Built build/hidpi and build/hidpi-test\n'
