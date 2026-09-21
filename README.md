# Next Transfer RM Planner

Next Transfer is an Android-first, offline-first Flutter planner for returned
missionaries. The permanent Android organization is `com.nexttransfer`; the
permanent application ID and namespace are `com.nexttransfer.rmplanner`.

## Current implementation status

Repository bootstrap, Q0, VS-01 (Guest Startup and Local Profile), VS-02
(Privacy Lock, Permissions, and Privacy Center), VS-03 (Planner Day and Tasks),
VS-04 (Calendar Events), and VS-05 (Task-Event Linking) are implemented.
VS-06 (Outcome Reporting and Activity Ledger) and VS-07 (Home and Life
Indicators) are implemented. VS-08 (Weekly Planning Lifecycle) is implemented.
VS-09 and later slices are intentionally not started.

VS-01 provides:

- offline guest startup without an account;
- a resumable Local Profile onboarding checkpoint;
- atomic, idempotent creation of one Local Profile;
- six approved Life Indicator definitions without targets or Actual values;
- local-first routing, privacy-gate precedence, safe invalid-link recovery, and
  non-destructive database recovery;
- a minimal truthful Home state showing local, account, and sync status.

VS-02 adds:

- OS biometric/device-credential Privacy Lock with immediate background relock;
- Android screenshots, screen recordings, and normal recent-app previews are
  allowed under `OWNER-AMENDMENT-001`;
- just-in-time permission foundations with no optional runtime permission
  declared or requested;
- Privacy and Data, Permissions, diagnostic-preview, and deletion-impact views;
- fail-closed local-only/Extra Private policy rules;
- a secure future account-token boundary outside Drift and backups.

VS-03 adds:

- an Android-first Planner tab with an approved-reference week strip, hour
  grid, time-positioned Calendar Event read models, and permanent bottom
  navigation;
- deterministic date-only navigation and the locked All-day, Timed, Tasks,
  Overdue, Awaiting Report, then Changes presentation order;
- offline Task create, edit, detail, Completed, Skipped, Cancelled, and guarded
  reopen flows;
- schema version 3 with profile-scoped Tasks and append-only, retry-idempotent
  Task status history;
- atomic save-failure recovery, required-report completion protection, and no
  direct Actual mutation.

VS-04 adds:

- offline one-time, all-day, timed, daily, weekly, monthly, and yearly Calendar
  Events;
- deterministic date/count recurrence ends, month-end clamping, and Feb 29 to
  Feb 28 non-leap behavior;
- stable reportable occurrence identities, retained original IANA time zones,
  and converted display-local times without shifting all-day dates;
- explicit occurrence, this-and-future, and entire-series edit scopes;
- non-destructive cancellation and rescheduling with replacement links;
- factual report outcome read boundaries, Awaiting Report attention, immutable
  reported history, and no elapsed-time outcome inference;
- schema version 4 with profile-scoped Event series, append-only exceptions,
  and retry-idempotent operation records.

VS-05 adds:

- explicit, offline Task-to-Calendar-Event links from either detail flow;
- multiple Tasks per Event and multiple Events per Task without merged status;
- series links plus occurrence-level overrides for recurring Events;
- explicit canonical planning-source selection so a link never creates
  progress, Actual, or duplicate Scheduled Potential;
- atomic “Create Calendar Event from Task” and reschedule-link transfer;
- reversible unlinking, append-only link history, and recoverable broken
  references;
- schema version 5 with profile-scoped links and idempotent history operations.

VS-06 adds:

- autosaved local Draft reports for Tasks, Calendar Event occurrences, and
  structured manual Activity Reports;
- factual Completed / Happened, Partially Completed, and Did Not Happen
  outcomes with explicit fixed-decimal values where a unit permits them;
- atomic required-Task completion, report submission, and append-only Activity
  Ledger contribution writes;
- user-selected Life Indicator contributions with no title or note inference;
- retry-idempotent report submission and ledger entries;
- correction reports that preserve originals and append reversals plus
  replacements instead of editing history;
- effective-first Activity History and ledger-derived, read-only Actual values;
- schema version 6 with profile-scoped reports, Draft contributions, and
  append-only ledger entries.

VS-07 adds:

- a native Android-first Home destination using the approved dark charcoal,
  pink-accent, compact card composition;
- the fixed six-indicator order with a current Monday-Sunday period;
- separately labeled, non-blended Actual, Target, and Scheduled Potential;
- ledger-derived read-only Actual with contribution history;
- explicitly qualified future Task/Event potential with no title inference and
  canonical-source de-duplication;
- optional Not set, zero, and positive weekly targets with append-only revision
  history and no silently applied suggestion;
