/// Cached audio route data from the latest native AudioRoute event.
///
/// This class stores the route string (e.g., 'bluetooth', 'speaker', 'earpiece')
/// and whether Bluetooth is available, as parsed from the native
/// `AudioRoute|<route>|bluetoothAvailable=<bool>` event string.
///
/// Used to avoid extra method channel round-trips when resolving audio state
/// in the BLoC after receiving a call event.
class AudioRouteData {
  /// The current audio route: 'bluetooth', 'speaker', 'earpiece', 'wired_headset', or 'receiver'.
  final String route;

  /// Whether a Bluetooth audio device is currently available/connected.
  final bool isBluetoothAvailable;

  const AudioRouteData({
    required this.route,
    required this.isBluetoothAvailable,
  });

  @override
  String toString() =>
      'AudioRouteData(route: $route, isBluetoothAvailable: $isBluetoothAvailable)';
}
