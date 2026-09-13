# VS16 M7 — DEEPSEEK INDEPENDENT IMPLEMENTATION — M7 ENGINEERING REPORT

Date: 2026-09-11 (final build UTC 2026-09-11T16:53:53Z)
Model: DeepSeek V4.1 Flash (independent benchmark run)
Base commit: `7b1395c10232b51f7d59464214ffe915415c4bb1` (schema 46)

Revision note: supersedes earlier reports of the same name. Earlier APK builds
(`081c5615…`, `c3759478…`, `377aa263…`, `e7c37cfe…`) are superseded.

---

## 0. HEADLINE — READ THIS FIRST (honest status)

**The M7 ENGINEERING GATE IS NOT PASSED.** Steps 1 (complete) and 2 (partial) of
contract §67 are implemented, and the full named differential, the analyzer and
the APK build are all green for that scope.

Implemented:
- **Step 1 (complete)** — purpose preserve/set/clear APIs; O8 shared formatter;
  typed creation intent; notification renderer (exact frozen copy); enrichment
  sanitizer; **live-link enrichment port + resolver** (P18/P19).
- **Step 2 (partial)** — strict three-key `CanonicalReminderWorkSpec` + parser;
  legacy/malformed delivery input as a terminal handled no-op; §64 Event-end
  relevance wired end-to-end for Event rows; §6 transport selection (injected
  worker port, sticky `m7w_` marker, native fallback) with tests.

NOT implemented (so the gate is not passed):
production wiring of the worker port, `ReminderDeliveryService`, the
generation/claim/CAS law and platform-id allocator, truthful WorkInfo mapping,
the WorkInfo state matrix, the dispatcher Snooze no-op, Event location
enrichment, form finalization/provenance, O9 display resolver, warm
`ensureLoaded`, same-transaction repair markers, horizon/recovery ownership
changes, and the `m7n_` native suffix (§12.4).

Consequences that must not be glossed over:
- The APK in §11 is a real debug build of this tree but is **not a complete M7
  artifact** and must not be used as an M7 acceptance artifact. It is
  **byte-identical** to the previous build because the new libraries are not yet
  referenced by any production path (Dart tree-shakes unreferenced libraries).
- Because M7 is incomplete this is **not** a valid apples-to-apples M7
  comparison against GLM.

---

## 1. WORKTREE / BRANCH / HEAD

| Item | Value |
|---|---|
| Worktree | `C:\Users\sherl\Downloads\NT_B5_DEVELOP__deepseek-m7m8-20260911` |
| Branch | `develop/vs16-m7-m8-deepseek-20260911` |
| HEAD | `7b1395c10232b51f7d59464214ffe915415c4bb1` |
| Base commit | verified present — `feat(planner): finalize live Goal Event Types and Astra follow-up` |
| Remote | none configured for this branch; no fetch/rebase/substitution performed |

**Deviation from the instruction premise (disclosed):** at the start of this run
the assigned worktree directory existed but was **empty**, and the branch
`develop/vs16-m7-m8-deepseek-20260911` **did not exist**. Both were created from
the exact SHA, so "verify HEAD is exactly that commit" was satisfied by
construction rather than verification.

Isolation respected: GLM's worktree, the failed candidate, the forensic snapshot
and the canonical `NT_B5_DEVELOP` working tree were **not** read, copied, diffed,
cherry-picked, reset, cleaned or stashed.

---

## 2. PRODUCTION FILES CHANGED (10 modified, 5 new)

