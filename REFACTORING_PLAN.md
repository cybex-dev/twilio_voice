# Call Management Refactoring Plan

## Goal

Replace the fragile `_heldCall*` shadow-field pattern with a single `List<CallSession>` that mirrors how the native layers already work (Android's `activeConnections: HashMap`, iOS's `calls: [UUID: Call]`). This gives us one source of truth per call, eliminates manual save/restore/clear logic, and makes the code naturally extensible to 3+ calls / conference.

## Three Phases

| Phase | What | Risk |
|-------|------|------|
| **1 — Model + Manager** | Create `CallSession` data class + `CallSessionManager` service that owns the list. Pure additions, zero existing code changes. | None — additive only |
| **2 — BLoC Migration** | Wire the manager into the BLoC, rewrite handlers one-by-one, update state class. Each handler is a self-contained swap. | Medium — functional changes, test after each handler |
| **3 — Cleanup** | Remove dead code (`CallWaitingManager`, duplicate accept, stale flags), deduplicate audio routing, verify UI. | Low — deletions + cosmetic |

---

## Detailed Checklist

### Phase 1 — Model + Manager (additive, no breakage)

- [x] **1.1 Create `CallSession` model**
  - File: `plugins/twilio_voice/lib/models/call_session.dart`
  - Fields: `callSid`, `activeCall` (ActiveCall ref), `status` (enum: ringing, active, holding, disconnected), `connectionStatus`, `callerName`, `callerNumber`, `myNumber`, `callerProfileDetails`, `startedAt`, `direction`
  - Immutable with `copyWith()`, `Equatable`

- [x] **1.2 Create `CallStatus` enum**
  - Values: `ringing`, `active`, `holding`, `disconnected`
  - Maps 1:1 to native connection states (STATE_RINGING=2, STATE_ACTIVE=4, STATE_HOLDING=5, STATE_DISCONNECTED=6)

- [x] **1.3 Create `CallSessionManager`**
  - File: `plugins/twilio_voice/lib/models/call_session_manager.dart`
  - Internal state: `List<CallSession> _sessions`
  - Methods:
    - `addSession(CallSession)` — called on new incoming/outgoing call
    - `removeSession(String callSid)` — called on disconnect
    - `updateStatus(String callSid, CallStatus)` — called on hold/unhold/answer
    - `updateSession(String callSid, CallSession Function(CallSession) updater)` — generic field update
    - `getSession(String callSid) → CallSession?`
    - `get activeSession → CallSession?` (status == active)
    - `get heldSession → CallSession?` (status == holding)
    - `get ringingSession → CallSession?` (status == ringing)
    - `get allSessions → List<CallSession>`
    - `get sessionCount → int`
    - `get hasMultipleCalls → bool`
    - `clear()` — remove all sessions

- [x] **1.4 Export new files from plugin barrel**
  - Add exports to `plugins/twilio_voice/lib/twilio_voice.dart`

---

### Phase 2 — BLoC Migration (functional, test after each step)

- [x] **2.1 Add `CallSessionManager` to BLoC constructor**
  - Inject via constructor, store as `_sessionManager`
  - Keep old `_heldCall*` fields alive temporarily (dual-write during migration)

- [x] **2.2 Migrate `hold` handler**
  - Before: manually copies 7 fields into `_heldCall*` variables
  - After: `_sessionManager.updateStatus(callSid, CallStatus.holding)` — session already has all the data
  - Remove `_heldCall*` writes from this handler

- [x] **2.3 Migrate `unhold` handler**
  - Before: restores 7 `_heldCall*` fields back into state
  - After: `_sessionManager.updateStatus(callSid, CallStatus.active)` + emit state from session
  - Remove `_heldCall*` reads from this handler

- [x] **2.4 Migrate `swap` / `_onSwapCalls` handlers**
  - Before: swaps `_heldCall*` ↔ active state fields with temp variables
  - After: flip statuses — old active → holding, old held → active. Read from manager.
  - Simplify `_suppressSwapEventCount` / `_suppressSwapEventTimer` (or remove entirely if swap events are reliably ordered now)

- [x] **2.5 Migrate `callEnded` handler**
  - Before: checks `_heldCallActiveCall != null` to decide suppression, 5s safety timer
  - After: check `_sessionManager.sessionCount > 1`. Remove ended session. If remaining session exists, no navigation reset — just emit remaining session as active.
  - Remove `_recoverHeldCallFromWaitingCall` entirely (manager handles it)

