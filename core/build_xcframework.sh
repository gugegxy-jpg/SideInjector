#!/bin/bash
# 在 macOS 上把 Rust core 编成 xcframework，供 Xcode 链接。
# 前置：rustup target add aarch64-apple-ios + cargo install cargo-lipo（可选）
set -euo pipefail
cd "$(dirname "$0")"

TARGET=aarch64-apple-ios
OUT=build
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> cargo build --release --target $TARGET"
cargo build --release --target "$TARGET"

# 产出放到 core/build，与 project.yml 中 framework 依赖路径一致
LIB=build/sideinjector_core.xcframework
rm -rf "$LIB"
# Swift 侧用 @_silgen_name FFI，不依赖 C 头文件；仅当 include 目录存在时才附带
if [ -d ../SideInjector/include ]; then
  xcodebuild -create-xcframework \
    -library "target/$TARGET/release/libsideinjector_core.a" \
    -headers ../SideInjector/include \
    -output "$LIB"
else
  xcodebuild -create-xcframework \
    -library "target/$TARGET/release/libsideinjector_core.a" \
    -output "$LIB"
fi

echo "==> 产出 $LIB"
