import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rmplanner/features/goals/domain/goal_icon_registry.dart';
import 'package:xml/xml.dart' as xml;

/// True when [source] contains a white/off-white path or rect whose bounds
/// cover ~the full viewBox (the baked Stage-1 backdrop pattern).
bool hasFullCanvasWhiteBackdrop(String source) {
  final document = xml.XmlDocument.parse(source);
  final root = document.rootElement;
  final viewBox = root.getAttribute('viewBox');
  if (viewBox == null) {
    return false;
  }
  final parts = viewBox.trim().split(RegExp(r'\s+'));
  if (parts.length != 4) {
    return false;
  }
  final viewBoxWidth = double.parse(parts[2]);
  final viewBoxHeight = double.parse(parts[3]);
  for (final element in document.descendantElements) {
    final name = element.localName.toLowerCase();
    if (name != 'path' && name != 'rect') {
      continue;
    }
    final fill = (element.getAttribute('fill') ?? '').trim().toLowerCase();
    if (!const <String>{'#fefefe', '#ffffff', '#fff', 'white'}.contains(fill)) {
      continue;
    }
    double left = double.infinity;
    double top = double.infinity;
    double right = double.negativeInfinity;
    double bottom = double.negativeInfinity;
    if (name == 'rect') {
      final x = double.tryParse(element.getAttribute('x') ?? '0') ?? 0;
      final y = double.tryParse(element.getAttribute('y') ?? '0') ?? 0;
      final width = double.tryParse(element.getAttribute('width') ?? '0') ?? 0;
      final height =
          double.tryParse(element.getAttribute('height') ?? '0') ?? 0;
      left = x;
      top = y;
      right = x + width;
      bottom = y + height;
    } else {
      final d = element.getAttribute('d') ?? '';
      final numbers = <double>[
        for (final match in RegExp(r'-?\d+\.?\d*').allMatches(d))
          double.parse(match.group(0)!),
      ];
      if (numbers.length < 4) {
        continue;
      }
      for (var i = 0; i + 1 < numbers.length; i += 2) {
        final x = numbers[i];
        final y = numbers[i + 1];
        if (x < left) {
          left = x;
        }
        if (x > right) {
          right = x;
        }
        if (y < top) {
          top = y;
        }
        if (y > bottom) {
          bottom = y;
        }
      }
    }
    if (left.isFinite &&
        right - left >= viewBoxWidth * 0.97 &&
        bottom - top >= viewBoxHeight * 0.97) {
      return true;
    }
  }
  return false;
}

