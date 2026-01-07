# Twilio Programmable Voice
-keep class com.twilio.** { *; }
-keep class tvo.webrtc.** { *; }
-dontwarn tvo.webrtc.**
-keep class com.twilio.voice.** { *; }
-keepattributes InnerClasses

# Twilio Voice Plugin - keep all plugin classes
-keep class com.twilio.twilio_voice.** { *; }
-keepclassmembers class com.twilio.twilio_voice.** { *; }

# Keep FirebaseMessagingService for push notifications
-keep class com.twilio.twilio_voice.fcm.VoiceFirebaseMessagingService { *; }
-keep class * extends com.google.firebase.messaging.FirebaseMessagingService { *; }

# Keep TVConnectionService for call handling
-keep class com.twilio.twilio_voice.service.TVConnectionService { *; }
-keep class com.twilio.twilio_voice.service.TVConnection { *; }

# Keep IncomingCallActivity
-keep class com.twilio.twilio_voice.IncomingCallActivity { *; }

# Keep CallInvite and related classes for parcelable deserialization
-keep class com.twilio.voice.CallInvite { *; }
-keep class com.twilio.voice.CancelledCallInvite { *; }
-keep class com.twilio.voice.Call { *; }
-keep class com.twilio.voice.Call$* { *; }

# Keep broadcast receivers
-keep class com.twilio.twilio_voice.receivers.** { *; }

# Keep method channel handlers
-keep class com.twilio.twilio_voice.TwilioVoicePlugin { *; }