| Path | Change |
|---|---|
| `lib/features/notifications/domain/reminder_policy_label.dart` | **NEW** — O8 shared formatter (`0 → "At event time"`, `1 → "1 minute before"`, `N≥2 → "<N> minutes before"`) |
| `lib/features/notifications/domain/contact_follow_up_creation_intent.dart` | **NEW** — P3 immutable typed provenance |
| `lib/features/notifications/application/reminder_notification_renderer.dart` | **NEW** — P17 exact frozen copy (generic / Event / Task / follow-up / location) |
| `lib/features/notifications/application/reminder_enrichment_resolver.dart` | **NEW** — P18 `ReminderEnrichmentSanitizer` (grapheme caps, control/bidi strip, URI/coordinate rejection) + `ReminderEnrichmentSource` port + `ReminderEnrichmentResolver` |
| `lib/features/notifications/data/drift_reminder_enrichment_source.dart` | **NEW** — P19 live-read port impl: effective Event series+occurrence link overlay, whole-source Task link check, active/unmerged/undeleted Contact gate. Never reads history |
| `lib/features/notifications/domain/reminder_policy.dart` | P8 — `unsetContactId` sentinel + explicit purpose/contact set/clear semantics |
| `lib/features/notifications/application/reminder_reconciler.dart` | P9 **F02 fix**; §64 `ReminderDeliveryEligibility` + optional `endsAtUtc`; §6 transport selection |
| `lib/core/background/workmanager_background_work_gateway.dart` | P14 — `CanonicalReminderWorkSpec` + dispatcher terminal no-op for legacy/extra input |
| `lib/features/planner/application/calendar_event_providers.dart` | §64 — supplies canonical `endsAtUtc` |
| `lib/features/planner/application/event_reminder_horizon_reconciler.dart` | §64 — keeps a due Event while `now < E` |
| `lib/features/notifications/presentation/reminder_time_picker.dart` | O8 consumer |
| `lib/features/planner/presentation/calendar_event_form_screen.dart` | O8 consumer |
| `lib/features/planner/presentation/task_form_screen.dart` | O8 consumer |
| `lib/features/settings/presentation/notifications_settings_screen.dart` | O8 consumer |

Diff: **12 files changed, 746 insertions(+), 53 deletions(-)** (tracked) plus
5 new production files.

---

## 3. TESTS ADDED / CHANGED

**New suites**
- `test/features/notifications/domain/reminder_policy_label_test.dart` (OAT3/OAT4) — 6 tests.
- `test/features/notifications/application/m7_enriched_delivery_test.dart` — 22 tests across three groups:
  - **OAT15 §64 relevance** (8): offset-0 at `T = S`, delivery just before `E`, `now ≥ E` obsolete, long-lead not expired by a fixed 15-minute rule, pre-target arming, Quiet-Hours suppression vs `Q == T` valid, invalid bounds, `isDeliverable`.
  - **T28/T29/T31 copy + sanitization** (7): frozen Generic copy with zero enrichment tokens, baseline Event/Task templates, one-line-each follow-up/notes/location ordering, Task never gaining a location line, URI/coordinate rejection with normal addresses preserved, grapheme caps and bidi stripping.
  - **OAT5/OAT6 live freshness through the real Drift port** (7): rename reads the CURRENT name; two renames keep only the newest; archived/merged Contacts never resolve; blank name is not enrichment; an occurrence-level `removed` link drops that date while the series stays live; unlinked Contact does not resolve; a Contact binds by id not by name.

**Extended**
- `notification_foundation_domain_test.dart` — T1/T2 Contact-id pins; T3/T5 omitted-preserves / explicit-standard-clears.
- `reminder_reconciler_test.dart` — T4 (F02 fail-first), T32 (§64 wiring), T21/T22/T24 (transport selection).
- `vs16_m4_platform_safety_test.dart` — strict three-field allowlist + legacy/extra-key terminal no-op (the single intentional replacement).

**+35 new tests; 1 intentional replacement.** No other existing assertion was
weakened, renamed, skipped or golden-loosened.

---

## 4. BASELINE vs CANDIDATE NAMED DIFFERENTIAL — CERTIFIED

Fresh baseline at exact `7b1395c` (pristine detached worktree
`NT_B5_DEVELOP__baseline-7b1395c-20260910`) vs the final candidate; identical
SDK/fixtures; `flutter test --no-pub --reporter json` (complete run, 22m38s).

| Metric | Baseline | Candidate |
|---|---|---|
| Tests executed | 1994 | 2028 |
| success | 1876 | 1910 |
| failure | 21 | 21 |
| error | 89 | 89 |
| skipped | 8 | 8 |
| suites | 271 | 271 |

| Gate | Result |
|---|---|
| New failures | **0** |
| New errors | **0** |
| New skips | **0** |
| Missing accepted names | **1 — the intentionally replaced platform-safety assertion (§3)** |
| Unauthorized outcome changes | **0** |
| Delta | **+35 new tests, +35 successes** |

Full-name set diff: 35 added (all new M7 tests), 1 removed (the deliberately
replaced `delivery WorkManager input is stable-key-only`). Arithmetic:
1994 − 1 + 35 = 2028.

**Run reliability:** earlier full-suite attempts aborted incomplete (1615 / 1743
events, one exit 127) and were discarded. Root cause identified: a full
`flutter test` must not run concurrently with a Gradle build or another test run.
Only complete runs are reported.

---

