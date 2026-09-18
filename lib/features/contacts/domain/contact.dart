import 'dart:convert';

import 'package:rmplanner/core/colors/vs11_color_system.dart';
import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:uuid/uuid.dart';

/// Lifecycle of a Contact.  Archived keeps the same ID and every historical
/// link; merged keeps the row so historical participation stays traceable to
/// the absorbed identity.
enum ContactLifecycleState { active, archived, recentlyDeleted, merged }

enum ContactSource { manual, deviceImport, betterCalendarImport }

enum ContactMethodType { phone, email, social }

enum ContactPreferredMethod { message, call, email }

enum ContactSortBy {
  name,
  nameDesc,
  recentlyAdded,
  oldestAdded,
  mostRecentlyInteracted,
  leastRecentlyInteracted,
  // Retained solely to decode legacy saved filters. Active Contacts UI uses
  // [activeOptions], never [values].
  @Deprecated('Legacy saved-filter compatibility only')
  status,
  @Deprecated('Legacy saved-filter compatibility only')
  lastViewed,
  @Deprecated('Legacy saved-filter compatibility only')
  nextEvent,
  @Deprecated('Legacy saved-filter compatibility only')
  lastEvent,
  @Deprecated('Legacy saved-filter compatibility only')
  lastHappenedEvent,
  @Deprecated('Legacy saved-filter compatibility only')
  leastRecentEvent,
  @Deprecated('Legacy saved-filter compatibility only')
  leastRecentHappenedEvent;

  static const List<ContactSortBy> activeOptions = <ContactSortBy>[
    name,
    nameDesc,
    recentlyAdded,
    oldestAdded,
    mostRecentlyInteracted,
    leastRecentlyInteracted,
  ];
}

enum ContactStandardFilter {
  status,
  recentlyViewed,
  recentlyContacted,
  noRecentContact,
  recentlyCreated,
}

/// Truth of a selectable Contact-filter category.  This is deliberately
/// independent of its selected-key list: an empty list alone cannot tell
/// unrestricted All from an owner-selected None.
enum ContactFilterSelectionMode { all, some, none }

enum ContactStatusBucket {
  notInteractedYet,
  interactedToday,
  interactedThisWeek,
  interactedThisMonth,
  oneToThreeMonthsAgo,
  threeToSixMonthsAgo,
  sixToTwelveMonthsAgo,
  onePlusYearAgo,
}

/// Computed relationship-history signal used only by aggregate Status.
enum ContactSmartStatus {
  recentlyReconnected,
  frequentConnection,
  regularConnection,
  reconnectSoon,
}

String contactSmartStatusLabel(ContactSmartStatus status) => switch (status) {
  ContactSmartStatus.recentlyReconnected => 'Recently Reconnected',
  ContactSmartStatus.frequentConnection => 'Frequent Connection',
  ContactSmartStatus.regularConnection => 'Regular Connection',
  ContactSmartStatus.reconnectSoon => 'Reconnect Soon',
};

final class ContactStandardView {
  const ContactStandardView({required this.filter, this.statusBucket})
    : assert(filter == ContactStandardFilter.status || statusBucket == null);

  final ContactStandardFilter filter;
  final ContactStatusBucket? statusBucket;

  String get label => switch (filter) {
    ContactStandardFilter.status =>
      statusBucket == null ? 'Status' : contactStatusBucketLabel(statusBucket!),
    ContactStandardFilter.recentlyViewed => 'Recently Viewed',
    ContactStandardFilter.recentlyContacted => 'Recently Contacted',
    ContactStandardFilter.noRecentContact => 'No Recent Contact',
    ContactStandardFilter.recentlyCreated => 'Recently Created',
  };
}

String contactStatusBucketLabel(ContactStatusBucket bucket) => switch (bucket) {
  ContactStatusBucket.notInteractedYet => 'Not Interacted Yet',
  ContactStatusBucket.interactedToday => 'Interacted Today',
  ContactStatusBucket.interactedThisWeek => 'Interacted This Week',
  ContactStatusBucket.interactedThisMonth => 'Interacted This Month',
  ContactStatusBucket.oneToThreeMonthsAgo => '1–3 Months Ago',
  ContactStatusBucket.threeToSixMonthsAgo => '3–6 Months Ago',
  ContactStatusBucket.sixToTwelveMonthsAgo => '6–12 Months Ago',
  ContactStatusBucket.onePlusYearAgo => '1+ Year Ago',
};

/// Row fields that can be selected for a saved Contacts view. Every field is
/// already present in [ContactSummary], so Displayed Fields never introduces
/// an N+1 query or a fabricated tracking primitive.
enum ContactDisplayedField {
  currentGroup,
  tags,
  nextEvent,
  lastEvent,
  lastHappenedEvent,
  contactMethod,
  address,
  lastInteraction,
  lastViewed,
  createdDate,
}

abstract final class ContactDisplayedFieldCodec {
  static String encode(ContactDisplayedField value) => value.name;

  static ContactDisplayedField? decode(String value) =>
      ContactDisplayedField.values.asNameMap()[value];

  static const List<ContactDisplayedField> defaults = <ContactDisplayedField>[
    ContactDisplayedField.currentGroup,
    ContactDisplayedField.nextEvent,
    ContactDisplayedField.lastEvent,
    ContactDisplayedField.lastHappenedEvent,
    ContactDisplayedField.contactMethod,
    ContactDisplayedField.address,
    ContactDisplayedField.lastInteraction,
    ContactDisplayedField.lastViewed,
    ContactDisplayedField.createdDate,
  ];
}

/// Canonical label keys for the Phone filter category.  These are the only
/// label keys the Filter screen understands; anything else is "Other".
abstract final class ContactPhoneFilterKeys {
  static const String noPhone = 'noPhone';
  static const String mobile = 'mobile';
  static const String home = 'home';
  static const String work = 'work';
  static const String other = 'other';

  /// Typed labels that are NOT "Other".  A phone with any other/null/blank
  /// label falls back to Other for Filter matching.
  static const Set<String> typed = <String>{mobile, home, work};
}

/// Canonical label keys for the Email filter category.  Device ecosystems
/// commonly label personal email as "home"; "Personal" accepts both.
abstract final class ContactEmailFilterKeys {
  static const String noEmail = 'noEmail';
  static const String personal = 'personal';
  static const String work = 'work';
  static const String family = 'family';
  static const String other = 'other';

  /// Labels that map to the Personal type (personal or device-home).
  static const Set<String> personalLabels = <String>{personal, 'home'};

  /// Typed labels that are NOT "Other".
  static const Set<String> typed = <String>{personal, work, family};
}

/// Canonical label keys for the Address filter category.
abstract final class ContactAddressFilterKeys {
  static const String notRecorded = 'notRecorded';
  static const String recorded = 'recorded';
}

/// Canonical label keys for the Social Profile filter category.
abstract final class ContactSocialFilterKeys {
  static const String noSocial = 'noSocial';
  static const String facebook = 'facebook';
  static const String messenger = 'messenger';
  static const String whatsapp = 'whatsapp';
  static const String line = 'line';
  static const String skype = 'skype';
  static const String kakaoTalk = 'kakaotalk';
  static const String instagram = 'instagram';
  static const String helloTalk = 'hellotalk';
  static const String x = 'x';
  static const String other = 'other';

  /// Canonical platforms that are NOT "Other".
  static const Set<String> canonical = <String>{
    facebook,
    messenger,
    whatsapp,
    line,
    skype,
    kakaoTalk,
    instagram,
    helloTalk,
    x,
  };
}

/// Lowercases and trims a stored method label for filter matching.
/// null / blank labels normalize to null so they always fall into "Other".
String? normalizedMethodLabel(String? label) {
  final t = label?.trim().toLowerCase();
  return t == null || t.isEmpty ? null : t;
}

enum ContactFilterSection { none, favorites, groups }

abstract final class ContactLifecycleStateCodec {
  static String encode(ContactLifecycleState value) => value.name;
  static ContactLifecycleState decode(String value) =>
      ContactLifecycleState.values.asNameMap()[value] ??
      ContactLifecycleState.active;
}

abstract final class ContactSourceCodec {
  static String encode(ContactSource value) => value.name;
  static ContactSource decode(String value) =>
      ContactSource.values.asNameMap()[value] ?? ContactSource.manual;
}

abstract final class ContactPreferredMethodCodec {
  static String encode(ContactPreferredMethod value) => value.name;
  static ContactPreferredMethod decode(String value) =>
      ContactPreferredMethod.values.asNameMap()[value] ??
      ContactPreferredMethod.message;
}

final class Contact {
  const Contact({
    required this.id,
    required this.profileId,
    required this.firstName,
    required this.lastName,
    required this.displayName,
    required this.preferredContactMethod,
    required this.isFavorite,
    required this.lifecycleState,
    required this.source,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.addressText,
    this.lastViewedAtUtc,
    this.archivedAtUtc,
    this.deletedAtUtc,
    this.mergedIntoContactId,
  });

