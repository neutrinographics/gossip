import 'dart:io';
import 'package:test/test.dart';

/// Part 2 spec: the machine-checked edge table (fluent's CA2-3 pattern).
/// The table IS the architecture; adding an edge means editing this test
/// in a reviewed diff.
const Map<String, Set<String>> edges = {
  'shared': {'shared'},
  // 'membership' allowed ONLY from sync/infrastructure/ (checked below).
  'sync': {'sync', 'shared', 'membership'},
  'membership': {'membership', 'shared'},
  // Composition root: may import everything. It is the graph's sink —
  // "nothing imports it" is enforced by its absence from every other row.
  'coordinator': {'coordinator', 'shared', 'sync', 'membership'},
};

void main() {
  test('every import in lib/src obeys the edge table', () {
    final violations = <String>[];
    final files = Directory('lib/src')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final module = file.path.split('/')[2]; // lib/src/<module>/...
      final allowed = edges[module];
      if (allowed == null) {
        violations.add(
          '${file.path}: unknown module "$module" — '
          'extend the edge table in a reviewed diff',
        );
        continue;
      }
      final contents = file.readAsStringSync();
      // Adaptation (per Task 5's normalization): every lib import must
      // already be package-form. A relative import would silently escape
      // this walker's regex, so fail loudly instead of trying to resolve
      // it — that means a file regressed to relative imports and must be
      // normalized first, not that the table is wrong.
      final relativeImports = RegExp(
        r"^import\s+'(?!dart:|package:)[^']*';",
        multiLine: true,
      ).allMatches(contents);
      for (final match in relativeImports) {
        violations.add(
          '${file.path}: relative import '
          '"${match.group(0)}" — normalize to package:gossip/src/... '
          'form first (Task 5), then re-run this test',
        );
      }
      final imports = RegExp(
        "import 'package:gossip/src/([a-z_]+)/",
      ).allMatches(contents).map((m) => m.group(1)!);
      for (final target in imports) {
        if (!allowed.contains(target)) {
          violations.add('${file.path} imports $target');
        }
        // The concession: a context importing another context must sit
        // under its own infrastructure/.
        if (target != module &&
            target != 'shared' &&
            module != 'coordinator' &&
            !file.path.contains('/$module/infrastructure/')) {
          violations.add(
            '${file.path} imports $target outside '
            'infrastructure/ (ACL concession violated)',
          );
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
