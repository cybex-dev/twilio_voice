import 'dart:async';

import 'package:flutter/material.dart';
import 'package:twilio_voice/twilio_voice.dart';

class CallScreen extends StatefulWidget {
  @override
  _CallScreenState createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  var speaker = false;
  var mute = false;
  var isEnded = false;

  String? message = "Connecting...";
  late StreamSubscription<CallEvent> callStateListener;
  void listenCall() {
    callStateListener = TwilioVoice.instance.callEventsListener.listen((event) {
      print("voip-onCallStateChanged $event");

      switch (event) {
        case CallEvent.callEnded:
          print("call Ended");
          if (!isEnded) {
            isEnded = true;
            Navigator.of(context).pop();
          }
          break;
        case CallEvent.mute:
          print("received mute");
          setState(() {
            mute = true;
          });
          break;
        case CallEvent.connected:
          print("call connected");
          setState(() {
            message = "Connected!";
          });
          break;
        case CallEvent.unmute:
          print("received unmute");
          setState(() {
            mute = false;
          });
          break;
        case CallEvent.speakerOn:
          print("received speakerOn");
          setState(() {
            speaker = true;
          });
          break;
        case CallEvent.speakerOff:
          print("received speakerOf");
          setState(() {
            speaker = false;
          });
          break;
        case CallEvent.ringing:
          print("ringing");
          setState(() {
            message = "Calling...";
          });
          break;
        case CallEvent.declined:
          setState(() {
            message = "Declined";
          });
          if (!isEnded) {
            isEnded = true;
            Navigator.of(context).pop();
          }
          break;
        case CallEvent.answer:
          print("call answered");
          setState(() {
            message = null;
          });
          break;
        case CallEvent.hold:
        case CallEvent.log:
        case CallEvent.unhold:
          break;
        default:
          break;
      }
    });
  }

  late String caller;

  String getCaller() {
    final activeCall = TwilioVoice.instance.call.activeCall;
    if (activeCall != null) {
      return activeCall.callDirection == CallDirection.outgoing
          ? activeCall.toFormatted
          : activeCall.fromFormatted;
    }
    return "Unknown";
  }

  @override
  void initState() {
    listenCall();
    super.initState();
    caller = getCaller();
  }

  @override
  void dispose() {
    super.dispose();
    callStateListener.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        backgroundColor: Theme.of(context).accentColor,
        body: Container(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 40),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  Column(
                    children: [
                      Text(
                        caller,
                        style: Theme.of(context)
                            .textTheme
                            .headline4!
                            .copyWith(color: Colors.white),
                      ),
                      SizedBox(height: 8),
                      if (message != null)
                        Text(
                          message!,
                          style: Theme.of(context)
                              .textTheme
                              .headline6!
                              .copyWith(color: Colors.white),
                        )
                    ],
                  ),
                  Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Material(
                          type: MaterialType
                              .transparency, //Makes it usable on any background color, thanks @IanSmith
                          child: Ink(
                            decoration: BoxDecoration(
                              border:
                                  Border.all(color: Colors.white, width: 1.0),
                              color: speaker
                                  ? Theme.of(context).primaryColor
                                  : Colors.white24,
                              shape: BoxShape.circle,
                            ),
                            child: InkWell(
                              //This keeps the splash effect within the circle
                              borderRadius: BorderRadius.circular(
                                  1000.0), //Something large to ensure a circle
                              child: Padding(
                                padding: EdgeInsets.all(20.0),
                                child: Icon(
                                  Icons.volume_up,
                                  size: 40.0,
                                  color: Colors.white,
                                ),
                              ),
                              onTap: () {
                                print("speaker!");
                                // setState(() {
                                //   speaker = !speaker;
                                // });
                                TwilioVoice.instance.call
                                    .toggleSpeaker(!speaker);
                              },
                            ),
                          ),
                        ),
                        Material(
                          type: MaterialType
                              .transparency, //Makes it usable on any background color, thanks @IanSmith
                          child: Ink(
                            decoration: BoxDecoration(
                              border:
                                  Border.all(color: Colors.white, width: 1.0),
                              color: mute
                                  ? Theme.of(context).accentColor
                                  : Colors.white24,
                              shape: BoxShape.circle,
                            ),
                            child: InkWell(
                              //This keeps the splash effect within the circle
                              borderRadius: BorderRadius.circular(
                                  1000.0), //Something large to ensure a circle
                              child: Padding(
                                padding: EdgeInsets.all(20.0),
                                child: Icon(
                                  Icons.mic_off,
                                  size: 40.0,
                                  color: Colors.white,
                                ),
                              ),
                              onTap: () {
                                print("mute!");
                                TwilioVoice.instance.call.toggleMute(!mute);
                                // setState(() {
                                //   mute = !mute;
                                // });
                              },
                            ),
                          ),
                        )
                      ]),
                  RawMaterialButton(
                    elevation: 2.0,
                    fillColor: Colors.red,
                    child: Icon(
                      Icons.call_end,
                      size: 40.0,
                      color: Colors.white,
                    ),
                    padding: EdgeInsets.all(20.0),
                    shape: CircleBorder(),
                    onPressed: () async {
                      final isOnCall =
                          await TwilioVoice.instance.call.isOnCall();
                      if (isOnCall) {
                        TwilioVoice.instance.call.hangUp();
                      }
                    },
                  )
                ],
              ),
            ),
          ),
        ));
  }
}
