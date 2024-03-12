import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:cloud_functions/cloud_functions.dart';

import 'utils.dart';

class Result {
  final String identity;
  final String accessToken;

  Result(this.identity, this.accessToken);
}

/// Register with a local token generator using URL http://localhost:3000/token. This is a function to generate token for twilio voice.
/// [generateLocalAccessToken] is the default method for registering
///
/// Returned data should contained the following format:
/// {
///  "identity": "user123",
///  "token": "ey...",
/// }
Future<Result?> generateLocalAccessToken() async {
  printDebug("voip-registering with token ");
  printDebug("GET http://localhost:3000/token");

  final uri = Uri.http("localhost:3000", "/token");
  final result = await http.get(uri);
  if (result.statusCode >= 200 && result.statusCode < 300) {
    printDebug("Error requesting token from server [${uri.toString()}]");
    printDebug(result.body);
    return null;
  }
  final data = jsonDecode(result.body);
  final identity = data["identity"] as String?;
  final token = data["token"] as String?;

  if (identity == null || token == null) {
    printDebug("Error requesting token from server [${uri.toString()}]");
    printDebug(result.body);
    return null;
  }
  return Result(identity, token);
}

/// Register with a firebase function token generator using function name 'voice-accessToken', this is a function to generate token for twilio voice.
///
/// Returned data should contained the following format:
/// {
///  "identity": "user123",
///  "token": "ey...",
/// }
///
Future<Result?> generateFirebaseAccessToken() async {
  printDebug("voip-registtering with token ");
  printDebug("voip-calling voice-accessToken");
  final function = FirebaseFunctions.instance.httpsCallable("voice-accessToken");

  final params = {
    "platform": Platform.isIOS ? "iOS" : "Android",
  };

  final result = await function.call(params);


  final data = jsonDecode(result.data);
  final identity = data["identity"] as String?;
  final token = data["token"] as String?;

  if (identity == null || token == null) {
    printDebug("Error requesting token from server [${function.toString()}]");
    printDebug(result.data);
    return null;
  }
  return Result(identity, token);
}