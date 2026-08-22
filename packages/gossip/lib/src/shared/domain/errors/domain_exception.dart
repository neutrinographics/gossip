/// Exception thrown when domain invariants are violated.
///
/// [DomainException] represents programming errors or invalid operations
/// that violate business rules. These are typically unrecoverable and
/// indicate bugs in the calling code.
///
/// Common scenarios:
/// - Adding the local node as a peer (invalid operation)
/// - Removing a non-existent peer
/// - Adding duplicate members to a channel
/// - Attempting operations on non-existent aggregates
///
/// These exceptions should not be caught and handled during normal operation.
/// They indicate that the caller has violated preconditions or invariants.
class DomainException implements Exception {
  /// Human-readable description of the invariant violation.
  final String message;

  /// Creates a [DomainException] with the given error message.
  const DomainException(this.message);

  @override
  String toString() => 'DomainException: $message';
}
