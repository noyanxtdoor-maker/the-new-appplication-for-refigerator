# VS16 M8 — DEVICE / OWNER ACCEPTANCE EVIDENCE (2026-09-13)

Owner authorization: install / device acceptance phase, GRANTED.
Worktree: `C:\Users\sherl\Downloads\NT_B5_DEVELOP__deepseek-m7m8-20260911`
Branch: `develop/vs16-m7-m8-deepseek-20260911` (dirty, authoritative)
Mode: device acceptance only — no source, test, schema or Gradle edit; no commit; no push.

## 1. Certified APK identity

| | |
|---|---|
| path | `build/app/outputs/flutter-apk/app-debug.apk` |
| bytes | 241 044 309 (host) |
| sha256 | `e6e049bb60feacf1658a549382ce214bc49d16850983f120b347ac22252976d1` |
| built | 2026-09-13 20:30 |
| host hash match | **YES** |
| installed `base.apk` read-back | 241 044 309 / `e6e049bb60…` → **YES** |

The artifact installed before this session was a DIFFERENT, older build
(240 980 609 / `d7c9b6b8…`, installed 16:29:43), so this was a real upgrade,
not a no-op reinstall.

## 2. Device

Infinix X6731 · serial `10620253B3004617` · Android 14 / SDK 34 · arm64-v8a.
Transport rediscovered by mDNS, not assumed: `adb mdns services` →
`adb-10620253B3004617-2m7ZVB _adb-tls-connect._tcp 192.168.1.50:43615`.
All commands went through the pinned-serial helper `.m7_v47_evidence/adbdev.sh`,
which refuses to act unless `getprop ro.serialno` equals `10620253B3004617`.

## 3. Install

`adb install -r <certified apk>` → **Success**, exit 0. No `-d`, no uninstall,
no `pm clear`, no data wipe, no downgrade.

* `firstInstallTime` 2026-07-27 15:42:22 → UNCHANGED (preserved)
* `lastUpdateTime` → 2026-09-13 21:39:31
* versionCode 1 / versionName 0.1.0

## 4. Data preservation (read-only, all 45 tables)

Copies pulled with `adb exec-out run-as com.nexttransfer.rmplanner cat
/data/user/0/com.nexttransfer.rmplanner/app_flutter/next_transfer.sqlite`
(no `-wal`/`-shm` present, so the pull is a complete, checkpointed image), then
compared by the pre-existing read-only verifier
`.m7_v47_evidence/device_db_verify.py`.

| phase | user_version | integrity | quick | tables | counts |
|---|---|---|---|---|---|
| pre-install (1 748 992 B / `292c5069…`) | 47 | ok | ok | 45 | reference |
| post-install | 47 | ok | ok | 45 | preserved |
| post-launch | 47 | ok | ok | 45 | preserved |
| post-restart (after `am kill`) | 47 | ok | ok | 45 | preserved |

`NON-DESTRUCTIVE INSTALL CONTRACT = PASS` for every comparison, including the
M7 `detailed_show_*` columns (5/5 present). Owner anchors unchanged:
contacts 16, calendar_events 313, saved_places 5, planner_tasks 31, goals 28,
outcome_reports 144. No private content was dumped at any point.

## 5. Startup / restart

* launch → window relayout to 1080x2400, MainActivity committed visible, process
  alive, `Task.detached` splash gone.
* `database is locked` / `SQLiteException` / `E/flutter` / `FATAL EXCEPTION`
  occurrences for our package across launch AND restart logcat: **0**.
  (The 2026-09-12 v47 startup hang — `BEGIN IMMEDIATE` lock race — did NOT
  recur.)
* process recreation WITHOUT clearing data: HOME → `am kill
  com.nexttransfer.rmplanner` (pid 20429 gone) → relaunch → new pid 10630,
  MainActivity focused, schema 47, counts preserved.
  This is a killed-cached-process recreation, NOT OS force-stop semantics.

## 6. Background / recovery health

* WorkManager initialized: exactly **one** active `androidx.work` SystemJobService
  job for the package (`…u0a477/225 RUNNABLE`); no multiplying chain.
