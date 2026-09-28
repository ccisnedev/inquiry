import 'package:modular_cli_sdk/modular_cli_sdk.dart';
import 'package:test/test.dart';

import 'package:inquiry_cli/inquiry_cli.dart';
import 'package:inquiry_cli/src/version.dart';

void main() {
  group('inquiry version', () {
    // `version` is registered by `modular_cli_sdk`'s own `VersionPlugin`
    // (ccisnedev/inquiry#321), which reports `<name>: <version>` rather than
    // the bare version string the CLI's own command used to print.
    test('reports name and version', () async {
      final query = VersionQuery(
        VersionInput(),
        name: 'inquiry',
        version: inquiryVersion,
      );
      final output = await query.execute();

      expect(output.exitCode, 0);
      expect(output.name, 'inquiry');
      expect(output.version, inquiryVersion);
      expect(output.toText(), 'inquiry: $inquiryVersion');
    });

    test('version matches expected format', () {
      expect(inquiryVersion, matches(RegExp(r'^\d+\.\d+\.\d+$')));
    });

    test('normalizes global version flags to the version command', () {
      expect(
        normalizeInquiryArgs(const ['--version']),
        equals(const ['version']),
      );
      expect(normalizeInquiryArgs(const ['-v']), equals(const ['version']));
      expect(
        normalizeInquiryArgs(const ['version']),
        equals(const ['version']),
      );
      expect(
        normalizeInquiryArgs(const ['host', 'get']),
        equals(const ['host', 'get']),
      );
    });
  });
}
