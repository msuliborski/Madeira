#!/bin/bash
# Bazowa libwineserver.a (brak w repo): wszystkie wine/server/*.c z flagami z build/wineserver/build.sh
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; BUILD_DIR=$REPO_ROOT/build/wineserver
WINE_SRC=$REPO_ROOT/wine
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
SHIMS_DIR=$REPO_ROOT/build/ntdll-unix/shims
CC_FLAGS=(
    -arch arm64 -isysroot "$SDK" -miphoneos-version-min=17.0 -O2
    -I"$WINE_SRC/include" -I"$WINE_SRC/include/wine"
    -I"$WINE_SRC/build-macos/include"
    -I"$BUILD_DIR" -I"$WINE_SRC/server"
    -I"$SHIMS_DIR"
    -I"$BUILD_DIR/../madsync" -DHAVE_LINUX_NTSYNC_H=1
    -include "$BUILD_DIR/config_ios.h"
    -include stdarg.h
    -include "$BUILD_DIR/unicode_fix.h"
    -include "$BUILD_DIR/wineserver_ios_kill.h"
    -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\"
    -D__WINESRC__ -DWINE_IOS=1
    -Dmain=wineserver_main
    # Symbol collisions with win32u are NOT handled via -D macros — that
    # rewrites macro args (e.g. DECL_HANDLER(name)) and breaks struct
    # name concatenation. Renames done post-compile via objcopy below,
    # applied to EVERY .o in libwineserver.a so cross-file refs (e.g.
    # clipboard.c calling send_notify_message defined in queue.c) stay
    # internal to the archive after the renames.
    -Wno-implicit-function-declaration
)

T=$BUILD_DIR/obj-base; mkdir -p $T $BUILD_DIR/obj; n=0; bad=0
for f in $WINE_SRC/server/*.c; do b=$(basename $f .c); if xcrun -sdk iphoneos clang "${CC_FLAGS[@]}" -c $f -o $T/$b.o 2>$T/$b.err; then n=$((n+1)); else bad=$((bad+1)); echo "FAIL $b: $(grep -m1 error: $T/$b.err | cut -c1-150)"; fi; done
echo "ok=$n fail=$bad"
xcrun ar rcs $BUILD_DIR/obj/libwineserver.a $T/*.o