  final String id;
  final String profileId;
  final String? firstName;
  final String? lastName;
  final String displayName;
  final ContactPreferredMethod preferredContactMethod;
  final bool isFavorite;
  final ContactLifecycleState lifecycleState;
  final ContactSource source;
  final String? addressText;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final DateTime? lastViewedAtUtc;
  final DateTime? archivedAtUtc;
  final DateTime? deletedAtUtc;
  final String? mergedIntoContactId;

  bool get isActive => lifecycleState == ContactLifecycleState.active;
  bool get isArchived => lifecycleState == ContactLifecycleState.archived;
  bool get isRecentlyDeleted =>
      lifecycleState == ContactLifecycleState.recentlyDeleted;
  bool get isMerged => lifecycleState == ContactLifecycleState.merged;

  String get initials {
    final first = firstName?.trim();
    final last = lastName?.trim();
    String leading(String value) =>
        value.isEmpty ? '' : String.fromCharCode(value.runes.first);
    if ((first == null || first.isEmpty) && (last == null || last.isEmpty)) {
      final name = displayName.trim();
      if (name.isEmpty) {
        return '?';
      }
      final parts = name.split(RegExp(r'\s+'));
      if (parts.length == 1) {
        return leading(parts.first).toUpperCase();
      }
      return (leading(parts.first) + leading(parts.last)).toUpperCase();
    }
    return (leading(first ?? '') + leading(last ?? '')).toUpperCase();
  }

  Contact copyWith({
    String? firstName,
    String? lastName,
    String? displayName,
    ContactPreferredMethod? preferredContactMethod,
    bool? isFavorite,
    ContactLifecycleState? lifecycleState,
    String? addressText,
    DateTime? updatedAtUtc,
    DateTime? lastViewedAtUtc,
  }) {
    return Contact(
      id: id,
      profileId: profileId,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      displayName: displayName ?? this.displayName,
      preferredContactMethod:
          preferredContactMethod ?? this.preferredContactMethod,
      isFavorite: isFavorite ?? this.isFavorite,
      lifecycleState: lifecycleState ?? this.lifecycleState,
      source: source,
      addressText: addressText ?? this.addressText,
      createdAtUtc: createdAtUtc,
      updatedAtUtc: updatedAtUtc ?? this.updatedAtUtc,
      lastViewedAtUtc: lastViewedAtUtc ?? this.lastViewedAtUtc,
      archivedAtUtc: archivedAtUtc,
      deletedAtUtc: deletedAtUtc,
      mergedIntoContactId: mergedIntoContactId,
    );
  }
}

final class ContactMethod {
  const ContactMethod({
    required this.id,
    required this.contactId,
    required this.type,
    required this.rawValue,
    required this.normalizedValue,
    this.label,
    this.isPrimary = false,
    this.receivesTexts,
    this.hasWhatsApp,
  });

  final String id;
  final String contactId;
  final ContactMethodType type;
  final String? label;
  final String rawValue;
  final String normalizedValue;
  final bool isPrimary;

  /// Phone-only capability facts. Null is retained for legacy data whose
  /// capability was never recorded; callers must treat it as unavailable.
  final bool? receivesTexts;
  final bool? hasWhatsApp;
}

final class ContactMethodDraft {
  const ContactMethodDraft({
    required this.type,
    required this.value,
    this.id,
    this.label,
    this.isPrimary = false,
    this.receivesTexts = false,
    this.hasWhatsApp = false,
  });

  /// The stable ContactMethods row ID when editing an existing method.  A
  /// null ID deliberately means a newly added row.
  final String? id;
  final ContactMethodType type;
  final String value;
  final String? label;
  final bool isPrimary;
  final bool? receivesTexts;
  final bool? hasWhatsApp;
}

final class ContactGroup {
  const ContactGroup({
    required this.id,
    required this.profileId,
    required this.name,
    required this.colorValue,
    required this.isArchived,
    required this.sortOrder,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });

  final String id;
  final String profileId;
  final String name;
  final int colorValue;
  final bool isArchived;
  final int sortOrder;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

final class ContactTag {
  const ContactTag({
    required this.id,
    required this.profileId,
    required this.name,
  });

  final String id;
  final String profileId;
  final String name;
}

final class ContactNote {
  const ContactNote({
    required this.id,
    required this.contactId,
    required this.noteText,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  });

  final String id;
  final String contactId;
  final String noteText;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
}

final class ContactAvailability {
  const ContactAvailability({
    required this.weekday,
    required this.startMinute,
    required this.endMinute,
  });

  /// ISO weekday, 1 (Monday) .. 7 (Sunday), matching [DateTime.weekday].
  final int weekday;
  final int startMinute;
  final int endMinute;

  ContactAvailability normalized() {
    if (weekday < 1 || weekday > 7) {
      throw const ContactValidationException('Weekday must be 1..7.');
    }
    if (startMinute < 0 ||
        startMinute > 1439 ||
        endMinute <= startMinute ||
        endMinute > 1440) {
      throw const ContactValidationException(
        'Availability needs a valid window after its start.',
      );
    }
    return this;
  }
}

/// Structured criteria behind the current view and any Saved Filter.
/// Persisted as JSON inside [SavedContactFilter.criteriaJson].
final class ContactFilterCriteria {
  const ContactFilterCriteria({
    this.groupIds = const <String>[],
    this.ungroupedOnly = false,
    this.tagIds = const <String>[],
    this.favoritesOnly = false,
    this.availabilityWeekdays = const <int>[],
    this.hasPhone = false,
    this.hasEmail = false,
    this.hasAddress = false,
    this.withEventsToday = false,
    this.withFutureEvents = false,
    this.withoutFutureEvents = false,
    this.noInteractionYet = false,
    this.source,
    this.includeArchived = false,
    this.archivedOnly = false,
    this.eventHistoryAny = false,
    this.phoneLabels = const <String>[],
    this.emailLabels = const <String>[],
    this.addressLabels = const <String>[],
    this.socialLabels = const <String>[],
    this.groupSelectionMode = ContactFilterSelectionMode.all,
    this.tagSelectionMode = ContactFilterSelectionMode.all,
    this.availabilitySelectionMode = ContactFilterSelectionMode.all,
    this.contactMethodsSelectionMode = ContactFilterSelectionMode.all,
    this.eventHistorySelectionMode = ContactFilterSelectionMode.all,
    this.phoneSelectionMode = ContactFilterSelectionMode.all,
    this.emailSelectionMode = ContactFilterSelectionMode.all,
    this.addressSelectionMode = ContactFilterSelectionMode.all,
    this.socialSelectionMode = ContactFilterSelectionMode.all,
  });

  final List<String> groupIds;

  /// The virtual "No Group" view state (owner law, 2026-09-18).
  ///
  /// It is a real criterion rather than a fake Group id: no Group row, no
  /// membership and no deterministic identity is created for it. It matches
  /// Contacts that hold no ACTIVE (primary) Group membership — the same single
  /// fact the Contacts list dot and the Group manager already agree on.
  final bool ungroupedOnly;

  final List<String> tagIds;
  final bool favoritesOnly;
  final List<int> availabilityWeekdays;
  final bool hasPhone;
  final bool hasEmail;
  final bool hasAddress;
  final bool withEventsToday;
  final bool withFutureEvents;
  final bool withoutFutureEvents;
  final bool noInteractionYet;
  final ContactSource? source;
  final bool includeArchived;
  final bool archivedOnly;
  final bool eventHistoryAny;

  /// Selected Phone category keys.  Empty means the Phone category imposes no
  /// restriction ("All").  Keys come from [ContactPhoneFilterKeys].
  final List<String> phoneLabels;

  /// Selected Email category keys.  Empty means "All".
  /// Keys come from [ContactEmailFilterKeys].
  final List<String> emailLabels;

  /// Selected Address category keys.  Empty means "All".
  /// Keys come from [ContactAddressFilterKeys].
  final List<String> addressLabels;

  /// Selected Social Profile category keys.  Empty means "All".
  /// Keys come from [ContactSocialFilterKeys].
  final List<String> socialLabels;
  final ContactFilterSelectionMode groupSelectionMode;
  final ContactFilterSelectionMode tagSelectionMode;
  final ContactFilterSelectionMode availabilitySelectionMode;
  final ContactFilterSelectionMode contactMethodsSelectionMode;
  final ContactFilterSelectionMode eventHistorySelectionMode;
  final ContactFilterSelectionMode phoneSelectionMode;
  final ContactFilterSelectionMode emailSelectionMode;
  final ContactFilterSelectionMode addressSelectionMode;
  final ContactFilterSelectionMode socialSelectionMode;

