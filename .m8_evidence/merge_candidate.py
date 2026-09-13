"""Merge one refreshed suite into the salvaged full-suite candidate stream.

The cancelled/complete `.m8_candidate.json` run is structurally complete
(297/297 suites, 2618/2618 testDone, `done` event), so its records are kept.
Only the suite whose TEST FIXTURE was corrected afterwards is replaced by a
fresh run of that single suite, captured with the identical Flutter SDK,
environment, JSON reporter and normalization law.

Refreshed event IDs are remapped into a disjoint namespace so the merged
stream stays unambiguous.
"""
import json
import sys

OFFSET = 10_000_000


def read_events(path):
    out = []
    bad = 0
    with open(path, encoding='utf-8', errors='replace') as f:
        for line in f:
            line = line.strip()
            if not line.startswith('{'):
                continue
            try:
                out.append(json.loads(line))
            except Exception:
                bad += 1
    return out, bad


def suite_id_of(ev):
    s = ev.get('suite')
    return s.get('id') if isinstance(s, dict) else None


def test_suite_map(events):
    m = {}
    for ev in events:
        if ev.get('type') == 'testStart':
            t = ev.get('test') or {}
            if t.get('id') is not None:
                m[t['id']] = t.get('suiteID')
    return m


def remap(events, sid):
    """Offset every id in a single-suite stream into a disjoint namespace.

    Run-level bookkeeping (start/allSuites/done) of the single-file capture is
    dropped: the merged stream keeps the original full-run equivalents.
    """
    smap = {sid: OFFSET + sid}
    gmap = {}
    tmap = {}
    for ev in events:
        t = ev.get('type')
        if t == 'group':
            gid = (ev.get('group') or {}).get('id')
            if gid is not None:
                gmap[gid] = OFFSET + 5_000_000 + gid
        elif t == 'testStart':
            tid = (ev.get('test') or {}).get('id')
            if tid is not None:
                tmap[tid] = OFFSET + 1_000_000 + tid

    kept = []
    for ev in events:
        t = ev.get('type')
        if t in ('start', 'allSuites', 'done'):
            continue
        if t == 'suite':
            s = ev.get('suite') or {}
            if s.get('id') in smap:
                s['id'] = smap[s['id']]
        elif t == 'group':
            g = ev.get('group') or {}
            if g.get('id') in gmap:
                g['id'] = gmap[g['id']]
            if g.get('parentID') is not None:
                g['parentID'] = gmap.get(g['parentID'], g['parentID'])
            if g.get('suiteID') in smap:
                g['suiteID'] = smap[g['suiteID']]
        elif t == 'testStart':
            tt = ev.get('test') or {}
            if tt.get('id') in tmap:
                tt['id'] = tmap[tt['id']]
            if tt.get('suiteID') in smap:
                tt['suiteID'] = smap[tt['suiteID']]
            tt['groupIDs'] = [gmap.get(x, x) for x in (tt.get('groupIDs') or [])]
        elif t in ('testDone', 'error', 'print'):
            if ev.get('testID') in tmap:
                ev['testID'] = tmap[ev['testID']]
            if ev.get('groupID') is not None:
                ev['groupID'] = gmap.get(ev['groupID'], ev['groupID'])
        kept.append(ev)
    return kept


def main(main_path, refresh_path, out_path, drop_suite_rel):
    main_events, bad_main = read_events(main_path)
    refresh_events, bad_refresh = read_events(refresh_path)

    tmap = test_suite_map(main_events)

    def norm(p):
        p = (p or '').replace(chr(92), '/')
        i = p.rfind('/test/')
        return p[i + 6:] if i >= 0 else p

    drop_suite_ids = {
        suite_id_of(ev) for ev in main_events
        if ev.get('type') == 'suite' and norm((ev.get('suite') or {}).get('path')) == drop_suite_rel
    }
    if not drop_suite_ids:
        raise SystemExit('suite not found in main stream: %s' % drop_suite_rel)

    kept = []
    dropped = 0
    for ev in main_events:
        t = ev.get('type')
        sid = None
        if t == 'suite':
            sid = suite_id_of(ev)
        elif t == 'group':
            sid = (ev.get('group') or {}).get('suiteID')
        elif t in ('testDone', 'error', 'print'):
            sid = tmap.get(ev.get('testID'))
        elif t == 'testStart':
            sid = (ev.get('test') or {}).get('suiteID')
        if sid in drop_suite_ids:
            dropped += 1
            continue
        kept.append(ev)

    refresh_sid = None
    for ev in refresh_events:
        if ev.get('type') == 'suite':
            refresh_sid = suite_id_of(ev)
            break
    if refresh_sid is None:
        raise SystemExit('refresh stream has no suite event')
    refresh_rel = norm((next(e for e in refresh_events
                            if e.get('type') == 'suite')['suite']['path']))
    if refresh_rel != drop_suite_rel:
        raise SystemExit('refresh suite mismatch: %s vs %s' % (refresh_rel, drop_suite_rel))

    refreshed = remap(refresh_events, refresh_sid)
    merged = kept + refreshed

    with open(out_path, 'w', encoding='utf-8') as f:
        for ev in merged:
            f.write(json.dumps(ev, ensure_ascii=False) + '\n')

    suite_ids = [suite_id_of(e) for e in merged if e.get('type') == 'suite']
    print('main stream:       %d events (%d unparsable)' % (len(main_events), bad_main))
    print('refresh stream:    %d events (%d unparsable)' % (len(refresh_events), bad_refresh))
    print('dropped records:   %d from %s' % (dropped, drop_suite_rel))
    print('appended records:  %d' % len(refreshed))
    print('suite events:      %d (unique ids %d)' % (len(suite_ids), len(set(suite_ids))))
    print('merged stream:     %d events -> %s' % (len(merged), out_path))
    if len(suite_ids) != len(set(suite_ids)):
        raise SystemExit('duplicate suite ids in merged stream')


if __name__ == '__main__':
    main(*sys.argv[1:])
