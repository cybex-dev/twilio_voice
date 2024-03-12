import 'dart:async';
import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:twilio_voice/twilio_voice.dart';

import '../../utils.dart';
import 'permission_tile.dart';

class PermissionsBlock extends StatefulWidget {
  const PermissionsBlock({super.key});

  @override
  State<PermissionsBlock> createState() => _PermissionsBlockState();
}

class _PermissionsBlockState extends State<PermissionsBlock> with WidgetsBindingObserver {
  late final StreamSubscription<CallEvent> _subscription;

  AppLifecycleState? _lastLifecycleState;

  final _tv = TwilioVoice.instance;
  bool activeCall = false;

  //#region #region Permissions
  bool _hasMicPermission = false;

  set setMicPermission(bool value) {
    setState(() {
      _hasMicPermission = value;
    });
  }

  bool _hasRegisteredPhoneAccount = false;

  set setPhoneAccountRegistered(bool value) {
    setState(() {
      _hasRegisteredPhoneAccount = value;
    });
  }

  bool _hasCallPhonePermission = false;

  set setCallPhonePermission(bool value) {
    setState(() {
      _hasCallPhonePermission = value;
    });
  }

  bool _hasManageCallsPermission = false;

  set setManageCallsPermission(bool value) {
    setState(() {
      _hasManageCallsPermission = value;
    });
  }

  bool _isPhoneAccountEnabled = false;

  set setIsPhoneAccountEnabled(bool value) {
    setState(() {
      _isPhoneAccountEnabled = value;
    });
  }

  bool _hasReadPhoneStatePermission = false;

  set setReadPhoneStatePermission(bool value) {
    setState(() {
      _hasReadPhoneStatePermission = value;
    });
  }

  bool _hasReadPhoneNumbersPermission = false;

  set setReadPhoneNumbersPermission(bool value) {
    setState(() {
      _hasReadPhoneNumbersPermission = value;
    });
  }

  bool _hasBackgroundPermissions = false;

  set setBackgroundPermission(bool value) {
    setState(() {
      _hasBackgroundPermissions = value;
    });
  }

  //#endregion

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    printDebug("AppLifecycleState: $state");
    if (_lastLifecycleState != state && state == AppLifecycleState.resumed) {
      _updatePermissions();
    }
    _lastLifecycleState = state;
  }

  @override
  void initState() {
    super.initState();
    _updatePermissions();
  }

  void _updatePermissions() {
    // get all permission states
    _tv.hasMicAccess().then((value) => setMicPermission = value);
    _tv.hasReadPhoneStatePermission().then((value) => setReadPhoneStatePermission = value);
    _tv.hasReadPhoneNumbersPermission().then((value) => setReadPhoneNumbersPermission = value);
    if (firebaseEnabled && Firebase.apps.isNotEmpty) {
      FirebaseMessaging.instance.requestPermission().then((value) => setBackgroundPermission = value.authorizationStatus == AuthorizationStatus.authorized);
    }
    _tv.hasCallPhonePermission().then((value) => setCallPhonePermission = value);
    _tv.hasManageOwnCallsPermission().then((value) => setManageCallsPermission = value);
    _tv.hasRegisteredPhoneAccount().then((value) => setPhoneAccountRegistered = value);
    _tv.isPhoneAccountEnabled().then((value) => setIsPhoneAccountEnabled = value);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        children: [
          // permissions
          Text("Permissions", style: Theme.of(context).textTheme.titleLarge),

          Column(
            children: [
              PermissionTile(
                icon: Icons.mic,
                title: "Microphone",
                granted: _hasMicPermission,
                onRequestPermission: () async {
                  await _tv.requestMicAccess();
                  setMicPermission = await _tv.hasMicAccess();
                },
              ),

              if (firebaseEnabled && Firebase.apps.isNotEmpty)
                PermissionTile(
                  icon: Icons.notifications,
                  title: "Notifications",
                  granted: _hasBackgroundPermissions,
                  onRequestPermission: () async {
                    await FirebaseMessaging.instance.requestPermission();
                    final settings = await FirebaseMessaging.instance.getNotificationSettings();
                    setBackgroundPermission = settings.authorizationStatus == AuthorizationStatus.authorized;
                  },
                ),

              // if android
              if (!kIsWeb && Platform.isAndroid)
                PermissionTile(
                  icon: Icons.phone,
                  title: "Read Phone State",
                  granted: _hasReadPhoneStatePermission,
                  onRequestPermission: () async {
                    await _tv.requestReadPhoneStatePermission();
                    setReadPhoneStatePermission = await _tv.hasReadPhoneStatePermission();
                  },
                ),

              // if android
              if (!kIsWeb && Platform.isAndroid)
                PermissionTile(
                  icon: Icons.phone,
                  title: "Read Phone Numbers",
                  granted: _hasReadPhoneNumbersPermission,
                  onRequestPermission: () async {
                    await _tv.requestReadPhoneNumbersPermission();
                    setReadPhoneNumbersPermission = await _tv.hasReadPhoneNumbersPermission();
                  },
                ),

              // if android
              if (!kIsWeb && Platform.isAndroid)
                PermissionTile(
                  icon: Icons.call_made,
                  title: "Call Phone",
                  granted: _hasCallPhonePermission,
                  onRequestPermission: () async {
                    await _tv.requestCallPhonePermission();
                    setCallPhonePermission = await _tv.hasCallPhonePermission();
                  },
                ),

              // if android
              if (!kIsWeb && Platform.isAndroid)
                PermissionTile(
                  icon: Icons.call_received,
                  title: "Manage Calls",
                  granted: _hasManageCallsPermission,
                  onRequestPermission: () async {
                    await _tv.requestManageOwnCallsPermission();
                    setManageCallsPermission = await _tv.hasManageOwnCallsPermission();
                  },
                ),

              // if android
              if (!kIsWeb && Platform.isAndroid)
                PermissionTile(
                  icon: Icons.phonelink_setup,
                  title: "Phone Account",
                  granted: _hasRegisteredPhoneAccount,
                  onRequestPermission: () async {
                    await _tv.registerPhoneAccount();
                    setPhoneAccountRegistered = await _tv.hasRegisteredPhoneAccount();
                  },
                ),

              // if android
              if (!kIsWeb && Platform.isAndroid)
                ListTile(
                  enabled: _hasRegisteredPhoneAccount,
                  dense: true,
                  leading: const Icon(Icons.phonelink_lock_outlined),
                  title: const Text("Phone Account Status"),
                  subtitle: Text(_hasRegisteredPhoneAccount ? (_isPhoneAccountEnabled ? "Enabled" : "Not Enabled") : "Not Registered"),
                  trailing: ElevatedButton(
                    onPressed: _hasRegisteredPhoneAccount && !_isPhoneAccountEnabled ? () => _tv.openPhoneAccountSettings() : null,
                    child: const Text("Open Settings"),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _subscription.cancel();
    super.dispose();
  }
}
