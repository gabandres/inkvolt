# Third-party notices

Inkvolt PDF for Mac includes the following third-party software. Each component is used under the license named here.
`assemble.sh` bundles this file, Sparkle's license text (`Sparkle-LICENSE.txt`) and the AGPL (`LICENSE.txt`) in the app,
and About Inkvolt PDF shows them. Everything else the app uses is part of macOS (AppKit, Core Text, JavaScriptCore,
Vision, ImageCaptureCore, Security).

| Component | Version | License | Copyright | Source |
|---|---|---|---|---|
| MuPDF (built from source as a static library, `mac/Vendor/mupdf/build.sh`) | 1.25.2 | AGPL-3.0-only | Artifex Software, Inc. | https://mupdf.com, https://github.com/ArtifexSoftware/mupdf |
| Sparkle (updates) | 2.10.1 | MIT, with the external licenses in its LICENSE file (bsdiff: BSD-2-Clause; sais-lite: MIT; ed25519: zlib) | Andy Matuschak and the Sparkle Project contributors | https://github.com/sparkle-project/Sparkle |
| InkvoltPrintKit (Inkvolt Print's scanning and What's New code, in this repository) | | MIT | Bermudez Systems LLC | https://github.com/gabandres/inkvolt |

## Libraries built into MuPDF

MuPDF's static library includes its third-party libraries, among them:

| Component | License |
|---|---|
| jbig2dec | AGPL-3.0 (Artifex) |
| extract | AGPL-3.0 (Artifex) |
| MuJS | ISC |
| FreeType | FreeType License (FTL) |
| HarfBuzz | MIT ("Old MIT") |
| Little CMS (lcms2mt, Artifex fork) | MIT |
| libjpeg (Independent JPEG Group) | IJG License |
| OpenJPEG | BSD-2-Clause |
| zlib | Zlib |
| Gumbo | Apache-2.0 |

The complete list and license texts are in the MuPDF 1.25.2 source distribution (`thirdparty/` and `COPYING`).

## MuPDF and the AGPL

MuPDF is licensed under the GNU Affero General Public License v3.0 (https://www.gnu.org/licenses/agpl-3.0.html), and so
is Inkvolt PDF for Mac. MuPDF's complete source code is available from https://mupdf.com/releases and
https://github.com/ArtifexSoftware/mupdf (tag 1.25.2); Inkvolt PDF's, including the build scripts, from
https://github.com/gabandres/inkvolt.