- [x] **2.6 Migrate `heldCallEnded` handler**
  - Before: clears `_heldCall*` fields, emits `clearHeldCall: true`
  - After: `_sessionManager.removeSession(heldCallSid)`, emit state with `hasHeldCall: false`

- [x] **2.7 Migrate `declined` handler**
  - Same pattern as callEnded — use session manager to check remaining calls

- [x] **2.8 Migrate `_onCheckCallReallyEnded`**
  - Replace 5s timer + stale guard with: `if (_sessionManager.sessionCount == 0) → navigate away`
  - Much simpler, no timing dependency

- [x] **2.9 Remove all 7 `_heldCall*` private fields**
  - `_heldCallActiveCall`
  - `_heldCallNativeCallerName`
  - `_heldCallNativeCallerNumber`
  - `_heldCallNativeMyNumber`
  - `_heldCallCallerProfileDetails`
  - `_heldCallConnectionStatus`
  - Plus `_heldCallCallerProfileDetails` (the 7th)
  - Confirm zero references remain

- [x] **2.10 Update `TwilioCallEventState`** *(verified: existing fields work as-is with session manager)*
  - Keep `heldCallDisplayName` / `heldCallNumber` / `hasHeldCall` as **computed getters** (or copyWith params derived from manager) so UI widgets don't break
  - Alternative: add `CallSession? heldSession` field, UI reads `heldSession?.callerName`
  - Preserve `clearHeldCall` and `clearPendingCall` copyWith flags (they control UI transitions)

- [x] **2.11 Fix method channel side-effect**
  - `twilio_voice_method_channel.dart` line ~422: `call.activeCall = null` on "Call Ended"
  - Move this to AFTER the BLoC processes the event, or remove it and let BLoC/manager own the lifecycle
  - This eliminates the race condition identified earlier

---

### Phase 3 — Cleanup (deletions, low risk)

- [x] **3.1 Remove `CallWaitingManager`**
  - Deleted — was never imported or instantiated anywhere in the codebase.

- [ ] **3.2 Remove duplicate `_onAcceptWaitingCall` / `AcceptWaitingCall`** *(deferred — 4 distinct variants serve different UI flows)*
  - Consolidate into single handler

- [ ] **3.3 Remove `_isSwitchingCalls` flag** *(deferred — still needed for End & Accept timing)*
  - Replace with `_sessionManager.hasMultipleCalls` or direct status check

- [ ] **3.4 Simplify swap suppression** *(deferred — still needed for cross-platform event ordering)*
  - Remove `_suppressSwapEventCount` + `_suppressSwapEventTimer`
  - Use session status transitions to determine if swap is in progress

- [x] **3.5 Reset `_firstIncomingCallTime` on failed/declined calls**
  - Already handled — reset in `callEnded || declined` pre-switch block (line ~1013).

- [x] **3.6 Deduplicate audio route resolution**
  - Extracted `_resolveAudioRoute(String rawRoute, {bool? isBluetoothAvailable})` static helper
  - Replaced 6 duplicate switch blocks with single-line calls using Dart record destructuring

- [x] **3.7 Verify all UI widgets**
  - `CallActionBar` → `isCallInProgress`, `isMuted`, `isSpeaker`, `isOnHold` ✅
  - `HeldCallBanner` → `hasHeldCall`, `heldCallDisplayName`, `heldCallNumber` ✅ (now computed from sessions)
  - `CallScreen` → `isCallAnswered`, `isCallEnded`, navigation guards ✅
  - `IncomingCallScreen` → `pendingCall`, `callDirection` ✅
  - `CallTimerWidget` → `callLiveDuration` ✅
  - All widgets use BlocSelector on state fields — computed getters provide backward compat.

- [ ] **3.8 Align native ↔ Flutter event contract**
  - Document the event strings and their expected payload/behavior
  - Android and iOS should send identical events for identical scenarios (already mostly true after our bug fixes)

---

### Phase 4 — Sessions-First State & Dynamic UI (N-call support)

- [x] **4.1 Add `List<CallSession> sessions` to state**
  - Added as field in `TwilioCallEventState`, replacing `heldCallDisplayName` / `heldCallNumber` flat fields
  - BLoC snapshots `_sessionManager.allSessions` into state on each emit
  - Computed getters provide backward compat: `hasHeldCall`, `heldCallDisplayName`, `heldCallNumber`

