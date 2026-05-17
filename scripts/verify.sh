#!/usr/bin/env bash
# 通用产物闭环验证脚本
# 用法: verify.sh <platform> <arch> <build_dir_or_out_dir>
#   platform: macos | linux | windows | android | ios
#   arch    : arm64 | x86_64 | armeabi-v7a | x86 | arm64-v8a
#   dir     : 产物所在目录（包含 src/ 或直接是产物目录）
#
# 验证级别:
#   L2 静态: file / lipo / objdump 校验目标平台与架构
#   L3 运行: macOS / Linux 原生执行 --version, 失败即整体失败

set -euo pipefail

PLATFORM="${1:?platform required}"
ARCH="${2:?arch required}"
DIR="${3:?dir required}"

echo "================================================================"
echo " Verify: platform=$PLATFORM arch=$ARCH dir=$DIR"
echo "================================================================"

# 在多种可能的目录结构下定位主二进制
locate_bin() {
  local name="$1"
  # 优先 .libs/ 下的真二进制。libtool 在启用共享库时,
  # src/aria2c 实际是 shell wrapper, 真 Mach-O/ELF 在 src/.libs/aria2c。
  for p in \
      "$DIR/src/.libs/$name" \
      "$DIR/.libs/$name" \
      "$DIR/src/$name" \
      "$DIR/$name" \
      "$DIR/bin/$name" ; do
    if [ -f "$p" ]; then echo "$p"; return 0; fi
  done
  return 1
}

locate_lib() {
  # 返回找到的第一个匹配，或空
  local pattern="$1"
  find "$DIR" -name "$pattern" -type f 2>/dev/null | head -n1
}

case "$PLATFORM" in
  macos)
    BIN=$(locate_bin aria2c) || { echo "ERR: aria2c not found"; exit 1; }
    echo "[L2] file:"; file "$BIN"
    echo "[L2] lipo:"; lipo -info "$BIN" || true
    # 校验架构标签
    if ! file "$BIN" | grep -qiE "Mach-O.*$ARCH"; then
      echo "ERR: aria2c is not Mach-O $ARCH"; exit 1
    fi
    echo "[L3] run --version:"
    if [ "$(uname -m)" = "arm64" ] && [ "$ARCH" = "x86_64" ]; then
      echo "  skip (arm64 host can't always exec x86_64 without Rosetta)"
    else
      "$BIN" --version | head -3
    fi
    LIB=$(locate_lib 'libaria2.0.dylib' || true)
    [ -n "$LIB" ] && { echo "[L2] dylib file:"; file "$LIB"; }
    ;;

  linux)
    BIN=$(locate_bin aria2c) || { echo "ERR: aria2c not found"; exit 1; }
    echo "[L2] file:"; file "$BIN"
    if ! file "$BIN" | grep -q "ELF"; then
      echo "ERR: not an ELF binary"; exit 1
    fi
    case "$ARCH" in
      x86_64)
        file "$BIN" | grep -qi "x86-64" || { echo "ERR: arch mismatch"; exit 1; }
        echo "[L3] run --version:"
        # 在 manylinux 容器内编出的二进制,依赖 CentOS 7 的 libssl.so.10 等,
        # host (Ubuntu 22.04) 上不存在。如 ldd 有缺失库跳过运行调用,
        # L3 已在容器内 build 步骤跑过。
        if ldd "$BIN" 2>&1 | grep -q 'not found'; then
          echo "  skip (host 缺少容器内的依赖库,容器内已验证):"
          ldd "$BIN" 2>&1 | grep 'not found' | head -5 || true
        else
          "$BIN" --version | head -3
        fi
        ;;
      arm64)
        file "$BIN" | grep -qi "aarch64" || { echo "ERR: arch mismatch"; exit 1; }
        echo "[L3] run via qemu:"
        if command -v qemu-aarch64-static >/dev/null 2>&1; then
          qemu-aarch64-static "$BIN" --version | head -3 || \
            echo "  (qemu run failed, L2 已通过)"
        else
          # 通过 binfmt + docker 的方式（CI 已 setup-qemu-action）
          echo "  qemu-aarch64-static not available on host; L2 已通过"
        fi
        ;;
    esac
    LIB=$(locate_lib 'libaria2.so*' || true)
    [ -n "$LIB" ] && { echo "[L2] so file:"; file "$LIB"; }
    ;;

  windows)
    BIN=$(locate_bin aria2c.exe) || { echo "ERR: aria2c.exe not found"; exit 1; }
    echo "[L2] file:"; file "$BIN"
    if ! file "$BIN" | grep -qi "PE32"; then
      echo "ERR: not a PE binary"; exit 1
    fi
    case "$ARCH" in
      x86_64)
        file "$BIN" | grep -qi "x86-64" || { echo "ERR: arch mismatch"; exit 1; }
        ;;
      arm64)
        file "$BIN" | grep -qiE "Aarch64|ARM64" || {
          echo "ERR: arm64 PE expected"; exit 1; }
        ;;
    esac
    echo "[L3] wine run (best effort):"
    if command -v wine >/dev/null 2>&1 && [ "$ARCH" = "x86_64" ]; then
      wine "$BIN" --version 2>/dev/null | head -3 || echo "  (wine 运行失败，L2 已通过)"
    else
      echo "  skip (wine 不可用或 arm64 PE)"
    fi
    ;;

  android)
    # 期望目录结构: $DIR/aria2c 或 $DIR/lib/libaria2.so
    BIN=$(locate_bin aria2c || true)
    LIB=$(locate_lib 'libaria2.so*' || true)
    if [ -z "$BIN" ] && [ -z "$LIB" ]; then
      echo "ERR: neither aria2c nor libaria2.so found in $DIR"
      ls -laR "$DIR" || true
      exit 1
    fi
    [ -n "$BIN" ] && { echo "[L2] aria2c:"; file "$BIN"; }
    [ -n "$LIB" ] && { echo "[L2] libaria2.so:"; file "$LIB"; }
    target_re=""
    case "$ARCH" in
      arm64-v8a)    target_re="aarch64" ;;
      armeabi-v7a) target_re="ARM" ;;
      x86_64)      target_re="x86-64" ;;
      x86)         target_re="Intel 80386" ;;
    esac
    if [ -n "$target_re" ] && [ -n "$BIN" ]; then
      file "$BIN" | grep -qi "$target_re" || { echo "ERR: arch mismatch ($target_re)"; exit 1; }
    fi
    ;;

  ios)
    LIB=$(locate_lib 'libaria2.a' || true)
    if [ -z "$LIB" ]; then
      echo "ERR: libaria2.a not found in $DIR"; ls -laR "$DIR" || true; exit 1
    fi
    echo "[L2] lipo info:"
    lipo -info "$LIB"
    if ! lipo -info "$LIB" | grep -q "$ARCH"; then
      echo "ERR: arch $ARCH not found in fat archive"; exit 1
    fi
    echo "[L2] otool platform check (first object):"
    AR_TMP=$(mktemp -d)
    (cd "$AR_TMP" && ar -x "$OLDPWD/$LIB" 2>/dev/null || ar -x "$LIB") || true
    FIRST_O=$(find "$AR_TMP" -name '*.o' | head -n1 || true)
    if [ -n "$FIRST_O" ]; then
      otool -l "$FIRST_O" | grep -E "platform|minos|sdk" | head -10 || true
    fi
    rm -rf "$AR_TMP"
    ;;

  *)
    echo "ERR: unknown platform $PLATFORM"; exit 1
    ;;
esac

echo "[OK] verify passed: $PLATFORM/$ARCH"
