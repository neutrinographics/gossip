/// Constrains [value] to `[min, max]`, saturating rather than throwing.
///
/// A single home for "keep a Duration inside its bounds" — an audit found
/// three hand-rolled variants of this operation scattered across the
/// library, each free to drift from the others.
Duration clampDuration(
  Duration value, {
  required Duration min,
  required Duration max,
}) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}
