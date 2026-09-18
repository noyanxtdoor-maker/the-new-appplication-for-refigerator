import 'dart:convert';

import 'package:rmplanner/core/colors/vs11_color_system.dart';
import 'package:rmplanner/features/planner/domain/event_type.dart';

/// The four built-in Contact Groups whose colors are shared by Contacts and
/// the Colors settings surface.  The group identity is stable; the label is
/// intentionally kept outside the color preference so a future rename does
/// not orphan the saved color.
final class ContactGroup {
  const ContactGroup({
    required this.id,
    required this.label,
    required this.defaultColorArgb,
  });

  final String id;
  final String label;
  final int defaultColorArgb;
}

abstract final class ContactGroupDefaults {
  static const ContactGroup family = ContactGroup(
    id: 'family',
    label: 'Family',
    defaultColorArgb: 0xFFEBC766,
  );
  static const ContactGroup friends = ContactGroup(
    id: 'friends',
    label: 'Friends',
    defaultColorArgb: 0xFF7FB7D1,
  );
  static const ContactGroup avoid = ContactGroup(
    id: 'avoid',
    label: 'Avoid',
    defaultColorArgb: 0xFFD35A70,
  );
  static const ContactGroup other = ContactGroup(
    id: 'other',
    label: 'Other',
    defaultColorArgb: 0xFF969B9E,
  );

  static const List<ContactGroup> ordered = <ContactGroup>[
    family,
    friends,
    avoid,
    other,
  ];

  static ContactGroup byId(String id) {
    return ordered.firstWhere((group) => group.id == id, orElse: () => other);
  }
}

/// One Goal-scoped Event Type presentation-name override stored in the
/// profile's Planner Preferences document (schema 46, additive JSON field).
///
/// Identity is the REAL Goal UUID plus the canonical Event Type stable key
/// that Goal occupies. This is NOT a new Event Type, NOT a `goal:<goalId>`
/// activity-types row, and never an accounting/ownership record; it is local
/// profile presentation metadata only.
final class GoalEventTypeNameOverride {
  const GoalEventTypeNameOverride({
    required this.eventTypeStableKey,
    required this.name,
  });

  final String eventTypeStableKey;
  final String name;

  Map<String, Object> toJson() => <String, Object>{
    'eventTypeStableKey': eventTypeStableKey,
    'name': name,
  };

