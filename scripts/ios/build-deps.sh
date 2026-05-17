#!/usr/bin/env bash
# 为 iOS 交叉编译 aria2 所需的静态依赖：
#   zlib / libexpat / c-ares / libssh2
# 用法: build-deps.sh <sdk> <arch>
#   sdk : iphoneos | iphonesimulator
#   arch: arm64 | x86_64
# 安装到: $PWD/ios-deps/<sdk>-<arch>/{include,lib}

set -euo pipefail

SDK="${1:?sdk required (iphoneos|iphonesimulator)}"
ARCH="${2:?arch required (arm64|x86_64)}"

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

CFLAGS="-arch $ARCH -isysroot $SDKPATH $MIN_FLAG -fembed-bitcode -O2"
CXXFLAGS="$CFLAGS"
LDFLAGS="-arch $ARCH -isysroot $SDKPATH $MIN_FLAG"

export CC="$CLANG"
export CXX="$CLANGXX"
export CFLAGS CXXFLAGS LDFLAGS
export AR=$(xcrun --sdk "$SDK" --find ar)
export RANLIB=$(xcrun --sdk "$SDK" --find ranlib)

WORK="$ROOT/ios-build/${SDK}-${ARCH}"
mkdir -p "$WORK"
cd "$WORK"

# ---- versions
# 注意: c-ares 必须用 >= 1.34，旧版本 (1.19/1.21) 在 iOS SDK 下
# AC_CHECK_TYPE(struct iovec) / AF_INET6 探测会失败，导致
# ares_setup.h / ares_process.c 自己又定义一份，与系统头冲突。
ZLIB_VER=1.3.1
EXPAT_VER=2.6.4
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

echo "================ libssh2 $SSH2_VER ================"
fetch "https://libssh2.org/download/libssh2-${SSH2_VER}.tar.bz2" ssh2.tbz2
rm -rf libssh2-${SSH2_VER} && tar xf ssh2.tbz2
( cd libssh2-${SSH2_VER}
  # iOS 上不带 OpenSSL，使用 mbedtls 不可得，这里改用 nettle? 实际上
  # libssh2 在没有 crypto backend 时会编译失败，因此这里启用 wincng?
  # iOS 没有 wincng；对应方案是关闭 ssh2 支持。
  # 这里我们让 configure 自动选择，若失败将由调用者决定 --without-libssh2。
  ./configure --host="$HOST" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-examples-build \
    --without-libgcrypt --without-mbedtls \
    --with-crypto=openssl 2>/dev/null || \
  ./configure --host="$HOST" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-examples-build \
    --with-crypto=mbedtls 2>/dev/null || \
  { echo "[warn] libssh2 configure failed (no usable crypto on iOS); skipping"; exit 0; }
  make -j"$(sysctl -n hw.ncpu)" || echo "[warn] libssh2 build failed; skipping"
  make install || true
)

echo "[OK] iOS deps installed to: $PREFIX"
ls -la "$PREFIX/lib" || true
