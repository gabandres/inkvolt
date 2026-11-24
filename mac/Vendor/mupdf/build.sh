#!/bin/sh
# Builds MuPDF for Inkvolt PDF on the Mac: a static XCFramework (arm64 and x86_64, macOS 15) with MuPDF's headers and a
# module map, so Swift imports it as CMuPDF. Run on the Mac:
#   sh mac/Vendor/mupdf/build.sh            MuPDF 1.25.2, the Windows app's version (pdf/THIRD-PARTY-NOTICES.md)
#   MUPDF_TAG=1.26.0 sh mac/Vendor/mupdf/build.sh
# MuPDF's source (AGPL-3.0, with its third-party libraries as submodules) is cloned at the tag into
# ~/build-artifacts/mupdf, never into the repo; the XCFramework goes to mac/InkvoltPdfKit/Frameworks (not in git).
# No X11, OpenGL or curl; everything else MuPDF builds (its fonts, HarfBuzz, FreeType, the image codecs, mujs) is in.
# patches/*.patch are applied to the clone (each says why and what to report upstream); the patches' hash names the
# source and stage folders, so a patched build never mixes with a plain one or another set of patches.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
tag="${MUPDF_TAG:-1.25.2}"
work="$HOME/build-artifacts/mupdf"
patches=""
for p in "$here"/patches/*.patch; do
  if [ -e "$p" ]; then patches="$patches $p"; fi
done
id=""
if [ -n "$patches" ]; then id="-$(cat $patches | shasum | cut -c1-8)"; fi
src="$work/mupdf-$tag$id"
out="$here/../../InkvoltPdfKit/Frameworks"
jobs="$(sysctl -n hw.ncpu)"
mkdir -p "$work"

# A worktree's Frameworks may be a link to the release clone's (`mac.sh`'s slots): building through it would replace
# what the release clone links. Build in the release clone, or put a folder in the link's place first.
if [ -L "$out" ]; then
  echo "$out is a link to $(readlink "$out"); build MuPDF there, or replace the link with a folder" >&2
  exit 1
fi

if [ ! -e "$src/.inkvolt-ready" ]; then
  rm -rf "$src"
  git clone --quiet --depth 1 --branch "$tag" --recurse-submodules --shallow-submodules \
    https://github.com/ArtifexSoftware/mupdf.git "$src"
  for p in $patches; do git -C "$src" apply "$p"; done
  touch "$src/.inkvolt-ready"
fi

# One build per architecture; the first also makes MuPDF's generated sources (its fonts), which the second reuses.
# -Dfdopen=fdopen: MuPDF's zlib takes macOS's TARGET_OS_MAC for classic Mac OS and defines fdopen as NULL, which breaks
# the SDK's own declaration; defined as itself, zlib leaves it alone.
for arch in arm64 x86_64; do
  make -C "$src" -j"$jobs" build=release OUT="build/release-$arch" \
    XCFLAGS="-arch $arch -mmacosx-version-min=15.0 -Dfdopen=fdopen" XLDFLAGS="-arch $arch -mmacosx-version-min=15.0" \
    HAVE_X11=no HAVE_GLUT=no HAVE_CURL=no HAVE_GLFW=no libs
done

stage="$work/stage-$tag$id"
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
printf '%s\n' "$tag$id" > "$out/MuPDF.version"
echo "MuPDF $tag$id:$out/MuPDF.xcframework ($(du -sh "$out/MuPDF.xcframework" | cut -f1))"
