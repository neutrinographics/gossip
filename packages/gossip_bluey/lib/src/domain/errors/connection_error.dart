import 'package:gossip/gossip.dart';

enum ConnectionErrorType {
  connectionNotFound,
  connectionLost,
  connectFailed,
  sendFailed,
  connectionLimitReached,
  frameDecode,
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
