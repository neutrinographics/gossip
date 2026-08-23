import 'dart:io';
import 'package:test/test.dart';

/// Part 2 spec: the machine-checked edge table.
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
  test('every import and export in lib/src obeys the edge table', () {
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
      // Adaptation: every lib import must
      // already be package-form — the context barrels (shared.dart,
      // sync.dart, membership.dart) are the one documented exception,
      // using relative *export* directives for their mechanical, full
      // re-export of their own context's files (ADR-010), which can never
      // reach outside that context without a relative import. A relative
      // *import* would silently escape the package-form regex below, so
      // fail loudly instead of trying to resolve it — that means a file
      // regressed to relative imports and must be normalized first, not
      // that the table is wrong. Un-anchored (no trailing `;` requirement)
      // so combinator forms like `import 'x.dart' show Y;` don't slip past.
      final relativeImports = RegExp(
        r"^import\s+'(?!dart:|package:)[^']*'",
        multiLine: true,
      ).allMatches(contents);
      for (final match in relativeImports) {
        violations.add(
          '${file.path}: relative import '
          '"${match.group(0)}" — normalize to package:gossip/src/... '
          'form first, then re-run this test',
        );
      }
      // Relative EXPORTS are legitimate only within a context (the barrels
      // hold same-context relative exports). Any `..` segment in a relative
      // import OR export can leave the context while matching neither regex
      // above — ban it outright; zero false positives against the tree.
      final parentEscapes = RegExp(
        r"^(import|export)\s+'(?!dart:|package:)[^']*\.\.[^']*'",
        multiLine: true,
      ).allMatches(contents);
      for (final match in parentEscapes) {
        violations.add(
          '${file.path}: relative ${match.group(1)} with a ".." segment '
          '"${match.group(0)}" — could cross a context boundary unseen; '
          'use package:gossip/src/... form',
        );
      }
      // Scans both `import` and `export` directives: the context barrels
      // are entirely `export` lines, so a walker that only matched `import`
      // would let a future cross-context `export` through silently.
      final crossModuleRefs = RegExp(
        r"(import|export)\s+'package:gossip/src/([a-z_]+)/",
      ).allMatches(contents);
      for (final match in crossModuleRefs) {
        final directive = match.group(1)!; // 'import' or 'export'
        final target = match.group(2)!;
        if (!allowed.contains(target)) {
          violations.add('${file.path} ${directive}s $target');
        }
        // The concession: a context importing another context must sit
        // under its own infrastructure/.
        if (target != module &&
            target != 'shared' &&
            module != 'coordinator' &&
            !file.path.contains('/$module/infrastructure/')) {
          violations.add(
            '${file.path} ${directive}s $target outside '
            'infrastructure/ (ACL concession violated)',
          );
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });
}
