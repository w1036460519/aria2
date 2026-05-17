#!/usr/bin/env bash
# Windows arm64 (aarch64-w64-mingw32) 依赖交叉编译
# 在 mstorsjo/llvm-mingw 容器内运行
# 输出到: $PREFIX (默认 /usr/local/aarch64-w64-mingw32)

set -euo pipefail

HOST="${HOST:-aarch64-w64-mingw32}"
PREFIX="${PREFIX:-/usr/local/$HOST}"
mkdir -p "$PREFIX"

WORK=/tmp/win-arm64-deps
mkdir -p "$WORK" && cd "$WORK"

ZLIB_VER=1.3.1
EXPAT_VER=2.5.0
CARES_VER=1.21.0
SSH2_VER=1.11.0

fetch() { [ -f "$2" ] || curl -L -o "$2" "$1"; }

echo "================ zlib $ZLIB_VER ================"
fetch "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz" zlib.tgz
rm -rf zlib-${ZLIB_VER} && tar xf zlib.tgz
( cd zlib-${ZLIB_VER}
  CC=${HOST}-gcc \
  AR=${HOST}-ar \
  LD=${HOST}-ld \
  RANLIB=${HOST}-ranlib \
  STRIP=${HOST}-strip \
  ./configure --prefix="$PREFIX" \
              --libdir="$PREFIX/lib" \
              --includedir="$PREFIX/include" \
              --static
  make -j"$(nproc)" install
)

echo "================ libexpat $EXPAT_VER ================"
fetch "https://github.com/libexpat/libexpat/releases/download/R_2_5_0/expat-${EXPAT_VER}.tar.bz2" expat.tbz2
rm -rf expat-${EXPAT_VER} && tar xf expat.tbz2
( cd expat-${EXPAT_VER}
  ./configure --host="$HOST" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --without-docbook --without-xmlwf
  make -j"$(nproc)" install
)

echo "================ c-ares $CARES_VER ================"
fetch "https://github.com/c-ares/c-ares/releases/download/cares-1_21_0/c-ares-${CARES_VER}.tar.gz" cares.tgz
rm -rf c-ares-${CARES_VER} && tar xf cares.tgz
( cd c-ares-${CARES_VER}
  ./configure --host="$HOST" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-tests \
    LIBS="-lws2_32 -liphlpapi"
  make -j"$(nproc)" install
)

echo "================ libssh2 $SSH2_VER (wincng backend) ================"
fetch "https://libssh2.org/download/libssh2-${SSH2_VER}.tar.bz2" ssh2.tbz2
rm -rf libssh2-${SSH2_VER} && tar xf ssh2.tbz2
( cd libssh2-${SSH2_VER}
  ./configure --host="$HOST" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --disable-examples-build \
    --with-crypto=wincng \
    LIBS="-lws2_32 -lbcrypt -lcrypt32"
  make -j"$(nproc)" install
)

echo "[OK] windows-arm64 deps installed to $PREFIX"
ls -la "$PREFIX/lib"