- [x] **4.2 Add rich computed getters to state**
  - `activeSession` → first session with status == active
  - `heldSession` → first session with status == holding
  - `heldSessions` → all holding sessions (supports N held calls)
  - `ringingSession` → first session with status == ringing
  - `hasMultipleCalls` → sessions.length > 1
  - `canActOnActiveCall` → exactly 1 active session (enables nav buttons; disabled in conference)

- [x] **4.3 Add `callSid` to `WaitingCallModel`**
  - Tracks which session each UI entry represents
  - Needed for targeted swap (swap with a specific held call, not just "the" held call)

- [x] **4.4 Rewrite `ActiveCallScreenV3` to build dynamic call list**
  - Replaced hardcoded 2-entry `waitingCalls` with loop over `state.sessions`
  - Active call always first, then N held calls rendered from sessions list
  - Each held entry includes `callSid` for future targeted swap

- [x] **4.5 Move `callerProfileDetails` into per-session tracking**
  - `_onFetchCallerDetails`: after successful API fetch, syncs profile into active session via `_sessionManager.updateSession()`
  - On swap/hold, session already has the latest profile — no manual save/restore needed
  - State's `callerProfileDetails` remains for the active call (backward compat)

- [x] **4.6 Enable/disable nav buttons based on `canActOnActiveCall`**
  - `DialPadContainer` + `ActiveCallScreenDialPadContainer`: added `enabled` prop with `IgnorePointer` + `AnimatedOpacity`
  - `DialPadIconSheetV3` + `ActiveCallScreenDialPadIconContainerWidget`: wrapped Email/CRM/SMS row with `BlocSelector<…, bool>` on `state.canActOnActiveCall`
  - Enabled when exactly 1 active session (buttons fully opaque, tappable)
  - Disabled in conference mode (faded to 35% opacity, taps ignored)

- [x] **4.7 Support targeted swap (swap with specific held call)**
  - `SwapCalls` event now has optional `callSid` param
  - `_onSwapCalls`: uses `callSid` to pick specific held session via `_sessionManager.getSession()`, falls back to first held if null
  - UI (`_onSwap`): reads `state.heldSessions` to find the `callSid` at the tapped index, passes it to `SwapCalls(callSid: targetSid)`

---

## Model Design

### CallSession

```dart
class CallSession extends Equatable {
  final String callSid;
  final ActiveCall? activeCall;
  final CallStatus status;
  final String? connectionStatus;
  final String? callerName;
  final String? callerNumber;
  final String? myNumber;
  final Map<String, dynamic>? callerProfileDetails;
  final DateTime startedAt;
  final CallDirection direction;

  // copyWith(), props, etc.
}
```

### CallStatus

```dart
enum CallStatus {
  ringing,   // STATE_RINGING = 2
  active,    // STATE_ACTIVE = 4
  holding,   // STATE_HOLDING = 5
  disconnected, // STATE_DISCONNECTED = 6
}
```

### CallSessionManager

```dart
class CallSessionManager {
  List<CallSession> _sessions = [];

  void addSession(CallSession session);
  void removeSession(String callSid);
  void updateStatus(String callSid, CallStatus status);
  void updateSession(String callSid, CallSession Function(CallSession) updater);
  CallSession? getSession(String callSid);

  CallSession? get activeSession;   // status == active
  CallSession? get heldSession;     // status == holding
  CallSession? get ringingSession;  // status == ringing
  List<CallSession> get allSessions;
  int get sessionCount;
  bool get hasMultipleCalls;
  void clear();
}
```

---

## Expected Metrics

| Metric | Before | After |
|--------|--------|-------|
| Private shadow fields | 7 `_heldCall*` | 0 (manager owns data) |
| Handlers touching held-call state | 9 | 0 (manager methods) |
| Swap suppression mechanisms | 3 (count + timer + flag) | 1 (session status) |
| Max concurrent calls supported | 2 (hard-coded) | N (list-based) |
| Lines of save/restore/clear code | ~120 | ~0 |
| State held-call fields | 3 flat fields | 0 (computed from sessions) |
| Active call screen entries | Hardcoded 2 | Dynamic from sessions |
| Nav button logic | Always enabled | `canActOnActiveCall` gated |

---

*Created: 28 February 2026*
*Branch: `swap-update-3`*