  bool get isEmpty =>
      groupIds.isEmpty &&
      !ungroupedOnly &&
      tagIds.isEmpty &&
      !favoritesOnly &&
      availabilityWeekdays.isEmpty &&
      !hasPhone &&
      !hasEmail &&
      !hasAddress &&
      !withEventsToday &&
      !withFutureEvents &&
      !withoutFutureEvents &&
      !noInteractionYet &&
      source == null &&
      !includeArchived &&
      !archivedOnly &&
      !eventHistoryAny &&
      phoneLabels.isEmpty &&
      emailLabels.isEmpty &&
      addressLabels.isEmpty &&
      socialLabels.isEmpty &&
      groupSelectionMode == ContactFilterSelectionMode.all &&
      tagSelectionMode == ContactFilterSelectionMode.all &&
      availabilitySelectionMode == ContactFilterSelectionMode.all &&
      contactMethodsSelectionMode == ContactFilterSelectionMode.all &&
      eventHistorySelectionMode == ContactFilterSelectionMode.all &&
      phoneSelectionMode == ContactFilterSelectionMode.all &&
      emailSelectionMode == ContactFilterSelectionMode.all &&
      addressSelectionMode == ContactFilterSelectionMode.all &&
      socialSelectionMode == ContactFilterSelectionMode.all;

  Map<String, Object?> toJson() {
    return <String, Object?>{
      'groupIds': groupIds,
      'ungroupedOnly': ungroupedOnly,
      'tagIds': tagIds,
      'favoritesOnly': favoritesOnly,
      'availabilityWeekdays': availabilityWeekdays,
      'hasPhone': hasPhone,
      'hasEmail': hasEmail,
      'hasAddress': hasAddress,
      'withEventsToday': withEventsToday,
      'withFutureEvents': withFutureEvents,
      'withoutFutureEvents': withoutFutureEvents,
      'noInteractionYet': noInteractionYet,
      'source': source?.name,
      'includeArchived': includeArchived,
      'archivedOnly': archivedOnly,
      'eventHistoryAny': eventHistoryAny,
      'phoneLabels': phoneLabels,
      'emailLabels': emailLabels,
      'addressLabels': addressLabels,
      'socialLabels': socialLabels,
      'groupSelectionMode': groupSelectionMode.name,
      'tagSelectionMode': tagSelectionMode.name,
      'availabilitySelectionMode': availabilitySelectionMode.name,
      'contactMethodsSelectionMode': contactMethodsSelectionMode.name,
      'eventHistorySelectionMode': eventHistorySelectionMode.name,
      'phoneSelectionMode': phoneSelectionMode.name,
      'emailSelectionMode': emailSelectionMode.name,
      'addressSelectionMode': addressSelectionMode.name,
      'socialSelectionMode': socialSelectionMode.name,
    };
  }

  factory ContactFilterCriteria.fromJson(Map<String, Object?> json) {
    final nested = json['criteria'];
    if (nested is Map<Object?, Object?>) {
      return ContactFilterCriteria.fromJson(nested.cast<String, Object?>());
    }
    final rawSource = json['source'] as String?;
    return ContactFilterCriteria(
      groupIds: _stringList(json['groupIds']),
      ungroupedOnly: json['ungroupedOnly'] == true,
      tagIds: _stringList(json['tagIds']),
      favoritesOnly: json['favoritesOnly'] == true,
      availabilityWeekdays:
          (json['availabilityWeekdays'] as List<Object?>? ?? const <Object?>[])
              .map((value) => value as int)
              .toList(growable: false),
      hasPhone: json['hasPhone'] == true,
      hasEmail: json['hasEmail'] == true,
      hasAddress: json['hasAddress'] == true,
      withEventsToday: json['withEventsToday'] == true,
      withFutureEvents: json['withFutureEvents'] == true,
      withoutFutureEvents: json['withoutFutureEvents'] == true,
      noInteractionYet: json['noInteractionYet'] == true,
      source: rawSource == null
          ? null
          : ContactSource.values.asNameMap()[rawSource],
      includeArchived: json['includeArchived'] == true,
      archivedOnly: json['archivedOnly'] == true,
      eventHistoryAny: json['eventHistoryAny'] == true,
      phoneLabels: _stringList(json['phoneLabels']),
      emailLabels: _stringList(json['emailLabels']),
      addressLabels: _stringList(json['addressLabels']),
      socialLabels: _stringList(json['socialLabels']),
      groupSelectionMode: _selectionMode(
        json['groupSelectionMode'],
        _stringList(json['groupIds']).isNotEmpty,
      ),
      tagSelectionMode: _selectionMode(
        json['tagSelectionMode'],
        _stringList(json['tagIds']).isNotEmpty,
      ),
      availabilitySelectionMode: _selectionMode(
        json['availabilitySelectionMode'],
        (json['availabilityWeekdays'] as List<Object?>? ?? const <Object?>[])
            .isNotEmpty,
      ),
      contactMethodsSelectionMode: _selectionMode(
        json['contactMethodsSelectionMode'],
        json['hasPhone'] == true ||
            json['hasEmail'] == true ||
            json['hasAddress'] == true,
      ),
      eventHistorySelectionMode: _selectionMode(
        json['eventHistorySelectionMode'],
        json['noInteractionYet'] == true || json['eventHistoryAny'] == true,
      ),
      phoneSelectionMode: _selectionMode(
        json['phoneSelectionMode'],
        _stringList(json['phoneLabels']).isNotEmpty,
      ),
      emailSelectionMode: _selectionMode(
        json['emailSelectionMode'],
        _stringList(json['emailLabels']).isNotEmpty,
      ),
      addressSelectionMode: _selectionMode(
        json['addressSelectionMode'],
        _stringList(json['addressLabels']).isNotEmpty,
      ),
      socialSelectionMode: _selectionMode(
        json['socialSelectionMode'],
        _stringList(json['socialLabels']).isNotEmpty,
      ),
    );
  }

  /// Returns a copy with the given fields replaced.  Absent (null) parameters
  /// keep the current value; [replaceSource] lets callers clear [source].
  ContactFilterCriteria copyWith({
    List<String>? groupIds,
    bool? ungroupedOnly,
    List<String>? tagIds,
    bool? favoritesOnly,
    List<int>? availabilityWeekdays,
    bool? hasPhone,
    bool? hasEmail,
    bool? hasAddress,
    bool? withEventsToday,
    bool? withFutureEvents,
    bool? withoutFutureEvents,
    bool? noInteractionYet,
    ContactSource? source,
    bool replaceSource = false,
    bool? includeArchived,
    bool? archivedOnly,
    bool? eventHistoryAny,
    List<String>? phoneLabels,
    List<String>? emailLabels,
    List<String>? addressLabels,
    List<String>? socialLabels,
    ContactFilterSelectionMode? groupSelectionMode,
    ContactFilterSelectionMode? tagSelectionMode,
    ContactFilterSelectionMode? availabilitySelectionMode,
    ContactFilterSelectionMode? contactMethodsSelectionMode,
    ContactFilterSelectionMode? eventHistorySelectionMode,
    ContactFilterSelectionMode? phoneSelectionMode,
    ContactFilterSelectionMode? emailSelectionMode,
    ContactFilterSelectionMode? addressSelectionMode,
    ContactFilterSelectionMode? socialSelectionMode,
  }) {
    return ContactFilterCriteria(
      groupIds: groupIds ?? this.groupIds,
      ungroupedOnly: ungroupedOnly ?? this.ungroupedOnly,
      tagIds: tagIds ?? this.tagIds,
      favoritesOnly: favoritesOnly ?? this.favoritesOnly,
      availabilityWeekdays: availabilityWeekdays ?? this.availabilityWeekdays,
      hasPhone: hasPhone ?? this.hasPhone,
      hasEmail: hasEmail ?? this.hasEmail,
      hasAddress: hasAddress ?? this.hasAddress,
      withEventsToday: withEventsToday ?? this.withEventsToday,
      withFutureEvents: withFutureEvents ?? this.withFutureEvents,
      withoutFutureEvents: withoutFutureEvents ?? this.withoutFutureEvents,
      noInteractionYet: noInteractionYet ?? this.noInteractionYet,
      source: replaceSource ? source : this.source,
      includeArchived: includeArchived ?? this.includeArchived,
      archivedOnly: archivedOnly ?? this.archivedOnly,
      eventHistoryAny: eventHistoryAny ?? this.eventHistoryAny,
      phoneLabels: phoneLabels ?? this.phoneLabels,
      emailLabels: emailLabels ?? this.emailLabels,
      addressLabels: addressLabels ?? this.addressLabels,
      socialLabels: socialLabels ?? this.socialLabels,
      groupSelectionMode: groupSelectionMode ?? this.groupSelectionMode,
      tagSelectionMode: tagSelectionMode ?? this.tagSelectionMode,
      availabilitySelectionMode:
          availabilitySelectionMode ?? this.availabilitySelectionMode,
      contactMethodsSelectionMode:
          contactMethodsSelectionMode ?? this.contactMethodsSelectionMode,
      eventHistorySelectionMode:
          eventHistorySelectionMode ?? this.eventHistorySelectionMode,
      phoneSelectionMode: phoneSelectionMode ?? this.phoneSelectionMode,
      emailSelectionMode: emailSelectionMode ?? this.emailSelectionMode,
      addressSelectionMode: addressSelectionMode ?? this.addressSelectionMode,
      socialSelectionMode: socialSelectionMode ?? this.socialSelectionMode,
    );
  }

