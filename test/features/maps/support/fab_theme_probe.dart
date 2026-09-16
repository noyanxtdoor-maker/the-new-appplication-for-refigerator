// M7 (2026-09-16) — test-only colour resolution helper.
//
// VS15-era map tests asserted `FloatingActionButton.backgroundColor` and
// `.foregroundColor` *constructor* properties. The accepted canonical theme law
// (see `AppTheme`: "App-owned primary FABs share one semantic role in every
// palette. Individual feature FABs must not bypass this with container colors:
// same theme + same primary-action role = primary/onPrimary.") means the map
// FABs deliberately pass NO colours and resolve them from
// `FloatingActionButtonThemeData` (primary / onPrimary).
//
// The retired VS15 assertions therefore read a pair the accepted architecture
// never sets. These helpers read the colour the widget tree ACTUALLY renders,
// so the tests keep locking the owner's visual law (primary surface, WHITE
// glyph) instead of an obsolete constructor argument.
//
// No production behaviour is involved: this file is imported by tests only.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The background the FAB at [key] actually paints with, following the
/// widget → FloatingActionButtonTheme → ColorScheme resolution chain.
Color? resolvedFabBackground(WidgetTester tester, Key key) {
  final material = tester.widget<Material>(
    find.descendant(of: find.byKey(key), matching: find.byType(Material)).first,
  );
  return material.color;
}

/// The colour the glyph inside the FAB at [key] actually paints with.
Color? resolvedFabIconColor(WidgetTester tester, Key key) {
  final richText = tester.widget<RichText>(
    find.descendant(of: find.byKey(key), matching: find.byType(RichText)).first,
  );
  final span = richText.text;
  return span is TextSpan ? span.style?.color : null;
}
