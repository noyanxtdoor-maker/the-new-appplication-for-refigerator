# VS16 M8 — ENGINEERING CLOSURE EVIDENCE (2026-09-13)

Branch: `develop/vs16-m7-m8-deepseek-20260911`
Worktree: `C:\Users\sherl\Downloads\NT_B5_DEVELOP__deepseek-m7m8-20260911`
Historical reference SHA only: `7b1395c10232b51f7d59464214ffe915415c4bb1`
Schema: **47** (`lib/core/database/app_database.dart:1476` → `_schemaVersionOverride ?? 47`)

## 1. Salvage of the "cancelled" differential

`.m8_candidate.json` (mtime 2026-09-13 21:09, stderr empty) is **structurally
COMPLETE**, not truncated:

| check | value |
|---|---|
| unparsable lines | 0 |
| suite events / distinct suite paths / `allSuites.count` | 297 / 297 / 297 (297 `*_test.dart` files in `test/`) |
| `testStart` / `testDone(all)` | 2618 / 2618 |
| `testDone` without `testStart` | 0 |
| run-level `done` event | present |
| production/test files modified after the run | 0 |

The run therefore finished; nothing had to be re-run for cancellation reasons.
`run duration = 1 367 372 ms` from the `done` event.

## 2. Regression missed by the accepted comparator (important)

The accepted `.m7_evidence/compare_full.py` cannot see an
accepted-PASS → candidate-FAIL change, because it only subtracts *bad* keys and
never compares a PASS outcome. Re-running it reproduced `NEW = 0`, while the
candidate had one more bad identity than the baseline bad set (113 vs 112).

A strict, outcome-aware comparator (`.m8_evidence/strict_differential.py`)
found exactly one such identity:

```
features/notifications/data/drift_notification_foundation_repository_test.dart
  ::bounded reminder-work query returns only active Event work in scope
  baseline PASS -> candidate FAILURE
  Expected: ['event-a-start', 'event-a-later']
  Actual:   []
```

**Classification: TEST FIXTURE, not a production regression.** The M8/S12 F03
law (comment cites contract section 34) makes the bounded reminder-work query
match the calling source kind's stable-key family prefix
(`ReminderSourceKind.stableKeyFamilyPrefix`, added 2026-09-13 16:52-16:54).
Production keys are always minted by `ReminderReconciler.stableKey`
(`reminder:calendarEvent:…`, `reminder:task:…`, `planning:weekly-review:…`,
`planning:awaiting-report:…`). The new M8 suite
`m8_recovery_ownership_test.dart::T41` asserts the law directly
("FAIL pre-fix: the owner-kind filter alone returned BOTH rows").

The legacy fixture seeded invented bare keys (`event-a-start`, `event-b`,
`task-a`) that belong to **no** family and that no production writer can emit.
`ReminderSourceKind` was already imported by that test; no production byte was
touched.

### Fixture correction (only change made this session)

`test/features/notifications/data/drift_notification_foundation_repository_test.dart`
(+26 −14): canonical family-prefixed keys via two local helpers (`eventKey`,
`taskKey`); every window / category / state / owner / argument-validation
assertion is unchanged. Re-run of that single suite with the identical Flutter
SDK, environment, JSON reporter and normalization law → `JSON_EXIT=0`, target
test `success`.

## 3. Final differential (merged candidate)

`.m8_evidence/candidate_merged.jsonl` = complete run with only that one suite's
records replaced by the refreshed single-suite capture (IDs remapped into a
disjoint namespace; refresh run-level bookkeeping excluded). Merged stream
re-verified structurally COMPLETE (297/297/297, 2618/2618, 0 unmatched, 0
unparsable).

Baseline: `.m7_evidence/baseline_complete_7b1395c.json`
Normalization: repository-relative suite path (after the last `/test/`) + `::`
+ full visible test name. Hidden/loading tests excluded as framework
bookkeeping.

