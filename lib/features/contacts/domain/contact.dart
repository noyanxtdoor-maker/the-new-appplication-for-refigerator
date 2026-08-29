import 'dart:convert';

import 'package:rmplanner/features/planner/domain/calendar_event.dart';
import 'package:rmplanner/features/planner/domain/planner_date.dart';
import 'package:uuid/uuid.dart';

/// Lifecycle of a Contact.  Archived keeps the same ID and every historical
/// link; merged keeps the row so historical participation stays traceable to
/// the absorbed identity.
enum ContactLifecycleState { active, archived, merged }

enum ContactSource { manual, deviceImport, betterCalendarImport }

enum ContactMethodType { phone, email, social }

enum ContactPreferredMethod { message, call, email }

enum ContactSortBy {
  name,
  nameDesc,
  recentlyAdded,
  oldestAdded,
  status,
  lastViewed,
  nextEvent,
  lastEvent,
  lastHappenedEvent,
  leastRecentEvent,
  leastRecentHappenedEvent,
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
  final String? mergedIntoContactId;

  bool get isActive => lifecycleState == ContactLifecycleState.active;
  bool get isArchived => lifecycleState == ContactLifecycleState.archived;
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

/// Wraps an ARGB color value with a neutral fallback so presentation code
/// never has to reason about absent group colors.
final class ColorValue {
  const ColorValue(this.value) : isNeutral = false;
  const ColorValue.neutral() : value = _neutral, isNeutral = true;

  static const int _neutral = 0xFF9CA0A6;

  final int value;
  final bool isNeutral;
}

/// Canonical built-in default group definitions (C2 owner lock).
///
/// The built-in identity is a deterministic UUIDv5 derived from a fixed
/// namespace plus the owning profile id, so the globally-unique
/// `contact_groups.id` primary key can never collide across profiles or sync,
/// and the same built-in group always maps to the same real row for a profile.
final class ContactBuiltInGroupDefaults {
  const ContactBuiltInGroupDefaults({
    required this.key,
    required this.name,
    required this.colorArgb,
  });

  final String key;
  final String name;
  final int colorArgb;

  static const ContactBuiltInGroupDefaults family = ContactBuiltInGroupDefaults(
    key: 'family',
    name: 'Family',
    colorArgb: 0xFFEBC766,
  );
  static const ContactBuiltInGroupDefaults friends =
      ContactBuiltInGroupDefaults(
        key: 'friends',
        name: 'Friends',
        colorArgb: 0xFF7FB7D1,
      );
  static const ContactBuiltInGroupDefaults avoid = ContactBuiltInGroupDefaults(
    key: 'avoid',
    name: 'Avoid',
    colorArgb: 0xFFD35A70,
  );
  static const ContactBuiltInGroupDefaults other = ContactBuiltInGroupDefaults(
    key: 'other',
    name: 'Other',
    colorArgb: 0xFF969B9E,
  );

  static const List<ContactBuiltInGroupDefaults> ordered =
      <ContactBuiltInGroupDefaults>[family, friends, avoid, other];

  static ContactBuiltInGroupDefaults byKey(String key) {
    return ordered.firstWhere((group) => group.key == key, orElse: () => other);
  }
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

final class DeviceContactDraft {
  const DeviceContactDraft({
    required this.displayName,
    this.firstName,
    this.lastName,
    this.phones = const <String>[],
    this.emails = const <String>[],
  });

  final String displayName;
  final String? firstName;
  final String? lastName;
  final List<String> phones;
  final List<String> emails;
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

enum ContactTimelineKind { recordCreated, eventOccurrence }

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
    this.activityTypeColorValue,
    this.isUpcoming = false,
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
  final int? activityTypeColorValue;
  final bool isUpcoming;

  bool get isTappable => eventId != null && originalDate != null;
}

final class ContactTimeline {
  const ContactTimeline({required this.upcoming, required this.history});

  /// Canonical future occurrence set, ordered nearest-first for the compact
  /// Profile Upcoming projection.
  final List<ContactTimelineEntry> upcoming;
  final List<ContactTimelineEntry> history;

  List<ContactTimelineEntry> get profileUpcoming => upcoming;

  /// Timeline deliberately presents the same future facts in the opposite
  /// direction: farthest first and the next Event immediately above History.
  List<ContactTimelineEntry> get timelineFuture =>
      List<ContactTimelineEntry>.unmodifiable(upcoming.reversed);

  bool get isEmpty => upcoming.isEmpty && history.isEmpty;
}

/// A repeated historical pattern derived only from completed/happened
/// occurrences (never inferred).  Requires at least two qualifying dates.
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
