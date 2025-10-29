import 'dart:async';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:twilio_voice/twilio_voice.dart';
import 'package:twilio_voice_example/dialogs/update_token_dialog.dart';
import 'package:twilio_voice_example/screens/ui_call_screen.dart';
import 'package:twilio_voice_example/screens/ui_registration_screen.dart';

import 'api.dart';
import 'utils.dart';

extension IterableExtension<E> on Iterable<E> {
  /// Extension on [Iterable]'s [firstWhere] that returns null if no element is found instead of throwing an exception.
  E? firstWhereOrNull(bool Function(E element) test, {E Function()? orElse}) {
    for (E element in this) {
      if (test(element)) return element;
    }
    return (orElse == null) ? null : orElse();
  }
}

enum RegistrationMethod {
  env,
  url,
  firebase;

  static RegistrationMethod? fromString(String? value) {
    if (value == null) return null;
    return RegistrationMethod.values.firstWhereOrNull((element) => element.name == value);
  }

  static RegistrationMethod? loadFromEnvironment() {
    const value = String.fromEnvironment("REGISTRATION_METHOD");
    return fromString(value);
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    if(firebaseEnabled) {

      // Add firebase config here
      const options = FirebaseOptions(
        apiKey: '',
        appId: '',
        messagingSenderId: '',
        projectId: '',
        authDomain: '',
        databaseURL: '',
        storageBucket: '',
        measurementId: '',
      );

      // For web apps only
      // ignore: body_might_complete_normally_catch_error
      await Firebase.initializeApp(options: options).catchError((error) {
        printDebug("Failed to initialise firebase $error");
      });
    }
  } else {
    // For Android, iOS - Firebase will search for google-services.json in android/app directory or GoogleService-Info.plist in ios/Runner directory respectively.
    await Firebase.initializeApp();
  }

  if(firebaseEnabled) {
    FirebaseAnalytics.instance.logEvent(name: "app_started");
  }

  final app = App(registrationMethod: RegistrationMethod.loadFromEnvironment() ?? RegistrationMethod.env);
  return runApp(MaterialApp(home: app));
}

class App extends StatefulWidget {
  final RegistrationMethod registrationMethod;

  const App({super.key, this.registrationMethod = RegistrationMethod.url});

  @override
  State<App> createState() => _AppState();
}

class _AppState extends State<App> {
  String userId = "";

  /// Flag showing if TwilioVoice plugin has been initialised
  bool twilioInit = false;

  /// Flag showing registration status (for registering or re-registering on token change)
  var authRegistered = false;

  /// Flag showing if incoming call dialog is showing
  var showingIncomingCallDialog = false;

  //#region #region Register with Twilio
  void register() async {
    printDebug("voip-service registration");

    // Use for locally provided token generator e.g. Twilio's quickstarter project: https://github.com/twilio/voice-quickstart-server-node
    // if (!kIsWeb) {
    bool success = false;
    // if not web, we use the requested registration method
    switch (widget.registrationMethod) {
      case RegistrationMethod.env:
        success = await _registerFromEnvironment();
        break;
      case RegistrationMethod.url:
        success = await _registerUrl();
        break;
      case RegistrationMethod.firebase:
        success = await _registerFirebase();
        break;
    }

    if (success) {
      setState(() {
        twilioInit = true;
      });
    }
    // } else {
    //   // for web, we always show the initialisation screen unless we specified an
    //   if (widget.registrationMethod == RegistrationMethod.env) {
    //     bool success = await _registerFromEnvironment();
    //     if (success) {
    //       setState(() {
    //         twilioInit = true;
    //       });
    //     }
    //   }
    // }

    if(firebaseEnabled) {
      FirebaseAnalytics.instance.logEvent(name: "registration", parameters: {
        "method": widget.registrationMethod.name,
        "platform": kIsWeb ? "web" : Platform.isAndroid ? "android" : Platform.isIOS ? "ios" : Platform.isMacOS ? "macos" : "unknown"
      });
    }
  }

  /// Registers [accessToken] with TwilioVoice plugin, acquires a device token from FirebaseMessaging and registers with TwilioVoice plugin.
  Future<bool> _registerAccessToken(String accessToken) async {
    printDebug("voip-registering access token");

    String? androidToken;
    if(!kIsWeb && Platform.isAndroid) {
      // Get device token for Android only
      androidToken = await FirebaseMessaging.instance.getToken();
      printDebug("androidToken is ${androidToken!}");
    }
    final result = await TwilioVoicePlatform.instance.setTokens(accessToken: accessToken, deviceToken: androidToken);
    return result ?? false;
  }