- isolated Current, Stale, Rebuilding, and Partial Failure presentation;
- schema version 7 with profile-scoped weekly target revisions.

VS-08 adds:

- one stable Local Profile / Monday-start Weekly Plan identity with the exact
  Monday-Sunday dates and a persisted IANA profile timezone;
- offline Draft, Active, Review Due, Reviewed, and Historical lifecycle states;
- separately labeled, factual Actual, user-controlled Target, and qualified
  Scheduled Potential values without any direct Actual write;
- explicit Task and Calendar Event occurrence commitments;
- a factual Weekly Review with unresolved-report acknowledgement, immutable
  indicator snapshots, and an optional local-only private reflection;
- post-review factual-change disclosure without rewriting the review snapshot;
- explicit incomplete-Task carryover decisions while Events never carry
  automatically;
- prior-week history and read-only reopening;
- a corrected native Planner time grid with duration-based and collision-aware
  event placement, current-time/initial scrolling, one-tap empty-time creation,
  deliberate long-press move/resize gestures, pinch zoom, configured snapping,
  and Event Type colors;
- a permanent top-bar workflow for date, filters, selection/delete, Search,
  Schedule, Day, Week, and Tasks without permanent Planner footer sections;
- an Event-Type-first, native bottom-sheet create/detail workflow and a
  destination-aware global `+` menu for Event, Task, Person, and Contact
  actions;
- all Events remain visible independently of Report Required, while an ended,
  unreported required Event receives a factual `Awaiting Report` overlay;
- local Event, Backup Event, Task, and Completed Task filters with the approved
  true/true/true/false defaults, plus a locally persisted pinch-zoom scale;
- Backup Appointment classification, linked-primary provenance, black-stripe
  treatment, and Scheduled Potential de-duplication;
- ten stable built-in Event Types, six exact Life Indicator mappings, explicit
  custom zero/one/many mappings, append-only mapping revisions, archive/restore,
  and locally persisted Planner settings;
- indicator-detail Schedule Activity routes that preselect the exact matching
  system Event Type while scheduling still creates no Actual;
- schema version 10 with profile timezone, plans, commitments, review snapshots,
  carryover decisions, Activity Types/Event Types, versioned mappings, Planner
  preferences, Event Type snapshots, Backup Appointment identity/provenance,
  Planner views/filters, and timeline zoom.

Remote account/sync code, provider Calendar integration, notifications, maps,
VS-09 Pathways, and later planning features remain outside the authorized
slice.

## Locked toolchain

- Flutter 3.44.7 / Dart 3.12.2
- Java, stated as two separate facts (M-1c, 2026-09-21): bytecode target 17
  (`sourceCompatibility` / `targetCompatibility` / Kotlin `jvmTarget`), built
  with JDK 21 — the pinned `maplibre_gl 0.26.2` compiles its own Android
  sources with Java 21, so a JDK 17 build fails in
  `:maplibre_gl:compileDebugJavaWithJavac`. Both values are enforced against
  `tool/toolchain.json` by `tool/verify_authority.dart`.
- Android compile/target SDK 36; minimum SDK 24

Exact Dart packages are recorded in `pubspec.lock`. See
[`tool/toolchain.json`](tool/toolchain.json) and
[`docs/implementation/dependency-review.md`](docs/implementation/dependency-review.md).

## Run locally

```bash
flutter pub get
dart run tool/verify_authority.dart
dart run build_runner build
dart format --output=none --set-exit-if-changed lib test integration_test tool
flutter analyze
flutter test
flutter build apk --debug
```

Environment selection uses compile-time values:

```bash
flutter run \
  --dart-define-from-file=tool/env/local.json.example
```

Equivalent non-secret examples exist for development, staging, and production.

No secret is required through VS-08. Never commit signing keys, private
environment files, service-role keys, or user database files.

Release APK assembly is fail-closed and requires all four values at build time:

```text
NEXT_TRANSFER_RELEASE_STORE_FILE
NEXT_TRANSFER_RELEASE_STORE_PASSWORD
NEXT_TRANSFER_RELEASE_KEY_ALIAS
NEXT_TRANSFER_RELEASE_KEY_PASSWORD
```

The key and passwords must come from the local/CI secret store. Never place
them in Git, `key.properties`, a tracked environment file, a command log, or
documentation. A local QA release may use a non-production test key; it must
never be distributed as the production signing identity.

## Repository layout

```text
android/           Android host project
lib/app/           App shell, theme, and routing
lib/core/          Database, diagnostics, platform, privacy, time, and IDs
lib/features/      Vertical feature modules; startup, privacy, planner, and weekly planning
test/              Unit, repository, migration, and widget tests
integration_test/  Android VS-01 through VS-08 smoke journeys
tool/              Toolchain metadata and authority verification
docs/              Approved sources, preserved baselines, and implementation evidence
.github/           PR quality and scheduled Android smoke workflows
```

