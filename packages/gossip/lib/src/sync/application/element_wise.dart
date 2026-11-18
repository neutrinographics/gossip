/// Whether [a] and [b] hold equal elements in the same order.
///
/// `package:collection` is not a dependency of this package, and the budgeter's
/// result values need list equality only.
bool elementWiseEqual<T>(List<T> a, List<T> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
