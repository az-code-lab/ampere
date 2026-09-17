#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# Wait for the old instance to actually exit (not a fixed sleep) — the new
# instance refuses to start while another Ampere process is still running.
pkill -x Ampere 2>/dev/null || true
for _ in $(seq 1 80); do
    pgrep -x Ampere >/dev/null 2>&1 || break
    sleep 0.1
done

# Give the linker the SDK explicitly. SwiftPM's Swift Build engine (the
# default since Xcode 27) runs swiftc without SDKROOT in its environment,
# and the Swift driver hands clang the sysroot only for the linker search
# path; clang derives the SDK version it records in the binary
# (LC_BUILD_VERSION) from -isysroot or SDKROOT, and with neither it falls
# back to the deployment target. The result is a binary stamped as built
# against the macOS 14 SDK, which AppKit and SwiftUI then run in macOS 14
# compatibility mode on every later macOS (on macOS 27 that opened an empty
# "Ampere Settings" window at launch). Passing -isysroot restores the real
# SDK version, verified with otool -l | grep -A4 LC_BUILD_VERSION.
SDK_FLAGS=(-Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$(xcrun --show-sdk-path)")

swift build -c debug "${SDK_FLAGS[@]}" 2>&1 && .build/debug/Ampere
