/// BLE transport for gossip, built on the bluey library.
///
/// See `docs/superpowers/specs/2026-05-04-gossip-bluey-design.md` for the
/// full design rationale.
library;

// Facade
export 'src/facade/bluey_transport.dart'
    show BlueyTransport, PeerEvent, PeerConnected, PeerDisconnected;

// Domain value objects
export 'src/domain/value_objects/service_uuid.dart' show ServiceUuid;

// Domain events
export 'src/domain/events/connection_event.dart'
    show ConnectionEvent, PeerOpened, PeerClosed;

// Domain errors
export 'src/domain/errors/connection_error.dart'
    show
        ConnectionError,
        ConnectionErrorType,
        ConnectionNotFoundError,
        ConnectionLostError,
        ConnectFailedError,
        SendFailedError,
        ConnectionLimitReachedError,
        FrameDecodeError;

// Observability
export 'src/application/observability/log_level.dart'
    show LogLevel, LogCallback;
export 'src/application/observability/bluey_metrics.dart' show BlueyMetrics;
