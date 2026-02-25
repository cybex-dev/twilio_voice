# Incoming Call Notification Research — Android Behavior vs Current Implementation

## Date: Research Notes for Fix

---

## 1. How Android's `setFullScreenIntent` is DESIGNED to Work

### The Golden Rule (from Android docs):
> When you call `Notification.Builder.setFullScreenIntent(pendingIntent, true)`:
> - **If the device is LOCKED / screen is OFF** → Android automatically launches the `fullScreenIntent` (the Activity)
> - **If the user is ACTIVELY USING the device** → Android shows a **heads-up notification** instead (the notification slides down from the top)

### This means:
- You only need **ONE notification** with `setFullScreenIntent` set
- Android **automatically decides** whether to show the full-screen Activity or the heads-up notification
- You should **NOT** also manually launch the Activity — Android handles that via the notification's `fullScreenIntent`

### Version-Specific Behavior:

| Android Version | Behavior |
|----------------|----------|
| **Pre-13 (< Tiramisu)** | System _may_ display heads-up instead of launching intent when device is in use |
| **13+ (Tiramisu)** | System _will_ display heads-up notification with emphasized action buttons when device is in use |
| **14+ (API 34)** | `USE_FULL_SCREEN_INTENT` permission is restricted to calling/alarm apps. Must check `canUseFullScreenIntent()`. Without it, heads-up shown for 60s (not persistent) |

### `USE_FULL_SCREEN_INTENT` Permission:
- **With permission**: Heads-up notification is persistent until user dismisses/snoozes/app cancels
- **Without permission** (Android 14+): Heads-up shown for only 60 seconds
- Can check: `NotificationManager.canUseFullScreenIntent()`
- Can send user to settings: `ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`

### Requirements for `setFullScreenIntent` to Work:
1. Notification channel must have `IMPORTANCE_HIGH` or `IMPORTANCE_MAX`
2. Permission `USE_FULL_SCREEN_INTENT` (auto-granted for phone/alarm apps pre-Android 14)
3. For self-managed `ConnectionService`: App is responsible for posting its own notification

---

## 2. Self-Managed ConnectionService & `onShowIncomingCallUi()`

### From Android docs on `Connection.onShowIncomingCallUi()`:
> "Notifies this Connection that its ConnectionService is responsible for displaying its incoming call user interface."
> 
> "You should trigger the display of the incoming call user interface for your application by **showing a Notification with a full-screen Intent** specified."

### The Official Pattern (from docs):
```java
// Step 1: Create notification channel with ringtone
NotificationChannel channel = new NotificationChannel(YOUR_CHANNEL_ID, "Incoming Calls",
    NotificationManager.IMPORTANCE_MAX);
Uri ringtoneUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE);
channel.setSound(ringtoneUri, new AudioAttributes.Builder()
    .setUsage(AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
    .build());

// Step 2: Build notification with fullScreenIntent
Intent intent = new Intent(Intent.ACTION_MAIN, null);
intent.setFlags(Intent.FLAG_ACTIVITY_NO_USER_ACTION | Intent.FLAG_ACTIVITY_NEW_TASK);
intent.setClass(context, YourIncomingCallActivity.class);
PendingIntent pendingIntent = PendingIntent.getActivity(context, 1, intent, ...);

Notification.Builder builder = new Notification.Builder(context);
builder.setOngoing(true);
builder.setPriority(Notification.PRIORITY_HIGH);
builder.setContentIntent(pendingIntent);
builder.setFullScreenIntent(pendingIntent, true);  // <-- KEY: Let Android decide
// ... setup content ...
notificationManager.notify(YOUR_CHANNEL_ID, YOUR_TAG, YOUR_ID, notification);
```

### Key Takeaway:
**You post ONE notification. Android decides the display mode:**
- Locked → launches fullScreenIntent (Activity)
- Unlocked/in-use → shows heads-up notification

---

## 3. Current Plugin Implementation — ROOT CAUSE ANALYSIS

### What the plugin currently does (the bug):

