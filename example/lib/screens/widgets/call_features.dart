import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twilio_voice/twilio_voice.dart';

import 'state_toggle.dart';

class CallControls extends StatefulWidget {
  const CallControls({super.key});

  @override
  State<CallControls> createState() => _CallControlsState();
}

class _CallControlsState extends State<CallControls> {

  late final StreamSubscription<CallEvent> _subscription;
  final _events = <CallEvent>[];

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

  final _tv = TwilioVoice.instance;
  bool activeCall = false;

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
        case CallEvent.reconnecting:
        case CallEvent.reconnected:
          _updateStates();
          break;

        case CallEvent.log:
          break;

        case CallEvent.permission:
        // Using app lifecycle states, we don't have to update permissions here - convenience only.
          break;
      }
    });
    _updateStates();
  }

  void _updateStates() {
    // get all states from call
    _tv.call.isMuted().then((value) => stateMute = value ?? false);
    _tv.call.isHolding().then((value) => stateHold = value ?? false);
    _tv.call.isOnSpeaker().then((value) => stateSpeaker = value ?? false);
    _tv.call.isBluetoothOn().then((value) => stateBluetooth = value ?? false);
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
          ],
        ),

        Row(
          children: [
            Expanded(
              child: StateToggle(
                state: activeCall,
                icon: Icons.call_end,
                title: "Hangup",
                iconColor: Colors.red,
                onTap: activeCall ? () => _tv.call.hangUp() : null,
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),
      ]
    );
  }

  @override
  void dispose() {
    _subscription.cancel();
    super.dispose();
  }
}
