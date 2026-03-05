import 'active_call.dart';

/// Status of a call session, maps 1:1 to native connection states.
enum CallStatus {
  /// Call is ringing (native STATE_RINGING = 2)
  ringing,

  /// Call is active/connected (native STATE_ACTIVE = 4)
  active,

  /// Call is on hold (native STATE_HOLDING = 5)
  holding,

  /// Call has been disconnected (native STATE_DISCONNECTED = 6)
  disconnected,
}

/// Represents a single call session — one per concurrent call.
///
/// Mirrors what the native layers track per-call:
/// - Android: `TVCallConnection` in `activeConnections: HashMap<String, TVCallConnection>`
/// - iOS: `Call` in `self.calls: [UUID: Call]`
///
/// The BLoC uses a list of these (via [CallSessionManager]) instead of
/// individual `_heldCall*` shadow fields.
class CallSession {
  /// Twilio Call SID — unique identifier for this call.
  final String callSid;

  /// The [ActiveCall] data from the method channel (from/to/direction/customParams).
  final ActiveCall? activeCall;

  /// Current status of this call session.
  final CallStatus status;

  /// Connection status string (e.g., "Ringing", "Connected", "Disconnected").
  final String? connectionStatus;

  /// Display name of the caller (resolved from contacts or server).
  final String? callerName;

  /// Phone number of the caller.
  final String? callerNumber;

  /// The local user's phone number for this call.
  final String? myNumber;

  /// Profile details fetched for the caller (avatar, company, etc.).
  final Map<String, dynamic>? callerProfileDetails;

  /// When this call session was created.
  final DateTime startedAt;

  /// Whether this is an incoming or outgoing call.
  final CallDirection direction;

  /// Whether this call was muted when it was placed on hold.
  /// Used to restore mute state after unholding.
  final bool isMuted;

  const CallSession({
    required this.callSid,
    this.activeCall,
    required this.status,
    this.connectionStatus,
    this.callerName,
    this.callerNumber,
    this.myNumber,
    this.callerProfileDetails,
    required this.startedAt,
    required this.direction,
    this.isMuted = false,
  });

  /// Creates a copy with the given fields replaced.
  CallSession copyWith({
    String? callSid,
    ActiveCall? activeCall,
    CallStatus? status,
    String? connectionStatus,
    String? callerName,
    String? callerNumber,
    String? myNumber,
    Map<String, dynamic>? callerProfileDetails,
    DateTime? startedAt,
    CallDirection? direction,
    bool? isMuted,
    // Explicit null setters for nullable fields
    bool clearActiveCall = false,
    bool clearCallerProfileDetails = false,
  }) {
    return CallSession(
      callSid: callSid ?? this.callSid,
      activeCall: clearActiveCall ? null : (activeCall ?? this.activeCall),
      status: status ?? this.status,
      connectionStatus: connectionStatus ?? this.connectionStatus,
      callerName: callerName ?? this.callerName,
      callerNumber: callerNumber ?? this.callerNumber,
      myNumber: myNumber ?? this.myNumber,
      callerProfileDetails: clearCallerProfileDetails
          ? null
          : (callerProfileDetails ?? this.callerProfileDetails),
      startedAt: startedAt ?? this.startedAt,
      direction: direction ?? this.direction,
      isMuted: isMuted ?? this.isMuted,
    );
  }

  /// Whether this call is currently active (not held, ringing, or disconnected).
  bool get isActive => status == CallStatus.active;

  /// Whether this call is currently on hold.
  bool get isHolding => status == CallStatus.holding;

  /// Whether this call is ringing (incoming or outgoing ring).
  bool get isRinging => status == CallStatus.ringing;

  /// Whether this call has been disconnected.
  bool get isDisconnected => status == CallStatus.disconnected;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CallSession &&
          runtimeType == other.runtimeType &&
          callSid == other.callSid &&
          activeCall == other.activeCall &&
          status == other.status &&
          connectionStatus == other.connectionStatus &&
          callerName == other.callerName &&
          callerNumber == other.callerNumber &&
          myNumber == other.myNumber &&
          startedAt == other.startedAt &&
          direction == other.direction &&
          isMuted == other.isMuted;

  @override
  int get hashCode =>
      callSid.hashCode ^
      activeCall.hashCode ^
      status.hashCode ^
      connectionStatus.hashCode ^
      callerName.hashCode ^
      callerNumber.hashCode ^
      myNumber.hashCode ^
      startedAt.hashCode ^
      direction.hashCode ^
      isMuted.hashCode;

  @override
  String toString() {
    return 'CallSession{'
        'callSid: $callSid, '
        'status: $status, '
        'callerName: $callerName, '
        'callerNumber: $callerNumber, '
        'direction: $direction, '
        'connectionStatus: $connectionStatus, '
        'isMuted: $isMuted'
        '}';
  }
}
