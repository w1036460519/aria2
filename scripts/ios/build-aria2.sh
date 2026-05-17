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

CFLAGS_ALL="-arch $ARCH -isysroot $SDKPATH $MIN_FLAG -O2"
# Apple framework 走 LDFLAGS (libtool 认 -framework 为 ld 选项, 不过滤)。
# SimpleRandomizer.cc 代码里 __APPLE__ 分支优先于 HAVE_OPENSSL,
# Apple 平台都会调 SecRandomCopyBytes → Security framework 必须显式链。
LDFLAGS_ALL="-arch $ARCH -isysroot $SDKPATH $MIN_FLAG \
  -L$DEPS/lib \
  -framework Security -framework CoreFoundation"
# OpenSSL 静态库走 LIBS 通道才稳:
# - src/Makefile.am 在 ENABLE_LIBARIA2 时把 OPENSSL_LIBS 只挂在
#   libaria2.la, aria2c 本体没有; Apple ld 不从 .la 的
#   dependency_libs 传递 → SSL_*/X509_* undefined。
# - 走 LDFLAGS 加 -lssl -lcrypto: libtool mode=link 会把 -l 当
#   deplibs 重新整理, 某些顺序场景下会丢掉。
# - 走 LIBS: 是 autoconf “基线终极库”, 确定拼到每条
#   link line 末尾, libtool 也不过滤。与 OPENSSL_LIBS 独立不互冲。
LIBS_EXTRA="-lssl -lcrypto"

# 设计取舍:
# - TLS backend: 用 OpenSSL，不用 AppleTLS。
#   AppleTLS (SSLContextRef / kTLSProtocol1*) 在 iOS 13+ 已 deprecated，
#   iOS 17.5 SDK 已将警告升为 error，编译 AppleTLSSession.cc 会挂。
# - C++11 探测: configure.ac 在 AX_CXX_COMPILE_STDCXX 之前会清空
#   CXXFLAGS，-arch / -isysroot 会丢; Apple clang++ 另外默认
#   -std=c++98，会抖 #error “This is not a C++11 compiler”。
#   两点都靠把 flag 直接绑进 CC/CXX 本身解决。
export CC="$CLANG -arch $ARCH -isysroot $SDKPATH $MIN_FLAG"
export CXX="$CLANGXX -arch $ARCH -isysroot $SDKPATH $MIN_FLAG -std=gnu++14"
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
  --without-appletls --without-gnutls --with-openssl \
  --without-libxml2 --with-libexpat \
  --without-sqlite3 \
  --with-libcares --with-libz $SSH2_OPT \
  OPENSSL_CFLAGS="-I$DEPS/include" \
  OPENSSL_LIBS="-L$DEPS/lib -lssl -lcrypto" \
  CFLAGS="$CFLAGS_ALL -I$DEPS/include" \
  CXXFLAGS="$CFLAGS_ALL -I$DEPS/include" \
  CPPFLAGS="-I$DEPS/include" \
  LDFLAGS="$LDFLAGS_ALL -L$DEPS/lib" \
  LIBS="$LIBS_EXTRA" \
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