  static List<String> _stringList(Object? value) {
    return (value as List<Object?>? ?? const <Object?>[])
        .whereType<String>()
        .toList(growable: false);
  }

  static ContactFilterSelectionMode _selectionMode(
    Object? raw,
    bool legacyHasSelection,
  ) {
    final decoded = raw is String
        ? ContactFilterSelectionMode.values.asNameMap()[raw]
        : null;
    // Old saved filters had no mode. Their established meaning was empty = All
    // and non-empty = Some; retain that behavior exactly on decode.
    return decoded ??
        (legacyHasSelection
            ? ContactFilterSelectionMode.some
            : ContactFilterSelectionMode.all);
  }

  String encode() => jsonEncode(toJson());

  /// Tags remain decodable for legacy data but are neutral in active UX.
  ContactFilterCriteria withoutRetiredTags() => copyWith(
    tagIds: const <String>[],
    tagSelectionMode: ContactFilterSelectionMode.all,
  );

  static ContactFilterCriteria decode(String value) {
    try {
      return ContactFilterCriteria.fromJson(
        (jsonDecode(value) as Map<Object?, Object?>).cast<String, Object?>(),
      );
    } on Object {
      return const ContactFilterCriteria();
    }
  }
}

final class SavedContactFilter {
  const SavedContactFilter({
    required this.id,
    required this.profileId,
    required this.name,
    required this.isSystem,
    required this.criteria,
    required this.sortBy,
    required this.createdAtUtc,
    required this.updatedAtUtc,
    this.description = '',
    this.displayedFields = ContactDisplayedFieldCodec.defaults,
  });

  final String id;
  final String profileId;
  final String name;
  final bool isSystem;
  final ContactFilterCriteria criteria;
  final ContactSortBy sortBy;
  final DateTime createdAtUtc;
  final DateTime updatedAtUtc;
  final String description;
  final List<ContactDisplayedField> displayedFields;
}

final class SavedContactFilterDraft {
  const SavedContactFilterDraft({
    required this.name,
    required this.criteria,
    this.sortBy = ContactSortBy.name,
    this.isSystem = false,
    this.description = '',
    this.displayedFields = ContactDisplayedFieldCodec.defaults,
  });

  final String name;
  final ContactFilterCriteria criteria;
  final ContactSortBy sortBy;
  final bool isSystem;
  final String description;
  final List<ContactDisplayedField> displayedFields;
}

/// Backward-compatible document stored in the existing criteria_json column.
/// Older rows contain the criteria object directly; new rows use this envelope
/// so description and displayed fields persist without a schema migration.
final class SavedContactFilterDocument {
  const SavedContactFilterDocument({
    required this.criteria,
    this.description = '',
    this.displayedFields = ContactDisplayedFieldCodec.defaults,
  });

  final ContactFilterCriteria criteria;
  final String description;
  final List<ContactDisplayedField> displayedFields;

  String encode() => jsonEncode(<String, Object?>{
    'criteria': criteria.toJson(),
    'description': description.trim(),
    'displayedFields': displayedFields
        .map(ContactDisplayedFieldCodec.encode)
        .toList(growable: false),
  });

  factory SavedContactFilterDocument.decode(String value) {
    try {
      final decoded = (jsonDecode(value) as Map<Object?, Object?>)
          .cast<String, Object?>();
      final rawFields = decoded['displayedFields'];
      final fields = rawFields is List<Object?>
          ? rawFields
                .whereType<String>()
                .map(ContactDisplayedFieldCodec.decode)
                .whereType<ContactDisplayedField>()
                .toList(growable: false)
          : ContactDisplayedFieldCodec.defaults;
      return SavedContactFilterDocument(
        criteria: ContactFilterCriteria.fromJson(decoded),
        description: decoded['description'] as String? ?? '',
        displayedFields: fields
            .where((field) => field != ContactDisplayedField.tags)
            .toList(growable: false),
      );
    } on Object {
      return const SavedContactFilterDocument(
        criteria: ContactFilterCriteria(),
      );
    }
  }
}

/// The two contextual lines available on list/search rows without N+1 reads:
/// the next upcoming occurrence and the most recent historical occurrence of
/// any Event this Contact participates in.
final class ContactListContext {
  const ContactListContext({
    this.nextEventTitle,
    this.nextEventDate,
    this.lastEventDate,
    this.lastHappenedEventDate,
    this.leastRecentEventDate,
    this.leastRecentHappenedEventDate,
  });

  final String? nextEventTitle;
  final PlannerDate? nextEventDate;
  final PlannerDate? lastEventDate;
  final PlannerDate? lastHappenedEventDate;
  final PlannerDate? leastRecentEventDate;
  final PlannerDate? leastRecentHappenedEventDate;

  bool get isEmpty =>
      nextEventTitle == null &&
      nextEventDate == null &&
      lastEventDate == null &&
      lastHappenedEventDate == null &&
      leastRecentEventDate == null &&
      leastRecentHappenedEventDate == null;
}

final class ContactSummary {
  const ContactSummary({
    required this.contact,
    this.primaryGroup,
    this.statusBucket,
    this.smartStatus,
    this.latestQualifyingInteractionDate,
    this.groupNames = const <String>[],
    this.tagNames = const <String>[],
    this.context = const ContactListContext(),
  });

  final Contact contact;
  final ContactGroup? primaryGroup;

  /// Canonical repository-calculated Status category for a Status system view.
  /// It remains null for all non-Status reads.
  final ContactStatusBucket? statusBucket;
  final ContactSmartStatus? smartStatus;
  final DateTime? latestQualifyingInteractionDate;
  final List<String> groupNames;
  final List<String> tagNames;
  final ContactListContext context;

  ColorValue get colorValue {
    final group = primaryGroup;
    return group == null
        ? const ColorValue.neutral()
        : ColorValue(group.colorValue);
  }

  String get subtitle {
    // C2/C3 one-group V1: the row subtitle shows the single current/primary
    // group only. Dormant legacy secondary memberships and tag names are not
    // shown in list/profile/search/Add People rows for this V1.
    return primaryGroup?.name ?? '';
  }
}

/// The single presentation colour for a Contact that has no primary Group.
///
/// Owner law (2026-09-17): "ungrouped" is a *visual state*. It is never a Group
/// row, never a membership and never a stored identity, and this constant is
/// the only place that state resolves — so the list dot and the detail
/// surfaces can never disagree about it.
///
/// Owner lock (2026-09-18): the ungrouped state resolves to the exact PMG
/// "Interested" yellow. This is the single source for that state — no Group
/// row, membership or stored identity ever carries it.
abstract final class ContactUngroupedColor {
  /// PMG "Interested" yellow — exact owner-transcribed reference (dark swatch).
  static const int argb = 0xFFEBC766;

  /// The owner-facing label for that state. It is a *state*, never a Group, so
  /// the label lives beside the colour instead of being re-typed by each
  /// surface that presents it.
  static const String displayName = 'No Group';
}

/// Wraps an ARGB color value with a neutral fallback so presentation code
/// never has to reason about absent group colors.
final class ColorValue {
  const ColorValue(this.value) : isNeutral = false;
  const ColorValue.neutral()
    : value = ContactUngroupedColor.argb,
      isNeutral = true;

  final int value;
  final bool isNeutral;
}

/// Canonical built-in default group definitions.
///
/// The built-in identity is a deterministic UUIDv5 derived from a fixed
/// namespace plus the owning profile id, so the globally-unique
/// `contact_groups.id` primary key can never collide across profiles or sync,
/// and the same built-in group always maps to the same real row for a profile.
///
/// Owner lock (2026-09-17): the canonical default set is exactly these five, in
/// exactly this order —
///
///   0 Family
///   1 Friends
///   2 Ministering Assignments
///   3 Members
///   4 Avoid
///
/// `Other` is retired as a *default*: it is never seeded for a new profile. The
/// constant is retained only because a real `other` row already exists for every
/// profile that predates this change. That row is preserved untouched (including
/// its memberships) and is displayed after the five canonical defaults, exactly
/// like a user-created group.
///
/// A profile that predates this set is NOT migrated automatically: creating the
/// two new rows is an explicit, user-initiated action
/// (`ContactRepository.applyDefaultGroups`).
final class ContactBuiltInGroupDefaults {
  const ContactBuiltInGroupDefaults({
    required this.key,
    required this.name,
    required this.colorArgb,
    required this.canonicalOrder,
  });

  final String key;
  final String name;
  final int colorArgb;

  /// Zero-based canonical position. Persisted as the row's `sortOrder` on
  /// create and used as the ordering key by [canonicalFirst].
  final int canonicalOrder;

