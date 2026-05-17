#!/usr/bin/env bash
# Android 单 ABI 构建脚本（CI 矩阵每次跑一个 ABI）
# 用法: build-android.sh <HOST> <OPENSSL_TARGET> <ABI>
#   HOST           : aarch64-linux-android | armv7a-linux-androideabi | x86_64-linux-android | i686-linux-android
#   OPENSSL_TARGET : android-arm64 | android-arm | android-x86_64 | android-x86
#   ABI            : arm64-v8a | armeabi-v7a | x86_64 | x86
#
# 依赖: $NDK 已设置，API=33 (env)。
# 输出: $PWD/android-out/<ABI>/{aria2c, lib/libaria2.so?}

set -euo pipefail

HOST="${1:?host required}"
OPENSSL_TARGET="${2:?openssl target required}"
ABI="${3:?abi required}"

: "${NDK:?NDK env required}"
API="${API:-33}"

ROOT="$PWD"
TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
PATH="$TOOLCHAIN/bin:$PATH"

# armv7 的工具链命名特殊：clang 前缀使用 armv7a-linux-androideabi$API
# AR/RANLIB 使用 arm-linux-androideabi
case "$HOST" in
  armv7a-linux-androideabi) BINPREFIX=arm-linux-androideabi ;;
  *)                        BINPREFIX="$HOST" ;;
esac

export AR="$TOOLCHAIN/bin/llvm-ar"
export RANLIB="$TOOLCHAIN/bin/llvm-ranlib"
export STRIP="$TOOLCHAIN/bin/llvm-strip"
export CC="$TOOLCHAIN/bin/${HOST}${API}-clang"
export CXX="$TOOLCHAIN/bin/${HOST}${API}-clang++"
PREFIX="$ROOT/android-deps/$ABI"
mkdir -p "$PREFIX"

# ----------------------------- deps versions
OPENSSL_VER=1.1.1w
EXPAT_VER=2.5.0
ZLIB_VER=1.3.1
CARES_VER=1.21.0
SSH2_VER=1.11.0

WORK="$ROOT/android-build/$ABI"
mkdir -p "$WORK" && cd "$WORK"

fetch() { [ -f "$2" ] || curl -L -o "$2" "$1"; }

echo "================ OpenSSL $OPENSSL_VER ($OPENSSL_TARGET) ================"
fetch "https://www.openssl.org/source/openssl-${OPENSSL_VER}.tar.gz" openssl.tgz
rm -rf openssl-${OPENSSL_VER} && tar xf openssl.tgz
( cd openssl-${OPENSSL_VER}
  ANDROID_NDK_HOME="$NDK" PATH="$TOOLCHAIN/bin:$PATH" \
    ./Configure no-shared --prefix="$PREFIX" "$OPENSSL_TARGET" -D__ANDROID_API__=$API
  make -j"$(nproc)"
  make install_sw
)

echo "================ libexpat $EXPAT_VER ================"
fetch "https://github.com/libexpat/libexpat/releases/download/R_2_5_0/expat-${EXPAT_VER}.tar.bz2" expat.tbz2
rm -rf expat-${EXPAT_VER} && tar xf expat.tbz2
( cd expat-${EXPAT_VER}
  ./configure --host="$BINPREFIX" --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)" \
    --prefix="$PREFIX" --disable-shared
  make -j"$(nproc)" install
)

echo "================ zlib $ZLIB_VER ================"
fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" zlib.tgz
rm -rf zlib-${ZLIB_VER} && tar xf zlib.tgz
( cd zlib-${ZLIB_VER}
  ./configure --prefix="$PREFIX" --static
  make -j"$(nproc)" install
)

echo "================ c-ares $CARES_VER ================"
fetch "https://github.com/c-ares/c-ares/releases/download/cares-1_21_0/c-ares-${CARES_VER}.tar.gz" cares.tgz
rm -rf c-ares-${CARES_VER} && tar xf cares.tgz
( cd c-ares-${CARES_VER}
  ./configure --host="$BINPREFIX" --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)" \
    --prefix="$PREFIX" --disable-shared
  make -j"$(nproc)" install
)

echo "================ libssh2 $SSH2_VER ================"
fetch "https://libssh2.org/download/libssh2-${SSH2_VER}.tar.bz2" ssh2.tbz2
rm -rf libssh2-${SSH2_VER} && tar xf ssh2.tbz2
( cd libssh2-${SSH2_VER}
  ./configure --host="$BINPREFIX" --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)" \
    --prefix="$PREFIX" --disable-shared
  make -j"$(nproc)" install
)

echo "================ aria2 ================"
cd "$ROOT"
[ -f configure ] || autoreconf -i

BUILD_DIR="$ROOT/build-android-$ABI"
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

../configure \
  --host="$BINPREFIX" \
  --build="$(dpkg-architecture -qDEB_BUILD_GNU_TYPE)" \
  --enable-libaria2 \
  --disable-nls \
  --without-gnutls --with-openssl \
  --without-sqlite3 --without-libxml2 --with-libexpat \
  --with-libcares --with-libz --with-libssh2 \
  CXXFLAGS="-Os -g" CFLAGS="-Os -g" \
  CPPFLAGS="-fPIE -I$PREFIX/include" \
  LDFLAGS="-fPIE -pie -L$PREFIX/lib -static-libstdc++" \
  PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

make -j"$(nproc)"
"$STRIP" src/aria2c || true

OUT="$ROOT/android-out/$ABI"
mkdir -p "$OUT" "$OUT/lib"
cp src/aria2c "$OUT/aria2c"
[ -f src/.libs/libaria2.so ] && cp src/.libs/libaria2.so "$OUT/lib/libaria2.so" || true
[ -f src/.libs/libaria2.a  ] && cp src/.libs/libaria2.a  "$OUT/lib/libaria2.a"  || true

echo "[OK] android $ABI built: $OUT"
ls -la "$OUT" "$OUT/lib" || true
file "$OUT/aria2c"
