# Next Transfer M5 Clean Implementation Audit

## Scope and source boundary

- Session date: 2026-09-14.
- New detached implementation worktree:
  `C:\Users\sherl\Downloads\NT_M5_CLEAN_25d3f2f_20260914`.
- Baseline commit: `25d3f2f676ae8a60fc921587c80a6add56e75cfb`
  (`fix(m4): unify light fab theme colors`).
- Baseline `git status --short` was empty before this session's additive
  evidence, assets, or implementation files were created.
- Excluded forensic checkout left untouched:
  `C:\Users\sherl\Downloads\NT_B5_DEVELOP__deepseek-m7m8-20260911`.
- No dirty M5/M5.1/M5.2/M5.3 files, implementation approach, or assets were
  copied from that excluded checkout.
- No schema, M6, onboarding, privacy/auth architecture, package/version,
  signing, or permission change was made.

## Approved assets used verbatim

| Purpose | Session attachment source | Destination | SHA-256 |
| --- | --- | --- | --- |
| Flutter intro splash | `976b2d4c-15aa-4e51-8c54-e49f61550ee7.png` | `assets/branding/next_transfer_journey_begins.png` | `DB1024D1A81870FC3FC6A1DA74247B5BECFA6902D52EFE95455DFB2731F5EA20` |
| Launcher artwork | `2440693c-126a-4bc3-a05f-a0ff7f77d5a8.png` | `android/app/src/main/res/drawable-nodpi/nt_launcher_art.png` and legacy mipmaps | `10AC0342CEC2555623875C609830F41021363487A9626CBF7BEB0B26664789AF` |

The PNGs were copied as-is. No generative change, crop, zoom, or text was
added to either approved asset.

## M5 implementation

### Launcher icon

- `AndroidManifest.xml` now retains `@mipmap/ic_launcher` for both regular and
  round launcher icon declarations.
- Pre-API-26 legacy `ic_launcher.png` fallbacks use the approved icon artwork
  in every existing density bucket.
- `mipmap-anydpi-v26/ic_launcher.xml` is an Android adaptive icon with the
  approved full-square artwork as its foreground and matching deep-blue
  background. The source artwork's existing outer margin remains intact; no
  additional crop or zoom was introduced.

### Android required/system launch stage

- Pre-Android-12 launch backgrounds and NormalTheme are opaque `#002B73`,
  matching the approved splash's deep outer blue instead of white, black, or
  a transparent surface.
- Android 12+ uses the standard AndroidX `core-splashscreen:1.0.1` handoff:
  the platform owns the required minimal deep-blue stage and shows the
  approved launcher icon. `MainActivity.installSplashScreen()` is called
  before Flutter starts. There is no app-created timer, overlay, or second
  legacy splash design.
- The first resource attempt used framework `android:style/Theme.SplashScreen`
  and failed resource linking in this pinned SDK because that framework style
  and `android:postSplashScreenTheme` were unavailable. It was replaced with
  the compatible AndroidX theme API. The subsequent fresh profile build passed.

### Flutter intro and routing safety

- `NextTransferIntroSplash` is the existing `/startup` route's complete,
  opaque, full-screen body. It uses the approved splash asset with `BoxFit.cover`:
  portrait phone screens fill vertically, while only empty side artwork may be
  trimmed on taller ratios. The title and two-line tagline are never vertically
  cropped or stretched.
- The route has no `Timer`, `Future.delayed`, button, spinner, progress
  indicator, fade, or semi-transparent destination overlay.
- Existing `StartupRouteGuard` remains the routing authority. `/startup`
  exists only while real `StartupOpening` resolution is pending; it then routes
  to the existing Privacy Lock when required or to the ordinary destination.
  No private Home/Planner/Contacts/Maps widget is composed underneath the
  fully opaque intro surface.

## Files changed

- `pubspec.yaml`
- `lib/app/intro_splash.dart`
- `lib/features/startup/presentation/startup_screen.dart`
- `test/app/intro_splash_test.dart`
- `android/app/build.gradle.kts`
- `android/app/src/main/AndroidManifest.xml`
- `android/app/src/main/kotlin/com/nexttransfer/rmplanner/MainActivity.kt`
- Android launch, color, adaptive-icon, legacy-icon, and Android-12 splash
  resources under `android/app/src/main/res/`
- `assets/branding/next_transfer_journey_begins.png`
- This additive audit directory.

## Verification

- `flutter test test/app/intro_splash_test.dart test/app/router/startup_route_guard_test.dart --reporter expanded`
  - PASS: 4 tests.
- `flutter test test/features/privacy/presentation/privacy_journey_test.dart test/features/privacy/application/m1_privacy_fail_closed_test.dart --reporter expanded`
  - PASS: 19 tests.
- `flutter analyze --no-pub`
  - PASS: No issues found.
- `git diff --check`
  - PASS.
- `git diff --cached --check`
  - PASS.
- Fresh profile build using local JDK 21 and Android SDK:
  - PASS after the AndroidX compatibility correction.

## Fresh APK and verified data-preserving install

- APK: `build/app/outputs/flutter-apk/app-profile.apk`
- Size: `149309772` bytes.
- SHA-256: `B4945138D5824B6E9D7F0E8A52C27FA437B78CECC2EEDA30BF7D22883D2ED926`.
- Verified device endpoint: `adb-10620253B3004617-2m7ZVB._adb-tls-connect._tcp`.
- Device model: `Infinix X6731`.
- Hardware serial read from device: `10620253B3004617`.
- Installation command: `adb -s <verified endpoint> install -r <fresh profile APK>`.
- Install result: `Success`.
- Package: `com.nexttransfer.rmplanner`.
- Version retained: `0.1.0`, version code `1`.
- Pre-update `firstInstallTime`: `2026-07-27 15:42:22`.
- Post-update `firstInstallTime`: `2026-07-27 15:42:22` (preserved).
- Pre-update `lastUpdateTime`: `2026-09-14 21:55:47`.
- Post-update `lastUpdateTime`: `2026-09-14 22:30:17` (advanced).
- No uninstall, `pm clear`, downgrade, or owner-data wipe occurred.
- Stop/relaunch smoke: the Next Transfer process was alive after relaunch
  (`pidof` returned PID `25313`); no immediate crash was observed.

## Final repository boundaries

- The Git index is empty; no M5 file was staged.
- No commit was created.
- No push was performed.
- M6 was not started.
- Visual launch-frame acceptance (icon treatment, no white/black flash,
  system-to-Flutter continuity, and no perceived duplicate splash) remains an
  owner physical review item and is not inferred from automation.