```
FCM push received
  → onStartCommand(ACTION_INCOMING_CALL)
    → startIncomingCallForegroundService(callInvite)
      → createIncomingCallNotification()     // ✅ Creates notification with setFullScreenIntent
      → startForeground(NOTIFICATION_ID, notification)  // ✅ Posts notification
      → startRinging()                       // ✅ Manual ringtone
      → showIncomingCallOverLockScreen()     // ❌ PROBLEM: ALSO manually launches the Activity!
        → acquires wake lock
        → Handler.postDelayed(200ms) {
            launchIncomingCallActivity()     // ❌ Calls startActivity() DIRECTLY
          }
```

### The Double-Launch Problem:

1. **Notification with `setFullScreenIntent`** is posted → Android may auto-launch the Activity (if locked) OR show heads-up (if unlocked)
2. **200ms later**, `launchIncomingCallActivity()` ALSO calls `startActivity()` directly

**Result when device is LOCKED:**
- Android launches Activity via `fullScreenIntent` ✅
- 200ms later, `launchIncomingCallActivity()` launches Activity AGAIN ❌ (but `isActivityAlive` check helps sometimes)

**Result when device is UNLOCKED/IN USE:**
- Android shows heads-up notification ✅
- 200ms later, `launchIncomingCallActivity()` ALSO launches the full-screen Activity ❌❌❌
- **User sees BOTH the heads-up notification AND the full-screen activity** — THIS IS THE BUG

### The `isActivityAlive` guard is insufficient:
- It only prevents double-launch when the first launch (via `fullScreenIntent`) has already completed `onCreate()`
- When the device is **unlocked**, Android shows heads-up instead of launching the Activity, so `isActivityAlive` is `false`
- Then `launchIncomingCallActivity()` fires and launches the Activity on top of the heads-up notification

---

## 4. The Fix — Clean Implementation Plan

### Correct Approach:
1. **Post the notification with `setFullScreenIntent`** — let Android decide display mode
2. **Do NOT manually call `startActivity()`** — remove `showIncomingCallOverLockScreen()` and `launchIncomingCallActivity()`
3. **Keep the wake lock** acquisition to ensure screen turns on (for locked device scenarios)
4. **Let the notification handle everything**:
   - Locked → Android auto-launches `IncomingCallActivity` via `fullScreenIntent`
   - Unlocked → Android shows heads-up notification with Answer/Decline buttons
   - User taps notification → `contentIntent` opens `IncomingCallActivity`

### What to modify in `startIncomingCallForegroundService()`:

**BEFORE (current — broken):**
```kotlin
private fun startIncomingCallForegroundService(callInvite: CallInvite) {
    val notification = createIncomingCallNotification(callInvite)
    startForeground(INCOMING_CALL_NOTIFICATION_ID, notification, ...)
    startRinging()
    showIncomingCallOverLockScreen(callInvite)  // ❌ REMOVE THIS
}
```

**AFTER (fixed):**
```kotlin
private fun startIncomingCallForegroundService(callInvite: CallInvite) {
    val notification = createIncomingCallNotification(callInvite)
    
    // Wake the screen so the notification/fullScreenIntent can be seen
    wakeScreen()
    
    startForeground(INCOMING_CALL_NOTIFICATION_ID, notification, ...)
    startRinging()
    
    // Do NOT manually launch IncomingCallActivity!
    // The notification's setFullScreenIntent will handle it:
    // - Locked device → Android auto-launches IncomingCallActivity
    // - Unlocked device → Android shows heads-up notification
}
```

### Additional Considerations:

1. **Android 14+ FSI Permission**: Should check `canUseFullScreenIntent()` and guide user to grant it if needed
2. **Notification Channel**: Must use `IMPORTANCE_MAX` (currently checking — need to verify)
3. **Ringtone**: Currently played manually via `startRinging()`. Could alternatively set sound on the notification channel for the heads-up notification to play the ringtone. But manual ringtone control gives more flexibility (stop on answer/decline).
4. **Answer from notification**: The `answerActivityPendingIntent` already works — it launches `IncomingCallActivity` with `action=answer`
5. **Decline from notification**: The `declinePendingIntent` already works — it sends `ACTION_HANGUP` to the service

### What NOT to change:
- `createIncomingCallNotification()` — the notification builder is correct (has `setFullScreenIntent`)
- `IncomingCallActivity` — the full-screen UI itself is fine
- Answer/Decline button handling — already works
- `onCreateIncomingConnection()` — the TelecomManager flow is fine
- Ringtone/vibration management — keep manual control
- Wake lock for screen wake — keep this, just don't manually launch the activity