| metric | value |
|---|---|
| accepted baseline identities | 1994 |
| candidate identities | 2293 |
| new failures | **0** |
| new errors | **0** |
| new skips | **0** |
| missing accepted identities | 4 (all authorized: 2 renames, 2 replaced) |
| unauthorized missing | **0** |
| regressions (accepted → worse) | **0** |
| same-severity outcome kind changes | **0** |
| unauthorized accepted outcome changes | **0** |
| inherited bad, outcome-identical to baseline | 112 |
| resolved inherited failures (baseline bad → candidate success) | 17, all declared |
| post-baseline suites present only in candidate | 35, **all GREEN**, 0 bad |
| post-baseline identities (new tests) | 303, of which bad **0** |

**VERDICT: PASS** (`.m8_evidence/differential_strict_final.txt`, exit 0)

### Authorized mappings

Renames (1:1)
1. `features/maps/data/saved_place_migration_test.dart::v33 to current (v38)…`
   → `…current (v47)…` (schema-47 label)
2. `features/notifications/vs16_m4_platform_safety_test.dart::durable work
   payload safety delivery WorkManager input is stable-key-only` → `…is the
   strict three-field allowlist` (+ a new legacy two-key/extra-key terminal
   no-op row)

Replaced (1:many, explicitly authorized Snooze deferral)
3. `snooze_action_dispatch_test.dart::Snooze applies in the response isolate
   before any deferred work` → the `T74 legacy Snooze representations terminate
   without executing` / `a legacy Snooze trigger never executes or enqueues`
   family
4. `snooze_action_dispatch_test.dart::retry retains original action time and
   generation` → same no-execution family

Resolved inherited failures (17, all declared in
`.m8_evidence/authorized_mappings.json`):
* 3 × maps/schema literals that asserted pre-v47 versions (`Expected: <38>/<39>
  Actual: <46>`) — relabelled to 47.
* 14 × baseline-capture widget-test errors with no assertion detail
  ("Test failed. See exception logs above.") that do not reproduce on the
  candidate tree; 12 of the same identities were already recorded as FIXED by
  the accepted 2026-09-12 differential.

## 4. Static gates

* `flutter analyze --no-pub --fatal-infos lib test` → **No issues found!** exit 0
* `git diff --check` → exit 0

## 5. Protected gates

| gate | result |
|---|---|
| schema | 47 |
| `AndroidManifest.xml` / `pubspec.yaml` / `pubspec.lock` modified | no (not in `git status`) |
| merged permission names vs HEAD | diff = 0 lines |
| permission set | ACCESS_COARSE_LOCATION, ACCESS_FINE_LOCATION, INTERNET, POST_NOTIFICATIONS, READ_CONTACTS, RECEIVE_BOOT_COMPLETED, USE_BIOMETRIC |
| exact alarm / background location / geofence / foreground service | 0 / 0 / 0 / 0 |
| new dependency | none (pubspec untouched) |
| reserved badge ID | `0x7ffffffe` present and reserved in allocation probe |
| Maps compass tap fix | PRESERVED (`NtPrecisionMapView.overSdkControl` → SDK keeps the compass north-up click) |
| Snooze | DEFERRED (T74 no-execution) |
| content | DORMANT |
| Saved Place reminders | DEFERRED |

## 6. APK (reused, not rebuilt)

```
build/app/outputs/flutter-apk/app-debug.apk
bytes     241 044 309
mtime     2026-09-13 20:30
sha256    e6e049bb60feacf1658a549382ce214bc49d16850983f120b347ac22252976d1
```

No `lib/` or `android/app` source byte changed after the build (newest source
mtime 20:23; only Gradle cache files under `android/.gradle/` are newer). The
APK is therefore current; the only post-build change is the test fixture above.

## 7. Device / git boundary

NOT installed, NO adb, NO owner DB mutation, NO commit, NO push, NO tag,
NO merge/rebase. Worktree left dirty and authoritative.
