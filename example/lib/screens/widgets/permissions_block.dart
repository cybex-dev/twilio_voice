import 'dart:async';
import 'dart:io';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:twilio_voice/twilio_voice.dart';
import 'package:twilio_voice_example/screens/widgets/permission_tile.dart';
import 'package:twilio_voice_example/screens/widgets/state_toggle.dart';

class PermissionsBlock extends StatefulWidget {
  const PermissionsBlock({super.key});

  @override
  State<PermissionsBlock> createState() => _PermissionsBlockState();
}

class _PermissionsBlockState extends State<PermissionsBlock> {
  late final StreamSubscription<CallEvent> _subscription;
  final _events = <CallEvent>[];

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

  //#region #region State Getters
  bool _stateHold = false;

  set stateHold(bool value) {
    setState(() {
      _stateHold = value;
    });
  }

  bool _stateMute = false;

  set stateMute(bool value) {
    setState(() {
      _stateMute = value;
    });
  }

  bool _stateSpeaker = false;

  set stateSpeaker(bool value) {
    setState(() {
      _stateSpeaker = value;
    });
  }

  bool _stateBluetooth = false;

  set stateBluetooth(bool value) {
    setState(() {
      _stateBluetooth = value;
    });
  }
  //#endregion

  @override
  void initState() {
    super.initState();
    _subscription = _tv.callEventsListener.listen((event) {
      _events.add(event);
      switch (event) {
        case CallEvent.unhold:
        case CallEvent.hold:
        case CallEvent.unmute:
        case CallEvent.mute:
        case CallEvent.speakerOn:
        case CallEvent.speakerOff:
        case CallEvent.bluetoothOn:
        case CallEvent.bluetoothOff:
          _updateStates();
          break;

        case CallEvent.connected:
          activeCall = true;
          _updateStates();
          break;

        case CallEvent.callEnded:
          activeCall = false;
          _updateStates();
          break;

        case CallEvent.incoming:
        case CallEvent.ringing:
        case CallEvent.declined:
        case CallEvent.answer:
        case CallEvent.missedCall:
        case CallEvent.returningCall:
          _updateStates();
          break;

        case CallEvent.log:
          break;

        case CallEvent.permission:
          _updatePermissions();
          break;
      }
    });
    _updatePermissions();
    _updateStates();
  }

  void _updateStates() {
    // get all states from call
    _tv.call.isMuted().then((value) => stateMute = value ?? false);
    _tv.call.isHolding().then((value) => stateHold = value ?? false);
    _tv.call.isOnSpeaker().then((value) => stateSpeaker = value ?? false);
    _tv.call.isBluetoothOn().then((value) => stateBluetooth = value ?? false);
  }

  void _updatePermissions() {
    // get all permission states
    _tv.hasMicAccess().then((value) => setMicPermission = value);
    _tv.hasReadPhoneStatePermission().then((value) => setReadPhoneStatePermission = value);
    FirebaseMessaging.instance.requestPermission().then((value) => setBackgroundPermission = value.authorizationStatus == AuthorizationStatus.authorized);
    _tv.hasRegisteredPhoneAccount().then((value) => setPhoneAccountRegistered = value);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // state
        Text("State", style: Theme.of(context).textTheme.titleLarge),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Expanded(
              child: StateToggle(
                state: _stateMute,
                icon: _stateMute ? Icons.mic : Icons.mic_off,
                title: "Mute",
                onTap: () => _tv.call.toggleMute(!_stateMute),
              ),
            ),
            Expanded(
              child: StateToggle(
                state: _stateHold,
                icon: Icons.pause,
                title: "Hold",
                iconColor: _stateHold ? Colors.orange : null,
                onTap: () => _tv.call.holdCall(holdCall: !_stateHold),
              ),
            ),
            Expanded(
              child: StateToggle(
                state: _stateSpeaker,
                icon: Icons.volume_up,
                title: "Speaker",
                iconColor: _stateSpeaker ? Colors.green : null,
                onTap: () => _tv.call.toggleSpeaker(!_stateSpeaker),
              ),
            ),
            Expanded(
              child: StateToggle(
                state: _stateBluetooth,
                icon: Icons.bluetooth,
                title: "Bluetooth",
                iconColor: _stateBluetooth ? Colors.blue : null,
                onTap: () => _tv.call.toggleBluetooth(bluetoothOn: !_stateBluetooth),
              ),
            ),
            Expanded(
              child: StateToggle(
                state: activeCall,
                icon: Icons.call_end,
                title: "Disconnect",
                iconColor: Colors.red,
                onTap: activeCall ? () => _tv.call.hangUp() : null,
              ),
            ),
          ],
        ),

        // permissions
        Text("Permissions", style: Theme.of(context).textTheme.titleLarge),
        Column(
          children: [
            PermissionTile(
              icon: Icons.mic,
              title: "Microphone",
              granted: _hasMicPermission,
              onRequestPermission: () => _tv.requestMicAccess(),
            ),

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
            if (Platform.isAndroid)
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
            if (Platform.isAndroid)
              PermissionTile(
                icon: Icons.phonelink_setup,
                title: "Phone Account",
                granted: _hasRegisteredPhoneAccount,
                onRequestPermission: () async {
                  final result = await _tv.registerPhoneAccount();
                  setPhoneAccountRegistered = await _tv.hasRegisteredPhoneAccount();
                  if (result != null && result) {
                    await _tv.openPhoneAccountSettings();
                    if (kDebugMode) {
                      print("openPhoneAccountSettings $result");
                    }
                  }
                },
              ),
          ],
        ),

        Text("Events (latest at top)", style: Theme.of(context).textTheme.titleLarge),
        Expanded(
          child: ListView.separated(
            reverse: true,
            itemBuilder: (context, index) => Text(_events[index].toString()),
            separatorBuilder: (context, index) => const Divider(height: 2, thickness: 0.5),
            itemCount: _events.length,
          ),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}