import 'dart:convert';
import 'dart:io';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:twilio_voice/twilio_voice.dart';

import 'call_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    // Add firebase config here
    final options = FirebaseOptions(
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
    await Firebase.initializeApp(options: options);
  } else {
    // For Android, iOS - Firebase will search for google-services.json in android/app directory or GoogleService-Info.plist in ios/Runner directory respectively.
    await Firebase.initializeApp();
  }
  return runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(home: DialScreen());
  }
}

class DialScreen extends StatefulWidget {
  @override
  _DialScreenState createState() => _DialScreenState();
}

class _DialScreenState extends State<DialScreen> with WidgetsBindingObserver {
  late TextEditingController _controller;
  String userId = "";

  registerUser() {
    print("voip- service init");
    // if (TwilioVoice.instance.deviceToken != null) {
    //   print("device token changed");
    // }

    // Use for locally provided token generator e.g. Twilio's quickstarter project: https://github.com/twilio/voice-quickstart-server-node
    registerLocal();
    // Or use firebase function to generate token, with function name 'voice-accessToken'.
    // register();

    TwilioVoice.instance.setOnDeviceTokenChanged((token) {
      print("voip-device token changed");
      registerLocal();
      // register();
    });
  }

  registerLocal() async {
    print("voip-registering with token ");
    print("GET http://localhost:3000/token");

    final uri = Uri.http("localhost:3000", "/token");
    final result = await http.get(uri);
    if (result.statusCode >= 200 && result.statusCode < 300) {
      print("Error requesting token from server [${uri.toString()}]");
      print(result.body);
      return;
    }
    final data = jsonDecode(result.body);
    final identity = data["identity"];
    userId = identity;
    final token = data["token"];
    String? androidToken;
    if (!kIsWeb && Platform.isAndroid) {
      androidToken = await FirebaseMessaging.instance.getToken();
      print("androidToken is " + androidToken!);
    }
    TwilioVoice.instance.setTokens(accessToken: token, deviceToken: androidToken);
  }

  register() async {
    print("voip-registtering with token ");
    print("voip-calling voice-accessToken");
    final function = FirebaseFunctions.instance.httpsCallable("voice-accessToken");

    final data = {
      "platform": Platform.isIOS ? "iOS" : "Android",
    };

    final result = await function.call(data);
    print("voip-result");
    print(result.data);
    String? androidToken;
    if (Platform.isAndroid || kIsWeb) {
      androidToken = await FirebaseMessaging.instance.getToken();
      print("androidToken is " + androidToken!);
    }
    TwilioVoice.instance.setTokens(accessToken: result.data, deviceToken: androidToken);
  }

  var registered = false;

  waitForLogin() {
    final auth = FirebaseAuth.instance;
    auth.authStateChanges().listen((user) async {
      // print("authStateChanges $user");
      if (user == null) {
        print("user is anonomous");
        await auth.signInAnonymously();
      } else if (!registered) {
        registered = true;
        // Note, you can either use Firebase provided [user.uid] or one provided from e.g. localhost:3000/token endpoint returning:
        // {token: "ey...", identity: "user123"}
        if (this.userId.isEmpty) {
          this.userId = user.uid;
        }
        print("registering client ${userId} [firebase id ${user.uid}]");
        registerUser();

        FirebaseMessaging.instance.requestPermission();
        // FirebaseMessaging.instance.configure(
        //     onMessage: (Map<String, dynamic> message) {
        //   print("onMessage");
        //   print(message);
        //   return;
        // }, onLaunch: (Map<String, dynamic> message) {
        //   print("onLaunch");
        //   print(message);
        //   return;
        // }, onResume: (Map<String, dynamic> message) {
        //   print("onResume");
        //   print(message);
        //   return;
        // });
      }
    });
  }

  @override
  void initState() {
    super.initState();
    waitForLogin();

    super.initState();
    waitForCall();
    WidgetsBinding.instance!.addObserver(this);

    final partnerId = "alicesId";
    TwilioVoice.instance.registerClient(partnerId, "Alice");
    _controller = TextEditingController();
  }