## 5. INHERITED FAILURES / ERRORS / SKIPS (disclosed, not fixed)

Inherited at 7b1395c, identical in baseline and candidate. Largest contributors:
`vs16_m4_delivery_snooze_test` (6F/34E), `goal_icon_d1_golden_test` (12E),
`planner_interactive_day_pager_cache_test` (4E),
`v38_notification_foundation_migration_test` (3F), `home_indicator_journey_test`
(3E), `light_ui_c_contract_test` (3E),
`planner_task_day_visibility_owner_fail_test` (3E), plus ~22 suites with 1–2 each.

**Baseline skips (8, all fixture-gated):** `goal_event_type_picker_visibility_test` (5),
`recovery/normal_event_type_linkage_test` (2), `recovery/phase_a_recovery_test` (1).

None were "silently fixed" and none are attributed to this work.

---

## 6. ANALYZER

```
flutter analyze --no-pub --fatal-infos lib test
→ Analyzing 2 items...
→ No issues found! (ran in 6.8s)
→ exit 0
```

Real process, real exit code, re-run after the final source change.

---

## 7. SCHEMA v46

`lib/core/database/app_database.dart:1407`
`int get schemaVersion => _schemaVersionOverride ?? 46;` — **unchanged**.
No schema/generated edit, no generator run, no migration. The enrichment port
reads existing tables only.

---

## 8. PUBSPEC / DEPENDENCY PRESERVATION

`git diff --name-only -- pubspec.yaml pubspec.lock` → **empty**. No dependency
added, removed or upgraded. `characters: 1.4.1` (already a direct dependency) is
used for grapheme limiting; `crypto` (already declared) for the worker-name digest.

---

## 9. ANDROID PERMISSION DIFF = ZERO

`git diff --name-only -- android/` → **empty**. No manifest, Gradle, signing,
package or SDK change. Source permissions unchanged: `USE_BIOMETRIC`,
`READ_CONTACTS`, `ACCESS_COARSE_LOCATION`, `ACCESS_FINE_LOCATION`, `INTERNET`,
`POST_NOTIFICATIONS`, `RECEIVE_BOOT_COMPLETED`. The APK's extra permissions
(VIBRATE, FOREGROUND_SERVICE, FGS_SHORT_SERVICE, WAKE_LOCK, ACCESS_NETWORK_STATE,
USE_FINGERPRINT, ACCESS_WIFI_STATE, DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION) are
plugin-inherited and present at baseline. **No new declaration or activation.**

---

## 10. PROTECTED-FILE / FORBIDDEN-FEATURE VERIFICATION

- Protected byte-identical: `app_database.dart` (+generated), `pubspec.*`,
  theme/font/assets, Maps persistence/services, Goal/ledger/accounting,
  Event Type binding/presentation, Education defaults, Study & Planning alias,
  Android manifests/signing.
- The enrichment port is **read-only** and never touches
  `event_occurrence_participants`, `readTimeline` or `readContactDetail` — no
  historical fallback, no data repair.
- **Snooze:** not exposed or executed; dormant path left intact.
- **Saved Place reminders:** none added.
- **Explicit OPEN action:** none added.
- No new Android permission, native bridge, receiver, foreground service, exact
  alarm or background location.

Note: `git status --porcelain` lists ~25 extra ` M` entries under
`lib/features/goals/...`. These are **stale index stat-cache artefacts** of this
environment — `git diff` reports only the 12 real files.

---

## 11. APK (current artifact)

| Field | Value |
|---|---|
| Absolute path | `C:\Users\sherl\Downloads\NT_B5_DEVELOP__deepseek-m7m8-20260911\build\app\outputs\flutter-apk\app-debug.apk` |
| Size | **208,136,668 bytes** (~198.5 MiB) |
| SHA-256 | `d8d4c2bc5ad6e1f200aa5bd588185e49e694256ff9b18bf858420c416f1ce27c` |
| Build timestamp (UTC) | start `2026-09-11T16:49:48Z`, end `2026-09-11T16:53:53Z` |
| Command | `flutter build apk --debug --no-pub` |
| Exit | 0 — `√ Built build\app\outputs\flutter-apk\app-debug.apk` |
| package / version | `com.nexttransfer.rmplanner` / versionName `0.1.0`, versionCode 1 |
| compileSdk / minSdk / targetSdk | 36 / 24 / 36 |
| Toolchain | Flutter 3.44.7 (stable, rev 84fc5cbb22) • Dart 3.12.2 • JDK 21.0.12.1+1 |