  static GoalEventTypeNameOverride? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final key = value['eventTypeStableKey'];
    final name = value['name'];
    if (key is! String || key.trim().isEmpty) {
      return null;
    }
    if (name is! String || name.trim().isEmpty) {
      return null;
    }
    return GoalEventTypeNameOverride(
      eventTypeStableKey: key,
      name: name.trim(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is GoalEventTypeNameOverride &&
      other.eventTypeStableKey == eventTypeStableKey &&
      other.name == name;

  @override
  int get hashCode => Object.hash(eventTypeStableKey, name);
}

final class PlannerColorPreferencesDocument {
  const PlannerColorPreferencesDocument({
    required this.events,
    required this.groups,
    this.goalEventTypeNames = const <String, GoalEventTypeNameOverride>{},
  });

  final Map<String, EventColorPreference> events;
  final Map<String, int> groups;

  /// Presentation-name overrides keyed by the real Goal UUID. A missing
  /// entry means AUTO (display name follows the Goal title). Invalid raw
  /// entries are dropped from this validated map but are preserved verbatim
  /// in storage by the presentation document store on unrelated writes.
  final Map<String, GoalEventTypeNameOverride> goalEventTypeNames;
}

/// The two user-editable colors that describe one Planner Event Type.
///
/// Preferences are keyed by an Event Type stable key rather than copied onto
/// Calendar Event rows. This keeps color changes presentation-only and lets a
/// renamed or re-seeded Event Type retain its saved colors.
final class EventColorPreference {
  const EventColorPreference({
    required this.accentArgb,
    required this.surfaceArgb,
  });

  final int accentArgb;
  final int surfaceArgb;

  Map<String, int> toJson() => <String, int>{
    'accent': accentArgb,
    'surface': surfaceArgb,
  };

  static EventColorPreference? fromJson(Object? value) {
    if (value is! Map) {
      return null;
    }
    final accent = _readArgb(value['accent']);
    final surface = _readArgb(value['surface']);
    if (accent == null || surface == null) {
      return null;
    }
    return EventColorPreference(accentArgb: accent, surfaceArgb: surface);
  }

  static int? _readArgb(Object? value) {
    if (value is! num || !value.isFinite) {
      return null;
    }
    final integer = value.toInt();
    return integer >= 0 && integer <= 0xFFFFFFFF ? integer : null;
  }

  @override
  bool operator ==(Object other) =>
      other is EventColorPreference &&
      other.accentArgb == accentArgb &&
      other.surfaceArgb == surfaceArgb;

  @override
  int get hashCode => Object.hash(accentArgb, surfaceArgb);
}

/// JSON codec for the existing profile-scoped Planner Preferences row.
abstract final class EventColorPreferenceCodec {
  static PlannerColorPreferencesDocument decodeDocument(String? encoded) {
    if (encoded == null || encoded.trim().isEmpty) {
      return const PlannerColorPreferencesDocument(
        events: <String, EventColorPreference>{},
        groups: <String, int>{},
      );
    }
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) {
        return const PlannerColorPreferencesDocument(
          events: <String, EventColorPreference>{},
          groups: <String, int>{},
        );
      }
      final hasDocumentShape =
          decoded.containsKey('events') ||
          decoded.containsKey('groups') ||
          // An envelope is recognized even when events/groups are empty so
          // name-only documents are never misread as legacy flat colors.
          decoded.containsKey('goalEventTypeNames');
      final eventValue = hasDocumentShape ? decoded['events'] : decoded;
      final groupValue = hasDocumentShape ? decoded['groups'] : null;
      final groups = <String, int>{};
      if (groupValue is Map) {
        for (final entry in groupValue.entries) {
          final key = entry.key;
          final value = entry.value;
          if (key is! String || key.trim().isEmpty || value is! num) {
            continue;
          }
          final argb = value.toInt();
          if (argb >= 0 && argb <= 0xFFFFFFFF) {
            groups[key] = argb;
          }
        }
      }
      return PlannerColorPreferencesDocument(
        events: _decodeEventMap(eventValue),
        groups: Map<String, int>.unmodifiable(groups),
        goalEventTypeNames: _decodeGoalEventTypeNames(
          hasDocumentShape ? decoded['goalEventTypeNames'] : null,
        ),
      );
    } on FormatException {
      return const PlannerColorPreferencesDocument(
        events: <String, EventColorPreference>{},
        groups: <String, int>{},
      );
    }
  }

  static Map<String, EventColorPreference> decode(String? encoded) {
    return decodeDocument(encoded).events;
  }

  static String encode(Map<String, EventColorPreference> preferences) {
    return jsonEncode(_encodeEventMap(preferences));
  }

  static String encodeDocument({
    required Map<String, EventColorPreference> events,
    required Map<String, int> groups,
    Map<String, GoalEventTypeNameOverride> goalEventTypeNames =
        const <String, GoalEventTypeNameOverride>{},
  }) {
    // Keep the legacy flat document when no Group color or Goal name
    // override has ever been saved. This is a lossless migration for
    // existing installs and leaves Restore Event Defaults compatible with
    // the pre-Prompt-B preference shape.
    if (groups.isEmpty && goalEventTypeNames.isEmpty) {
      return encode(events);
    }
    return jsonEncode(<String, Object>{
      'events': _encodeEventMap(events),
      'groups': <String, int>{
        for (final entry in groups.entries)
          if (entry.key.trim().isNotEmpty) entry.key: entry.value,
      },
      if (goalEventTypeNames.isNotEmpty)
        'goalEventTypeNames': <String, Object>{
          for (final entry in goalEventTypeNames.entries)
            if (entry.key.trim().isNotEmpty) entry.key: entry.value.toJson(),
        },
    });
  }

