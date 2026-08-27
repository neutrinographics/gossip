/// Constrains [value] to `[min, max]`, saturating rather than throwing.
///
/// A single home for "keep a Duration inside its bounds" — hand-rolled
/// clamping scattered across the library is free to drift into
/// inconsistent bounds.
Duration clampDuration(
  Duration value, {
  required Duration min,
  required Duration max,
}) {
  if (value < min) return min;
  if (value > max) return max;
  return value;
}
