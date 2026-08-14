import 'call_quality_warning.dart';

/// A change in the set of active [CallQualityWarning]s for a call.
class CallQualityEvent {
  /// The full set of warnings now active. Empty once quality has recovered.
  final Set<CallQualityWarning> current;

  /// The set of warnings active immediately before this change.
  final Set<CallQualityWarning> previous;

  const CallQualityEvent({
    required this.current,
    required this.previous,
  });

  /// Warnings newly raised by this change.
  Set<CallQualityWarning> get raised => current.difference(previous);

  /// Warnings newly cleared by this change.
  Set<CallQualityWarning> get cleared => previous.difference(current);

  /// Whether any warning is currently active for this call.
  bool get hasWarnings => current.isNotEmpty;

  @override
  String toString() => 'CallQualityEvent{current: $current, previous: $previous}';
}