  static Map<String, GoalEventTypeNameOverride> _decodeGoalEventTypeNames(
    Object? value,
  ) {
    if (value is! Map) {
      return const <String, GoalEventTypeNameOverride>{};
    }
    final result = <String, GoalEventTypeNameOverride>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String || key.trim().isEmpty) {
        continue;
      }
      final override = GoalEventTypeNameOverride.fromJson(entry.value);
      if (override != null) {
        result[key] = override;
      }
    }
    return Map<String, GoalEventTypeNameOverride>.unmodifiable(result);
  }

  static Map<String, EventColorPreference> _decodeEventMap(Object? value) {
    if (value is! Map) {
      return const <String, EventColorPreference>{};
    }
    final result = <String, EventColorPreference>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String || key.trim().isEmpty) {
        continue;
      }
      final preference = EventColorPreference.fromJson(entry.value);
      if (preference != null) {
        result[key] = preference;
      }
    }
    return Map<String, EventColorPreference>.unmodifiable(result);
  }

  static Map<String, Map<String, int>> _encodeEventMap(
    Map<String, EventColorPreference> preferences,
  ) {
    return <String, Map<String, int>>{
      for (final entry in preferences.entries)
        if (entry.key.trim().isNotEmpty) entry.key: entry.value.toJson(),
    };
  }
}

/// PMG-derived defaults used by the Event Colors settings screen.
///
/// The label map supports an existing or future custom Event Type whose
/// approved name already matches the PMG vocabulary. The icon map provides a
/// deterministic muted fallback for the current Next Transfer system types,
/// which intentionally do not use those PMG labels.
abstract final class PlannerEventColorDefaults {
  /// The synthetic canonical Task identity's stable key.
  ///
  /// Mirrors `PlannerEventColorResolver.taskStableKey` in the presentation
  /// layer so the data layer can reason about the Task identity without
  /// importing presentation. The two constants must stay equal; a contract
  /// test asserts that, so drift can never pass silently.
  static const String taskStableKey = 'planner_task';

  // PMG tonal discipline (Parts 11-15): every accent is faded, desaturated,
  // gray-mixed, and comfortable on black — never fresh, candy, or neon.  The
  // surfaces are the same hue blended into a neutral charcoal veil at a
  // medium-dark band (`EventColorMath.lightMutedSurfaceArgb`), so the blocks
  // read as "faded color on black" with white text.
  // Exact PMG-derived default Accent + Surface pairs (Surgical delta).
  // Every surface below is the explicit dark PMG-style block body and must
  // be rendered verbatim (never re-derived). Planner text stays white.
  //   Job           <- PMG Teaching  #EBC766 / #4C4942
  //   Scripture     <- PMG Finding   #DE9EDA / #4C464A
  //   Exercise      <- PMG Sacrament #EAA15D / #474141
  //   Temple Visit  <- PMG Baptism   #98CED8 / #454B4B
  static const EventColorPreference teaching = EventColorPreference(
    accentArgb: 0xFFEBC766,
    surfaceArgb: 0xFF4C4942,
  );
  static const EventColorPreference finding = EventColorPreference(
    accentArgb: 0xFFDE9EDA,
    surfaceArgb: 0xFF4C464A,
  );
  static const EventColorPreference exercise = EventColorPreference(
    accentArgb: 0xFFEAA15D,
    surfaceArgb: 0xFF474141,
  );
  static const EventColorPreference service = EventColorPreference(
    accentArgb: 0xFFDEEDF2,
    surfaceArgb: 0xFF404447,
  );
  // Work is deliberately separated from Service (which keeps its approved
  // icy DEEDF2 family) into a muted steel/slate-blue family that stays
  // low-glare and PMG-like while remaining distinguishable from Service at
  // normal Planner scale (Post-VS-11 planner polish P-01D).
  static const EventColorPreference work = EventColorPreference(
    accentArgb: 0xFFA9BEC9,
    surfaceArgb: 0xFF43494D,
  );
  static const EventColorPreference other = EventColorPreference(
    accentArgb: 0xFF868A8D,
    surfaceArgb: 0xFF494949,
  );
  static const EventColorPreference meeting = EventColorPreference(
    accentArgb: 0xFFE27386,
    surfaceArgb: 0xFF463D40,
  );
  static const EventColorPreference studyOrPlan = EventColorPreference(
    accentArgb: 0xFFA272C8,
    surfaceArgb: 0xFF47444B,
  );