  /// The owner-transcribed PMG reference colours (2026-09-18 lock).
  ///
  /// These are written as literal ARGB, never via a [ContactGroupColorPalette]
  /// name: several of the VS-11 palette constant *names* do not describe their
  /// *values*, so a name-based mapping would silently store the wrong colour.
  ///
  /// PMG source per mapping (dark reference swatch):
  ///   Family                 -> PMG "Being Taught"      #76B181
  ///   Friends                -> owner-approved orange   #E89C72
  ///   Ministering Assignments-> PMG "New Members"       #98CED8
  ///   Members                -> PMG "Members"           #29646C
  ///   Avoid                  -> PMG "Don't Contact"     #C7566A
  static const int familyArgb = 0xFF76B181;
  static const int friendsArgb = 0xFFE89C72;
  static const int ministeringArgb = 0xFF98CED8;
  static const int membersArgb = 0xFF29646C;
  static const int avoidArgb = 0xFFC7566A;

  /// The retired built-in `Other` row's muted slate identity (owner-approved
  /// 2026-09-18). `Other` is not a default any more, so this value is used in
  /// exactly two places: the explicit restore of the real legacy row, and the
  /// creation default for a brand-new Group a user deliberately names Other.
  static const int otherArgb = 0xFF7D8B8C;

  /// The documented historical seeded colours of the retired `Other` built-in
  /// (the C2-canonicalised value, and the older Store A default that a
  /// pre-C2 override could leave on the row). A stored colour equal to either
  /// one is *provably* untouched, which is what makes the muted-slate move
  /// safe; any other value is a user customization and is never rewritten.
  static const List<int> otherHistoricalDefaultArgbs = <int>[
    0xFFB373A2,
    0xFF969B9E,
  ];

  static const ContactBuiltInGroupDefaults family = ContactBuiltInGroupDefaults(
    key: 'family',
    name: 'Family',
    colorArgb: familyArgb,
    canonicalOrder: 0,
  );
  static const ContactBuiltInGroupDefaults friends =
      ContactBuiltInGroupDefaults(
        key: 'friends',
        name: 'Friends',
        colorArgb: friendsArgb,
        canonicalOrder: 1,
      );
  static const ContactBuiltInGroupDefaults ministeringAssignments =
      ContactBuiltInGroupDefaults(
        key: 'ministering_assignments',
        name: 'Ministering Assignments',
        colorArgb: ministeringArgb,
        canonicalOrder: 2,
      );
  static const ContactBuiltInGroupDefaults members =
      ContactBuiltInGroupDefaults(
        key: 'members',
        name: 'Members',
        colorArgb: membersArgb,
        canonicalOrder: 3,
      );
  static const ContactBuiltInGroupDefaults avoid = ContactBuiltInGroupDefaults(
    key: 'avoid',
    name: 'Avoid',
    colorArgb: avoidArgb,
    canonicalOrder: 4,
  );

  /// Legacy pre-2026-09-17 built-in. NOT part of [ordered] and never seeded for
  /// a new profile — retained for the real rows that already exist.
  static const ContactBuiltInGroupDefaults other = ContactBuiltInGroupDefaults(
    key: 'other',
    name: 'Other',
    colorArgb: otherArgb,
    canonicalOrder: -1,
  );

  /// The five canonical defaults, in canonical order.
  static const List<ContactBuiltInGroupDefaults> ordered =
      <ContactBuiltInGroupDefaults>[
        family,
        friends,
        ministeringAssignments,
        members,
        avoid,
      ];

  static ContactBuiltInGroupDefaults byKey(String key) {
    return ordered.firstWhere((group) => group.key == key, orElse: () => other);
  }

  /// Applies the owner order law to a Group row list: the canonical built-ins
  /// come first, in canonical order, and every other row follows preserving its
  /// incoming relative order exactly.
  ///
  /// This is a partition, not a re-sort, so groups that share the historical
  /// `sortOrder = 0` fallback keep the stable order they already had (the
  /// repository query's `sortOrder, name` order) — nothing is reshuffled. The
  /// legacy `other` row is deliberately NOT canonical here, so it follows the
  /// five defaults like any custom group.
  static List<ContactGroup> canonicalFirst(
    List<ContactGroup> rows,
    String profileId,
  ) {
    final byId = <String, ContactGroup>{
      for (final row in rows) row.id: row,
    };
    final orderedRows = <ContactGroup>[];
    final claimed = <String>{};
    for (final definition in ordered) {
      final row = byId[
        ContactBuiltInGroupIdentity.idForProfile(profileId, definition.key)
      ];
      if (row != null && claimed.add(row.id)) {
        orderedRows.add(row);
      }
    }
    for (final row in rows) {
      if (!claimed.contains(row.id)) {
        orderedRows.add(row);
      }
    }
    return List<ContactGroup>.unmodifiable(orderedRows);
  }
}

/// One same-name collision found by a canonical-default run.
///
/// It is reported as data rather than only as a sentence because the owner's
/// law offers the user a real choice for exactly these rows: the conflict is
/// "your Group already owns this default name", never "your Group is wrong".
final class ContactGroupNameCollision {
  const ContactGroupNameCollision({
    required this.definition,
    required this.groupId,
    required this.groupName,
    required this.currentColorArgb,
    required this.isUnambiguous,
  });

  final ContactBuiltInGroupDefaults definition;

  /// The pre-existing real row that owns the canonical name. Untouched by the
  /// run: its id, memberships and colour are its own.
  final String groupId;
  final String groupName;
  final int currentColorArgb;

  /// True when exactly one row owns this canonical name, so it may also stand
  /// in the canonical display slot and be offered the default colour. When
  /// several rows share the name the app never guesses which one is meant.
  final bool isUnambiguous;

  String get canonicalName => definition.name;
  int get defaultColorArgb => definition.colorArgb;
}

/// Result of one explicit canonical-default-groups run
/// (`ContactRepository.applyDefaultGroups`).
///
/// Truthful and user-facing: Manage Groups reports [collidingNames] verbatim so
/// a same-name clash is never silent, and reports [addedNames] so the user can
/// see exactly what the run did.
final class ContactGroupDefaultsOutcome {
  const ContactGroupDefaultsOutcome({
    this.addedNames = const <String>[],
    this.collisions = const <ContactGroupNameCollision>[],
    this.reappliedNames = const <String>[],
    this.migratedColorNames = const <String>[],
  });

  /// Canonical groups newly created by this run.
  final List<String> addedNames;

  /// Canonical defaults that were NOT created because a different real Group
  /// already uses that exact name. Those pre-existing rows are left untouched.
  final List<ContactGroupNameCollision> collisions;

  /// Canonical rows whose name/order/colour were explicitly restored.
  final List<String> reappliedNames;

  /// Rows whose *untouched* historical default colour was migrated to the
  /// current approved value (the retired `Other` built-in, and nothing else).
  /// A row whose colour was customized is never listed here or written.
  final List<String> migratedColorNames;

  List<String> get collidingNames => List<String>.unmodifiable(<String>[
    for (final collision in collisions) collision.canonicalName,
  ]);

  /// The collisions the user may be offered the default colour for.
  List<ContactGroupNameCollision> get adoptableCollisions =>
      List<ContactGroupNameCollision>.unmodifiable(
        collisions.where((collision) => collision.isUnambiguous),
      );

  bool get hasCollisions => collisions.isNotEmpty;

  bool get changedAnything =>
      addedNames.isNotEmpty ||
      reappliedNames.isNotEmpty ||
      migratedColorNames.isNotEmpty;
}

/// Read-only view of whether a profile already holds the canonical default set.
///
/// Computed from already-loaded rows — it never writes and never seeds, so a
/// Group the user permanently deleted is never resurrected by a read.
final class ContactDefaultGroupsStatus {
  const ContactDefaultGroupsStatus({
    required this.missingNames,
    required this.collidingNames,
  });

  /// Canonical defaults whose stable id is absent from the profile.
  final List<String> missingNames;

  /// Canonical defaults that cannot be created because a *different* real row
  /// already uses that exact name.
  final List<String> collidingNames;

  bool get needsAttention => missingNames.isNotEmpty;

  /// Owner law (2026-09-18): whether the profile already holds the canonical
  /// five, so an explicit "Restore default groups" run must be a pure no-op.
  ///
  /// The check reuses the very projection Manage Groups displays, so what counts
  /// as restored is exactly what the user already sees as restored: a row that
  /// fills an official slot by exact name — a display SUBSTITUTE — is accepted,
  /// and the deterministic canonical id is deliberately NOT required. Every
  /// official slot must carry the canonical name, the canonical colour and the
  /// canonical effective position, or the slot is not restored.
  ///
  /// This reads rows the caller already loaded; it never writes and never
  /// seeds, so a Group the user permanently deleted is never resurrected here.
  static bool isFullyRestored({
    required List<ContactGroup> groups,
    required String profileId,
  }) {
    final presentation = ContactGroupsPresentation.resolve(
      groups: groups,
      profileId: profileId,
    );
    // More than one row owning an official name is never automatically
    // restored: the app must not guess which row is meant.
    if (presentation.ambiguousNames.isNotEmpty) {
      return false;
    }
    for (final slot in presentation.slots) {
      final row = slot.row;
      if (row == null ||
          row.name.trim().toLowerCase() !=
              slot.definition.name.trim().toLowerCase() ||
          !Vs11ColorSystem.sameOpaqueRgb(
            row.colorValue,
            slot.definition.colorArgb,
          )) {
        return false;
      }
    }
    return true;
  }

