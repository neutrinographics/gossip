import 'package:gossip/gossip.dart';

import '../value_objects/device_id.dart';

/// Base class for recoverable connection errors.
///
/// [ConnectionError] represents expected failures during BLE transport
/// operations:
/// - Connection failures (not found, disconnected)
/// - Handshake failures (timeout, invalid data)
/// - Send failures (network issues)
///
/// Applications should observe the error stream from `BleTransport`
/// to log errors, implement retry policies, or alert users.
sealed class ConnectionError {
  /// Human-readable description of the error.
  final String message;

  /// When the error occurred.
  final DateTime occurredAt;

  /// Classification of the error type.
  final ConnectionErrorType type;

  /// Original exception or error that caused this failure (if available).
  final Object? cause;

  const ConnectionError(
    this.message, {
    required this.occurredAt,
    required this.type,
    this.cause,
  });
}

/// Error when trying to communicate with a peer that has no active connection.
final class ConnectionNotFoundError extends ConnectionError {
  /// The NodeId that was not found.
  final NodeId nodeId;

  const ConnectionNotFoundError(
    this.nodeId,
    super.message, {
    required super.occurredAt,
    super.cause,
  }) : super(type: ConnectionErrorType.connectionNotFound);

  @override
  String toString() =>
      'ConnectionNotFoundError(nodeId: $nodeId, message: $message)';
}

/// Error when handshake didn't complete within the timeout period.
final class HandshakeTimeoutError extends ConnectionError {
  /// The device that timed out.
  final DeviceId deviceId;

  const HandshakeTimeoutError(
    this.deviceId,
    super.message, {
    required super.occurredAt,
    super.cause,
  }) : super(type: ConnectionErrorType.handshakeTimeout);

  @override
  String toString() =>
      'HandshakeTimeoutError(deviceId: $deviceId, message: $message)';
}

/// Error when received malformed handshake data.
final class HandshakeInvalidError extends ConnectionError {
  /// The device that sent invalid data.
  final DeviceId deviceId;

  const HandshakeInvalidError(
    this.deviceId,
    super.message, {
    required super.occurredAt,
    super.cause,
  }) : super(type: ConnectionErrorType.handshakeInvalid);

  @override
  String toString() =>
      'HandshakeInvalidError(deviceId: $deviceId, message: $message)';
}

/// Error when failed to send bytes over BLE.
final class SendFailedError extends ConnectionError {
  /// The destination NodeId.
  final NodeId nodeId;

  const SendFailedError(
    this.nodeId,
    super.message, {
    required super.occurredAt,
    super.cause,
  }) : super(type: ConnectionErrorType.sendFailed);

  @override
  String toString() => 'SendFailedError(nodeId: $nodeId, message: $message)';
}

/// Error when connection was unexpectedly lost.
final class ConnectionLostError extends ConnectionError {
  /// The NodeId that disconnected.
  final NodeId nodeId;

  const ConnectionLostError(
    this.nodeId,
    super.message, {
    required super.occurredAt,
    super.cause,
  }) : super(type: ConnectionErrorType.connectionLost);

  @override
  String toString() =>
      'ConnectionLostError(nodeId: $nodeId, message: $message)';
}

/// Categories of connection errors.
enum ConnectionErrorType {
  /// Tried to send to a NodeId with no active connection.
  connectionNotFound,

  /// Connection was unexpectedly lost.
  connectionLost,

  /// Handshake didn't complete in time.
  handshakeTimeout,

  /// Received malformed handshake data.
  handshakeInvalid,

  /// Failed to send bytes over the transport.
  sendFailed,
}
