# PDFBox-Android (text extraction in the PDF reader).
#
# The library references optional encryption (BouncyCastle) and JPEG-2000
# (jp2-android) code paths. The reader only needs the text layer of ordinary
# local PDFs, and both dependencies are absent on purpose; suppress R8's
# missing-class warnings instead of pulling ~7 MB of unused code in.
-dontwarn com.gemalto.jp2.**
-dontwarn org.bouncycastle.**

# PDFBox resolves fonts, security handlers and document-interchange handlers by
# name; keep the library intact so R8 cannot remove a class reflection may ask
# for.
-keep class com.tom_roush.pdfbox.** { *; }
-keep class com.tom_roush.fontbox.** { *; }
