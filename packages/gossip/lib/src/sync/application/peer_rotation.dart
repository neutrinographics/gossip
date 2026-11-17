import 'package:meta/meta.dart';
import 'package:gossip/src/sync/application/recency.dart';

/// What one peer has last been offered in each of the three lists: the
/// request, the response and the announcements.
@immutable
class PeerRotation {
  final Recency request;
  final Recency response;
  final Recency announce;

  const PeerRotation({
    this.request = Recency.initial,
    this.response = Recency.initial,
    this.announce = Recency.initial,
  });

  PeerRotation copyWith({
    Recency? request,
    Recency? response,
    Recency? announce,
  }) => PeerRotation(
    request: request ?? this.request,
    response: response ?? this.response,
    announce: announce ?? this.announce,
  );

  @override
  bool operator ==(Object other) =>
      other is PeerRotation &&
      other.request == request &&
      other.response == response &&
      other.announce == announce;

  @override
  int get hashCode => Object.hash(request, response, announce);

  @override
  String toString() => 'PeerRotation($request, $response, $announce)';
}