  //#region #region Register from Environment
  /// Use this method to register with a environment variables: RECIPIENT, ID, TOKEN
  /// RECIPIENT - the recipient of the call
  /// ID - the identity of the caller
  /// TOKEN - the access token
  ///
  /// To access this, run with `--dart-define=RECIPIENT=alicesId --dart-define=ID=bobsId --dart-define=TOKEN=ey... --dart-define=REGISTRATION_METHOD=env`
  Future<bool> _registerFromEnvironment() async {
    // Load config via --dart-define if available
    String? myId = const String.fromEnvironment("ID");
    String? myToken = const String.fromEnvironment("TOKEN");
    if (myId.isEmpty) myId = null;
    if (myToken.isEmpty) myToken = null;

    printDebug("voip-registering with environment variables");
    if (myId == null || myToken == null) {
      printDebug("Failed to register with environment variables, please provide ID and TOKEN");
      return false;
    }
    userId = myId;
    return _registerAccessToken(myToken);
  }

  //#endregion

  //#region #region Register from Credentials
  /// Use this method to register with provided credentials
  Future<bool> _registerFromCredentials(String identity, String token) async {
    userId = identity;
    return _registerAccessToken(token);
  }

  //#endregion

  //#region #region Register with url provider
  /// Use this method to register with a url token generator
  /// To access this, run with `--dart-define=REGISTRATION_METHOD=url`
  Future<bool> _registerUrl() async {
    printDebug("voip-registering with url token generator");
    String url = const String.fromEnvironment("URL");
    if (url.isEmpty) {
      printDebug("No URL provided, defaulting to http://localhost:3000");

      String identity = const String.fromEnvironment("ID");
      if (identity.isEmpty) {
        printDebug("No ID provided, defaulting to server generated identity");
      }
      url = "http://localhost:3000";
    }
    final result = await generateURLAccessToken(url);
    if (result == null) {
      printDebug("Failed to register with local token generator");
      return false;
    }
    userId = result.identity;
    return _registerAccessToken(result.accessToken);
  }

  //#endregion

  //#region #region Register with Firebase provider
  void _listenForFirebaseLogin() {
    final auth = FirebaseAuth.instance;
    auth.authStateChanges().listen((user) async {
      // printDebug("authStateChanges $user");
      if (user == null) {
        printDebug("user is anonomous");
        await auth.signInAnonymously();
      } else if (!authRegistered) {
        authRegistered = true;
        // Note, you can either use Firebase provided [user.uid] or one provided from e.g. localhost:3000/token endpoint returning:
        // {token: "ey...", identity: "user123"}
        if (userId.isEmpty) {
          userId = user.uid;
        }
        printDebug("registering client $userId [firebase id ${user.uid}]");
        _registerFirebase();
      }
    });
  }

  /// Use this method to register with a firebase token generator
  /// To access this, run with `--dart-define=REGISTRATION_METHOD=firebase`
  Future<bool> _registerFirebase() async {
    if (!authRegistered) {
      _listenForFirebaseLogin();
      return false;
    }
    printDebug("voip-registering with firebase token generator");
    final result = await generateFirebaseAccessToken();
    if (result == null) {
      printDebug("Failed to register with firebase token generator");
      return false;
    }
    userId = result.identity;
    return _registerAccessToken(result.accessToken);
  }

  //#endregion

  //#endregion

  @override
  void initState() {
    super.initState();

    TwilioVoicePlatform.instance.setOnDeviceTokenChanged((token) {
      printDebug("voip-device token changed");
      if (!kIsWeb) {
        register();
      }
    });

    listenForEvents();
    register();

    const partnerId = "alicesId";
    TwilioVoicePlatform.instance.registerClient(partnerId, "Alice");
    // TwilioVoicePlatform.instance.requestReadPhoneStatePermission();
    // TwilioVoicePlatform.instance.requestMicAccess();
    // TwilioVoicePlatform.instance.requestCallPhonePermission();
  }

  /// Listen for call events
  void listenForEvents() {
    TwilioVoicePlatform.instance.callEventsListener.listen((event) {
      printDebug("voip-onCallStateChanged $event");

      switch (event) {
        case CallEvent.incoming:
        // applies to web only
          if (kIsWeb || Platform.isAndroid) {
            final activeCall = TwilioVoicePlatform.instance.call.activeCall;
            if (activeCall != null && activeCall.callDirection == CallDirection.incoming) {
              _showWebIncomingCallDialog();
            }
          }
          break;
        case CallEvent.ringing:
          final activeCall = TwilioVoicePlatform.instance.call.activeCall;
          if (activeCall != null) {
            final customData = activeCall.customParams;
            if (customData != null) {
              printDebug("voip-customData $customData");
            }
          }
          break;
        case CallEvent.connected:
        case CallEvent.callEnded:
        case CallEvent.declined:
        case CallEvent.answer:
          if (kIsWeb || Platform.isAndroid) {
            final nav = Navigator.of(context);
            if (nav.canPop() && showingIncomingCallDialog) {
              nav.pop();
              showingIncomingCallDialog = false;
            }
          }
          break;
        default:
          break;
      }
    });
  }

