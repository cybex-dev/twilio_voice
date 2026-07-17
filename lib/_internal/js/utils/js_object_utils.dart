// import 'dart:js_interop';
// TODO(cybex-dev) implement js_interop for js package
// ignore: deprecated_member_use
import 'package:js/js.dart';
// TODO(cybex-dev) implement js_interop for js_util package
// ignore: deprecated_member_use
import 'package:js/js_util.dart';

Map<String, String> jsToStringMap(dynamic jsonObject) {
  final map = <String, String>{};
  final keys = objectKeys(jsonObject);
  for (dynamic key in keys) {
    final value = getProperty(jsonObject, key);
    map[key] = value;
  }
  return map;
}

/// En/disables all audio tracks of a raw JS MediaStream via `track.enabled`.
/// Disabled tracks render silence; the stream itself stays active.
void setAudioTracksEnabled(dynamic mediaStream, bool enabled) {
  if (mediaStream == null) {
    return;
  }
  final tracks = callMethod(mediaStream, "getAudioTracks", []) as List<dynamic>;
  for (final track in tracks) {
    setProperty(track, "enabled", enabled);
  }
}

/// Stops all tracks of a raw JS MediaStream, releasing their sources.
void stopMediaStreamTracks(dynamic mediaStream) {
  if (mediaStream == null) {
    return;
  }
  final tracks = callMethod(mediaStream, "getTracks", []) as List<dynamic>;
  for (final track in tracks) {
    callMethod(track, "stop", []);
  }
}

@JS('JSON.stringify')
external String stringify(Object obj);

@JS('Object.keys')
external List<String> objectKeys(Object obj);

@JS('Array.from')
external Object toArray(dynamic source);