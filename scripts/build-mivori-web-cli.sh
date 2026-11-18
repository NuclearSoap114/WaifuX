#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
binary="${1:?Pass an absolute output path for the Web renderer}"
architecture="${2:-arm64}"

mkdir -p "$(dirname "$binary")"
xcrun swiftc -parse-as-library -O -whole-module-optimization \
  -target "$architecture-apple-macosx14.4" \
  -Xlinker -stack_size -Xlinker 0x2000000 \
  -Xlinker -rpath -Xlinker @loader_path \
  -Xlinker -rpath -Xlinker @loader_path/Resources \
  -framework AppKit -framework AVFoundation -framework IOKit -framework WebKit -framework Combine \
  -o "$binary" "$project_root/wallpaperengine-cli.swift" "$project_root/Utilities/OwnedProcessIdentity.swift"
strip -x -S "$binary"
codesign --force --sign - "$binary"
