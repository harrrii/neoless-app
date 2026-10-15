#!/bin/bash
# Type-checks NeolessCore and NeolessCloud for an iOS-family target with only the Command Line Tools:
# Mac Catalyst (arm64-apple-ios17.0-macabi) uses the macOS SDK's iOSSupport, so iOS-only code paths
# (#if os(iOS)) and APIs unavailable on iOS are checked. Not a substitute for a real iOS build in Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=$(xcrun --show-sdk-path)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT
TARGET=arm64-apple-ios17.0-macabi
swiftc -emit-module -emit-module-path "$OUT/NeolessCore.swiftmodule" -module-name NeolessCore -parse-as-library \
    -swift-version 5 -target "$TARGET" -sdk "$SDK" Sources/NeolessCore/*.swift
swiftc -typecheck -I "$OUT" -module-name NeolessCloud -parse-as-library -swift-version 5 -target "$TARGET" -sdk "$SDK" \
    Sources/NeolessCloud/*.swift
echo "NeolessCore and NeolessCloud type-check for $TARGET"
