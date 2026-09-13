"""VS16 M8 final differential.

Normalization law (unchanged from the accepted .m7_evidence/compare_full.py):
  repository-relative suite path (path after the last '/test/') + '::' + full
  visible test name.

Differences from compare_full.py, which is retained unchanged as the accepted
reference:
  * compares FULL OUTCOMES, so an accepted PASS -> candidate FAIL/ERROR (a
    regression compare_full.py structurally cannot see) is detected;
  * separates REGRESSIONS from resolved inherited failures;
  * consumes an explicit authorized-mapping file for renames/replacements;
  * verifies the candidate stream is structurally complete before judging it.
"""
import json
import sys
import collections

BS = chr(92)
SEVERITY = {'success': 0, 'skip': 1, 'failure': 2, 'error': 3}
BAD = ('failure', 'error', 'skip')


def norm(p):
    p = (p or '').replace(BS, '/')
    i = p.rfind('/test/')
    return p[i + 6:] if i >= 0 else p


def load_with_stats(path):
    suites = {}
    tests = {}
    outcomes = collections.OrderedDict()
    stats = collections.Counter()
    dup = collections.Counter()
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line.startswith('{'):
                if line:
                    stats['unparsable_lines'] += 1
                continue
            try:
                ev = json.loads(line)
            except Exception:
                stats['unparsable_lines'] += 1
                continue
            t = ev.get('type')
            stats['type:' + str(t)] += 1
            if t == 'allSuites':
                stats['allSuites_count'] = ev.get('count')
            elif t == 'suite':
                s = ev.get('suite', {})
                suites[s.get('id')] = norm(s.get('path'))
            elif t == 'testStart':
                tt = ev.get('test', {})
                tests[tt.get('id')] = (tt.get('name', ''), tt.get('suiteID'))
            elif t == 'testDone':
                stats['testDone_all'] += 1
                if ev.get('hidden'):
                    stats['testDone_hidden'] += 1
                    continue
                stats['testDone_visible'] += 1
                name, sid = tests.get(ev.get('testID'), (None, None))
                if name is None:
                    stats['testDone_unmatched'] += 1
                    continue
                if ev.get('skipped'):
                    out = 'skip'
                else:
                    res = ev.get('result')
                    out = res if res in SEVERITY else str(res)
                key = suites.get(sid, '?') + '::' + norm(name)
                dup[key] += 1
                prev = outcomes.get(key)
                if prev is None or SEVERITY.get(out, 9) > SEVERITY.get(prev, 9):
                    outcomes[key] = out
    stats['testStart'] = stats.get('type:testStart', 0)
    stats['suites'] = len(suites)
    stats['suite_paths'] = len({v for v in suites.values()})
    return outcomes, dup, stats


