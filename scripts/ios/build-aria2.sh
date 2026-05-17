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
# Apple framework 放 LDFLAGS 里注入。不能放 LIBS=,
# 那会覆盖 configure 自动探测出的 OPENSSL_LIBS (-lssl -lcrypto)。
# SimpleRandomizer.cc 代码里 __APPLE__ 分支优先于 HAVE_OPENSSL,
# 无论 TLS 后端选什么,Apple 平台都会调 SecRandomCopyBytes,
# 所以 Security framework 必须显式链。
#
# -lssl -lcrypto 也要手动加: src/Makefile.am 在 ENABLE_LIBARIA2 时
# 把 OPENSSL_LIBS 只挂在 libaria2.la 上, aria2c 本体没有;
# 静态归档 + Apple ld 不会从 .la 的 dependency_libs 传递依赖,
# 以致 SSL_* / X509_* 符号全部 undefined。最干净的旁路是
# 在 LDFLAGS 里显式加上。
LDFLAGS_ALL="-arch $ARCH -isysroot $SDKPATH $MIN_FLAG \
  -L$DEPS/lib -lssl -lcrypto \
  -framework Security -framework CoreFoundation"

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