  static ContactDefaultGroupsStatus evaluate({
    required List<ContactGroup> groups,
    required String profileId,
  }) {
    final ids = <String>{for (final group in groups) group.id};
    final names = <String>{for (final group in groups) group.name.trim().toLowerCase()};
    final missing = <String>[];
    final colliding = <String>[];
    for (final definition in ContactBuiltInGroupDefaults.ordered) {
      final expectedId = ContactBuiltInGroupIdentity.idForProfile(
        profileId,
        definition.key,
      );
      if (ids.contains(expectedId)) {
        continue;
      }
      if (names.contains(definition.name.trim().toLowerCase())) {
        colliding.add(definition.name);
        continue;
      }
      missing.add(definition.name);
    }
    return ContactDefaultGroupsStatus(
      missingNames: List<String>.unmodifiable(missing),
      collidingNames: List<String>.unmodifiable(colliding),
    );
  }
}

/// One canonical presentation slot in Manage Groups.
///
/// A slot always exists for each of the five canonical defaults, in canonical
/// order, whether or not a real row can fill it. An empty slot is rendered as
/// nothing: a Group the user permanently deleted must stay deleted, so the
/// presentation never invents a phantom row.
final class ContactGroupSlot {
  const ContactGroupSlot({
    required this.definition,
    this.row,
    this.isDisplaySubstitute = false,
  });

  final ContactBuiltInGroupDefaults definition;

  /// The real row occupying this slot: the canonical row, or — when the
  /// canonical row is absent and exactly one row owns the canonical name —
  /// that row as a DISPLAY SUBSTITUTE. Null when the slot is empty.
  final ContactGroup? row;

  /// True when [row] merely *shares* the canonical name. Its id, name,
  /// memberships and colour stay entirely its own; only its position on this
  /// screen comes from the slot.
  final bool isDisplaySubstitute;
}

/// The owner's Manage Groups presentation law (2026-09-18): the five canonical
/// defaults first, then "Your Other Groups" when any exist, then the virtual
/// "No Group" state last.
///
/// This is a PURE projection of the rows the repository already returns (which
/// are themselves canonical-first). It writes nothing, seeds nothing and never
/// changes an identity.
final class ContactGroupsPresentation {
  const ContactGroupsPresentation({
    required this.slots,
    required this.otherGroups,
    required this.ambiguousNames,
  });

  /// The five canonical slots, in canonical order.
  final List<ContactGroupSlot> slots;

  /// Every active row that does not occupy a canonical slot, in the incoming
  /// (already stable) order. Rows whose canonical name is ambiguous are kept
  /// here rather than guessed into a slot.
  final List<ContactGroup> otherGroups;

  /// Canonical names owned by more than one active row.
  final List<String> ambiguousNames;

  bool get hasOtherGroups => otherGroups.isNotEmpty;

  /// The active rows that occupy a canonical slot, in canonical order.
  List<ContactGroup> get slottedGroups => <ContactGroup>[
    for (final slot in slots)
      if (slot.row != null) slot.row!,
  ];

  static ContactGroupsPresentation resolve({
    required List<ContactGroup> groups,
    required String profileId,
  }) {
    final active = groups
        .where((group) => !group.isArchived)
        .toList(growable: false);
    final byId = <String, ContactGroup>{
      for (final row in active) row.id: row,
    };
    final byName = <String, List<ContactGroup>>{};
    for (final row in active) {
      byName
          .putIfAbsent(row.name.trim().toLowerCase(), () => <ContactGroup>[])
          .add(row);
    }
    final claimed = <String>{};
    final slots = <ContactGroupSlot>[];
    final ambiguous = <String>[];
    for (final definition in ContactBuiltInGroupDefaults.ordered) {
      final canonical =
          byId[ContactBuiltInGroupIdentity.idForProfile(
            profileId,
            definition.key,
          )];
      if (canonical != null && claimed.add(canonical.id)) {
        slots.add(ContactGroupSlot(definition: definition, row: canonical));
        continue;
      }
      final unclaimed =
          (byName[definition.name.trim().toLowerCase()] ?? const <ContactGroup>[])
              .where((row) => !claimed.contains(row.id))
              .toList(growable: false);
      if (unclaimed.length == 1) {
        final substitute = unclaimed.single;
        claimed.add(substitute.id);
        slots.add(
          ContactGroupSlot(
            definition: definition,
            row: substitute,
            isDisplaySubstitute: true,
          ),
        );
        continue;
      }
      if (unclaimed.length > 1) {
        // Never guess which of several same-name rows is "the" canonical one.
        ambiguous.add(definition.name);
      }
      slots.add(ContactGroupSlot(definition: definition));
    }
    return ContactGroupsPresentation(
      slots: List<ContactGroupSlot>.unmodifiable(slots),
      otherGroups: List<ContactGroup>.unmodifiable(<ContactGroup>[
        for (final row in active)
          if (!claimed.contains(row.id)) row,
      ]),
      ambiguousNames: List<String>.unmodifiable(ambiguous),
    );
  }
}

/// Owner-approved muted palette for the Manage Groups creation shortcuts
/// (2026-09-18).
///
/// These are *creation* defaults for a brand-new Group, and the restore target
/// for the retired `Other` built-in. They deliberately never rewrite an
/// existing row: the repository cannot prove that, say, an existing "Clients"
/// group was never recoloured by hand, so an existing row is reported instead
/// of being silently changed.
///
/// The palette stays inside the existing restrained Next Transfer family while
/// pulling the widely-used shortcuts far enough apart to be told apart at a
/// glance.
abstract final class ContactGroupSuggestedDefaults {
  static const int familyArgb = ContactBuiltInGroupDefaults.familyArgb;
  static const int friendsArgb = ContactBuiltInGroupDefaults.friendsArgb;
  static const int workArgb = 0xFF9C8068;
  static const int schoolArgb = 0xFF6789A8;
  static const int clientsArgb = 0xFF8E7CB3;
  static const int teamArgb = 0xFFA77B9B;
  static const int otherArgb = ContactBuiltInGroupDefaults.otherArgb;

  /// The approved colour for a shortcut name, or null for an unknown name.
  static int? colorFor(String name) {
    return switch (name.trim().toLowerCase()) {
      'family' => familyArgb,
      'friends' => friendsArgb,
      'work' => workArgb,
      'school' => schoolArgb,
      'clients' => clientsArgb,
      'team' => teamArgb,
      'other' => otherArgb,
      _ => null,
    };
  }
}

/// One muted, solid Contact Group identity palette for every VS-11 Group
/// surface. The same ARGB values are intentionally used in Light and Dark
/// themes; each value was chosen to remain legible on both existing surfaces
/// without creating a separate neon Light-mode palette.
///
/// Future Maps law (documented only): a Contact map pin uses the canonical
/// color of its primary Group. Contacts with no primary Group use the Maps
/// neutral/default marker law when that feature is implemented.
final class ContactGroupColorPalette {
  const ContactGroupColorPalette._();

  // Existing persisted Groups are intentionally not rewritten. These values
  // only govern future defaults and deliberate recommended-color choices.
  static const int mutedRoseArgb = Vs11ColorSystem.p01RoseEmber;
  static const int warmAmberArgb = Vs11ColorSystem.p05BurntApricot;
  static const int sageArgb = Vs11ColorSystem.p13Moss;
  static const int tealArgb = Vs11ColorSystem.p18ReferenceTeal;
  static const int calmBlueArgb = Vs11ColorSystem.p21Denim;
  static const int mutedVioletArgb = Vs11ColorSystem.p25DustyViolet;
  static const int dustyRoseArgb = Vs11ColorSystem.p30TaupeGray;
  static const int neutralGrayArgb = Vs11ColorSystem.p29CoolGray;

  /// The full owner-approved 32-color vocabulary. Group and Event Type
  /// recommendation pools are deliberately separate; only their vocabulary
  /// is shared.
  static final List<ContactGroupRecommendedColor>
  recommended = List<ContactGroupRecommendedColor>.unmodifiable(
    Vs11ColorSystem.colors
        .map(
          (color) =>
              ContactGroupRecommendedColor(name: color.name, argb: color.argb),
        )
        .toList(growable: false),
  );
}

final class ContactGroupRecommendedColor {
  const ContactGroupRecommendedColor({required this.name, required this.argb});