def main(base_path, cand_path, authorized_path=None):
    base, bdup, bstats = load_with_stats(base_path)
    cand, cdup, cstats = load_with_stats(cand_path)

    authorized = {}
    if authorized_path:
        with open(authorized_path, encoding='utf-8') as f:
            authorized = json.load(f)
    renamed = authorized.get('renamed_identities', {})
    replaced = authorized.get('replaced_identities', {})
    declared_resolved = authorized.get('resolved_inherited', {})

    def report(tag, path, outcomes, stats, dup):
        print('%s: %s' % (tag, path))
        print('  suite events=%d  distinct suite paths=%d  allSuites.count=%s' %
              (stats['suites'], stats['suite_paths'], stats.get('allSuites_count')))
        print('  testStart=%d  testDone(all)=%d  testDone(visible)=%d  hidden=%d  unmatched=%d  unparsable=%d' %
              (stats['testStart'], stats['testDone_all'], stats['testDone_visible'],
               stats['testDone_hidden'], stats['testDone_unmatched'],
               stats['unparsable_lines']))
        print('  identities=%d  suites=%d' %
              (len(outcomes), len({k.split('::', 1)[0] for k in outcomes})))
        c = collections.Counter(outcomes.values())
        for k in ('success', 'skip', 'failure', 'error'):
            if c[k]:
                print('    %-8s %d' % (k, c[k]))
        d = [k for k, n in dup.items() if n > 1]
        if d:
            print('  duplicate identities=%d' % len(d))

    report('BASELINE ', base_path, base, bstats, bdup)
    report('CANDIDATE', cand_path, cand, cstats, cdup)

    print()
    print('=== CANDIDATE STREAM STRUCTURAL CONSISTENCY ===')
    problems = []
    if cstats['unparsable_lines']:
        problems.append('unparsable lines present')
    if cstats['testStart'] != cstats['testDone_all']:
        problems.append('testStart != testDone')
    if cstats.get('allSuites_count') and cstats['suites'] != cstats['allSuites_count']:
        problems.append('suite events != allSuites.count')
    if cstats['suites'] != cstats['suite_paths']:
        problems.append('duplicate suite paths')
    if cstats['testDone_unmatched']:
        problems.append('testDone without testStart')
    print('  testStart == testDone(all):        %s' %
          ('YES' if cstats['testStart'] == cstats['testDone_all'] else 'NO'))
    print('  suite events == allSuites.count:   %s' %
          ('YES' if cstats.get('allSuites_count') == cstats['suites'] else 'NO'))
    print('  distinct suite paths == suites:    %s' %
          ('YES' if cstats['suites'] == cstats['suite_paths'] else 'NO'))
    print('  unparsable lines:                  %d' % cstats['unparsable_lines'])
    print('  STRUCTURAL VERDICT: %s' % ('COMPLETE' if not problems else 'INCOMPLETE: %s' % problems))

    base_ids = set(base)
    cand_ids = set(cand)

    new_bad = sorted(k for k in cand_ids if cand[k] in BAD and k not in base_ids)
    new_failures = [k for k in new_bad if cand[k] == 'failure']
    new_errors = [k for k in new_bad if cand[k] == 'error']
    new_skips = [k for k in new_bad if cand[k] == 'skip']

    regressions = []
    improvements = []
    kind_changes = []
    for k in sorted(base_ids & cand_ids):
        b, c = base[k], cand[k]
        if b == c:
            continue
        sb, sc = SEVERITY.get(b, 9), SEVERITY.get(c, 9)
        if sc > sb:
            regressions.append((k, b, c))
        elif sc < sb:
            improvements.append((k, b, c))
        else:
            kind_changes.append((k, b, c))

    missing = sorted(base_ids - cand_ids)
    authorized_missing = [k for k in missing if k in renamed or k in replaced]
    unauthorized_missing = [k for k in missing if k not in renamed and k not in replaced]

    declared = [k for k, _, _ in improvements if k in declared_resolved]
    undeclared = [(k, b, c) for k, b, c in improvements if k not in declared_resolved]

    print()
    print('=== FINAL DIFFERENTIAL ===')
    print('accepted baseline identities:        %d' % len(base_ids))
    print('candidate identities:                %d' % len(cand_ids))
    print('new failures:                        %d' % len(new_failures))
    print('new errors:                          %d' % len(new_errors))
    print('new skips:                           %d' % len(new_skips))
    print('missing accepted identities:         %d' % len(missing))
    print('  authorized (renamed/replaced):     %d' % len(authorized_missing))
    print('  unauthorized:                      %d' % len(unauthorized_missing))
    print('regressions (accepted -> worse):     %d' % len(regressions))
    print('resolved inherited (bad -> success): %d' % len(improvements))
    print('  declared with a reason:            %d' % len(declared))
    print('  undeclared:                        %d' % len(undeclared))
    print('same-severity outcome kind changes:  %d' % len(kind_changes))
    baseline_bad = {k for k, v in base.items() if v in BAD}
    cand_bad = {k for k, v in cand.items() if v in BAD}
    print('inherited bad (bad in both):         %d' % len(baseline_bad & cand_bad))

    def dump(title, rows, fmt):
        if not rows:
            return
        print()
        print(title)
        for r in rows:
            print('  ' + fmt(r))

    dump('NEW FAILURES', new_failures, lambda k: k)
    dump('NEW ERRORS', new_errors, lambda k: k)
    dump('NEW SKIPS', new_skips, lambda k: k)
    dump('REGRESSIONS', regressions,
         lambda r: '%-8s -> %-8s %s' % (r[1], r[2], r[0]))
    dump('UNAUTHORIZED MISSING ACCEPTED IDENTITIES', unauthorized_missing, lambda k: k)
    dump('AUTHORIZED MISSING ACCEPTED IDENTITIES', authorized_missing,
         lambda k: '%s\n            -> %s' % (
             k, renamed.get(k, replaced.get(k, {}).get('by'))))
    dump('UNRESOLVED OUTCOME KIND CHANGES', kind_changes,
         lambda r: '%-8s -> %-8s %s' % (r[1], r[2], r[0]))
    dump('RESOLVED INHERITED FAILURES (declared)', declared,
         lambda k: k)
    dump('RESOLVED INHERITED FAILURES (undeclared)', undeclared,
         lambda r: '%-8s -> %-8s %s' % (r[1], r[2], r[0]))

    new_suites = sorted({k.split('::', 1)[0] for k in cand_ids - base_ids})
    print()
    print('=== POST-BASELINE SUITES (present only in candidate): %d ===' % len(new_suites))
    bad_suites = 0
    for s in new_suites:
        keys = [k for k in cand_ids if k.startswith(s + '::')]
        bad = sorted(k for k in keys if cand[k] in BAD)
        if bad:
            bad_suites += 1
        print('  %-5s %3d tests  %s' % ('GREEN' if not bad else 'BAD', len(keys), s))
        for b in bad:
            print('        %-8s %s' % (cand[b], b.split('::', 1)[1]))
    print('post-baseline suites with bad outcomes: %d' % bad_suites)

    # post-baseline identities added to pre-existing suites must also be green
    new_ids = sorted(cand_ids - base_ids)
    new_ids_bad = [k for k in new_ids if cand[k] in BAD]
    print()
    print('post-baseline identities (new tests):  %d' % len(new_ids))
    print('  of which bad:                        %d' % len(new_ids_bad))
    for k in new_ids_bad:
        print('    %-8s %s' % (cand[k], k))

    verdict = (not problems and not new_failures and not new_errors and
               not new_skips and not unauthorized_missing and not regressions and
               not kind_changes and not undeclared and not bad_suites and
               not new_ids_bad)
    print()
    print('FINAL DIFFERENTIAL VERDICT: %s' % ('PASS' if verdict else 'FAIL'))
    return 0 if verdict else 1


if __name__ == '__main__':
    sys.exit(main(*sys.argv[1:]))
