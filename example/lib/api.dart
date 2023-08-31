import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

import 'package:cloud_functions/cloud_functions.dart';

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
  print("voip-registering with token ");
  print("GET http://localhost:3000/token");

  final uri = Uri.http("localhost:3000", "/token");
  final result = await http.get(uri);
  if (result.statusCode >= 200 && result.statusCode < 300) {
    print("Error requesting token from server [${uri.toString()}]");
    print(result.body);
    return null;
  }
  final data = jsonDecode(result.body);
  final identity = data["identity"] as String?;
  final token = data["token"] as String?;

  if (identity == null || token == null) {
    print("Error requesting token from server [${uri.toString()}]");
    print(result.body);
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
  print("voip-registtering with token ");
  print("voip-calling voice-accessToken");
  final function = FirebaseFunctions.instance.httpsCallable("voice-accessToken");

  final params = {
    "platform": Platform.isIOS ? "iOS" : "Android",
  };

  final result = await function.call(params);


  final data = jsonDecode(result.data);
  final identity = data["identity"] as String?;
  final token = data["token"] as String?;

  if (identity == null || token == null) {
    print("Error requesting token from server [${function.toString()}]");
    print(result.data);
    return null;
  }
  return Result(identity, token);
}