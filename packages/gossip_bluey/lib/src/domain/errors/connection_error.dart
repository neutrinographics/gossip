import 'package:gossip/gossip.dart';

import '../value_objects/rejection_reason.dart';

enum ConnectionErrorType {
  connectionNotFound,
  connectionLost,
  connectFailed,
  sendFailed,
  connectionLimitReached,
  frameDecode,
  connectionRejectedByPeer,
}

/// Sealed base class for errors emitted on `BlueyTransport.errors`.
sealed class ConnectionError {
  final String message;
  final DateTime occurredAt;
  final ConnectionErrorType type;
  final Object? cause;

  const ConnectionError({
    required this.message,
    required this.occurredAt,
    required this.type,
    this.cause,
  });

  @override
  String toString() => '${type.name}: $message';
}

final class ConnectionNotFoundError extends ConnectionError {
  final NodeId nodeId;
  const ConnectionNotFoundError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.connectionNotFound);
}

final class ConnectionLostError extends ConnectionError {
  final NodeId nodeId;
  const ConnectionLostError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.connectionLost);
}

final class ConnectFailedError extends ConnectionError {
  final NodeId nodeId;
  const ConnectFailedError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.connectFailed);
}

final class SendFailedError extends ConnectionError {
  final NodeId nodeId;
  const SendFailedError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.sendFailed);
}

final class ConnectionLimitReachedError extends ConnectionError {
  final NodeId nodeId;
  const ConnectionLimitReachedError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.connectionLimitReached);
}

final class FrameDecodeError extends ConnectionError {
  final NodeId nodeId;
  const FrameDecodeError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    super.cause,
  }) : super(type: ConnectionErrorType.frameDecode);
}

/// The remote peer rejected our connection via an in-band GSP2 control
/// frame (COR3-21) — e.g. it is at its connection cap. We closed our own
/// link in response; retrying later is legitimate (a slot may free up).
final class ConnectionRejectedByPeerError extends ConnectionError {
  final NodeId nodeId;
  final RejectionReason reason;
  const ConnectionRejectedByPeerError({
    required super.message,
    required super.occurredAt,
    required this.nodeId,
    required this.reason,
    super.cause,
  }) : super(type: ConnectionErrorType.connectionRejectedByPeer);
}
