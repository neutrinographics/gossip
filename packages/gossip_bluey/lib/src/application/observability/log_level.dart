/// Unified logging surface.
///
/// Re-exports `LogLevel` and `LogCallback` from the `gossip` package so
/// applications get the same logging API regardless of which transport
/// they use.
library;

export 'package:gossip/gossip.dart' show LogLevel, LogCallback;