  /// Place a call to [clientIdentifier]
  Future<void> _onPerformCall(String clientIdentifier) async {
    if (!await (TwilioVoicePlatform.instance.hasMicAccess())) {
      printDebug("request mic access");
      TwilioVoicePlatform.instance.requestMicAccess();
      return;
    }
    printDebug("starting call to $clientIdentifier");
    TwilioVoicePlatform.instance.call.place(to: clientIdentifier, from: userId, extraOptions: {"_TWI_SUBJECT": "Company Name"});
  }

  Future<void> _onRegisterWithToken(String token, [String? identity]) async {
    return _registerFromCredentials(identity ?? "Unknown", token).then((value) {
      if (!value) {
        showDialog(
          // ignore: use_build_context_synchronously
          context: context,
          builder: (context) =>
          const AlertDialog(
            title: Text("Error"),
            content: Text("Failed to register for calls"),
          ),
        );
      } else {
        setState(() {
          twilioInit = true;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Plugin example app"),
        actions: [
          if(twilioInit) ...[
            const SizedBox(width: 8),
            const _UpdateTokenAction(),
          ],
          _LogoutAction(
            onSuccess: () {
              setState(() {
                twilioInit = false;
              });
            },
            onFailure: (error) {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text("Error"),
                  content: Text("Failed to unregister from calls: $error"),
                ),
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: twilioInit
                ? UICallScreen(
              userId: userId,
              onPerformCall: _onPerformCall,
            )
                : UIRegistrationScreen(
              onRegister: _onRegisterWithToken,
            ),
          ),
        ),
      ),
    );
  }

  /// Show incoming call dialog for web and Android
  void _showWebIncomingCallDialog() async {
    showingIncomingCallDialog = true;
    final activeCall = TwilioVoicePlatform.instance.call.activeCall!;
    final action = await showIncomingCallScreen(context, activeCall);
    if (action == true) {
      printDebug("accepting call");
      TwilioVoicePlatform.instance.call.answer();
    } else if (action == false) {
      printDebug("rejecting call");
      TwilioVoicePlatform.instance.call.hangUp();
    } else {
      printDebug("no action");
    }
  }

  Future<bool?> showIncomingCallScreen(BuildContext context, ActiveCall activeCall) async {
    if (!kIsWeb && !Platform.isAndroid) {
      printDebug("showIncomingCallScreen only for web");
      return false;
    }

    // show accept/reject incoming call screen dialog
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text("Incoming Call"),
          content: Text("Incoming call from ${activeCall.from}"),
          actions: [
            TextButton(
              child: const Text("Accept"),
              onPressed: () {
                Navigator.of(context).pop(true);
              },
            ),
            TextButton(
              child: const Text("Reject"),
              onPressed: () {
                Navigator.of(context).pop(false);
              },
            ),
          ],
        );
      },
    );
  }
}

class _LogoutAction extends StatelessWidget {
  final void Function()? onSuccess;
  final void Function(String error)? onFailure;

  const _LogoutAction({Key? key, this.onSuccess, this.onFailure}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
        onPressed: () async {
          final result = await TwilioVoicePlatform.instance.unregister();
          if (result == true) {
            onSuccess?.call();
          } else {
            onFailure?.call("Failed to unregister");
          }
        },
        label: const Text("Logout", style: TextStyle(color: Colors.white)),
        icon: const Icon(Icons.logout, color: Colors.white));
  }
}

class _UpdateTokenAction extends StatelessWidget {
  const _UpdateTokenAction({Key? key}): super(key: key);

  @override
  Widget build(BuildContext context) {
    return TextButton.icon(
      onPressed: () async {
        // show dialog to enter new token
        final token = await showDialog<String?>(
          context: context,
          builder: (context) => const UpdateTokenDialogContent(),
        );
        if (token?.isEmpty ?? true) {
          return;
        }
        final result = await TwilioVoicePlatform.instance.setTokens(accessToken: token!);
        final message = (result ?? false) ? "Successfully updated token" : "Failed to update token";
        // ignore: use_build_context_synchronously
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(message)),
        );
      },
      label: const Text("Update Token", style: TextStyle(color: Colors.white)),
      icon: const Icon(Icons.refresh, color: Colors.white),
    );
  }
}