---

## 5. Edge Cases to Handle

### 5.1 Android 14+ without `USE_FULL_SCREEN_INTENT` permission
- The heads-up notification will only show for 60 seconds (not persistent)
- Consider: check `canUseFullScreenIntent()` and prompt user if not granted
- Fallback: The notification still shows, just not persistent

### 5.2 MIUI / Xiaomi devices
- MIUI sometimes blocks `fullScreenIntent` from launching
- Current code has special MIUI handling in `launchIncomingCallActivity()` and `showIncomingCallOverLockScreen()`
- With the fix: If MIUI blocks the `fullScreenIntent`, the heads-up notification should still show
- May need to keep a MIUI-specific fallback that detects if the activity didn't launch within X seconds

### 5.3 Call waiting (second incoming call during active call)
- Currently passes `hasActiveCallDuringIncoming` extras to the activity
- With the fix: The `fullScreenIntent` already has these extras (set in `createIncomingCallNotification`)
- When the full-screen Activity launches (via notification), it will have the active call info

### 5.4 App terminated state
- When app is killed and FCM wakes it up
- The notification with `fullScreenIntent` should still work because it's posted from the service
- No change needed — the notification handles both cases

### 5.5 `isActivityAlive` flag
- Can be simplified or removed since we're no longer doing manual launches
- The `IncomingCallActivity.isActivityAlive` flag was primarily used to prevent double-launch
- After the fix, only ONE launch happens (from the notification's `fullScreenIntent`)

---

## 6. Notification Channel Configuration Check

### Current channel setup needs verification:
- Must be `IMPORTANCE_MAX` or at minimum `IMPORTANCE_HIGH` for `setFullScreenIntent` to work
- Sound should be set on the channel for heads-up notification audio
- But since we play ringtone manually, we might want to set channel sound to `null` to avoid double audio

### Recommended channel config:
```kotlin
val channel = NotificationChannel(id, "Incoming Calls", NotificationManager.IMPORTANCE_MAX).apply {
    description = "Incoming Voice Calls"
    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
    setSound(null, null)  // No channel sound — we manage ringtone manually
    enableVibration(false) // No channel vibration — we manage vibration manually
    setBypassDnd(true)     // Show even in DND mode
}
```

---

## 7. Summary of Changes ✅ IMPLEMENTED

| File | Change | Status |
|------|--------|--------|
| `TVConnectionService.kt` | Removed `showIncomingCallOverLockScreen()` call from `startIncomingCallForegroundService()` | ✅ Done |
| `TVConnectionService.kt` | Moved wake lock acquisition (`FULL_WAKE_LOCK`) into `startIncomingCallForegroundService()` directly | ✅ Done |
| `TVConnectionService.kt` | Removed `showIncomingCallOverLockScreen()` call from exception fallback path | ✅ Done |
| `TVConnectionService.kt` | Removed redundant `wakeScreen()` call (PARTIAL_WAKE_LOCK) from ACTION_INCOMING_CALL handler — FULL_WAKE_LOCK in startIncomingCallForegroundService covers it | ✅ Done |
| `TVConnectionService.kt` | Deleted dead code: `showIncomingCallOverLockScreen()` (~55 lines) | ✅ Done |
| `TVConnectionService.kt` | Deleted dead code: `launchIncomingCallActivity()` (~75 lines) | ✅ Done |
| `TVConnectionService.kt` | Updated comments to reflect new fullScreenIntent-only behavior | ✅ Done |
| `IncomingCallActivity.kt` | Updated comments referencing old double-launch behavior | ✅ Done |
| `TVConnectionService.kt` | Channel uses `IMPORTANCE_HIGH` — sufficient for `setFullScreenIntent` | ✅ Verified |
| `TVConnectionService.kt` | `USE_FULL_SCREEN_INTENT` permission already in AndroidManifest.xml | ✅ Verified |
| `TVConnectionService.kt` | `FOREGROUND_SERVICE_IMMEDIATE` already set on notification builder (API 31+) | ✅ Verified |

### What was NOT changed (preserved existing behavior):
- `createIncomingCallNotification()` — already correct with `setFullScreenIntent`
- `IncomingCallActivity` — UI, answer/decline, call waiting, lock screen support all preserved
- `isMiuiDevice()` — still used by other code (IncomingCallActivity, TwilioVoicePlugin)
- Ringtone/vibration management
- `onCreateIncomingConnection()` flow
- Notification channel configuration

---

## 8. App Foreground/Open Behavior — Deep Dive

### Research Date: January 30, 2026

### Question: What happens when the app is open/in foreground and an incoming call arrives?

### Answer (from Android Official Documentation):

#### `setFullScreenIntent` Behavior by Android Version:

| Scenario | Pre-Tiramisu (< Android 13) | Tiramisu+ (Android 13+) |
|----------|------|------|
| **Device locked / screen off** | System launches fullScreenIntent Activity | System launches fullScreenIntent Activity |
| **Device unlocked / user active** | System _may_ show heads-up instead of launching intent | System **will** show heads-up with **emphasized action buttons** |
| **App is in foreground** | Same as unlocked — heads-up notification shown | Same — heads-up notification with system-styled Answer/Decline buttons |

#### Key Documentation Quotes:

> **setFullScreenIntent docs (API ref):**  
> "Prior to TIRAMISU, the system may display a heads-up notification instead of launching the intent, while the user is using the device."  
> "From TIRAMISU, the system UI will display a heads-up notification, instead of launching this intent, while the user is using the device. This notification will display with emphasized action buttons."

#### Heads-Up Notification Persistence:

| Permission State | Behavior |
|-----------------|----------|
| App holds `USE_FULL_SCREEN_INTENT` | Heads-up is **persistent** until user dismisses, snoozes, or app cancels ✅ |
| App does NOT hold `USE_FULL_SCREEN_INTENT` (API 34+) | Heads-up shown for only **60 seconds** |

Since our app declares `USE_FULL_SCREEN_INTENT` in the manifest, the heads-up notification will be **persistent** — it won't auto-dismiss after a timeout.

#### `FOREGROUND_SERVICE_IMMEDIATE` (API 31+):

Android may defer showing a foreground service notification for a short time to avoid visual disturbances. For incoming calls, this delay is unacceptable. Our notification builder already sets:

```kotlin
setForegroundServiceBehavior(Notification.FOREGROUND_SERVICE_IMMEDIATE)
```

This guarantees the notification appears **immediately** when the foreground service starts, with **zero deferral**.

- `FOREGROUND_SERVICE_DEFAULT` (0) — may suppress briefly
- `FOREGROUND_SERVICE_IMMEDIATE` (1) — **no suppression, show immediately** ✅ (what we use)
- `FOREGROUND_SERVICE_DEFERRED` (2) — deliberately suppress briefly

#### `Notification.CallStyle` (API 31+ / Android 12+):

Our notification uses `Notification.CallStyle.forIncomingCall()` on Android 12+:
- System renders **native** Answer/Decline buttons with emphasized styling
- Buttons appear directly in the heads-up notification
- Tapping Answer → `answerActivityPendingIntent` → opens IncomingCallActivity
- Tapping Decline → `declinePendingIntent` → sends ACTION_HANGUP to TVConnectionService
- The system decorates the notification with colorized call UI

For pre-Android 12, we use custom `RemoteViews` with manual Answer/Decline button click handlers — same behavior, just custom-styled.

### Notification Flags Verification:

| Flag / Setting | Value | Purpose | Status |
|---------------|-------|---------|--------|
| `setFullScreenIntent(PI, true)` | fullScreenPendingIntent | Auto-launch on locked; heads-up on unlocked | ✅ Set |
| `setContentIntent(PI)` | fullScreenPendingIntent | Tap notification body → opens IncomingCallActivity | ✅ Set |
| `setOngoing(true)` | true | Prevents user from swiping notification away | ✅ Set |
| `setAutoCancel(false)` | false | Prevents notification dismissal when tapped | ✅ Set |
| `setCategory(CATEGORY_CALL)` | "call" | Tells system this is an incoming call | ✅ Set |
| `setVisibility(VISIBILITY_PUBLIC)` | public | Show full notification on lock screen | ✅ Set |
| `setShowWhen(false)` | false | Don't show timestamp (not relevant for incoming call) | ✅ Set |
| `setForegroundServiceBehavior(IMMEDIATE)` | 1 | No delay in showing notification (API 31+) | ✅ Set |
| `Notification.CallStyle.forIncomingCall()` | style | System-rendered Answer/Decline (API 31+) | ✅ Set |
| Channel `IMPORTANCE_HIGH` | high | Required for fullScreenIntent + heads-up | ✅ Set |
| Channel `setSound(null, null)` | null | We manage ringtone manually | ✅ Set |
| Channel `enableVibration(false)` | false | We manage vibration manually | ✅ Set |

### Complete Incoming Call Flow (After Fix):

```
FCM push received (or app process already running)
  → TVConnectionService.onStartCommand(ACTION_INCOMING_CALL)
    → Safety checks (pending call, simultaneous call rejection)
    → startIncomingCallForegroundService(callInvite)
      → createIncomingCallNotification()
        → Builds notification with:
          • setFullScreenIntent(IncomingCallActivity PendingIntent, true)
          • setContentIntent(same IncomingCallActivity PendingIntent)
          • CallStyle.forIncomingCall(person, declinePI, answerPI) [API 31+]
          • Custom RemoteViews with Answer/Decline buttons [pre-API 31]
          • FOREGROUND_SERVICE_IMMEDIATE [API 31+]
          • CATEGORY_CALL, VISIBILITY_PUBLIC, ongoing, no auto-cancel
      → Acquires FULL_WAKE_LOCK (turns screen on)
      → startForeground(INCOMING_CALL_NOTIFICATION_ID, notification)
      → startRinging()
      
    ┌─ ANDROID DECIDES DISPLAY MODE ─────────────────────────┐
    │                                                          │
    │  IF device locked / screen off:                          │
    │    → Android launches fullScreenIntent                   │
    │    → IncomingCallActivity opens full-screen              │
    │    → User sees full-screen incoming call UI              │
    │    → User taps Answer/Decline on full-screen UI          │
    │                                                          │
    │  IF device unlocked / app in foreground:                 │
    │    → Android shows heads-up notification                 │
    │    → Pre-13: may show heads-up (system decides)          │
    │    → 13+: WILL show heads-up with emphasized buttons     │
    │    → Heads-up is PERSISTENT (USE_FULL_SCREEN_INTENT)     │
    │    → User can:                                           │
    │      • Tap Answer button → IncomingCallActivity opens    │
    │      • Tap Decline button → call rejected via service    │
    │      • Tap notification body → IncomingCallActivity opens│
    │      • Pull down to expand → see more details            │
    │                                                          │
    └──────────────────────────────────────────────────────────┘
```

### No Additional Changes Needed for App-Foreground Case:

The current implementation correctly handles all scenarios because:

1. **`setFullScreenIntent` with `IMPORTANCE_HIGH` channel** — Android automatically decides heads-up vs full-screen
2. **`FOREGROUND_SERVICE_IMMEDIATE`** — notification shown instantly, no deferral
3. **`CallStyle.forIncomingCall()`** — system-styled Answer/Decline in heads-up (Android 12+)
4. **Custom RemoteViews** — manual Answer/Decline in heads-up (pre-Android 12)
5. **`setContentIntent`** — tapping notification body opens IncomingCallActivity
6. **`setOngoing(true)` + `setAutoCancel(false)`** — notification stays until answered/declined
7. **`USE_FULL_SCREEN_INTENT` permission** — heads-up is persistent (no 60s timeout)
8. **`VISIBILITY_PUBLIC`** — full content shown on lock screen

### Potential Future Improvements:

1. **Android 14+ `canUseFullScreenIntent()` check**: If the user has revoked `USE_FULL_SCREEN_INTENT`, detect this and guide them to re-grant it via `ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT`
2. **MIUI fallback**: If MIUI blocks the `fullScreenIntent`, detect via timeout and manually launch. (Current dead code removed, but the IncomingCallActivity itself handles lock screen display via its own window flags)
3. **`IncomingCallActivity.isActivityAlive` flag**: Can be simplified since manual double-launch no longer occurs. However, it may still be useful for other purposes (e.g., preventing duplicate IncomingCallActivity instances from rapid notification taps)
