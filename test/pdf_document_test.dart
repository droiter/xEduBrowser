import 'package:flutter_test/flutter_test.dart';
import 'package:tablet_browser/bookmarks/bookmark.dart';
import 'package:tablet_browser/files/local_file_url.dart';
import 'package:tablet_browser/pdf/pdf_document.dart';

/// The page maths and address handling of the PDF reader.
void main() {
  group('PdfPager', () {
    test('starts at the first page and reports it 1-based', () {
      final pager = PdfPager(pageCount: 5);
      expect(pager.index, 0);
      expect(pager.pageNumber, 1);
      expect(pager.label, '1 / 5');
      expect(pager.canGoPrevious, isFalse);
      expect(pager.canGoNext, isTrue);
    });

    test('turning clamps at both ends', () {
      final pager = PdfPager(pageCount: 3);
      expect(pager.previous(), isFalse, reason: '第一页再往前没有变化');
      expect(pager.next(), isTrue);
      expect(pager.next(), isTrue);
      expect(pager.label, '3 / 3');
      expect(pager.canGoNext, isFalse);
      expect(pager.next(), isFalse);
      expect(pager.goTo(99), isFalse);
      expect(pager.index, 2);
      expect(pager.goTo(-5), isTrue);
      expect(pager.index, 0);
    });

    test('an empty or single-page document is handled', () {
      final empty = PdfPager(pageCount: 0);
      expect(empty.isEmpty, isTrue);
      expect(empty.label, '- / -');
      expect(empty.next(), isFalse);
      expect(empty.previous(), isFalse);

      final single = PdfPager(pageCount: 1);
      expect(single.canGoNext, isFalse);
      expect(single.canGoPrevious, isFalse);
      expect(single.label, '1 / 1');
    });

    test('a tap zone is the outer thirds', () {
      const width = 900.0;
      expect(PdfPager.zoneForTap(10, width), PdfTapZone.previous);
      expect(PdfPager.zoneForTap(299, width), PdfTapZone.previous);
      expect(PdfPager.zoneForTap(450, width), PdfTapZone.toggleChrome);
      expect(PdfPager.zoneForTap(601, width), PdfTapZone.next);
      expect(PdfPager.zoneForTap(890, width), PdfTapZone.next);
      // A degenerate width must not divide by zero.
      expect(PdfPager.zoneForTap(10, 0), PdfTapZone.toggleChrome);
    });
  });

  group('PdfDocuments', () {
    test('recognises a local PDF address', () {
      expect(LocalFileUrl.isPdf('file:///sdcard/ebooks/说明.pdf'), isTrue);
      expect(LocalFileUrl.isPdf('/sdcard/ebooks/READ%20ME.PDF'), isTrue);
      expect(LocalFileUrl.isPdf('file:///sdcard/ebooks/a.html'), isFalse);
      expect(LocalFileUrl.isPdf('https://school.test/notes.pdf'), isTrue);
    });

    test('only local PDFs get a path to render', () {
      expect(
        PdfDocuments.localPathOf('file:///sdcard/%E8%AF%BE%E4%BB%B6/a.pdf'),
        '/sdcard/课件/a.pdf',
      );
      expect(PdfDocuments.localPathOf('/sdcard/a.pdf'), '/sdcard/a.pdf');
      // Remote PDFs are not rendered by the platform renderer.
      expect(PdfDocuments.localPathOf('https://school.test/a.pdf'), isNull);
      expect(PdfDocuments.localPathOf('file:///sdcard/a.html'), isNull);
    });

    test('the fallback title is the file name without its extension', () {
      expect(PdfDocuments.titleFor('file:///sdcard/ebooks/READ%20ME!.pdf'),
          'READ ME!');
      expect(PdfDocuments.titleFor('/sdcard/no-extension'), 'no-extension');
    });
  });

  group('PdfPageText', () {
    test('parses normalised lines and hit-tests a tap', () {
      final PdfPageText? page = PdfPageText.fromMap(<String, dynamic>{
        'width': 595.0,
        'height': 842.0,
        'lines': <Object?>[
          <String, Object?>{
            'text': ' 第一行 ',
            'left': 0.1,
            'top': 0.2,
            'right': 0.6,
            'bottom': 0.25,
          },
          <String, Object?>{
            'text': '第二行',
            'left': 0.1,
            'top': 0.3,
            'right': 0.9,
            'bottom': 0.35,
          },
        ],
      });
      expect(page, isNotNull);
      expect(page!.hasText, isTrue);
      expect(page.lines.first.text, '第一行');
      expect(page.aspectRatio, closeTo(842 / 595, 0.0001));
      expect(page.lineAt(0.2, 0.22)?.text, '第一行');
      expect(page.lineAt(0.8, 0.32)?.text, '第二行');
      expect(page.lineAt(0.95, 0.22), isNull);
    });

    test('drops malformed lines and falls back without a page size', () {
      expect(PdfPageText.fromMap(<String, dynamic>{'lines': <Object?>[]}), isNull);
      final page = PdfPageText.fromMap(<String, dynamic>{
        'width': 0,
        'height': 0,
        'lines': <Object?>[
          <String, Object?>{
            'text': '只有文字',
            'left': 0.2,
            'top': 0.4,
            'right': 0.5,
            'bottom': 0.45,
          },
          <String, Object?>{
            'text': '',
            'left': 0.1,
            'top': 0.1,
            'right': 0.2,
            'bottom': 0.2,
          },
          <String, Object?>{
            'text': '倒过来',
            'left': 0.8,
            'top': 0.8,
            'right': 0.2,
            'bottom': 0.9,
          },
        ],
      });
      expect(page, isNotNull);
      expect(page!.lines, hasLength(1));
      expect(page.lines.single.text, '只有文字');
      expect(page.width, greaterThan(0));
      expect(page.height, greaterThan(0));
    });
  });

  group('whitelist grant', () {
    test('a PDF grants the file itself, not its whole folder', () {
      // The reader opens the file directly, so the sibling pages of a course
      // folder do not need to be allowed.
      expect(
        BookmarkWhitelist.grantPatterns('file:///sdcard/course/%E8%AF%BE.pdf'),
        ['file:///sdcard/course/%E8%AF%BE.pdf'],
      );
      // A local HTML page still gets its folder.
      expect(
        BookmarkWhitelist.grantPatterns('file:///sdcard/course/%E8%AF%BE.html'),
        [
          'file:///sdcard/course/%E8%AF%BE.html',
          'file:///sdcard/course/',
        ],
      );
    });
  });
}
