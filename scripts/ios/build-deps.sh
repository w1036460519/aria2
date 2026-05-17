#!/usr/bin/env bash
# 为 iOS 交叉编译 aria2 所需的静态依赖：
#   zlib / libexpat / c-ares / libssh2
# 用法: build-deps.sh <sdk> <arch>
#   sdk : iphoneos | iphonesimulator
#   arch: arm64
# 安装到: $PWD/ios-deps/<sdk>-<arch>/{include,lib}

set -euo pipefail

SDK="${1:?sdk required (iphoneos|iphonesimulator)}"
ARCH="${2:?arch required (arm64)}"

ROOT="$PWD"
PREFIX="$ROOT/ios-deps/${SDK}-${ARCH}"
mkdir -p "$PREFIX"

SDKPATH=$(xcrun --sdk "$SDK" --show-sdk-path)
CLANG=$(xcrun --sdk "$SDK" --find clang)
CLANGXX=$(xcrun --sdk "$SDK" --find clang++)

case "$SDK" in
  iphoneos)        MIN_FLAG="-mios-version-min=13.0"           ; HOST=arm-apple-darwin ;;
  iphonesimulator) MIN_FLAG="-mios-simulator-version-min=13.0" ; HOST=${ARCH}-apple-darwin ;;
  *) echo "unknown sdk: $SDK" >&2; exit 1 ;;
esac

CFLAGS="-arch $ARCH -isysroot $SDKPATH $MIN_FLAG -O2"
CXXFLAGS="$CFLAGS"
LDFLAGS="-arch $ARCH -isysroot $SDKPATH $MIN_FLAG"

export CC="$CLANG -arch $ARCH -isysroot $SDKPATH $MIN_FLAG"
export CXX="$CLANGXX -arch $ARCH -isysroot $SDKPATH $MIN_FLAG -std=gnu++14"
export CFLAGS CXXFLAGS LDFLAGS
export AR=$(xcrun --sdk "$SDK" --find ar)
export RANLIB=$(xcrun --sdk "$SDK" --find ranlib)

WORK="$ROOT/ios-build/${SDK}-${ARCH}"
mkdir -p "$WORK"
cd "$WORK"

# ---- versions
# c-ares 必须用 >= 1.34，旧版本 (1.19/1.21) 在 iOS SDK 下
# AC_CHECK_TYPE(struct iovec) / AF_INET6 探测会失败，导致
# ares_setup.h / ares_process.c 自己又定义一份，与系统头冲突。
# OpenSSL 3.0.x 是 LTS (支持到 2026-09以后)，iOS 换下 OpenSSL
# 是因为 Apple Security framework 的 SSLContextRef API 在 iOS 13+
# 已 deprecated，到 iOS 17 SDK 部分符号已 unavailable。
ZLIB_VER=1.3.1
EXPAT_VER=2.6.4
OPENSSL_VER=3.0.16
CARES_VER=1.34.4
SSH2_VER=1.11.0

fetch() {
  local url="$1" file="$2"
  if [ ! -f "$file" ]; then
    curl -L -o "$file" "$url"
  fi
}

echo "================ zlib $ZLIB_VER ================"
fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" zlib.tgz
rm -rf zlib-${ZLIB_VER} && tar xf zlib.tgz
( cd zlib-${ZLIB_VER}
  ./configure --prefix="$PREFIX" --static
  make -j"$(sysctl -n hw.ncpu)"
  make install
)

echo "================ libexpat $EXPAT_VER ================"
# 新版 expat 的 tag 形如 R_2_6_4
EXPAT_TAG="R_$(echo $EXPAT_VER | tr . _)"
fetch "https://github.com/libexpat/libexpat/releases/download/${EXPAT_TAG}/expat-${EXPAT_VER}.tar.bz2" expat.tbz2
rm -rf expat-${EXPAT_VER} && tar xf expat.tbz2
( cd expat-${EXPAT_VER}
  ./configure --host="$HOST" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --without-docbook --without-xmlwf
  make -j"$(sysctl -n hw.ncpu)"
  make install
)

echo "================ c-ares $CARES_VER ================"
# 1.34+ 起 release URL 改为 v$VER 形式
fetch "https://github.com/c-ares/c-ares/releases/download/v${CARES_VER}/c-ares-${CARES_VER}.tar.gz" cares.tgz
rm -rf c-ares-${CARES_VER} && tar xf cares.tgz
( cd c-ares-${CARES_VER}
  # 兜底: 即便探测逻辑失败,也告诉 c-ares 这些类型/宏存在
  # (iOS SDK 必然提供它们)
  ./configure --host="$HOST" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-tests \
    ac_cv_have_struct_iovec=yes \
    ac_cv_func_recvfrom=yes \
    ac_cv_func_writev=yes \
    cares_cv_getaddrinfo=yes
  make -j"$(sysctl -n hw.ncpu)"
  make install
)

echo "================ OpenSSL $OPENSSL_VER ================"
fetch "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz" openssl.tgz
rm -rf openssl-${OPENSSL_VER} && tar xf openssl.tgz
(
  cd openssl-${OPENSSL_VER}
  # OpenSSL Configure 不读环境 CC，也不能多出一堆 -arch/-isysroot;
  # 它靠 CROSS_TOP/CROSS_SDK 加 ios64-cross/iossimulator-xcrun target 自己拼。
  # 临时 unset 我们给其他包设的 CC/CXX，避免双重 flag。
  case "$SDK-$ARCH" in
    iphoneos-arm64)         OS_TARGET=ios64-cross ;;
    iphonesimulator-arm64)  OS_TARGET=iossimulator-xcrun ;;
    *) echo "unknown OpenSSL target: $SDK-$ARCH" >&2; exit 1 ;;
  esac
  export CROSS_TOP="${SDKPATH%/SDKs/*}"
  export CROSS_SDK="${SDKPATH##*/}"
  ( unset CC CXX CFLAGS CXXFLAGS LDFLAGS
    ./Configure "$OS_TARGET" \
      no-shared no-tests no-dso no-async no-engine no-ui-console \
      --prefix="$PREFIX"
    make -j"$(sysctl -n hw.ncpu)"
    make install_sw
  )
)

echo "================ libssh2 $SSH2_VER ================"
fetch "https://libssh2.org/download/libssh2-${SSH2_VER}.tar.bz2" ssh2.tbz2
rm -rf libssh2-${SSH2_VER} && tar xf ssh2.tbz2
( cd libssh2-${SSH2_VER}
  # 现在有 OpenSSL 了，libssh2 能顺利拿 openssl 做 crypto backend
  ./configure --host="$HOST" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-examples-build \
    --with-crypto=openssl --with-libssl-prefix="$PREFIX"
  make -j"$(sysctl -n hw.ncpu)"
  make install
)

echo "[OK] iOS deps installed to: $PREFIX"
ls -la "$PREFIX/lib" || true