  final String name;
  final int argb;
}

/// Deterministic UUIDv5 identity for built-in Contact Group rows.
///
/// Identity incorporates enough stable context (fixed namespace + profile id +
/// built-in key) so no unsafe duplication can occur across profiles or sync.
/// Uses the project's existing `uuid` dependency (no new package).
abstract final class ContactBuiltInGroupIdentity {
  /// Fixed project namespace for built-in contact group identities.
  static const String namespace = '6a1f8e5b-7c2d-4a3f-9b8e-0d1c2e3f4a5b';

  static String idForProfile(String profileId, String builtInKey) {
    return const Uuid().v5(
      namespace,
      'nexttransfer.builtin-contact-group:$profileId:$builtInKey',
    );
  }

  static bool isBuiltInId(String groupId, String profileId) {
    return ContactBuiltInGroupDefaults.ordered.any(
      (group) =>
          groupId == idForProfile(profileId, group.key) && groupId.isNotEmpty,
    );
  }
}

final class ContactDetail {
  const ContactDetail({
    required this.contact,
    this.methods = const <ContactMethod>[],
    this.groups = const <ContactGroup>[],
    this.primaryGroupId,
    this.tags = const <ContactTag>[],
    this.notes = const <ContactNote>[],
    this.availability = const <ContactAvailability>[],
  });

  final Contact contact;
  final List<ContactMethod> methods;
  final List<ContactGroup> groups;
  final String? primaryGroupId;
  final List<ContactTag> tags;
  final List<ContactNote> notes;
  final List<ContactAvailability> availability;

  ContactMethod? get primaryMethod {
    for (final method in methods) {
      if (method.isPrimary) {
        return method;
      }
    }
    return methods.isEmpty ? null : methods.first;
  }
}

/// Bounded data projection for a purpose-specific Contact action.  It keeps
/// the list row's canonical group identity beside the persisted methods the
/// recipient classifier must inspect, without inheriting Contacts Main's
/// current filters or issuing one detail query per visible row.
final class ContactRecipientCandidate {
  const ContactRecipientCandidate({
    required this.summary,
    required this.detail,
  });

  final ContactSummary summary;
  final ContactDetail detail;
}

/// A truthful Event Detail participant label. Historical occurrences use the
/// immutable display-name snapshot; current and future occurrences use a live
/// Event-to-Contact link. The presentation never substitutes one for the
/// other.
final class EventParticipantPresentation {
  const EventParticipantPresentation({
    required this.contactId,
    required this.displayName,
    required this.isSnapshot,
  });

  final String contactId;
  final String displayName;
  final bool isSnapshot;
}

/// Draft used for both create and update. [id] is a fresh UUID on create and
/// the stable Contact ID on update. Legacy drafts retain their historical
/// shape; C4 manual creates opt into stricter validation explicitly.
final class ContactDraft {
  const ContactDraft({
    required this.id,
    required this.firstName,
    required this.lastName,
    required this.displayName,
    required this.preferredContactMethod,
    required this.isFavorite,
    this.addressText,
    this.source = ContactSource.manual,
    this.methods = const <ContactMethodDraft>[],
    this.groupIds = const <String>[],
    this.primaryGroupId,
    this.tagNames = const <String>[],
    this.availability = const <ContactAvailability>[],
    this.initialNoteText,
    this.requiresNewManualContactValidation = false,
  });

  final String id;
  final String firstName;
  final String lastName;
  final String displayName;
  final ContactPreferredMethod preferredContactMethod;
  final bool isFavorite;
  final String? addressText;
  final ContactSource source;
  final List<ContactMethodDraft> methods;
  final List<String> groupIds;
  final String? primaryGroupId;
  final List<String> tagNames;
  final List<ContactAvailability> availability;
  final String? initialNoteText;

  /// The Contact form sets this for a user-created manual Contact.  Imports
  /// and historical seed/import paths remain free to preserve the legacy
  /// shapes they already own.  The repository enforces this below the form.
  final bool requiresNewManualContactValidation;

  /// Enforces the new-manual-contact law before normalization, rather than
  /// relying on the presentation layer's Save affordance. A contact method is
  /// optional, but any nonblank method supplied by the user must be valid so
  /// it cannot be silently discarded during normalization.
  void validateNewManualContact() {
    if (firstName.trim().isEmpty) {
      throw const ContactValidationException(
        'First Name is required for a new Contact.',
      );
    }
    if (lastName.trim().isEmpty) {
      throw const ContactValidationException(
        'Last Name is required for a new Contact.',
      );
    }
    for (final method in methods) {
      if (method.value.trim().isNotEmpty &&
          !isValidNewManualContactMethod(method)) {
        throw const ContactValidationException(
          'Use a valid Phone, Email, or Social Profile when a contact method is entered.',
        );
      }
    }
  }

  ContactDraft normalized() {
    final trimmedDisplay = displayName.trim();
    if (trimmedDisplay.isEmpty) {
      throw const ContactValidationException('A Contact needs a usable name.');
    }
    final trimmedFirst = firstName.trim();
    final trimmedLast = lastName.trim();
    final methods = <ContactMethodDraft>[];
    for (final method in this.methods) {
      final value = method.value.trim();
      if (value.isEmpty) {
        continue;
      }
      final normalizedMethod = _normalizeMethod(method);
      if (normalizedMethod != null) {
        methods.add(normalizedMethod);
      }
    }
    final availability = <ContactAvailability>[];
    for (final window in this.availability) {
      try {
        availability.add(window.normalized());
      } on ContactValidationException {
        // Invalid windows are dropped rather than failing the whole save.
      }
    }
    final groupIds = <String>[];
    for (final groupId in this.groupIds) {
      if (!groupIds.contains(groupId)) {
        groupIds.add(groupId);
      }
    }
    final primaryGroupId = groupIds.contains(this.primaryGroupId)
        ? this.primaryGroupId
        : null;
    final tagNames = <String>[];
    for (final tag in this.tagNames) {
      final trimmed = tag.trim();
      if (trimmed.isNotEmpty && !tagNames.contains(trimmed)) {
        tagNames.add(trimmed);
      }
    }
    return ContactDraft(
      id: id,
      firstName: trimmedFirst,
      lastName: trimmedLast,
      displayName: trimmedDisplay,
      preferredContactMethod: preferredContactMethod,
      isFavorite: isFavorite,
      addressText: _normalizeOptional(addressText),
      source: source,
      methods: List<ContactMethodDraft>.unmodifiable(methods),
      groupIds: List<String>.unmodifiable(groupIds),
      primaryGroupId: primaryGroupId,
      tagNames: List<String>.unmodifiable(tagNames),
      availability: List<ContactAvailability>.unmodifiable(availability),
      initialNoteText: _normalizeOptional(initialNoteText),
      requiresNewManualContactValidation: requiresNewManualContactValidation,
    );
  }

  static ContactMethodDraft? _normalizeMethod(ContactMethodDraft method) {
    final normalized = switch (method.type) {
      ContactMethodType.phone => normalizePhone(method.value),
      ContactMethodType.email => method.value.toLowerCase().trim(),
      ContactMethodType.social => method.value.trim(),
    };
    return normalized.isEmpty
        ? null
        : ContactMethodDraft(
            id: method.id,
            type: method.type,
            value: method.value.trim(),
            // Keep a legacy/custom label byte-for-byte through an unrelated
            // edit. New labels are chosen from the C4 presentation list.
            label: method.label,
            isPrimary: method.isPrimary,
            receivesTexts: method.receivesTexts,
            hasWhatsApp: method.hasWhatsApp,
          );
  }

  static String? _normalizeOptional(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}

/// C4's manual-create test is intentionally stricter than legacy edit data:
/// phones need digits, emails need a basic address shape, and social values
/// remain raw identifiers/URLs with no URL-format requirement.
bool isValidNewManualContactMethod(ContactMethodDraft method) {
  final value = method.value.trim();
  return switch (method.type) {
    ContactMethodType.phone => normalizePhone(value).isNotEmpty,
    ContactMethodType.email => RegExp(
      r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
    ).hasMatch(value),
    ContactMethodType.social => value.isNotEmpty,
  };
}

/// Best-effort phone normalization used for duplicate detection only.
/// Returns an empty string when the value contains no digits.
String normalizePhone(String value) {
  final digits = value.replaceAll(RegExp(r'[^\d]'), '');
  if (digits.isEmpty) {
    return '';
  }
  // Strip a leading country code of 00 or 011 equivalents is intentionally
  // conservative: we only drop a leading "1" when the number is long enough
  // to be a US-style number, and never merge on this alone.
  return digits;
}

final class DeviceContactPhone {
  const DeviceContactPhone({required this.value, this.sourceLabel});

  final String value;
  final String? sourceLabel;
}

final class DeviceContactDraft {
  const DeviceContactDraft({
    required this.displayName,
    this.firstName,
    this.lastName,
    this.phones = const <String>[],
    this.phoneDetails = const <DeviceContactPhone>[],
    this.emails = const <String>[],
  });

