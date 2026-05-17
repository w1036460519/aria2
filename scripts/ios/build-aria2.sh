#!/usr/bin/env bash
# 为 iOS 交叉编译 aria2 静态库
# 用法: build-aria2.sh <sdk> <arch>
#   sdk : iphoneos | iphonesimulator
#   arch: arm64 | x86_64
# 输出到: $PWD/ios-out/<sdk>-<arch>/lib/libaria2.a + include/

set -euo pipefail

SDK="${1:?sdk required}"
ARCH="${2:?arch required}"

ROOT="$PWD"
DEPS="$ROOT/ios-deps/${SDK}-${ARCH}"
OUT="$ROOT/ios-out/${SDK}-${ARCH}"
mkdir -p "$OUT/lib" "$OUT/include"

SDKPATH=$(xcrun --sdk "$SDK" --show-sdk-path)
CLANG=$(xcrun --sdk "$SDK" --find clang)
CLANGXX=$(xcrun --sdk "$SDK" --find clang++)

case "$SDK" in
  iphoneos)        MIN_FLAG="-mios-version-min=13.0"           ; HOST=arm-apple-darwin ;;
  iphonesimulator) MIN_FLAG="-mios-simulator-version-min=13.0" ; HOST=${ARCH}-apple-darwin ;;
esac

# 检测 libssh2 是否成功构建，决定是否启用
if [ -f "$DEPS/lib/libssh2.a" ]; then
  SSH2_OPT="--with-libssh2"
else
  SSH2_OPT="--without-libssh2"
fi

CFLAGS_ALL="-arch $ARCH -isysroot $SDKPATH $MIN_FLAG -O2 -fembed-bitcode"
LDFLAGS_ALL="-arch $ARCH -isysroot $SDKPATH $MIN_FLAG"

# 关键: configure.ac 第 142 行在 AX_CXX_COMPILE_STDCXX 之前会清空 CXXFLAGS,
# 导致 -arch / -isysroot 丢失, 探测程序找不到 iOS SDK 的 C++ 标准库头。
# 解法是把这些 flag 直接绑进 CC/CXX 本身,让它们被隐含在“编译器调用”里。
export CC="$CLANG -arch $ARCH -isysroot $SDKPATH $MIN_FLAG"
export CXX="$CLANGXX -arch $ARCH -isysroot $SDKPATH $MIN_FLAG"
export AR=$(xcrun --sdk "$SDK" --find ar)
export RANLIB=$(xcrun --sdk "$SDK" --find ranlib)

cd "$ROOT"
[ -f configure ] || autoreconf -i

BUILD_DIR="$ROOT/build-ios-${SDK}-${ARCH}"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

../configure \
  --host="$HOST" \
  --enable-libaria2 --enable-static --disable-shared --disable-nls \
  --with-appletls --without-gnutls --without-openssl \
  --without-libxml2 --with-libexpat \
  --without-sqlite3 \
  --with-libcares --with-libz $SSH2_OPT \
  CFLAGS="$CFLAGS_ALL -I$DEPS/include" \
  CXXFLAGS="$CFLAGS_ALL -I$DEPS/include" \
  CPPFLAGS="-I$DEPS/include" \
  LDFLAGS="$LDFLAGS_ALL -L$DEPS/lib" \
  PKG_CONFIG_LIBDIR="$DEPS/lib/pkgconfig" \
  PKG_CONFIG_PATH="$DEPS/lib/pkgconfig"

make -j"$(sysctl -n hw.ncpu)"

# 收集产物
if [ -f src/.libs/libaria2.a ]; then
  cp src/.libs/libaria2.a "$OUT/lib/libaria2.a"
elif [ -f src/libaria2.a ]; then
  cp src/libaria2.a "$OUT/lib/libaria2.a"
else
  echo "ERR: libaria2.a not produced"; ls -la src/.libs || true; exit 1
fi

# 拷贝公共头
if [ -d "$ROOT/src/includes/aria2" ]; then
  cp -R "$ROOT/src/includes/aria2" "$OUT/include/"
fi

echo "[OK] iOS aria2 built: $OUT"
lipo -info "$OUT/lib/libaria2.a"
ls -la "$OUT/include/aria2" || true