  /// Education uses the locked Recommended Color P22 (Gray Blue) accent with
  /// its locked dark surface partner, written verbatim above (approved
  /// Education pair, Prompt-P46). Deliberately absent from `_labelDefaults`:
  /// a custom row merely named "Education" must keep the accepted fallback
  /// behavior, never adopt the system default.
  static const EventColorPreference education = EventColorPreference(
    accentArgb: Vs11ColorSystem.p22SteelBlue,
    // Exact RecommendedEventColorSurfacePartners P22 companion, verbatim.
    surfaceArgb: 0xFF484F56,
  );
  static const EventColorPreference scriptureStudy = EventColorPreference(
    accentArgb: 0xFFDE9EDA,
    surfaceArgb: 0xFF4C464A,
  );
  static const EventColorPreference budgetReview = EventColorPreference(
    accentArgb: 0xFFBFA384,
    surfaceArgb: 0xFF575048,
  );
  static const EventColorPreference ministeringVisit = EventColorPreference(
    accentArgb: 0xFFB0A971,
    surfaceArgb: 0xFF565448,
  );
  static const EventColorPreference contact = EventColorPreference(
    accentArgb: 0xFF76B181,
    surfaceArgb: 0xFF494E48,
  );
  static const EventColorPreference baptism = EventColorPreference(
    accentArgb: 0xFF98CED8,
    surfaceArgb: 0xFF454B4B,
  );
  static const EventColorPreference travel = EventColorPreference(
    accentArgb: 0xFFECC7D8,
    surfaceArgb: 0xFF4F4D4E,
  );
  static const EventColorPreference meal = EventColorPreference(
    accentArgb: 0xFFE1CFB9,
    surfaceArgb: 0xFF4B4744,
  );

  /// Closed-beta V2 Task identity (owner decision, 2026-09-18; corrected on the
  /// same day after owner physical review #3).
  ///
  /// The owner wants the ORIGINAL warm Task accent AND a dark block body that
  /// belongs to the same warm Task family. The previously shipped body
  /// #3D4F59 (hue 201) was physically rejected on the device: it reads BLUE,
  /// not Task. The retired pair before it (#F2E9E0 / #494844) was worse in the
  /// other direction — that body collapsed onto Meal's own #4B4744.
  ///
  /// The body below is deliberately NOT a Task-only magic hex. It is Task's own
  /// accent hue carried into the dark band the accepted system blocks already
  /// occupy: hue 30 at low chroma and a medium-dark lightness, i.e.
  ///
  ///   EventColorMath.fromHsl(h: 30, s: 0.04, l: 0.35)  ->  #5D5956
  ///
  /// `planner_task_color_test.dart` recomputes that derivation on every run, so
  /// this constant can never silently drift away from the family it documents.
  ///
  /// Measured against the accepted neighbours: warm neutral (h 26, s 0.039,
  /// l 0.351), white-text contrast 6.93:1, and an OKLab distance of 0.066 from
  /// Meal's #4B4744 — sixteen times the retired #494844 collision that forced
  /// the original blue detour in the first place.
  ///
  /// The canonical Task identity, its stable key, its preference storage and
  /// the user's ability to customize it through Settings > Colors are all
  /// unchanged; only the default pair moves. Meal and Shopping are deliberately
  /// untouched, and a SAVED Task preference is never rewritten — the repository
  /// reads legacy saved colours as evidence, never as a migration input.
  static const EventColorPreference task = EventColorPreference(
    accentArgb: 0xFFF2E9E0,
    surfaceArgb: 0xFF5D5956,
  );