  final String displayName;
  final String? firstName;
  final String? lastName;
  final List<String> phones;
  final List<DeviceContactPhone> phoneDetails;
  final List<String> emails;

  /// Keeps older import fixtures and integrations source-compatible while a
  /// real device reader can preserve a phone's source label.
  List<DeviceContactPhone> get resolvedPhones => phoneDetails.isNotEmpty
      ? phoneDetails
      : phones
            .map((value) => DeviceContactPhone(value: value))
            .toList(growable: false);
}

final class ContactImportResult {
  const ContactImportResult({
    required this.createdCount,
    required this.skippedCount,
    required this.duplicateContactIds,
  });

  final int createdCount;
  final int skippedCount;
  final List<String> duplicateContactIds;
}

/// Field-level merge choices keyed by canonical field name
/// (`displayName`, `addressText`, `preferredContactMethod`).  The value is
/// the source Contact ID whose value should survive for that field.
final class ContactMergeChoices {
  const ContactMergeChoices(this.values);

  final Map<String, String> values;

  String? valueFor(String field, {required String fallbackContactId}) {
    return values[field] ?? fallbackContactId;
  }
}

final class ContactMergePlan {
  const ContactMergePlan({
    required this.survivor,
    required this.absorbed,
    required this.survivorLinkCount,
    required this.absorbedLinkCount,
    required this.absorbedNoteCount,
  });

  final Contact survivor;
  final List<Contact> absorbed;
  final int survivorLinkCount;
  final int absorbedLinkCount;
  final int absorbedNoteCount;
}

// ---------------------------------------------------------------------------
// Timeline projection (canonical facts only — no inference).
// ---------------------------------------------------------------------------

enum ContactTimelineKind { recordCreated, eventOccurrence, plannerTask }

final class ContactTimelineEntry {
  const ContactTimelineEntry({
    required this.kind,
    required this.date,
    required this.chronology,
    required this.title,
    this.subtitle,
    this.status,
    this.statusLabel,
    this.eventId,
    this.originalDate,
    this.occurrenceId,
    this.activityTypeId,
    this.activityTypeStableKey,
    this.activityTypeColorValue,
    this.effectiveStartMinute,
    this.taskId,
    this.isUpcoming = false,
    this.isStructurallyCancelled = false,
    this.hasSubmittedOutcome = false,
  });

  final ContactTimelineKind kind;
  final PlannerDate date;

  /// A derived, local calendar-time ordering key. Event occurrences use their
  /// effective Planner date and start minute (all-day is midnight); Record
  /// Created uses the factual local [Contact.createdAtUtc] timestamp. It is a
  /// read-model value only -- no second Timeline store is introduced.
  final DateTime chronology;
  final String title;
  final String? subtitle;
  final CalendarEventStatus? status;
  final String? statusLabel;
  final String? eventId;
  final PlannerDate? originalDate;
  final String? occurrenceId;
  final String? activityTypeId;
  final String? activityTypeStableKey;
  final int? activityTypeColorValue;
  final int? effectiveStartMinute;
  final String? taskId;
  final bool isUpcoming;
  final bool isStructurallyCancelled;
  final bool hasSubmittedOutcome;

  bool get isTappable => eventId != null && originalDate != null;

  bool get isTaskTappable => taskId != null;

  String get canonicalIdentity => switch (kind) {
    ContactTimelineKind.eventOccurrence =>
      'event:${eventId ?? ''}:${occurrenceId ?? ''}',
    ContactTimelineKind.plannerTask => 'task:${taskId ?? ''}',
    ContactTimelineKind.recordCreated =>
      'record:${chronology.microsecondsSinceEpoch}',
  };
}

final class ContactTimeline {
  const ContactTimeline({
    required this.upcoming,
    required this.history,
    this.futureTasks = const <ContactTimelineEntry>[],
    this.cancelledEvents = const <ContactTimelineEntry>[],
  });

  /// Canonical future occurrence set, ordered nearest-first for the compact
  /// Profile Upcoming projection.
  final List<ContactTimelineEntry> upcoming;
  final List<ContactTimelineEntry> history;

  /// Factual, dated, incomplete Tasks linked through task_contact_links.
  /// They belong in Timeline Future and the compact merged Profile Upcoming.
  final List<ContactTimelineEntry> futureTasks;

  /// Structurally cancelled Event occurrences that have no factual submitted
  /// historical outcome. They never participate in Profile Upcoming.
  final List<ContactTimelineEntry> cancelledEvents;

  List<ContactTimelineEntry> get profileUpcoming {
    final entries = <ContactTimelineEntry>[...upcoming, ...futureTasks]
      ..sort((left, right) {
        final chronology = left.chronology.compareTo(right.chronology);
        if (chronology != 0) {
          return chronology;
        }
        return _timelineIdentity(left).compareTo(_timelineIdentity(right));
      });
    return List<ContactTimelineEntry>.unmodifiable(entries);
  }

  /// Timeline deliberately presents the same future facts in the opposite
  /// direction: farthest first and the next Event immediately above History.
  List<ContactTimelineEntry> get timelineFuture {
    final entries = <ContactTimelineEntry>[...upcoming, ...futureTasks]
      ..sort((left, right) => right.chronology.compareTo(left.chronology));
    return List<ContactTimelineEntry>.unmodifiable(entries);
  }

  bool get isEmpty =>
      upcoming.isEmpty &&
      futureTasks.isEmpty &&
      history.isEmpty &&
      cancelledEvents.isEmpty;

  static String _timelineIdentity(ContactTimelineEntry entry) => <String>[
    entry.kind.name,
    entry.eventId ?? '',
    entry.originalDate?.iso8601 ?? '',
    entry.occurrenceId ?? '',
    entry.taskId ?? '',
  ].join(':');
}

/// A repeated historical pattern derived only from completed/happened
/// occurrences (never inferred). Requires at least three qualifying dates.
final class CommonEventPattern {
  const CommonEventPattern({
    required this.eventId,
    required this.title,
    required this.weekdayLabel,
    required this.startMinuteLabel,
    required this.count,
  });

  final String eventId;
  final String title;
  final String weekdayLabel;
  final String startMinuteLabel;
  final int count;
}

/// Derives Common Happened Events from the same canonical historical
/// occurrence projection rendered by Contact Timeline. Duplicate inherited
/// participant rows therefore cannot inflate the threshold.
List<CommonEventPattern> commonEventPatternsFromTimeline(
  ContactTimeline timeline,
) {
  final canonicalOccurrences = <String, ContactTimelineEntry>{};
  for (final entry in timeline.history) {
    if (entry.kind != ContactTimelineKind.eventOccurrence ||
        entry.status != CalendarEventStatus.completedHappened ||
        entry.eventId == null ||
        entry.occurrenceId == null ||
        entry.isUpcoming) {
      continue;
    }
    canonicalOccurrences.putIfAbsent(entry.canonicalIdentity, () => entry);
  }

  final groups =
      <({String eventId, int weekday, int? startMinute}),
          List<ContactTimelineEntry>>{};
  for (final entry in canonicalOccurrences.values) {
    final key = (
      eventId: entry.eventId!,
      weekday: entry.date.weekday,
      startMinute: entry.effectiveStartMinute,
    );
    groups.putIfAbsent(key, () => <ContactTimelineEntry>[]).add(entry);
  }

  final patterns = <CommonEventPattern>[];
  for (final group in groups.entries) {
    if (group.value.length < 3) continue;
    final first = group.value.first;
    patterns.add(
      CommonEventPattern(
        eventId: group.key.eventId,
        title: first.title,
        weekdayLabel: _commonEventWeekday(group.key.weekday),
        startMinuteLabel: _commonEventTime(group.key.startMinute),
        count: group.value.length,
      ),
    );
  }
  patterns.sort((left, right) {
    final count = right.count.compareTo(left.count);
    if (count != 0) return count;
    final event = left.eventId.compareTo(right.eventId);
    if (event != 0) return event;
    final weekday = left.weekdayLabel.compareTo(right.weekdayLabel);
    if (weekday != 0) return weekday;
    return left.startMinuteLabel.compareTo(right.startMinuteLabel);
  });
  return List<CommonEventPattern>.unmodifiable(patterns);
}

String _commonEventWeekday(int weekday) => const <String>[
  'Mon',
  'Tue',
  'Wed',
  'Thu',
  'Fri',
  'Sat',
  'Sun',
][weekday - 1];

String _commonEventTime(int? minute) {
  if (minute == null) return 'All day';
  final hour = minute ~/ 60;
  final displayHour = hour == 0 ? 12 : (hour > 12 ? hour - 12 : hour);
  final suffix = hour < 12 ? 'AM' : 'PM';
  final minuteText = (minute % 60).toString().padLeft(2, '0');
  return '$displayHour:$minuteText $suffix';
}

final class ContactValidationException implements Exception {
  const ContactValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

final class ContactMergeException implements Exception {
  const ContactMergeException(this.message);

  final String message;

  @override
  String toString() => message;
}