**The SHA-256 is unchanged across the last two builds.** This is expected, not a
stale artifact: none of the new libraries (renderer, resolver, enrichment source)
is referenced by a production path yet, so Dart tree-shaking excludes them and the
packaged bytes are identical. The build was re-run (exit 0) to confirm the tree
still compiles and packages.

---

## 12. LIMITATIONS / UNRESOLVED ENGINEERING ISSUES

1. **M7 substantially incomplete** — steps 1 complete, step 2 partial,
   steps 3–6 not started. Dominant limitation.
2. **The renderer, resolver and enrichment port are not wired into any
   production path yet.** They are implemented, exported and unit-tested, but
   nothing calls them — which is why the APK hash is unchanged. Wiring requires
   `ReminderDeliveryService`, which does not exist.
3. **Event location enrichment is not implemented.** The renderer supports a
   Location line and the sanitizer validates it, but no port method reads
   `CalendarEventOccurrence.locationText` yet.
4. **Environment instability (reproduced):**
   - `git worktree add -b` / `git branch` silently fail to persist nested refs;
     worked around with a hand-written ref file + `git pack-refs --all`.
   - `git worktree add` corrupts the recorded path for POSIX `/c/...` inputs.
   - The sandbox denies writes outside the workspace (Gradle `build/`), so builds
     run outside the sandbox.
   - The WorkBuddy proxy breaks `flutter test` ("Invalid WebSocket upgrade
     request"); proxy vars must be unset.
   - `flutter.bat` requires `PROGRAMFILES(X86)`, unset in Git Bash.
   - **File writes are occasionally lost** — several `Edit` calls reported success
     with no on-disk change (the reconciler needed two retries, the resolver and
     test import blocks one each, and this report had to be rewritten wholesale
     three times). Every write here was re-verified by reading the file back.
   - **A full `flutter test` must not run concurrently with a Gradle build or
     another test run**, or it aborts incomplete.
5. **Deviation from §6 (disclosed):** only the `m7w_` worker marker is persisted;
   native rows keep their historical render token instead of gaining an `m7n_`
   suffix, because "no marker" already means "select transport from current
   truth" — and because forcing `'m7n_generic'` broke durable-row matching in
   existing fixtures (a real regression found and fixed in this run).
6. **Transport selection is not wired in production** — nothing constructs
   `scheduleWorker`, so every key currently stays native. Deliberate: it
   guarantees a key is never marked `m7w_` without a real worker registration.
7. `CanonicalReminderWorkSpec` validates `source_revision`; the delivery service
   that consumes it is not implemented.
8. `ReminderDeliveryEligibility` is wired end-to-end for Event rows; the delivery
   service's use of it is outstanding. Task/planning keep their own relevance
   rules (§64: do not apply Event E to Task/planning).
9. No commit, tag, push, merge, rebase or cherry-pick performed; nothing staged.
   No device/ADB action taken.
10. `android/local.properties` is a gitignored local build file; not a source change.

---

## 13. FINAL STATUS

```
DEVICE STATUS = NOT INSTALLED
COMMIT STATUS = NOT COMMITTED
PUSH STATUS   = NOT PUSHED
```

```
M7 ENGINEERING GATE  = NOT PASSED (partial implementation)
M7 SEQUENCE STEP 1   = COMPLETE (purpose APIs, O8, typed intent, renderer,
                       sanitizer, live-link enrichment port + resolver)
M7 SEQUENCE STEP 2   = PARTIAL (three-key spec/parser; §64 wired end-to-end for
                       Event rows; transport selection implemented + tested but
                       not wired in production; generation/CAS, WorkInfo,
                       targeted worker and Snooze no-op not implemented)
M7 SEQUENCE STEPS 3-6 = NOT IMPLEMENTED
M8                   = NOT STARTED (as instructed)
OWNER DEVICE AUTHORIZATION = NOT REQUESTED
FULL DIFFERENTIAL    = CERTIFIED (0 new failures / 0 new errors / 0 new skips)
```

Evidence artefacts (worktree, untracked): `.m7_evidence/baseline_tests.json`,
`candidate_tests10.json` (certified complete run), `candidate_tests4/8/9.json`
(earlier certified runs), `candidate_tests5/6/7.json` (regression / incomplete),
`analyze8.out`, `build8.out`, `parse_tests.py`, `coverage_check.py`,
`list_inherited.py`.

**STOP** after this report and the APK, per instruction.