## Authority and evidence

The approved Phase 3 workbook and vertical-slice specification are preserved
byte-for-byte under `docs/baseline/phase-3/`. Their hashes and the approval
overlay are recorded in
[`docs/implementation/phase-3-authority.md`](docs/implementation/phase-3-authority.md).
Slice mappings and verification evidence are maintained in
[`docs/implementation/vs-01-traceability.md`](docs/implementation/vs-01-traceability.md)
and
[`docs/implementation/vs-02-traceability.md`](docs/implementation/vs-02-traceability.md),
[`docs/implementation/vs-03-traceability.md`](docs/implementation/vs-03-traceability.md),
[`docs/implementation/vs-04-traceability.md`](docs/implementation/vs-04-traceability.md),
and
[`docs/implementation/vs-05-traceability.md`](docs/implementation/vs-05-traceability.md).

VS-06 evidence is recorded in
[`docs/implementation/vs-06-traceability.md`](docs/implementation/vs-06-traceability.md).

VS-07 evidence is recorded in
[`docs/implementation/vs-07-traceability.md`](docs/implementation/vs-07-traceability.md).

VS-08 evidence is recorded in
[`docs/implementation/vs-08-traceability.md`](docs/implementation/vs-08-traceability.md).
The correction source audit, owner amendment, and Android capture QA checklist
are recorded in
[`docs/audits/vs08-planner-event-types-reference-audit.md`](docs/audits/vs08-planner-event-types-reference-audit.md),
[`docs/audits/vs08-planner-detail-plus-zoom-reference-review.md`](docs/audits/vs08-planner-detail-plus-zoom-reference-review.md),
[`docs/decisions/OWNER-AMENDMENT-001-screen-capture-and-vs08-scope.md`](docs/decisions/OWNER-AMENDMENT-001-screen-capture-and-vs08-scope.md),
[`docs/decisions/vs08-planner-owner-refinement.md`](docs/decisions/vs08-planner-owner-refinement.md),
and
[`docs/implementation/vs-08-correction-manual-qa.md`](docs/implementation/vs-08-correction-manual-qa.md).

Do not begin VS-09 without explicit product-owner authorization after the VS-08
quality-gate report.

## APPROVED VISUAL AND PIXEL-REFERENCE CONTRACT

The repository contains approved visual reference images and matching
HTML reference files inside the `UI Preferences/` directory for:

- Home
- Planner
- Pathways
- Contacts
- More

### SOURCE PRECEDENCE

1. Approved Phase 3 workbook and vertical-slice specifications
   control behavior, data, privacy, navigation, business rules,
   feature scope, and acceptance criteria.

2. Approved PNG reference images
   are the primary visual authority.

3. Matching HTML files
   are secondary implementation references used to inspect:
   - spacing
   - margins
   - padding
   - component dimensions
   - typography scale
   - border radius
   - divider thickness
   - icon placement
   - alignment
   - timeline positioning
   - bottom-navigation proportions
   - color values
   - responsive relationships

When the PNG and HTML differ visually, the PNG image wins.

When either the PNG or HTML conflicts with the approved behavioral
specifications, the approved behavioral specifications win.

### IMPLEMENTATION REQUIREMENT

Before implementing each permanent destination:

1. Open the corresponding approved PNG image.
2. Open and inspect the corresponding HTML file.
3. Extract reusable measurements and design tokens.
4. Reimplement the screen natively in Flutter.
5. Compare the Flutter result against the PNG at the matching reference
   viewport.
6. Correct material differences in spacing, hierarchy, alignment,
   typography, borders, icon sizing, and component proportions.
7. Preserve responsive Android behavior and accessibility.

The HTML is not production code.

Do not:

- embed the HTML inside the Flutter app;
- use a WebView to render the application screens;
- copy Tailwind CSS or CDN dependencies into the production app;
- depend on external image URLs used by the HTML;
- reproduce simulated iOS system status bars or home indicators;
- hard-code the sample names, phone numbers, dates, progress values,
  event titles, temple names, or photographs;
- treat sample content as approved product data;
- allow the HTML to override domain or privacy requirements.

### ANDROID-FIRST REQUIREMENT

The reference files may visually simulate iOS-style status bars,
navigation areas, or home indicators.

Next Transfer remains Android-first.

Use:

- real Android safe areas;
- Android system status and navigation behavior;
- Flutter-native accessibility;
- responsive layouts for different Android screen sizes.

Preserve the approved visual composition without copying fake operating-
system chrome from the reference files.

