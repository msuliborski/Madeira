#!/bin/zsh
# Budowanie Madeiry z main wg docs/BUILDING.md. Każdy krok -> logs/<krok>.log; stop na pierwszym błędzie.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$ROOT" || exit 1
mkdir -p ../logs toolchains
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$HOME/.cargo/bin:/opt/homebrew/bin:$PATH"
step() { local n=$1; shift; echo "$(date +%H:%M) START $n"; if ( "$@" ) > $ROOT/../logs/$n.log 2>&1; then echo "$(date +%H:%M) OK $n"; else echo "$(date +%H:%M) BLAD $n (logs/$n.log)"; tail -5 $ROOT/../logs/$n.log; exit 1; fi; }

mingw() {
  cd toolchains && [ -d llvm-mingw-20260421-ucrt-macos-universal ] && return 0
  curl -sSLO https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/llvm-mingw-20260421-ucrt-macos-universal.tar.xz
  echo "bd85a3975723815cef28dbbd2ca2cb0c926f6b348a12a0453f39f7af273cb3f7  llvm-mingw-20260421-ucrt-macos-universal.tar.xz" | shasum -a 256 -c - && tar xf llvm-mingw-*.tar.xz && rm llvm-mingw-*.tar.xz
}
llvm() {
  cd toolchains
  [ -d llvm-project ] || { git init -q llvm-project && cd llvm-project && git remote add origin https://github.com/llvm/llvm-project.git && git fetch -q --depth 1 origin 8dfdcc7b7 2>/dev/null || git fetch -q --depth 1 origin $(git ls-remote origin | awk '$1 ~ /^8dfdcc7b7/{print $1; exit}'); git checkout -q FETCH_HEAD; cd ..; }
  cmake -G Ninja -S llvm-project/llvm -B llvm-host-build -DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_INCLUDE_TESTS=Off && ninja -C llvm-host-build llvm-tblgen llvm-config || return 1
  cmake -G Ninja -S llvm-project/llvm -B llvm-ios-build -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos -DCMAKE_BUILD_TYPE=Release -DLLVM_HOST_TRIPLE=arm64-apple-ios17.0 -DLLVM_DEFAULT_TARGET_TRIPLE=arm64-apple-ios17.0 -DLLVM_TARGET_ARCH=host -DLLVM_TARGETS_TO_BUILD= -DLLVM_ENABLE_PROJECTS= -DLLVM_BUILD_TOOLS=Off -DLLVM_INCLUDE_TESTS=Off -DLLVM_ENABLE_ZLIB=Off -DCMAKE_MACOSX_BUNDLE=OFF -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF -DLLVM_TABLEGEN=$PWD/llvm-host-build/bin/llvm-tblgen -DLLVM_NATIVE_TOOL_DIR=$PWD/llvm-host-build/bin && ninja -C llvm-ios-build $(ninja -C llvm-ios-build -t targets all | grep -oE "^lib/lib[A-Za-z0-9_]+\.a" | sort -u)
}
vcrt() {
  D=app/Madeira/x86_64-vcruntime; [ -n "$(ls $D/*.dll 2>/dev/null)" ] && return 0
  rm -rf /tmp/vcr && mkdir -p /tmp/vcr/c /tmp/vcr/c2 $D && cd /tmp/vcr && curl -sSL -o vc_redist.x64.exe https://aka.ms/vs/17/release/vc_redist.x64.exe || return 1
  cabextract -q -d c vc_redist.x64.exe 2>/dev/null; for f in c/*; do file -b "$f" | grep -qi cabinet && cabextract -q -d c2 "$f" 2>/dev/null; done; cd - >/dev/null
  for f in /tmp/vcr/c2/*_amd64; do b=$(basename "$f" _amd64); case "$b" in concrt140*|msvcp140*|vcamp140*|vccorlib140*|vcruntime140*) cp "$f" "$D/$b";; esac; done
  ls $D/vcruntime140.dll
}
dxmtpe() {
  export PATH="$PWD/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
  [ -d dxmt/build-arm64ec ] || meson setup dxmt/build-arm64ec dxmt -Dbuildtype=release -Dwine_build_path=$PWD/wine/build-arm64ec --cross-file=dxmt/build-arm64ec-win.txt || return 1
  ninja -C dxmt/build-arm64ec src/winemetal/winemetal.dll src/d3d11/d3d11.dll && cp dxmt/build-arm64ec/src/winemetal/winemetal.dll dxmt/build-arm64ec/src/d3d11/d3d11.dll app/Madeira/arm64ec-windows/
}

# --- poprawki do drzewa źródeł, których nie ma w repo (2026-10-22, msuliborski) ---
prep() {
  # Xcode 26 na runnerach GitHuba: rusage_info_v6 bez pola z SDK iOS 27 (tylko log diagnostyczny) -> 0
  sed -i "" "s/XP_MS( ru.ri_page_wait_time_mach - pru.ri_page_wait_time_mach )/0.0/" build/ntdll-unix/server_ios.c
  export PATH="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:$ROOT/toolchains/llvm-mingw-20260421-ucrt-macos-universal/bin:$PATH"
  [ -d research/freetype ] || git clone -q --depth 1 --branch VER-2-13-3 https://github.com/freetype/freetype.git research/freetype
  sed -i '' "s|'@GLOBAL_SOURCE_ROOT@' / 'toolchains/|'$ROOT/toolchains/|" dxmt/build-arm64ec-win.txt
  [ "$(xcodebuild -version | awk 'NR==1{print int($2)}')" -ge 27 ] && sed -i '' 's|__METAL_MEMORY_SCOPE_THREADGROUP__);|__METAL_MEMORY_SCOPE_THREADGROUP__, false);|' dxmt/src/airconv/shaders/air_tessellation.metal
  (cd dxmt/src/airconv && for s in air_msad air_samplepos air_tessellation; do xcrun -sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 -o /tmp/$s.air -c shaders/$s.metal && (cd /tmp && xxd -n $s -i $s.air) > $s.h || return 1; done)
  if [ ! -f wine/build-macos/include/config.h ]; then mkdir -p wine/build-macos && (cd wine/build-macos && ../configure --enable-archs=arm64ec,aarch64 --without-x --without-vulkan --without-freetype --without-gnutls --disable-tests --enable-winegstreamer) || return 1; fi
  sed -i '' 's|^/\* #undef HAVE_GNUTLS_CIPHER_INIT \*/|#define HAVE_GNUTLS_CIPHER_INIT 1|; s|^/\* #undef SONAME_LIBGNUTLS \*/|#define SONAME_LIBGNUTLS "libgnutls.30.dylib"|' wine/build-macos/include/config.h
  (cd wine/build-macos && make -j"$(sysctl -n hw.ncpu)" __tooldeps__ && make -k -j"$(sysctl -n hw.ncpu)" $(cd ../include && ls *.idl | sed 's/\.idl$/.h/; s/^/include\//')) >/dev/null 2>&1; [ -f wine/build-macos/include/wtypes.h ]
}
basews() {
  [ -f build/wineserver/obj/libwineserver.a ] && return 0
  bash tools/ci/base-wineserver.sh
}
step mingw mingw
step llvm llvm
step vcruntime vcrt
step prep prep
step gnutls bash build/gnutls-ios/build.sh
step ffmpeg bash build/ffmpeg/build.sh
step fex-ios bash build/fex-ios/build.sh
step fex-arm64ec bash build/fex-arm64ec/build.sh
step freetype bash build/freetype-ios/build.sh
step ntdll-unix bash build/ntdll-unix/build.sh
step base-wineserver basews
step wineserver bash build/wineserver/build.sh
step win32u-unix bash build/win32u-unix/build.sh
step wine-pe bash build/wine-pe/build-ntdll.sh
step dxmt-ios bash -c "bash build/dxmt-ios/build.sh && cd build/dxmt-ios && xcrun -sdk iphoneos libtool -static -o libdxmt_combined.a obj/*.o ../../toolchains/llvm-ios-build/lib/*.a && cp libdxmt_combined.a ../../app/Madeira/"
step dxmt-pe dxmtpe
step rppairing bash -c "rustup target add aarch64-apple-ios && bash build/rppairing-ios/build.sh"
step d3d12 bash build/madeira-d3d12/build-pe.sh
step faultrep bash build/faultrep/build.sh
step licenses bash build/stage-licenses.sh
step app xcodebuild -project app/Madeira.xcodeproj -scheme Madeira -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath $ROOT/../dd CODE_SIGNING_ALLOWED=NO 'OTHER_LDFLAGS=$(inherited) -lcurses' build
echo "GOTOWE: $(ls -d ../dd/Build/Products/Debug-iphoneos/Madeira.app)"