  checkActiveCall() async {
    final isOnCall = await TwilioVoice.instance.call.isOnCall();
    print("checkActiveCall $isOnCall");
    if (isOnCall &&
        !hasPushedToCall &&
        TwilioVoice.instance.call.activeCall!.callDirection ==
            CallDirection.incoming) {
      print("user is on call");
      pushToCallScreen();
    }
  }

  var hasPushedToCall = false;

  void waitForCall() {
    checkActiveCall();
    TwilioVoice.instance.callEventsListener
      ..listen((event) {
        print("voip-onCallStateChanged $event");

        switch (event) {
          case CallEvent.answer:
            //at this point android is still paused
            if (kIsWeb ||
                Platform.isIOS && state == null ||
                state == AppLifecycleState.resumed) {
              pushToCallScreen();
            }
            break;
          case CallEvent.incoming:
            // applies to web only
            if (kIsWeb) {
              final activeCall = TwilioVoice.instance.call.activeCall;
              if (activeCall != null && activeCall.callDirection == CallDirection.incoming) {
                _showWebIncomingCallDialog();
              }
            }
            break;
          case CallEvent.ringing:
            final activeCall = TwilioVoice.instance.call.activeCall;
            if (activeCall != null) {
              final customData = activeCall.customParams;
              if (customData != null) {
                print("voip-customData $customData");
              }
            }
            break;
          case CallEvent.declined:
            final activeCall = TwilioVoice.instance.call.activeCall;
            if(activeCall != null) {
              TwilioVoice.instance.call.hangUp().then((value) {
                hasPushedToCall = false;
              });
            } else {
              hasPushedToCall = false;
            }
            break;
          case CallEvent.connected:
            if (kIsWeb) {
              if (state == null || state == AppLifecycleState.resumed) {
                pushToCallScreen();
              }
            } else if (Platform.isAndroid &&
                TwilioVoice.instance.call.activeCall!.callDirection ==
                    CallDirection.incoming) {
              if (state != AppLifecycleState.resumed) {
                TwilioVoice.instance.showBackgroundCallUI();
              } else if (state == null || state == AppLifecycleState.resumed) {
                pushToCallScreen();
              }
            }
            break;
          case CallEvent.callEnded:
            hasPushedToCall = false;
            break;
          case CallEvent.returningCall:
            pushToCallScreen();
            break;
          default:
            break;
        }
      });
  }

  AppLifecycleState? state;
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    this.state = state;
    print("didChangeAppLifecycleState");
    if (state == AppLifecycleState.resumed) {
      checkActiveCall();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance!.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Plugin example app'),
      ),
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TextFormField(
                  controller: _controller,
                  decoration: InputDecoration(
                      labelText: 'Client Identifier or Phone Number'),
                ),
                SizedBox(
                  height: 10,
                ),
                ElevatedButton(
                  child: Text("Make Call"),
                  onPressed: () async {
                    if (!await (TwilioVoice.instance.hasMicAccess())) {
                      print("request mic access");
                      TwilioVoice.instance.requestMicAccess();
                      return;
                    }
                    print("starting call to ${_controller.text}");
                    TwilioVoice.instance.call
                        .place(to: _controller.text, from: userId);
                    pushToCallScreen();
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showWebIncomingCallDialog() async {
    final activeCall = TwilioVoice.instance.call.activeCall!;
    final action = await showIncomingCallScreen(context, activeCall);
    if (action == true) {
      print("accepting call");
      TwilioVoice.instance.call.answer();
      pushToCallScreen();
    } else {
      print("rejecting call");
      TwilioVoice.instance.call.hangUp();
    }
  }

  void pushToCallScreen() {
    if (hasPushedToCall) {
      return;
    }
    hasPushedToCall = true;
    Navigator.of(context, rootNavigator: true).push(MaterialPageRoute(fullscreenDialog: true, builder: (context) => CallScreen()));
  }

  Future<bool?> showIncomingCallScreen(BuildContext context, ActiveCall activeCall) async {
    if (!kIsWeb) {
      print("showIncomingCallScreen only for web");
      return false;
    }

    // show accept/reject incoming call screen dialog
    return showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text("Incoming Call"),
          content: Text("Incoming call from ${activeCall.from}"),
          actions: [
            TextButton(
              child: Text("Accept"),
              onPressed: () {
                Navigator.of(context).pop(true);
              },
            ),
            TextButton(
              child: Text("Reject"),
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
