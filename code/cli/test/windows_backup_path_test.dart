import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:inquiry_cli/hosts/windows_platform_ops.dart';

/// `selfReplace` renames the running exe out of the way before copying the new
/// one in. Choosing that name used to assume any leftover `<exe>.bak` could be
/// deleted — and when a stray `inquiry.exe host get` process still held it,
/// the whole upgrade aborted with an error naming a temp file rather than the
/// cause.
void main() {
  late Directory tempDir;
  late String exePath;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('iq_bak_test_');
    exePath = p.join(tempDir.path, 'inquiry.exe');
    File(exePath).writeAsStringSync('binary');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  group('freeBackupPath', () {
    test('uses .bak when nothing is in the way', () {
      expect(freeBackupPath(exePath), '$exePath.bak');
    });

    test('reclaims a leftover .bak that can be deleted', () {
      File('$exePath.bak').writeAsStringSync('previous binary');

      expect(freeBackupPath(exePath), '$exePath.bak');
      expect(File('$exePath.bak').existsSync(), isFalse);
    });

    test(
      'steps over a locked .bak instead of failing the upgrade',
      () {
        // A locked file is only reproducible on Windows: elsewhere an open
        // handle does not prevent deletion, which is exactly why this defect
        // was invisible until it ran on a real Windows machine.
        final bak = File('$exePath.bak')..writeAsStringSync('locked binary');
        final handle = bak.openSync(mode: FileMode.write);
        addTearDown(() {
          handle.closeSync();
          if (bak.existsSync()) bak.deleteSync();
        });

        expect(freeBackupPath(exePath), '$exePath.bak1');
        // The locked one is left alone rather than half-removed.
        expect(bak.existsSync(), isTrue);
      },
      skip: Platform.isWindows ? false : 'file locking is Windows-only',
    );

    test('the error names the real cause when nothing can be freed', () {
      // Simulated by exhausting every candidate with undeletable entries:
      // a directory cannot be removed by File.deleteSync on any platform.
      for (var i = 0; i < 20; i++) {
        Directory('$exePath.bak${i == 0 ? '' : i}').createSync();
      }

      expect(
        () => freeBackupPath(exePath),
        throwsA(
          isA<FileSystemException>().having(
            (e) => e.message,
            'message',
            allOf(contains('still running'), contains('Get-Process inquiry')),
          ),
        ),
      );
    });
  });
}
