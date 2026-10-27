#!/bin/sh
# Builds MuPDF for Inkvolt PDF on the Mac: a static XCFramework (arm64 and x86_64, macOS 15) with MuPDF's headers and a
# module map, so Swift imports it as CMuPDF. Run on the Mac:
#   sh mac/Vendor/mupdf/build.sh            MuPDF 1.25.2, the Windows app's version (pdf/THIRD-PARTY-NOTICES.md)
#   MUPDF_TAG=1.26.0 sh mac/Vendor/mupdf/build.sh
# MuPDF's source (AGPL-3.0, with its third-party libraries as submodules) is cloned at the tag into
# ~/build-artifacts/mupdf, never into the repo; the XCFramework goes to mac/InkvoltPdfKit/Frameworks (not in git).
# No X11, OpenGL or curl; everything else MuPDF builds (its fonts, HarfBuzz, FreeType, the image codecs, mujs) is in.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
tag="${MUPDF_TAG:-1.25.2}"
work="$HOME/build-artifacts/mupdf"
src="$work/mupdf-$tag"
out="$here/../../InkvoltPdfKit/Frameworks"
jobs="$(sysctl -n hw.ncpu)"
mkdir -p "$work"

if [ ! -d "$src" ]; then
  git clone --quiet --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules \
    https://github.com/ArtifexSoftware/mupdf.git "$src"
fi

# One build per architecture; the first also makes MuPDF's generated sources (its fonts), which the second reuses.
# -Dfdopen=fdopen: MuPDF's zlib takes macOS's TARGET_OS_MAC for classic Mac OS and defines fdopen as NULL, which breaks
# the SDK's own declaration; defined as itself, zlib leaves it alone.
for arch in arm64 x86_64; do
  make -C "$src" -j"$jobs" build=release OUT="build/release-$arch" \
    XCFLAGS="-arch $arch -mmacosx-version-min=15.0 -Dfdopen=fdopen" XLDFLAGS="-arch $arch -mmacosx-version-min=15.0" \
    HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no HAVE_GLFW=no libs
done

stage="$work/stage-$tag"
rm -rf "$stage"
mkdir -p "$stage/lib" "$stage/include"
for arch in arm64 x86_64; do
  libtool -static -o "$stage/lib/libmupdf-$arch.a" \
    "$src/build/release-$arch/libmupdf.a" "$src/build/release-$arch/libmupdf-third.a"
done
lipo -create "$stage/lib/libmupdf-arm64.a" "$stage/lib/libmupdf-x86_64.a" -output "$stage/lib/libmupdf.a"
cp -R "$src/include/mupdf" "$stage/include/"
cat > "$stage/include/module.modulemap" <<'EOF'
module CMuPDF {
    header "mupdf/fitz.h"
    header "mupdf/pdf.h"
    link "z"
    export *
}
EOF

mkdir -p "$out"
rm -rf "$out/MuPDF.xcframework"
xcodebuild -create-xcframework -library "$stage/lib/libmupdf.a" -headers "$stage/include" \
  -output "$out/MuPDF.xcframework" >/dev/null
printf '%s\n' "$tag" > "$out/MuPDF.version"
echo "MuPDF $tag: $out/MuPDF.xcframework ($(du -sh "$out/MuPDF.xcframework" | cut -f1))"