void main() {
  const registry = GoalIconRegistry.instance;

  test('the production registry contains exactly the Stage-1.1 manifest', () {
    expect(
      GoalIconRegistry.allIcons.map((definition) => definition.id),
      GoalIconRegistry.approvedIconIds,
    );
    expect(GoalIconRegistry.allIcons, hasLength(41));
    expect(
      GoalIconRegistry.allIcons.map((definition) => definition.id).toSet(),
      hasLength(41),
    );
    expect(
      GoalIconRegistry.allIcons
          .map((definition) => definition.assetPath)
          .toSet(),
      hasLength(41),
    );
    expect(
      GoalIconRegistry.allIcons.every((definition) {
        return definition.displayName.trim().isNotEmpty &&
            definition.semanticsLabel.trim().isNotEmpty &&
            definition.category.trim().isNotEmpty;
      }),
      isTrue,
    );
    expect(
      GoalIconRegistry.allIcons.every((definition) {
        final normalized = definition.keywords
            .map((keyword) => keyword.trim().toLowerCase())
            .toList(growable: false);
        // Multi-word approved keywords (e.g. 'job hunt', 'follow through')
        // are allowed; they must be unique after normalization and free of
        // leading/trailing or doubled spaces.
        return normalized.length == definition.keywords.length &&
            normalized.toSet().length == normalized.length &&
            normalized.every(
              (keyword) => keyword == keyword.trim() && !keyword.contains('  '),
            );
      }),
      isTrue,
    );
    expect(registry.validate(), isEmpty);
    expect(
      registry.validate(
        availableAssetPaths: GoalIconRegistry.allIcons.map(
          (definition) => definition.assetPath,
        ),
      ),
      isEmpty,
    );
  });

  test('Stage-1.1 foundation retirement keeps stable IDs with new names', () {
    final work = registry.findById('work_briefcase')!;
    expect(work.displayName, 'Find Job');
    expect(work.semanticsLabel, 'Job search and applications');
    expect(work.category, 'Work & Learning');
    expect(
      work.keywords,
      containsAll(<String>['job', 'apply', 'search', 'application']),
    );

    final wallet = registry.findById('finance_wallet')!;
    expect(wallet.displayName, 'Pie Chart');
    expect(wallet.semanticsLabel, 'Budgeting and financial planning');
    expect(wallet.category, 'Money & Home');
    expect(
      wallet.keywords,
      containsAll(<String>[
        'budget',
        'spending',
        'allocation',
        'chart',
        'money',
      ]),
    );
  });

  test(
    'find_job and finance_pie_chart are retired aliases, not selectable',
    () {
      // Aliases resolve to their canonical Stage-1.1 definitions.
      expect(registry.findById('find_job')?.id, 'work_briefcase');
      expect(registry.findById('find_job')?.displayName, 'Find Job');
      expect(registry.findById('finance_pie_chart')?.id, 'finance_wallet');
      expect(registry.findById('finance_pie_chart')?.displayName, 'Pie Chart');
      // contains() accepts retired IDs so stored values stay valid.
      expect(registry.contains('find_job'), isTrue);
      expect(registry.contains('finance_pie_chart'), isTrue);
      // Aliases must never appear in the selectable manifest.
      expect(GoalIconRegistry.approvedIconIds, isNot(contains('find_job')));
      expect(
        GoalIconRegistry.approvedIconIds,
        isNot(contains('finance_pie_chart')),
      );
      expect(GoalIconRegistry.allIcons.any((d) => d.id == 'find_job'), isFalse);
      expect(
        GoalIconRegistry.allIcons.any((d) => d.id == 'finance_pie_chart'),
        isFalse,
      );
      // Alias assets are not registered; canonical assets remain.
      expect(
        GoalIconRegistry.allIcons.any(
          (d) => d.assetPath.endsWith('find_job.svg'),
        ),
        isFalse,
      );
      expect(
        GoalIconRegistry.allIcons.any(
          (d) => d.assetPath.endsWith('finance_pie_chart.svg'),
        ),
        isFalse,
      );
      // Unknown/null still use the safe fallback; social_two_people unchanged.
      expect(registry.findById('not-an-icon'), isNull);
      expect(registry.findById('social_two_people'), isNull);
      expect(registry.contains('social_two_people'), isFalse);
    },
  );

  test('social_two_people is NOT selectable in Stage 1.1 but stays a stored '
      'string-safe unknown ID', () {
    expect(registry.findById('social_two_people'), isNull);
    expect(registry.contains('social_two_people'), isFalse);
    expect(
      GoalIconRegistry.approvedIconIds,
      isNot(contains('social_two_people')),
    );
    expect(
      GoalIconRegistry.allIcons.any(
        (definition) => definition.assetPath.endsWith('social_two_people.svg'),
      ),
      isFalse,
    );
  });

  test('the 41 registered SVGs match the locked Stage-1.1 source hashes '
      'exactly', () {
    const expected = <String, String>{
      'work_briefcase.svg':
          '625d7a0a5a796af94260cda956ce08b268616949a06fed85111482020646d7dc',
      'finance_wallet.svg':
          'd27080e1e92aabc3cf34afe6ee078a6cebad58af0adc60e15f41295ed51d4412',
      'career_growth.svg':
          '57902542bf0a256ba4d662c3d00d48782c1681526df27ef4798661d7dde8762e',
      'document_check.svg':
          'd8dec947ac517e86dc389171b7ec3017710fd61fb235a1985026eb4405c0ff7d',
      'handshake.svg':
          '88bf6fd49972981ab5b45747769746786ff22c829046db26aa152cc8bf9e976d',
      'id_badge.svg':
          'a83a6f7fa5f2cd316c5b472c79156e6188dce457186518c35dba42ebe3b3d63a',
      'office_building.svg':
          'bc803c7e73db0181d3413f9e111430329c3662508e4929db7e3913ad2e6969c9',
      'resume.svg':
          '2e7aa806a5a3b4be09067311b743d283e6d6c2a359356fecd8ebaa203158b3ee',
      'stacked_coins.svg':
          '28f6b1e2b1f964c28e15fcd8d0b504987b0de6b3ba9872d6f5fdfa3ad0485be5',
      'airplane.svg':
          '2e7300fd4b52ded619eb744affa241c5c13cc36f3cc7b994965d0f48168fb0ff',
      'map_pin.svg':
          '72e8a4f40a44bb245a6e44c652c470ebfd011908239f793cf3ea9ec16ed871bc',
      'suitcase.svg':
          'd79c859188b517d9c99ee14ff529a550185b0c3b37c4f50af1ba94537850e286',
      'baby.svg':
          '659b2299e8417eb8419461bc08533ed0903af179b5b5d52d2029b94ce03ac38b',
      'brain.svg':
          'f6c956cd29a95c345d921358210b506fab929072c50e8b547185d24881e257d7',
      'calendar_date.svg':
          '6e8f585136fea2da3655ff104e55dd6ee8bd9bdf5152dce42d19dcd123d3851b',
      'checklist.svg':
          'e364ba0664c46eeedb530827a779f5ca7a68c7326048371a0696b67911a0eb2c',
      'church.svg':
          '9524343c557d9f6a4737bb70f546b63b323a6c1ffb28f8816f509a66fbfd2381',
      'commitment.svg':
          'db7191ecf0cdbedc7fdc26a6441675a5d6e5c16f00843e9b506a7f02769a51eb',
      'commitment_101.svg':
          '9d0e037d370a9b607b2efed4140457e24f93ce7da5a3f7bb42db35cd065c7386',
      'dating.svg':
          '2b2dc4b620afca8727a0d5756667de4bcb196206759304cba77b031c29e2cfa3',
      'elders.svg':
          'b7c89b1ebf4d4684767da274fd91da53333c59c79e20dc761ee0884e97921f1e',
      'engagement_ring.svg':
          '98a562064a11547ffa839a88b82ad8602ede87ae0ff44ed2b4fd4d3986b06d29',
      'fire.svg':
          '0ef4ac6adc429865ec6eb05313a014d1fccc37282bfb52606f8ae3034715ef4b',
      'habit.svg':
          '073690c66c8ecae88ae310553b6de011c8d6549c3410a85ceb04c572ba53a25a',
      'heartbeat.svg':
          '0eb6fe8b1ecc09a7bab7679ce1f8fc1b86651a3eb741543fa551c94b971a5644',
      'idea.svg':
          '527854096a0fbf51155577bed8a9a95b67e8fcab150b73e0dc185748fec7dc49',
      'jogging.svg':
          '3256fedad6f867e470fb5f64fa8048a1a26bf02291cc8f7a96760438856897a2',
      'learning_101.svg':
          '8d42389ba8498db4e3f89d0abd5d01424e98a1cf005fff8149ac1f18971ba5ef',
      'learning_open_book.svg':
          'bfcf237de7ada5f857a25d1be51b4b3b3397461a0cffc079161bf4d1551d745f',
      'marriage_rings.svg':
          'ed4d7ff177729bf7d25049553563805179135ee90c9f986bb08c96b20b1ca3fa',
      'notes.svg':
          '8e41d180319262bc6f93f417e9cb09563c316df2a169ac670a5f70f09203af16',
      'prayer.svg':
          '121f5023c77768affa5f16c7277f951b4809226220f14da383cf148a4e0d52ae',
      'shield.svg':
          '6abd6798aaff50fdbc0869db67b0d3c29c0b065765e882b36f463bd209d7dcee',
      'sisters.svg':
          '686f18d464f67ed7aad81cf252ac3ac4479dc44cf2c1a8570d3a603f8fcd605c',
      'social_dating.svg':
          '97332e4cc054867627acbf84498ef0829e1981da447fb0edd5fc3e5e4887a38f',
      'spiritual_temple.svg':
          '0d8921e45c99f385e81608a79fc3ce901c71ed6f7b9ff324e3874502ff34e240',
      'target_arrow.svg':
          '70a4378f046161aaf716cebc04d71e191fd2b750b19126868ae044940becc2ce',
      'temple_marriage.svg':
          'fe28ac35f3ce864d4d17664190f9973a42a08a3edd0a52ed03fbb79c5ad079db',
      'wedding.svg':
          'e97e6936cfbb075e3dba7ae843750a6985febc9ae8dca24c73c419c34ed8cbaf',
      'weight.svg':
          '4ec1f9803be0643d251eee6de92e6652736aab2bb2cf239ce81d10fb1d33b1d1',
      'yoga.svg':
          '732392777fbe4539b38a449998b9ce2ddeb6c6b01eb4e0e79929d166dadff022',
    };

    expect(expected.length, GoalIconRegistry.allIcons.length);
    for (final definition in GoalIconRegistry.allIcons) {
      final file = File(definition.assetPath);
      expect(file.existsSync(), isTrue, reason: definition.assetPath);
      final source = file.readAsBytesSync();
      // The lock asserts the canonical SVG TEXT, never a checkout's line
      // endings. A Windows working tree (core.autocrlf=true) materialises these
      // assets with CRLF while the identical git blob is LF, so hashing the raw
      // working-tree bytes failed here on content that is byte-identical to the
      // lock. Normalising to LF compares the same canonical bytes on every
      // platform and keeps the lock exact (a real content edit still fails).
      final canonicalBytes = String.fromCharCodes(
        source,
      ).replaceAll('\r\n', '\n').codeUnits;
      expect(
        sha256.convert(canonicalBytes).toString(),
        expected[definition.assetPath.split('/').last],
        reason: definition.assetPath,
      );
      expect(
        GoalIconRegistry.validateSvg(String.fromCharCodes(source)),
        isEmpty,
        reason: definition.assetPath,
      );
    }
  });

  test('every registered SVG has a transparent canvas (no baked backdrop)', () {
    for (final definition in GoalIconRegistry.allIcons) {
      final file = File(definition.assetPath);
      final source = String.fromCharCodes(file.readAsBytesSync());
      expect(
        hasFullCanvasWhiteBackdrop(source),
        isFalse,
        reason:
            '${definition.assetPath} must have no full-canvas baked '
            'background (Stage-1.1 theme principle)',
      );
    }
    // The helper itself must detect a synthetic full-canvas white backdrop.
    const synthetic = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1095 1095">
  <path d="M0.25 0.25 L1094.75 0.25 L1094.75 1094.75 L0.25 1094.75 Z"
        fill="#fefefe" fill-rule="evenodd"/>
  <path d="M500 500 L600 500 L550 600 Z" fill="#5bb0cd"/>
</svg>
''';
    expect(hasFullCanvasWhiteBackdrop(synthetic), isTrue);
  });

  test('retired old mockup visual hashes are absent from the registry', () {
    const retiredHashes = <String>{
      // Old learning open book / temple / rings / two people mockups.
      '0775dbc2446f28d47d03d99de4e8b47b17bad6c1b0d4cb2729633521de28256a',
      'ba24daffe284874e7dada3bf3579ed58554499b9b36979ca6f85688e2b9f9eae',
      '3630690e5a215bfb36f0af63e831c35dff672d0f85066c822f093fea7cf94ff3',
      'ac9e58f8a481781dcf0c0e65c399010158ae181ec39d0e52751f467e5f562f69',
    };
    for (final definition in GoalIconRegistry.allIcons) {
      final file = File(definition.assetPath);
      final hash = sha256.convert(file.readAsBytesSync()).toString();
      expect(
        retiredHashes,
        isNot(contains(hash)),
        reason:
            '${definition.assetPath} must use the approved Stage-1.1 visual',
      );
    }
  });

  test('registry validation rejects duplicate, missing, and blank metadata', () {
    final duplicate = <GoalIconDefinition>[
      ...GoalIconRegistry.allIcons,
      GoalIconRegistry.allIcons.first,
    ];
    expect(
      registry.validate(definitions: duplicate),
      contains('Duplicate icon ID: work_briefcase'),
    );

    expect(
      registry.validate(
        availableAssetPaths: GoalIconRegistry.allIcons
            .skip(1)
            .map((definition) => definition.assetPath),
      ),
      contains(
        'Missing registered asset: ${GoalIconRegistry.allIcons.first.assetPath}',
      ),
    );

    final first = GoalIconRegistry.allIcons.first;
    final blankSemantics = <GoalIconDefinition>[
      GoalIconDefinition(
        id: first.id,
        displayName: first.displayName,
        category: first.category,
        keywords: first.keywords,
        assetPath: first.assetPath,
        semanticsLabel: '',
      ),
      ...GoalIconRegistry.allIcons.skip(1),
    ];
    expect(
      registry.validate(definitions: blankSemantics),
      contains('Icon metadata contains a blank required field.'),
    );
  });

  test('SVG validation rejects executable and external content', () {
    const unsafe = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">
  <script>window.alert('unsafe')</script>
  <image href="https://example.invalid/icon.png" />
</svg>
''';
    final errors = GoalIconRegistry.validateSvg(unsafe);
    expect(errors, contains('SVG contains forbidden content: <script'));
    expect(errors, contains('SVG contains forbidden content: <image'));
    expect(errors, contains('SVG contains forbidden content: href='));
  });

  test('SVG validation rejects a full-canvas baked white backdrop', () {
    const bakedRect = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1095 1095">
  <rect x="0" y="0" width="1095" height="1095" fill="#fefefe"/>
  <path d="M500 500 L600 500 L550 600 Z" fill="#5bb0cd"/>
</svg>
''';
    expect(
      GoalIconRegistry.validateSvg(bakedRect),
      contains('SVG contains a baked full-canvas background.'),
    );

    const bakedPath = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1095 1095">
  <path d="M0 0 L1095 0 L1095 1095 L0 1095 Z"
        fill="#ffffff" fill-rule="evenodd"/>
  <path d="M500 500 L600 500 L550 600 Z" fill="#e3a853"/>
</svg>
''';
    expect(
      GoalIconRegistry.validateSvg(bakedPath),
      contains('SVG contains a baked full-canvas background.'),
    );

    // Small intentional light artwork must stay accepted.
    const smallLightDetail = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1095 1095">
  <path d="M500 500 L520 500 L510 520 Z" fill="#fefefe"/>
  <path d="M200 200 L400 200 L300 400 Z" fill="#5bb0cd"/>
</svg>
''';
    expect(GoalIconRegistry.validateSvg(smallLightDetail), isEmpty);
  });

  test('SVG validation rejects malformed XML and missing viewBox', () {
    const malformed = '''
<svg xmlns="http://www.w3.org/2000/svg">
  <path d="M1 1" />
''';
    final errors = GoalIconRegistry.validateSvg(malformed);
    expect(errors, contains('SVG XML parse failed.'));

    const noViewBox = '''
<svg xmlns="http://www.w3.org/2000/svg">
  <path d="M1 1" />
</svg>
''';
    final noViewBoxErrors = GoalIconRegistry.validateSvg(noViewBox);
    expect(noViewBoxErrors, contains('SVG viewBox is missing or invalid.'));

    const zeroViewBox = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 0 24">
  <path d="M1 1" />
</svg>
''';
    final zeroViewBoxErrors = GoalIconRegistry.validateSvg(zeroViewBox);
    expect(zeroViewBoxErrors, contains('SVG viewBox is missing or invalid.'));
  });

  test('expanded family SVGs pass the Stage-1.1 validator (mixed viewBox, '
      'teal/gold native colors)', () {
    const valid1095 = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1095 1095"
     width="1095" height="1095">
  <path d="M10 10 L20 20" fill="#5bb0cd" stroke="#5bb0cd"/>
  <path d="M5 5 L15 15" fill="#eaa647" stroke="#eaa647"/>
</svg>
''';
    expect(GoalIconRegistry.validateSvg(valid1095), isEmpty);

    const valid1342 = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1342 894"
     width="1342" height="894">
  <path d="M10 10 L20 20" fill="#5bafd0" stroke="#5bafd0"/>
  <path d="M5 5 L15 15" fill="#eaa647" stroke="#eaa647"/>
</svg>
''';
    expect(GoalIconRegistry.validateSvg(valid1342), isEmpty);
  });

  test('lookup and search cover display, semantics, categories, keywords, and '
      'legacy aliases', () {
    expect(registry.findById('learning_open_book')?.displayName, 'Learning');
    expect(registry.findById(null), isNull);
    expect(registry.findById('not-a-stage1-icon'), isNull);
    expect(registry.findById('social_two_people'), isNull);
    // 'study' unambiguously resolves to Learning (Learning 101 also
    // matches but comes later in registry order).
    expect(registry.search('study').first.id, 'learning_open_book');
    expect(
      registry.search('LEARNING AND STUDY').first.id,
      'learning_open_book',
    );
    expect(registry.search('money-budgeting').first.id, 'finance_wallet');
    // 'application' matches Find Job and Document Check; registry order
    // keeps work_briefcase (Find Job) first.
    final applicationHits = registry.search('APPLICATION');
    expect(applicationHits.first.id, 'work_briefcase');
    expect(applicationHits.map((d) => d.id), contains('resume'));
    expect(registry.search('resume').single.id, 'resume');
    // 'job search' resolves to the canonical Find Job entry.
    expect(registry.search('job search').first.id, 'work_briefcase');
    // 'temple' matches both Temple and Temple Marriage.
    final templeHits = registry.search('temple');
    expect(templeHits.map((d) => d.id), contains('spiritual_temple'));
    expect(templeHits.map((d) => d.id), contains('temple_marriage'));
    // 'marriage rings' matches both Rings and Engagement Ring.
    final ringsHits = registry.search('marriage rings');
    expect(ringsHits.map((d) => d.id), contains('marriage_rings'));
    expect(ringsHits.map((d) => d.id), contains('engagement_ring'));
    expect(registry.search('prayer').single.id, 'prayer');
    expect(registry.search('not-a-real-icon'), isEmpty);
    expect(
      registry.search('').map((definition) => definition.id),
      GoalIconRegistry.approvedIconIds,
    );
    expect(
      GoalIconRegistry.allIcons,
      hasLength(41),
      reason: 'Stage-1.1 manifest must expose exactly 41 selectable icons',
    );
  });

  test('suggestions are local, whole-word, deterministic, capped at three, and '
      'never return retired aliases', () {
    final examples = <String, String>{
      'Scripture Study': 'learning_open_book',
      // Retired 'find_job' keywords now live on the canonical Find Job entry.
      'Apply for Jobs': 'work_briefcase',
      'Monthly Budget': 'finance_wallet',
      'Career Growth Plan': 'career_growth',
      'Temple Worship': 'spiritual_temple',
      'Marriage Partnership': 'marriage_rings',
      'Write My Resume': 'resume',
    };
    for (final entry in examples.entries) {
      expect(
        registry.suggestForGoalTitle(entry.key)?.iconId,
        entry.value,
        reason: entry.key,
      );
    }
    expect(registry.suggestForGoalTitle('Unrelated Gardening'), isNull);
    expect(registry.suggestForGoalTitle('bookkeeper'), isNull);
    expect(registry.suggestForGoalTitle('budgeting'), isNull);
    expect(registry.suggestionsForGoalTitle(''), isEmpty);
    // social_two_people is not selectable: no suggestion returns it.
    for (final suggestion in registry.suggestionsForGoalTitle(
      'Meet New Friends',
    )) {
      expect(suggestion.iconId, isNot('social_two_people'));
    }
    // Retired aliases are never suggested.
    for (final suggestion in registry.suggestionsForGoalTitle('job search')) {
      expect(suggestion.iconId, isNot('find_job'));
    }
    for (final suggestion in registry.suggestionsForGoalTitle('budget chart')) {
      expect(suggestion.iconId, isNot('finance_pie_chart'));
    }
    final careerStudy = registry.suggestionsForGoalTitle('career study');
    expect(careerStudy.first.iconId, 'work_briefcase');
    expect(careerStudy, hasLength(3));
  });

  test('displayCategoryLabel maps the six internal categories to the exact '
      'Stage-1.2 labels with stable counts', () {
    expect(
      GoalIconRegistry.displayCategoryLabel('Work & Learning'),
      'Career & Learning',
    );
    expect(
      GoalIconRegistry.displayCategoryLabel('Money & Home'),
      'Finance & Home',
    );
    expect(
      GoalIconRegistry.displayCategoryLabel('Health & Daily Life'),
      'Health',
    );
    expect(
      GoalIconRegistry.displayCategoryLabel('People & Relationships'),
      'Social',
    );
    expect(
      GoalIconRegistry.displayCategoryLabel('Faith & Service'),
      'Spiritual',
    );
    expect(
      GoalIconRegistry.displayCategoryLabel('Travel & Interests'),
      'Travel',
    );
    // Display-only mapping: unknown internal values pass through unchanged.
    expect(GoalIconRegistry.displayCategoryLabel('Unknown'), 'Unknown');
    // The mapping covers every registered category with the exact counts.
    expect(GoalIconRegistry.categoryDisplayLabels, hasLength(6));
    final counts = <String, int>{};
    for (final definition in GoalIconRegistry.allIcons) {
      counts.update(
        GoalIconRegistry.displayCategoryLabel(definition.category),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    expect(counts['Career & Learning'], 10);
    expect(counts['Finance & Home'], 2);
    expect(counts['Health'], 9);
    expect(counts['Social'], 6);
    expect(counts['Spiritual'], 11);
    expect(counts['Travel'], 3);
  });

  test(
    'SVG validation rejects class/style-only assets (Stage-1.2 hardening)',
    () {
      // The exact Stacked-Coins blank-icon failure class: styling only via CSS
      // classes in a <style> block, with no inline stroke/fill on drawables.
      const classOnly = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" fill="none">
  <defs>
    <style>
      .blue { stroke:#62B0CC; stroke-width:14; stroke-linecap:round; stroke-linejoin:round; }
    </style>
  </defs>
  <ellipse class="blue" cx="260" cy="138" rx="118" ry="54"/>
  <path class="blue" d="M142 138V302"/>
</svg>
''';
      final errors = GoalIconRegistry.validateSvg(classOnly);
      expect(errors, contains('SVG contains forbidden element: style.'));
      expect(
        errors,
        contains(
          'SVG drawable relies on class-only styling without an inline '
          'stroke or fill.',
        ),
      );
      // An inline-stroke equivalent of the fixed Stacked Coins must pass.
      const inlineFixed = '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" fill="none">
  <ellipse cx="260" cy="138" rx="118" ry="54"
           stroke="#62B0CC" stroke-width="14"
           stroke-linecap="round" stroke-linejoin="round"/>
  <path d="M142 138V302" stroke="#DFA34A" stroke-width="14"
        stroke-linecap="round" stroke-linejoin="round"/>
</svg>
''';
      expect(GoalIconRegistry.validateSvg(inlineFixed), isEmpty);
    },
  );

  test('every registered SVG uses inline drawable styling (no <style> or '
      'class-only drawables) — Stage-1.2 blank-icon regression guard', () {
    for (final definition in GoalIconRegistry.allIcons) {
      final source = String.fromCharCodes(
        File(definition.assetPath).readAsBytesSync(),
      );
      expect(
        source.contains('<style'),
        isFalse,
        reason: '${definition.assetPath} must not rely on <style> CSS',
      );
      final document = xml.XmlDocument.parse(source);
      for (final element in document.descendantElements) {
        final name = element.localName.toLowerCase();
        if (!const <String>{
          'path',
          'ellipse',
          'rect',
          'circle',
          'line',
          'polyline',
          'polygon',
        }.contains(name)) {
          continue;
        }
        final hasClass = element.getAttribute('class') != null;
        final hasStroke = element.getAttribute('stroke') != null;
        final hasFill = element.getAttribute('fill') != null;
        expect(
          hasClass && !hasStroke && !hasFill,
          isFalse,
          reason:
              '${definition.assetPath} drawable <$name> must not rely '
              'only on class styling',
        );
      }
    }
  });
}