  // Locked system-type pairs. The six fixed Goal-linked Event Types resolve
  // through these canonical constants; Ministering Visit and Budget Review
  // are NOT remapped by the exact-defaults delta and keep their prior pair.
  static const EventColorPreference lockedJobApplication = teaching;
  static const EventColorPreference lockedScriptureStudy = finding;
  static const EventColorPreference lockedExercise = exercise;
  static const EventColorPreference lockedBudgetReview = budgetReview;
  static const EventColorPreference lockedMinisteringVisit = ministeringVisit;
  static const EventColorPreference lockedTempleVisit = baptism;

  static const Map<String, EventColorPreference> _labelDefaults =
      <String, EventColorPreference>{
        'teaching': teaching,
        'finding': finding,
        'exercise': exercise,
        'service': service,
        'work': work,
        'other': other,
        'meeting': meeting,
        'study or plan': studyOrPlan,
        'scripture study': scriptureStudy,
        'budget review': budgetReview,
        'ministering visit': ministeringVisit,
        'contact': contact,
        'baptism': baptism,
        'travel': travel,
        'meal': meal,
        'task': task,
        'church activity': other,
        'new referral group message': other,
        'sacrament': EventColorPreference(
          accentArgb: 0xFFEAA15D,
          surfaceArgb: 0xFF474141,
        ),
      };

  /// Return the approved default pair for an existing Event Type.
  ///
  /// Current system types are mapped by icon so their category identity is
  /// retained even if the user has localized or renamed their label. Unknown
  /// custom types receive the muted neutral pair instead of a bright full
  /// block.
  static EventColorPreference forEventType(EventType type) {
    final byStableKey = pmgStableKeyDefaults[type.stableKey];
    if (byStableKey != null) {
      return byStableKey;
    }
    final byLabel = _labelDefaults[_normalize(type.label)];
    if (byLabel != null) {
      return byLabel;
    }
    return switch (type.icon) {
      EventTypeIcon.calendar => other,
      EventTypeIcon.temple => baptism,
      EventTypeIcon.scripture => scriptureStudy,
      EventTypeIcon.exercise => contact,
      EventTypeIcon.budget => budgetReview,
      EventTypeIcon.job => finding,
      EventTypeIcon.connection => contact,
      EventTypeIcon.appointment => meeting,
      EventTypeIcon.work => work,
      EventTypeIcon.personal => travel,
    };
  }

  /// The exact locked default pair per system Event Type stable key.
  ///
  /// Exposed to the drift repository so the explicit PMG surfaces are never
  /// re-derived by the legacy surface repair (the locked surfaces are
  /// deliberately NOT derivation-consistent).
  static const Map<String, EventColorPreference> pmgStableKeyDefaults =
      <String, EventColorPreference>{
        SystemEventTypeKeys.jobApplication: lockedJobApplication,
        SystemEventTypeKeys.scriptureStudy: lockedScriptureStudy,
        SystemEventTypeKeys.exercise: lockedExercise,
        SystemEventTypeKeys.budgetReview: lockedBudgetReview,
        SystemEventTypeKeys.meaningfulConnection: lockedMinisteringVisit,
        SystemEventTypeKeys.contact: contact,
        SystemEventTypeKeys.meeting: meeting,
        SystemEventTypeKeys.studyOrPlan: studyOrPlan,
        SystemEventTypeKeys.education: education,
        SystemEventTypeKeys.templeVisit: lockedTempleVisit,
        SystemEventTypeKeys.travel: travel,
        SystemEventTypeKeys.meal: meal,
        SystemEventTypeKeys.service: service,
        SystemEventTypeKeys.work: work,
        SystemEventTypeKeys.other: other,
      };

  static String _normalize(String value) {
    return value
        .trim()
        .toLowerCase()
        .replaceAll('&', 'and')
        .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
        .trim();
  }
}
