# Vendored PDF libraries

`pdfbox-android-2.0.27.0.aar` is the AWT-free Android port of Apache PDFBox 2.0,
from the `TomRoush/PdfBox-Android` project (Apache License 2.0). It is vendored
so the Android build does not depend on network access to Maven Central.

It is used only by `PdfTextExtractor.kt`, to read the PDF text layer (lines plus
their bounding boxes) for the reader's tap-to-speak. Android's own `PdfRenderer`
can only produce page bitmaps and exposes no text.

- version: 2.0.27.0
- sha256: `30277f879cfd571db2a137582c95516a0d4ea6778e945519bc58ca93d57d88c7`
- upstream: https://github.com/TomRoush/PdfBox-Android
- license: Apache License 2.0 (https://www.apache.org/licenses/LICENSE-2.0)

`PdfBoxResourceLoader` reads the glyph lists and CMaps from the AAR's `assets/`
directory; those are merged into the APK automatically. Optional encryption
(BouncyCastle) and JPEG-2000 (jp2-android) code paths are not shipped; see
`android/app/proguard-rules.pro`.