* Durable `background_work_requests`: 61 rows / **1** live (non-terminal) /
  **0** duplicate `stable_key` — identical at pre-install, post-launch and
  post-restart. The startup reconciliation pass moved the profile-scoped marker
  running → completed and re-armed one planning reminder; it fabricated nothing
  (row count unchanged, no new keys).
* The single live reminder is `planning:weekly-review`, `state=scheduled`,
  persisted transport marker **`m7n_` (native)**, platform ID 9103922,
  attempts 0, failure category null. The OS shows exactly ONE matching
  `RTC_WAKEUP` alarm (flutter_local_notifications `ScheduledNotificationReceiver`)
  whose `when` equals the row's `scheduled_for_utc`. One logical reminder ↔ one
  owner ↔ one alarm; no worker+native double ownership.
* KEY_FAMILY split on device confirms the F03 law is live:
  `reminder:calendarEvent` 39, `reminder:task` 6, `planning:awaiting-report` 4,
  `planning:weekly-review` 1, `reconcile:reminders` 1, `achievement:*` 11.

## 7. Notification surface (observed)

Exactly **one** posted record: `id=2147483646` = **0x7FFFFFFE**, the reserved
launcher-badge ID, channel `next_transfer_app_status`, `visibility=SECRET`,
`contentIntent` = startActivity (body tap opens the app), and **no `actions=`
field at all** → zero action buttons. Channels defined: `next_transfer_planning`,
`next_transfer_app_status`, `next_transfer_reminders` — no Snooze channel.
No reminder-channel notification was posted during this window, so the reminder
action surface itself (Test F/G) is also on the owner checklist.

## 8. Permissions

Runtime grants unchanged and pre-existing: POST_NOTIFICATIONS, ACCESS_FINE_LOCATION,
ACCESS_COARSE_LOCATION, READ_CONTACTS (all `USER_SET`). No optional permission
prompt appeared (`GrantPermissionsActivity` visible count = 0), no exact-alarm
special access, no background location, no geofence, no new foreground-service
declaration, no battery exemption. Merged library permissions (ACCESS_NETWORK_STATE,
ACCESS_WIFI_STATE, FOREGROUND_SERVICE*, RECEIVE_BOOT_COMPLETED) are unchanged
from the previously certified build.

## 9. Owner visual checklist (things a programmatic check cannot read)

Screenshots captured for review in this directory
(`screen_home.png`, `screen_final_for_owner.png`). The app was left focused on
its Home/MainShell. Steps, in order:

1. **Normal use (Test A)** — open Planner, Tasks, Events, Notifications Settings,
   Privacy & Data, Maps. Confirm all open with no redesign surprise.
2. **Diagnostics (Test D)** — Privacy & Data → Diagnostic Preview. Before
   `Prepare`, confirm background operational rows are NOT auto-exposed; enable the
   existing optional operational-details control; tap `Prepare`; confirm the
   factual rows (scheduler, pending reminders, recovery state, attempts, failure
   category) appear with no title/name/note/description/location/payload/source-id/
   profile-id/unique-name/source-revision/stack trace, and that
   unavailable values say Unavailable / Not recorded / Background details
   unavailable rather than fabricating success.
3. **Task recurrence (Test E)** — with a DISPOSABLE timed recurring Task, confirm
   one canonical Task row, no invented second Task per occurrence, no reminder
   for a date-only occurrence, no automatic completion.
4. **Reminder notification (Test F/G)** — let the live weekly-review reminder fire
   (or add a disposable near-future reminder) and confirm the notification shows
   NO Snooze and NO explicit Open button, body tap opens the app, and Privacy Lock
   renders the neutral `🔔 Next Transfer` / `You have a new notification.` copy.
   Some delay is ACCEPTED; fail only for stale private content, fabricated
   source-invalid reminders, or duplicate native+worker reminders.
5. **Maps (Test I)** — open Maps, rotate away from north, confirm the top-left
   compass needle appears and a compass tap returns to north-up without the
   target jumping or zoom changing; confirm Locate Me still behaves.
6. **Planner (Test J)** — confirm the current-time indicator still appears, Events
   and Tasks render normally, and no Weekly Review completion UI, Goal achievement
   notification or Snooze UI has been resurrected.

## 10. Boundary

No commit, no push, no tag, no merge, no device-data mutation beyond the
authorized `adb install -r`. No production or test source was edited in this
session.