### KNOWN SPECIFICATION EXCEPTION

The Pathways reference contains an example “Overall Progress 65%” card.

Do not implement a universal Pathways or Covenant Path percentage.

The visual container and hierarchy may be reused, but its actual content
must follow the approved requirements, using factual milestone counts,
statuses, scheduled items, or other permitted summaries.

### VISUAL FIDELITY EXPECTATION

The Flutter implementation should closely match the approved images in:

- dark charcoal and black surfaces;
- pink accent system;
- compact PMG-inspired density;
- top-bar structure;
- permanent bottom navigation;
- section spacing;
- card and list geometry;
- icon scale;
- text hierarchy;
- timeline grid and event positioning;
- divider and border treatment;
- floating-action-button position;
- active and inactive navigation states.

Do not replace the approved direction with:

- generic Material starter screens;
- default Flutter demo styling;
- glassmorphism;
- bento-style redesigns beyond what is explicitly shown;
- oversized hero sections;
- excessive gradients;
- bright unrelated color palettes;
- decorative gamification.

### VISUAL DEVIATIONS

A deviation is allowed only when required by:

- an approved product requirement;
- accessibility;
- Android system behavior;
- responsive layout;
- technical impossibility;
- privacy or security;
- prevention of data loss.

Material deviations must be documented with:

- affected screen;
- reference file;
- reason;
- resulting implementation.

Recommended folder naming:

```text
UI Preferences/
├── home/
│   ├── home-approved-reference.png
│   └── home-pixel-reference.html
├── planner/
│   ├── planner-approved-reference.png
│   └── planner-pixel-reference.html
├── pathways/
│   ├── pathways-approved-reference.png
│   └── pathways-pixel-reference.html
├── contacts/
│   ├── contacts-approved-reference.png
│   └── contacts-pixel-reference.html
└── more/
    ├── more-approved-reference.png
    └── more-pixel-reference.html
```

Use this exact repository-relative mapping:

```text
UI Preferences/
├── home-approved-reference.png
├── planner-approved-reference.png
├── pathways-approved-reference.png
├── contacts-approved-reference.png
├── more-approved-reference.png
│
└── stitch_next_transfer/
    ├── home_recreated/
    │   └── code.html
    ├── planner_recreated/
    │   └── code.html
    ├── pathways_recreated/
    │   └── code.html
    ├── contacts_recreated/
    │   └── code.html
    └── more_recreated/
        └── code.html
```

## APPROVED UI REFERENCE LOCATIONS

All approved permanent-destination visual references are located at:

- `UI Preferences/home-approved-reference.png`
- `UI Preferences/planner-approved-reference.png`
- `UI Preferences/pathways-approved-reference.png`
- `UI Preferences/contacts-approved-reference.png`
- `UI Preferences/more-approved-reference.png`

The corresponding HTML measurement references are located at:

- `UI Preferences/stitch_next_transfer/home_recreated/code.html`
- `UI Preferences/stitch_next_transfer/planner_recreated/code.html`
- `UI Preferences/stitch_next_transfer/pathways_recreated/code.html`
- `UI Preferences/stitch_next_transfer/contacts_recreated/code.html`
- `UI Preferences/stitch_next_transfer/more_recreated/code.html`

### REFERENCE PRECEDENCE

1. Approved Phase 3 workbook and vertical-slice specifications:
   authoritative for behavior, data, scope, privacy, and business rules.

2. The five approved PNG images:
   authoritative for the desired visual appearance.

3. The matching HTML files:
   implementation aids for pixel-level measurements, including spacing,
   padding, dimensions, typography, alignment, icon sizing, borders,
   timeline placement, and bottom-navigation proportions.

When the PNG and HTML differ visually, follow the PNG.

When either visual reference conflicts with an approved requirement,
follow the approved requirement and document the visual deviation.

### MANDATORY SCREEN WORKFLOW

Before implementing Home, Planner, Pathways, Contacts, or More:

1. Open the approved PNG for that destination.
2. Inspect the matching `code.html`.
3. Extract shared Flutter design tokens and component measurements.
4. Implement the screen natively in Flutter.
5. Compare the Flutter render against the PNG at a matching viewport.
6. Correct material differences before marking visual work complete.

Do not render these HTML files through a WebView.
Do not use the HTML as production code.
Do not hard-code the sample people, phone numbers, dates, activities,
progress values, photographs, or other demonstration content.

### KNOWN PATHWAYS EXCEPTION

Do not implement the sample universal “Overall Progress 65%” value.
The Pathways screen must follow the approved factual milestone/status
rules and must not calculate spiritual worthiness or a universal
Covenant Path percentage.
