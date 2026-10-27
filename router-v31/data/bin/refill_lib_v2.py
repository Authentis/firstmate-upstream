#!/usr/bin/env python3
"""Router v3 surface (pass 2, chief 4645-4661): roles, bans, bindings, quota schema.

  roles     build: free BINDINGS first (weighted rotation, a 429 benches one binding 30 min),
            then flat plans. manager (pass-5, chief): the router NEVER picks a manager model -
            route_pick('manager') only checks the configured rows against the bans and quota
            windows and returns a VERDICT ('OK'/WAIT with reasons); FM and the bosgame SM run
            Muse, the netcup SM runs Sonnet (the captain's choices, named in the row).
            plan / review / t3: named top models
            (hard roles, scarce pools always reachable). gate-step: fixer/test/lint/doc steps on
            Kimi (flat); Codex only for hard (T3) runs.
  reviewer  chosen by the WRITER family (route_reviewer / route-reviewer.sh), never by quota:
            OpenAI-built (codex, gpt-6.1-sol, gpt-5.6-sol) -> the literal off-host marker
            'muse-spark-1.3-contributor-via-firstmate'; Muse-built -> 'droid:gpt-6.1-sol';
            Claude-built -> 'droid-local:gpt-6.1-sol'. Every other writer family (Kimi, free,
            DeepSeek, unknown) still gets 'droid:gpt-6.1-sol' - never WAIT. Claude, free and Kimi
            are never reviewers, on live data most of all.
  bindings  one row per model+provider+harness ('cat-jam@opencode'), each with its own 429 bench
            entry and quota row; a weight field (default 1) paces rotation. Old model-keyed bench
            files still load: a model bench applies to ALL bindings of that model.
  bans      data rows ({role/family/billing/via/host/live_data/id_pattern..., hard: false}); a ban
            with hard: false applies to routine picks only; a scalar value prefixed with '!'
            negates that one condition (host: '!netcup' = every host except netcup).
            Always on: no free/Kimi on live data,
            no Muse on netcup, no Claude via Cline, no Haiku/K3; opencode-go/* (the paid Go plan,
            NOT the OpenCode free tier) is a routine-build/manager ban.
  quota     state/quota.json {'pools': {<pool or binding id>: {used_pct, reset_at, observed_at,
            source, manual}}}; stale (>6 h) or unknown = skip that pool. Manual readings (e.g. the
            opencode-go pool: monthly 30 d window) are labelled manual. See quota.json.example.

v2 (chief 4627): can_start() single start check, explicit live-data label. Old file kept beside it: refill_lib.py.
Pure steps of lane-refill (chief 1672: one clear flow, one small test per step; tests in test_refill.py, fixture tracker, no live calls).

  landed   <raw>                      main-commit and merged-PR text, minus planning/tracker commits that merely LIST leaf ids
  supply   <tracker> <msgs> <briefs> <closed-tracker> <live-paths> <t1-list>   -> candidates.json on stdout (the supply count is its length)
  pick     <candidates.json> <live-paths> <netcup-slots> <bosgame-sends>       -> lines 'netcup|bosgame <suf>'
  brief    <brief.md> <candidates.json> <suf>                                   fill a leaf brief
  bosgame-live <bosgame-lanes.tsv>                                             live bosgame leaf lanes (asks gh for finished branches)
  partition <used letters...>                                                  next free planning partition 'L|text'
  busy-partitions <home> <bosgame-snapshot.json> <open-branches-file>          letters held by any unfinished planning pass (chief 2692)
"""
import ast, copy, json, math, os, re, subprocess, sys, tempfile, time
from collections import Counter

import yaml

FM_DEFAULT_HOME = '/home/holu/fm-secondmate-upstream-20260907'


def _fm_home_path(*parts):
    """Resolve import-time state against FM_HOME; fm_path below adds escape checks."""
    return os.path.join(os.environ.get('FM_HOME', FM_DEFAULT_HOME), *parts)

SHARED = {'core/src/dos/contract/vocab.py', 'core/src/dos/models/judgment.py', 'core/src/dos/models/instruments.py'}  # SO-13: max 2 live lanes each
HELD = re.compile(r'10\.15\.1$|10\.15\.2\.3|10\.3\.2|11\.11\.6\.1|11\.2\.4\.1|11\.5\.1|11\.5\.2|11\.11\.4\.[45]$|12\.9\.2\.14$|12\.1\.20$|12\.3\.1\.12$|13\.7$|13\.8$|12\.17$|12\.19$|12\.8\.1\.10$')   # PR 2522 FAIL split: held until dos-file-2522-p209-spec-followup re-specs them
BAD = re.compile(r'DECISION NEEDED|needs-spec|DECISION \(product\)|Not a code task', re.I)
SKIP = re.compile(r'planning|split .*spec-ready|^tracker|tracker:|spec-ready|leaf supply|\.beads', re.I)
PARTS = [('A', 'product-v1 epics 9 and 10 only'), ('B', 'product-v1 epics 11.1 through 11.9 only'),   # chief 2656 (ref 2019): 11.10 and higher belong to bosgame
         ('C1', 'product-v1 epics 11.10 through 11.18 only'), ('C2', 'product-v1 epics 11.19 and higher only'), ('D', 'product-v1 epics 12, 13 and 14 and non-product program parents only')]   # chief 2669: C1/C2 both bosgame's
PFX = 'dos-product-v1-88cgo.'
HELD_FULL = re.compile('(?:' + HELD.pattern.replace('$', '') + ')')   # main 2294: anchored (unanchored '10\\.3\\.2' matched 11.10.3.20)
# chief 2522 (SO-19): leaves from a spec PR without an exact-head cross-family PASS stay out of supply; one full id per line
try:
    SPEC_HOLD = {l.strip() for l in open(_fm_home_path('data', 'spec-hold-ids.txt')) if l.strip()}
except OSError:
    SPEC_HOLD = set()
# chief 2298: leaf ids bosgame owns (its dispatchable list, one id or dotted suffix per line) are never started on netcup.
# chief 1547 (10-08): that static list is a RESERVATION, not proof of a live lane: its leaves stay in supply as bosgame_only (never a netcup
# start, but routed to bosgame by pick) instead of vanishing from both hosts. Sent (3 days) and bosgame-live ids below stay fully excluded.
try:
    BOSGAME_RESERVED = {x.strip() for x in open(_fm_home_path('data', 'bosgame-owned.txt')) if x.strip() and not x.startswith('#')}
except OSError:
    BOSGAME_RESERVED = set()
BOSGAME_OWNED = set()
# SM 10-08 (dup 12.8.18): leaves routed to bosgame in the last 3 days (data/bosgame-lanes.tsv 'sent' rows) are never started on netcup.
try:
    import time as _t
    BOSGAME_OWNED |= {r[1] for r in (l.rstrip('\n').split('\t') for l in open(_fm_home_path('data', 'bosgame-lanes.tsv')))
                      if len(r) > 2 and r[2] == 'sent' and r[0].isdigit() and _t.time() - int(r[0]) < 14400}
except OSError:
    pass
# chief 2643 (12.7.1.4 / 12.9.2.6 double routes): a send older than 4 h (up to 3 days) stays bosgame-owned unless bosgame's FRESH snapshot
# (< 20 min) lists no lane for it. Then it is reclaimable: lane-refill may start it on netcup, writes a 'not-started, reclaimed' row and tells
# bosgame's SM in the same pass. A stale or unreadable snapshot reclaims nothing. Backup: refill_lib.py.bak-20261009-2643
BOSGAME_RECLAIMABLE = set()
try:
    _sd = json.load(open(_fm_home_path('data', 'bosgame-snapshot.json')))
    _snap = {re.sub(r'^dos-bosgame-|-\d{4}$', '', str(l.get('lane', ''))) for l in _sd['lanes']} if 0 <= _t.time() - float(_sd['ts']) <= 1200 else None
except (OSError, ValueError, KeyError, TypeError):
    _snap = None
try:
    _old = {r[1] for r in (l.rstrip('\n').split('\t') for l in open(_fm_home_path('data', 'bosgame-lanes.tsv')))
            if len(r) > 2 and r[2] == 'sent' and r[0].isdigit() and 14400 <= _t.time() - int(r[0]) < 259200} - BOSGAME_OWNED
    for _i in _old:
        if _snap is not None and _i.replace(PFX, '').replace('.', '-') not in _snap and _i not in _snap:
            BOSGAME_RECLAIMABLE.add(_i)
        else:
            BOSGAME_OWNED.add(_i)
except OSError:
    pass
# chief 2393: leaves bosgame has LIVE lanes on (bosgame keeps data/bosgame-live.txt current; same format) are never started on netcup.
try:
    BOSGAME_OWNED |= {x.strip() for x in open(_fm_home_path('data', 'bosgame-live.txt')) if x.strip() and not x.startswith('#')}
except OSError:
    pass


def landed(raw):
    """What main and merged PRs say has landed (planning/tracker commits and PRs are skipped: they list new leaf ids without building them)."""
    commits, _, prs = raw.partition('@@PRS@@')
    keep = []
    for rec in commits.split('\x1e'):
        subj = rec.split('\x1f')[0]
        if subj.strip() and not SKIP.search(subj):
            keep.append(rec.replace('\x1f', '\n'))
    for rec in prs.split('\x1e'):
        parts = rec.split('\x1f')
        if len(parts) == 3 and not SKIP.search(parts[0] + ' ' + parts[1]):
            keep.append('\n'.join(parts))
    return '\n'.join(keep)


def _lst(v):
    if isinstance(v, list):
        return v
    try:
        return ast.literal_eval(v) if isinstance(v, str) else []
    except Exception:
        return []


def shared_ok(f):
    """Chief 1805 (captain SO-13): the dispatch overlap check counts SOURCE files only; tests, docs/README rows and the tracker may overlap."""
    return (f == 'core/README.md' or f.endswith('.md') or f.startswith('core/tests/') or '/tests/' in f
            or f.rsplit('/', 1)[-1].startswith('test_') or f.startswith('docs/') or f.startswith('.beads/'))


def blocked(f, livecount):
    return livecount[f] >= (2 if f in SHARED else 1)


def prior_attempts(leaf, brief_path):
    """main 2297/2304: a new lane is told when an earlier attempt at the same leaf exists (a dead or torn-down lane, or a closed PR)."""
    import glob, os
    home = os.environ.get('FM_HOME', FM_DEFAULT_HOME)
    me = os.path.basename(os.path.dirname(brief_path))
    tasks = []
    for b in glob.glob(home + '/data/dos-*/brief.md'):
        t = os.path.basename(os.path.dirname(b))
        if t == me:
            continue
        try:
            if re.search(r'(?<![\w.])' + re.escape(leaf) + r'(?![\w.]|\.\d)', open(b, errors='ignore').read()):
                tasks.append(t)
        except OSError:
            pass
    prs = []
    try:
        allp = json.load(open('/tmp/claude-1000/lane-refill/prs.json'))
        prs = sorted(n for n, st in ((p['n'], p['s']) for p in allp) if st == 'CLOSED' and n in
                     {p['n'] for p in allp if leaf in pr_links([p], [leaf])})
    except Exception:
        pass
    if not tasks and not prs:
        return ''
    out = '\n- PREVIOUS ATTEMPT(S) at this leaf exist and did not land; learn from them, do not repeat them blindly:'
    for t in sorted(tasks):
        out += f'\n  - lane {t}: brief and any report under {home}/data/{t}/; its branch may be archived on origin as archive/{t} or as fm/{t}'
    for n in prs:
        out += f'\n  - closed PR https://github.com/Authentis/decision-os/pull/{n} (read its review comments for why it did not land)'
    return out + '\n'


def _merged_after(merged_at, created_at):
    """True when the merge is newer than the child's creation; unknown or unparseable times answer True (block, never duplicate)."""
    try:
        from datetime import datetime
        m = datetime.fromisoformat(str(merged_at).replace('Z', '+00:00'))
        c = datetime.fromisoformat(str(created_at).replace('Z', '+00:00'))
        if m.tzinfo is None or c.tzinfo is None:
            return True
        return m > c
    except Exception:
        return True


def pr_links(prs, ids, detail=None):
    """main 2297: hard evidence only. A PR is linked to a leaf when its body names the full leaf id, or its head branch encodes the
    dotted suffix with dashes as a whole token (followed by -1NNN, -rN or the end), or its body says 'leaf <suffix>' exactly.
    Planning/tracker PRs (they list ids without building them) never link. Returns {id: set of PR states}. One pass per PR."""
    want = set(ids)
    full = re.compile(re.escape(PFX) + r'(\d+(?:\.\d+)*)(?![\w.]|\.\d)')
    leaf = re.compile(r'\bleaf\s+(\d+(?:\.\d+)+)(?![\d.]|\.\d)', re.I)
    brp = re.compile(r'(?<![\d])(\d+(?:-\d+)+?)(?=-1\d{3}\b|-r\d|$)')
    out, own, fixes = {}, {}, []
    for p in prs:
        br, body = p.get('b') or '', p.get('body') or ''
        if SKIP.search(br) or re.search(r'planning|respec|file-leaf', br, re.I):   # chief 2610: re-spec and leaf-filing lanes are tracker-only; their merge never lands the leaf
            continue
        fx = re.search(r'fix-pr(\d+)', br)
        if fx:                                   # a fix lane's PR supersedes PR <N>: it carries <N>'s leaf links (resolved below)
            fixes.append((int(fx.group(1)), p.get('s'), p.get('ma')))
        # SM netcup 10-12 (FM 3693/3696): a tracker PR's body lists ids it files, closes or edits (#2673 named 10.474, #2082 named
        # 10.9.3.3.13) without building them, so body links count only off tracker branches; a tracker branch still links the leaf
        # its own branch encodes (dos-tracker-10-475-note-...). Kill switch: REFILL_TRACKER_BODY_LINKS=1 restores body links.
        trk = bool(re.search(r'(?:^|/)dos-tracker-', br)) and os.environ.get('REFILL_TRACKER_BODY_LINKS') != '1'
        sufs = set() if trk else set(full.findall(body)) | set(leaf.findall(body))
        for m in re.finditer(r'(?<![\d])\d+(?:-\d+)*', br):
            tok, rest = m.group(0), br[m.end():]
            parts = tok.split('-')
            for k in range(1, len(parts) + 1):   # every prefix that is followed by the -1NNN/-rN tail or the end
                cand, tail = '-'.join(parts[:k]), '-' + '-'.join(parts[k:]) + rest if k < len(parts) else rest
                if re.match(r'(-(?:(?:dsgo|dsos|sonnet|haiku|opus|kimi)-)?1\d{3}\b|-r\d|$)', tail):   # chief 2648 #6: only the known tier tags   # SM 10-08 + chief 2610: any tier tag (-dsgo, -dsos, -sonnet, -haiku, -opus, -kimi) before -1NNN (dup 11.18.2.5; 10.278 retry loop)
                    sufs.add(cand.replace('-', '.'))
        # chief 1547 (10-08, dup p116-digest-archive vs open #1960): non-product-v1 ids (dos-p116-...-jh7fr) carry a unique slug, so a PR
        # links to one when its head branch or body names the whole id
        sufs |= {i for i in want if not i.startswith(PFX) and (i in br or (not trk and i in body))}
        own[p.get('n')] = sufs
        for suf in sufs:
            if not suf.startswith(PFX) and suf in want:
                out.setdefault(suf, set()).add(p.get('s'))
            i = PFX + suf
            if i in want:
                out.setdefault(i, set()).add(p.get('s'))
    if detail is not None:   # chief 4822: per-leaf (state, mergedAt) pairs so the ancestor rule can compare merge time with the child's creation
        for p in prs:
            for suf in own.get(p.get('n'), ()):
                i = suf if suf in want and not suf.startswith(PFX) else PFX + suf
                if i in want:
                    detail.setdefault(i, []).append((p.get('s'), p.get('ma')))
    for n, st, ma in fixes:
        for suf in own.get(n, ()):
            i = suf if suf in want and not suf.startswith(PFX) else PFX + suf
            if i in want:
                out.setdefault(i, set()).add(st)
                if detail is not None:   # Sol r6 #2: an inherited fix-PR link needs a detail entry or the ancestor rule never sees it
                    detail.setdefault(i, []).append((st, ma))
    return out


T1_FOCUS_OFF = _fm_home_path('data', 't1-focus.off')
PLAN_BUSY_OFF = _fm_home_path('data', 'plan-busy.off')   # chief 212832: own switch for the held-pass busy rule (FM 3244/3248)


P2_EXCEPTION_ON = _fm_home_path('data', 'p2-refill-exception.on')
P2_EXCEPTION_OFF = _fm_home_path('data', 'p2-refill-exception.off')
P2_EXCEPTION_UNTIL = 1792310400  # 2026-10-18T08:00Z; chief SO18 temporary exception


def p2_exception_enabled(now=None):
    return ((time.time() if now is None else now) < P2_EXCEPTION_UNTIL
            and os.path.exists(P2_EXCEPTION_ON) and not os.path.exists(P2_EXCEPTION_OFF))


def product_phase(title):
    match = re.match(r'^\s*\[?P([235])(?:[.\s\]-]|$)', title or '')
    return int(match[1]) if match else None


def p2_fixture_only(row, labels):
    text = '\n'.join((row.get('title') or '', ' '.join(labels),
                      row.get('description') or '', row.get('acceptance_criteria') or ''))
    # Only explicit negative lists are masked. In particular, "no-op" must
    # never hide a later positive requirement to read the real book.
    nouns = (r'(?:book|DB|database|network|credentials?|secrets?|tokens?|DSN|'
             r'store|data|models?|Claude|private exports?|production endpoints?|'
             r'remote writes?|migrations?|deploys?|cash|mandate|trim)')
    item = r'(?:(?:new|real|live|private|provider)\s+)*' + nouns
    negative_list = r'\b(?:no|never|without)\s+' + item + r'(?:(?:\s*[,/]\s*|\s+(?:or|and)\s+)' + item + r')*'
    positive = re.sub(r'(?im)\bOUT OF SCOPE(?: RECHECK)?:[^.\n]*(?:\.|$)', ' ', text)
    positive = re.sub(negative_list, ' ', positive, flags=re.I)
    # A named existing review citation is evidence, not a fetch requirement.
    # Other URL contexts (including an instruction to fetch that same URL)
    # remain refused by the HTTP match below.
    positive = re.sub(r'Existing follow-up from https://github\.com/Authentis/decision-os/pull/\d+\b', ' ', positive)
    forbidden = (r'\b(?:book|DB|database|postgres\w*|psql|sqlite|network|https?|api|'
                 r'remote|credential\w*|secret\w*|token|DSN|migrat\w*|deploy\w*|br|push|post|endpoint)\b|'
                 r'production[ -]endpoint|DOS_CORE_PG_DSN|core\.env|EODHD_API_KEY')
    return ({'free-ok', 'spec-ready'} <= set(labels)
            and not {'netcup', 'not-free', 'requires-live', 'gate-operator'} & set(labels)
            and bool(re.search(r'fixture|synthetic', text, re.I))
            and not re.search(forbidden, positive, re.I)
            and not live_match((row.get('description') or '') + ' ' + (row.get('title') or '') + ' ' + ' '.join(labels)))


def supply(rows, msgs, briefs, closed_local, livecount, t1, prs=None):
    """Open, unassigned, spec-ready, unblocked leaves not already landed or in a lane, ordered T1 closure first, then priority (the supply is the list length)."""
    parents, dependents = set(), {}
    for r in rows.values():
        for d in _lst(r.get('dependencies')):
            if d.get('type') == 'parent-child':
                parents.add(d['depends_on_id'])
            if d.get('type') == 'blocks':
                dependents[d['depends_on_id']] = dependents.get(d['depends_on_id'], 0) + 1
    out = []
    pr_detail = {}
    # all rows, not only open ones: a CLOSED ancestor can still carry an OPEN or newer-MERGED PR that must block an open child (Sol r4 #1);
    # candidates are still filtered to open rows below
    links = pr_links(prs, list(rows), pr_detail) if prs is not None else {}
    for i, r in rows.items():
        if r.get('status') != 'open' or (r.get('assignee') or '').strip():
            continue
        labels = _lst(r.get('labels'))
        if {'needs-spec', 'decision'} & set(labels) or i in parents or HELD_FULL.fullmatch(i.replace(PFX, '')) or i in SPEC_HOLD:   # chief 2522: SPEC_HOLD
            continue
        if i in BOSGAME_OWNED or i.replace(PFX, '') in BOSGAME_OWNED:
            continue
        desc = r.get('description') or ''
        if 'FILES:' not in desc or BAD.search(desc):
            continue
        blockers = [d['depends_on_id'] for d in _lst(r.get('dependencies')) if d.get('type') == 'blocks']
        if any(rows.get(b, {}).get('status') not in ('closed', 'tombstone') for b in blockers):
            continue
        suf = i.replace(PFX, '')
        # chief 4536/4538 (step-4 rule, captain 03:3x 2026-10-17): T1 work is ONLY the verticals listed in data/t1-allowed-verticals.txt (now V9 759, V11 761,
        # V1 751, V2 752) and rows parent-child under them; every other T1 row, and every other vertical's rows (V3 nightly timer NOT enabled), stays
        # unclaimable even when ready. Kill switch: env T1_VI_FILTER=0
        if os.environ.get('T1_VI_FILTER', '1') != '0':
            _af = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 't1-allowed-verticals.txt')
            _allow = {l.strip() for l in open(_af) if l.strip()} if os.path.exists(_af) else set()
            _par = {d['depends_on_id'] for d in _lst(r.get('dependencies')) if d.get('type') == 'parent-child'}
            _in_vi = 'vertical-integration' in labels or any('vertical-integration' in _lst(rows.get(x, {}).get('labels')) for x in _par)
            if ((t1 and suf in t1) or _in_vi) and i not in _allow and not (_par & _allow):
                continue
        # chief 183037 (captain 18:4x "Refocus Sextant on T1: yes"): no new P2/P3/P5 leaf starts outside the T1 closure (t1-priority.txt);
        # P0/P1 and T1 leaves still start, in-flight work is untouched. Active only with a non-empty T1 list. Kill switch: data/t1-focus.off
        exception_admission = False
        if t1 and suf not in t1 and int(r.get('priority') or 9) in (2, 3, 5) and not os.path.exists(T1_FOCUS_OFF):
            # Add admissions only: off/expired/unknown-T1 restores old supply.
            if not (p2_exception_enabled() and product_phase(r.get('title')) == 2
                    and p2_fixture_only(r, labels)):
                continue
            exception_admission = True
        if prs is None:   # legacy text rules (kept for callers without PR data)
            if i in msgs or re.search(r'(?<![\d.])' + re.escape(suf) + r'(?![\d.])', msgs):
                continue
            if i in briefs or i in closed_local:
                continue
        else:             # main 2297: landed = closed row or a MERGED linked PR; in work = a live lane brief or an OPEN linked PR
            st = set(links.get(i, set()))
            # chief 4819/4822: a child leaf (10.759.1) is the same work as its dotted ancestor (10.759, two or more components) while that ancestor
            # has an OPEN PR, or a MERGED PR newer than the child's creation (an older merge never blocks a later child; unknown merge time
            # blocks until the next hourly cache refresh fills it). Kill switch: REFILL_ANCESTOR_PR_SKIP=0
            if os.environ.get('REFILL_ANCESTOR_PR_SKIP', '1') != '0':
                _p = suf.split('.')
                for _k in range(2, len(_p)):
                    for _s, _ma in pr_detail.get(PFX + '.'.join(_p[:_k]), ()):
                        if _s == 'OPEN' or (_s == 'MERGED' and _merged_after(_ma, r.get('created_at'))):
                            st.add('OPEN')
            if i in closed_local or 'MERGED' in st or 'OPEN' in st or i in briefs:
                continue
            # chief 2548: the main 2304 legacy text match is retired on the PR path; it excluded leaves only MENTIONED in commit messages
            # (e.g. 10.278 in "file 10.278 to produce...", 10.26.2 as a "sibling leaf"). Landed = closed row or a MERGED linked PR, as above.
        files = re.findall(r'core/[A-Za-z0-9_./-]+\.(?:py|md)', desc.split('FILES:')[1].split('OWNER:')[0])
        out.append(dict(
            id=i, suf=suf, prio=int(r.get('priority') or 9), unblocks=dependents.get(i, 0), est=int(r.get('estimated_minutes') or 999),
            files=files, overlap=[f for f in files if blocked(f, livecount) and not shared_ok(f)], t1=suf in t1,
            bosgame_only=(i in BOSGAME_RESERVED or suf in BOSGAME_RESERVED),
            # chief 2806 (SO-12 + SO-16, 10-10): netcup only when the leaf touches the live DB, the real book or credentials/runtime keys
            # (in doubt: the spec mentions DSN, book or key paths). free-ok no longer routes; it only says a free model may build it.
            # chief ruling (pass 7, fail closed): a leaf is live when it carries the explicit
            # label 'live-data: yes' OR the v1 keyword inference fires (live_match, keyword list
            # unchanged); only a leaf with neither is portable.
            # chief 4740 (captain 21:5x): live DB and the book are ordinary work on any host and model; only credentials stay restricted.
            # netcup_only now means credentials only (explicit label 'credentials: yes' or a credential keyword outside a negation).
            netcup_only=cred_label(labels) or cred_match(desc + ' ' + r['title'] + ' ' + ' '.join(labels)),
            free_ok=('free-ok' in labels) and ('Not free-ok' not in desc),
            offline_ok=('offline' in labels and p2_fixture_only(r, labels) and 'Not free-ok' not in desc),   # v4: explicit offline fixture-only classification; only these may start on netcup automatically
            # netcup SM (main 2989/2990): a leaf labelled netcup or not-free never routes to bosgame (10.446 and the p221 calendar leaves went
            # there on the text match alone); it only changes routing, not the brief. Kill switch: env REFILL_LABEL_FILTER=0
            netcup_label=os.environ.get('REFILL_LABEL_FILTER', '1') != '0' and bool({'netcup', 'not-free'} & set(labels)),
            title=r['title'],
            body=f"{i} · {r['title']}\nLabels: {', '.join(labels)}\nEstimate: {r.get('estimated_minutes')}m\n\n{desc}\n\nAcceptance Criteria:\n{r.get('acceptance_criteria') or ''}\n"))
        if exception_admission:
            out[-1]['p2_exception'] = True
    # SO18, chief0037: T1 takes eligible slots first; spare slots may take P2.
    # The temporary exception applies only below ten dispatchable T1 leaves.
    t1_count = sum(c['t1'] and not c['overlap'] for c in out)
    out = [c for c in out if not c.get('p2_exception') or
           (t1_count < 10 and not c['netcup_only'] and not c['netcup_label']
            and c['free_ok'] and re.fullmatch(r'\d+(?:\.\d+)*', c['suf']))]
    out.sort(key=lambda c: (bool(c['overlap']), not c['t1'], bool(c.get('p2_exception')),
                           (tuple(int(n) for n in c['suf'].split('.')),)
                           if c.get('p2_exception') else (c['prio'], -c['unblocks'], c['est'], c['id'])))
    return out


LIVE_RE = re.compile(r'(\bDSN\b|DOS_CORE_PG_DSN|core\.env|live[ -](?:DB|database|store|run|witness|data)|real book|the book\b|book[_ ]guard|\bcredential|api[_ ]?key|EODHD_API_KEY|eodhd_token|\btoken\b|secret|requires-live|gate-operator)', re.I)
# chief 2816: the match ignores negated or out-of-scope mentions ('No real book, ... credentials.', 'OUT OF SCOPE: live store reads')
NEG_RE = re.compile(r'(OUT OF SCOPE:.*?(?=\b(?:SIZE|BLOCKED-BY|FILES|ACCEPTANCE|AC)\b|$)|\b(?:No|no|never|Never|without|Without)\b[^.;]*[.;])', re.S)


def live_label(labels):
    """A leaf is live-data only when it carries the explicit label 'live-data: yes' (or 'live-data:yes'); the default is portable."""
    return any(re.sub(r'\s+', '', str(l)).lower() == 'live-data:yes' for l in labels)


def live_match(text):
    return bool(LIVE_RE.search(NEG_RE.sub(' ', text)))


CRED_RE = re.compile(r'(\bcredential|api[_ ]?key|EODHD_API_KEY|eodhd_token|\btoken\b|\bsecrets?[ _-]?(?:key|value|token|file)s?\b|requires-credentials)', re.I)   # a 'secret scan' guard is not a credential


def cred_label(labels):
    """chief 4740: explicit label 'credentials: yes' (or 'credentials:yes') marks a credentials leaf."""
    return any(re.sub(r'\s+', '', str(l)).lower() == 'credentials:yes' for l in labels)


def cred_match(text):
    return bool(CRED_RE.search(NEG_RE.sub(' ', text)))


CJ_DEDUPE_OFF = _fm_home_path('data', 'netcup-catjam-dedupe.off')


def bosgame_held(tsv, snap):
    """Set of full leaf ids and dashed lane tokens bosgame holds, or None when it cannot be read."""
    held_ids, lanes = {}, []
    try:
        for l in open(tsv, errors='ignore'):
            p = l.rstrip('\n').split('\t')
            if len(p) >= 3 and p[1].startswith(PFX):
                try:
                    ts = int(p[0])
                except ValueError:
                    ts = 0
                if p[1] not in held_ids or ts >= held_ids[p[1]][0]:
                    held_ids[p[1]] = (ts, p[2].strip())
        sd = json.load(open(snap))
        lanes = [str(x.get('lane')) for x in sd['lanes'] if str(x.get('last_verb') or '').split(' ', 1)[0].split('[', 1)[0].rstrip(':') != 'cancelled']
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return None
    return {i for i, (t, s) in held_ids.items() if s in ('sent', 'go', 'ruling')}, lanes


def held_by_bosgame(c, held):
    if held is None:
        return True
    ids, lanes = held
    if c['id'] in ids:
        return True
    tok = c['suf'].replace('.', '-')
    return any(re.search(r'(?:^|-)' + re.escape(tok) + r'(?:-|$)', l) for l in lanes)


def pick(cands, livecount, netcup_slots, bosgame_sends, bos_first=0):
    """Supply (SO-18 priority) order, FILES overlap with a live lane or an earlier pick skipped. Automatic netcup picks are explicit offline
    leaves only (offline_ok is True); live/netcup-only leaves stay manual. Free-ok leaves fill bosgame first below its floor. Returns [(host, cand)]."""
    # Recheck revocation/expiry at selection, not only when supply was built.
    cands = [c for c in cands if not c.get('p2_exception') or
             (p2_exception_enabled() and not c.get('netcup_only') and not c.get('netcup_label'))]
    if sum(bool(c.get('t1')) and not c['overlap'] for c in cands) >= 10:
        cands = [c for c in cands if not c.get('p2_exception')]
    picked = Counter()
    chosen = {}
    dedupe = os.environ.get('REFILL_NETCUP_FREE') == '1' and not os.path.exists(CJ_DEDUPE_OFF)   # chief 4373: only while the netcup Cat Jam feature is on
    held = bosgame_held(os.environ.get('REFILL_BOSGAME_TSV', _fm_home_path('data', 'bosgame-lanes.tsv')), os.environ.get('REFILL_BOSGAME_SNAP', _fm_home_path('data', 'bosgame-snapshot.json'))) if dedupe else None

    def ok(c):
        if c['overlap']:
            return False
        fs = [f for f in c['files'] if not shared_ok(f)]
        return not any(picked[f] >= 1 and picked[f] + livecount[f] >= (2 if f in SHARED else 1) for f in fs)

    def take(c, host):
        picked.update([f for f in c['files'] if not shared_ok(f)])
        chosen[c['id']] = (host, c)

    live_on = os.environ.get('REFILL_NETCUP_LIVE') == '1'      # chief 4556/4557: netcup auto-starts netcup_only (live-data) leaves, at most REFILL_LIVE_ROOM of them
    try:
        live_room = int(os.environ.get('REFILL_LIVE_ROOM', '0'))
    except ValueError:
        live_room = 0
    for c in cands:                      # v4: one pass in supply order (no live-first pass); netcup takes only explicit offline leaves
        if netcup_slots <= 0 and bosgame_sends <= 0:
            break
        if (live_on and live_room > 0 and netcup_slots > 0 and c['netcup_only'] and not c.get('netcup_label') and not c.get('bosgame_only')
                and c['id'] not in chosen and ok(c) and (not dedupe or (held is not None and not held_by_bosgame(c, held)))):
            take(c, 'netcup'); netcup_slots -= 1; live_room -= 1       # live-data lane: routed Sonnet (Codex if Claude is off), never free or Kimi
            continue
        if c['id'] in chosen or c['netcup_only'] or c.get('netcup_label') or not ok(c):
            continue
        # chief 090658 (main 2991): bosgame takes free-ok leaves only; a non-free-ok leaf is never sent there (kill switch REFILL_LABEL_FILTER=0)
        if os.environ.get('REFILL_LABEL_FILTER', '1') != '0' and not c.get('free_ok'):
            continue
        if c.get('bosgame_only'):            # chief 1547: reserved for bosgame, never a netcup start
            if bosgame_sends > 0:
                take(c, 'bosgame'); bosgame_sends -= 1
            continue
        # chief 2644 (SO-6 pacing): while bosgame has fewer than BOS_FIRST_UNDER live lanes, free-ok leaves go to bosgame first (BOS_FIRST sends)
        if bos_first > 0 and bosgame_sends > 0:
            take(c, 'bosgame'); bosgame_sends -= 1; bos_first -= 1
        elif netcup_slots > 0 and (c.get('offline_ok') is True or (os.environ.get('REFILL_NETCUP_FREE') == '1' and c.get('free_ok') and not c.get('netcup_only') and (not dedupe or (held is not None and not held_by_bosgame(c, held))))):   # chief 4373: Cat Jam free pick only; unreadable ledger => no free pick   # chief 1108: netcup builds non-live free_ok leaves on Cat Jam
            take(c, 'netcup'); netcup_slots -= 1
        elif bosgame_sends > 0:
            take(c, 'bosgame'); bosgame_sends -= 1
    return [chosen[c['id']] for c in cands if c['id'] in chosen]


def leaf_brief(c):
    intent = f"Build tracker leaf {c['id']}, as written in the tracker:\n\n{c['body']}\n"
    scope = "Fixture-first; no network, no real book, no live store, no model calls."
    spec = ("- Scope is exactly the FILES the leaf names. " + scope + "\n"
            "- Tests first for every acceptance line including the Negatives; run the full suite only via bash scripts/gate_test.sh.\n"
            "- Commit when ready, then wait for firstmate's GO before starting /no-mistakes (the gate is capped at 4 concurrent runs); never --yes.\n"
            "- Before committing for GO, run the formatter and linter on your change (cd core && uv run --frozen ruff format . && uv run --frozen ruff check --fix .; the app linter for app/ files) and commit the result (chief 2531): a pipeline commit after review approval needs a new gate run unless it is formatting-only. Run targeted tests yourself; the full suite runs only through scripts/gate_test.sh.\n"
            "- PACKAGES ROW (chief 162440/174851): before committing for GO, if your change adds a new module or command, add its core/PACKAGES.md row (the one allowed out-of-FILES doc edit); the reviewer FAILs a missing row.\n"
            "- If the run stops at ci awaiting_approval, approve it in the same turn: decision-os has no CI; landing goes through cross-family review (chief 2542).\n"
            "- Ship through no-mistakes as one PR naming the leaf; update a branch with git merge origin/main; never rebase; never force-push (SO-3: history rewrites are the captain's).\n"
            "- TRACKER (chief 1662): this lane has its own worktree-local tracker DB; before any br command run export BEADS_DIR=$PWD/.beads, and never use or create a .beads/redirect to /home/holu/decision-os. Do NOT commit .beads/issues.jsonl or any .beads change, and make no br writes that need to reach main; the closure lane closes the leaf in the tracker.\n")
    if c.get('netcup_only'):
        spec = spec.replace(scope, "Fixture-first for the gate tests (hermetic: fixtures, fake model client); this lane runs on netcup with full access, so real book, live DB, credentials and runtime model calls are allowed where the leaf needs them (SO-16, captain 10-02).")
        spec += "- SECRETS AND LIMITS (SO-16): code reads secrets from env or files, never pasted into prompts, PRs or logs; any bulk model-call loop needs a cap in its spec; dropping or mass-deleting real data still asks the captain.\n"
    if any(f in SHARED for f in c['files']):
        spec += "- SHARED FILE (SO-13): another lane may edit one of this leaf's shared files (vocab.py, judgment.py or instruments.py); merge origin/main before the gate and keep your additions append-only.\n"
    return intent, spec


# chief 1694: bosgame's real state is invisible here, so a lane counts only for 90 min after the send (a build takes about that long); done lanes drop out via their open or merged PR
BOS_WINDOW = 14400   # chief 2470: a send counts as a live bosgame lane for 4 h (was 25 min: re-routed before the lane started)


def bosgame_live(ledger_lines, done_branches, now):
    """Bosgame leaf lanes sent or started in the last 90 min whose branch fm/dos-bosgame-<slug>-100N has no merged or closed PR."""
    last = {}
    for l in ledger_lines:
        f = l.rstrip('\n').split('\t')
        if len(f) >= 3 and f[1].startswith(PFX):
            last[f[1]] = (f[0], f[2])
    n = 0
    for leaf, (ts, st) in last.items():
        if st not in ('sent', 'started'):
            continue
        try:
            if now - float(ts) > BOS_WINDOW:
                continue
        except ValueError:
            continue
        slug = leaf.replace(PFX, '').replace('.', '-')
        if any(re.fullmatch(r'fm/dos-bosgame-%s-\d{4}(-r\d+)?' % re.escape(slug), x) for x in done_branches):   # chief 2648 #1: any -MMDD date
            continue
        n += 1
    return n


AGENT = re.compile(r'(^|/)(codex|claude|pi|opencode|commandcode|kimi|grok|omp|agy|cursor-agent|gemini)(-code-mode)?(\s|$)|bin/(codex|claude|pi|opencode|commandcode)\b')


def has_agent(procs, wt):
    """chief 1739 #1: a lane is alive only if an AGENT process (not a leftover shell) has its cwd inside the lane worktree. procs: [(cwd, comm, cmdline)]."""
    wt = wt.rstrip('/')
    for cwd, comm, cmd in procs:
        if (cwd == wt or cwd.startswith(wt + '/')) and (AGENT.search(comm) or AGENT.search(cmd)):
            return True
    return False


def _procs():
    import os
    out = []
    for p in os.listdir('/proc'):
        if not p.isdigit():
            continue
        try:
            cwd = os.readlink('/proc/%s/cwd' % p)
            comm = open('/proc/%s/comm' % p).read().strip()
            cmd = open('/proc/%s/cmdline' % p, 'rb').read().replace(b'\0', b' ').decode('utf8', 'replace')[:300]
        except OSError:
            continue
        out.append((cwd, comm, cmd))
    return out


SNAP_MAX_AGE = 1200


BOS_UNKNOWN_OFF = _fm_home_path('data', 'bosgame-unknown-bound.off')   # kill switch: unknown lanes stop counting (A as first installed)
BOS_GATE_OFF = _fm_home_path('data', 'bosgame-gate-count.off')   # kill switch: ignore the gate flag


def _snapshot_lanes(path, now):
    """Read the snapshot ONCE and return its validated lane list, or None (missing, unreadable, stale, malformed, bad gate flag)."""
    try:
        d = json.load(open(path))
        ts = float(d['ts'])
        lanes = d['lanes']
    except (OSError, ValueError, KeyError, TypeError):
        return None
    if now - ts > SNAP_MAX_AGE or ts - now > 300:
        return None
    if not isinstance(lanes, list) or not all(isinstance(l, dict) and 'agent_alive' in l and 'last_verb' in l for l in lanes):
        return None   # malformed or older-format snapshot: invalid, never an undercount
    if any('gate' in l and not isinstance(l['gate'], bool) for l in lanes):
        return None   # a present gate flag must be true or false
    return lanes


def bosgame_snapshot_live(path, now, working=None):
    """chief 1739 #3: bosgame publishes {"ts": epoch, "lanes": [{"lane", "agent_alive", "last_verb", optional "gate": bool}]}; netcup applies
    the SAME is_working predicate to each fresh observation, plus lanes flagged gate:true with a live agent (chief 4369/4379 A).
    Returns the count, or None when the snapshot is missing, unreadable, older than 20 min or malformed."""
    lanes = _snapshot_lanes(path, now)
    if lanes is None:
        return None
    gate_counts = not os.path.exists(BOS_GATE_OFF)
    n = 0
    for l in lanes:
        if is_working('state: working', str(l.get('last_verb') or ''), bool(l.get('agent_alive'))):
            n += 1
        elif gate_counts and l.get('gate') is True and l.get('agent_alive') is True:
            n += 1
    if not os.path.exists(BOS_UNKNOWN_OFF):
        # FM 4380: an alive waiting lane with no gate flag is UNKNOWN capacity, not zero. Until the owner publishes gate evidence it counts in
        # full, so the cap is a conservative upper bound and admission never rests on a silently dropped lane.
        n += sum(1 for l in lanes if l.get('agent_alive') is True and not is_working('state: working', str(l.get('last_verb') or ''), True) and 'gate' not in l)
    return n


def bosgame_gate_unknown(path):
    """Alive lanes that are not working and carry no gate flag: gate state UNKNOWN, never inferred from the display string, not counted."""
    lanes = _snapshot_lanes(path, time.time())
    if lanes is None:
        return None
    return sum(1 for l in lanes if l.get('agent_alive') is True and not is_working('state: working', str(l.get('last_verb') or ''), True) and 'gate' not in l)


WAITING = ('done', 'paused', 'blocked', 'needs-decision', 'parked', 'stale', 'failed')


def is_working(crew_line, last_status, agent_alive=None):
    """The one counting rule (chief 1681, 1736): a lane counts only with a live agent process (agent_alive; None = not checked)
    whose last verb is not done/paused/blocked/needs-decision/parked. Every count (netcup leaves, planning, caps) goes through here."""
    if agent_alive is False:
        return False
    if any(x in crew_line for x in ('worktree gone', 'backend target gone', 'no metadata')):
        return False
    m = __import__('re').match(r'state:\s*(\w[\w-]*)', crew_line)
    if m and m.group(1) in WAITING:
        return False
    w = (last_status or '').strip().split(' ', 1)[0].split('[', 1)[0].rstrip(':')
    return w not in WAITING


def has_open_pr(branch_prefix, open_branches):
    """Captain 10-02 'yes A' (chief 1690): a lane whose PR is already open no longer holds its FILES against a new leaf (git rebases; SO-13's max 2 stays)."""
    return bool(branch_prefix) and any(b.startswith(branch_prefix) for b in open_branches)


SENT_MAX_AGE = 2700   # a bosgame pass sent but not yet in its snapshot counts as sent-not-started for 45 min (same window as bosgame-pending-sends)


def pass_busy(p):
    """chief 2692: a planning range is busy while it has any pass that is sent-not-started, working, paused, in a gate, or landing
    (an unmerged PR). p: dict(kind='netcup'|'bosgame', status=<last status/verb or ''>, open_pr=bool,
    in_snapshot=bool (bosgame), marker_age=<secs or None> (bosgame), snapshot_fresh=bool (bosgame)). Free only when the pass is
    cancelled, or finished with no open PR, or (bosgame) dropped: absent from a fresh snapshot, past the sent window, with no open PR."""
    if p.get('expired'):
        return False                                  # packet-4102 change 4: the preservation rename already succeeded
    st = (p.get('status') or '').strip().split(' ', 1)[0].split('[', 1)[0].rstrip(':')
    if p.get('open_pr'):
        return True                                   # landing: the PR is not merged yet
    if p.get('kind') == 'bosgame' and not p.get('snapshot_fresh') and not os.path.exists(PLAN_BUSY_OFF):
        return True                                   # Codex 3244 r1 #1/r2 #1: a stale snapshot never frees a bosgame pass (done or cancelled)
    if st == 'cancelled':
        return False
    if p.get('kind') == 'bosgame' and not p.get('in_snapshot'):
        if not p.get('snapshot_fresh'):
            return True                               # no fresh snapshot: never undercount
        age = p.get('marker_age')
        if p.get('marker_path'):                     # packet-4102 change 4: the real marker path decides, not a passed-in age
            try:
                age = time.time() - os.path.getmtime(p['marker_path'])
            except OSError:
                return True                           # marker path unreadable: stale/unknown stays busy
        if os.path.exists(PLAN_BUSY_OFF):             # kill switch data/plan-busy.off: the old 45-min sent window
            return age is not None and age < SENT_MAX_AGE  # sent, not started yet; older = dropped by bosgame
        # chief 21:1x (FM 3244): a HELD pass is busy by presence, not age; free only once dropped (marker renamed),
        # its PR closed or merged, or seen final in a snapshot. A failed closed-PR lookup leaves closed_pr False (busy).
        if p.get('closed_pr') or p.get('seen_final'):
            return False
        return age is not None
    return st != 'done'                               # working, paused, needs-decision, blocked, parked, stale, failed, or unknown


def closed_pr_for(branch):
    """FM 3244 + packet-4102 change 4 (bounded expiry): tri-state. True only when gh PROVES a closed or merged
    decision-os PR whose head is exactly this branch (Codex r1 #2: a per-branch lookup, so an old PR is never
    cut off by a list limit). False only on a SUCCESSFUL lookup that proves no such PR exists. None on any
    lookup failure (unknown: the pass stays busy, never freed)."""
    if os.environ.get('REFILL_CLOSED_BRANCHES_FILE'):   # test hook: a file of branch names, or a missing file = gh failure
        try:
            return branch in set(open(os.environ['REFILL_CLOSED_BRANCHES_FILE']).read().split())
        except OSError:
            return None
    try:
        r = subprocess.run(['gh', 'pr', 'list', '--repo', 'Authentis/decision-os', '--state', 'closed', '--head', branch,
                            '--limit', '5', '--json', 'headRefName', '-q', '.[].headRefName'], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    return branch in r.stdout.split()


# packet-4102 change 4 (bounded expiry): a >24 h orphan marker may release its partition only AFTER an
# exact-identity, no-overwrite preservation rename. Unknown/stale/failed rename stays busy; never delete;
# protected200/145 markers are never touched; a present .preserved file blocks a second rename (never
# repeat a preservation), which stays busy.
EXPIRY_AGE_S = 86400
PROTECTED_PLAN_RE = re.compile(r'dos-planning(200|145)-')

try:
    import fcntl as _fcntl
    _HAS_FCNTL = True
except ImportError:                                   # pragma: no cover (netcup/netcup are Linux)
    _HAS_FCNTL = False
import stat as _stat


def _locked(path):
    """Hold an exclusive non-blocking sidecar lock for one marker path. Returns the open file or None."""
    if not _HAS_FCNTL:
        return None
    try:
        f = open(path + '.lock', 'w')
        _fcntl.flock(f.fileno(), _fcntl.LOCK_EX | _fcntl.LOCK_NB)
        return f
    except OSError:
        return None


def try_expire_marker(p):
    """Attempt the bounded-expiry release for one bosgame pass dict. Returns True only when the marker was
    preservation-renamed (the caller then treats the pass as free). Every other outcome is False (busy).
    CF F4: identity-safe, no separate unlink of a re-stat'ed path. The marker is pinned by file descriptor
    (O_NOFOLLOW: symlinks refused, the existing ownership must be ours), its age comes from the pinned
    fstat (never a path stat), and all expirer/writer contenders serialize on the shared sidecar lock
    (the candidate sender holds the same lock while recording the marker, so replacement-through-removal
    cannot interleave with preservation). Preservation is ONE atomic os.rename onto a placeholder created
    with O_CREAT|O_EXCL (no-overwrite: a present .preserved blocks any repeat): there is no stat->unlink
    window to race. After the rename the destination's (dev, ino) must equal the pinned identity; on any
    mismatch the content is rolled back under a recovered name (never deleted, never released)."""
    mp = p.get('marker_path')
    if not mp or p.get('kind') != 'bosgame':
        return False
    if PROTECTED_PLAN_RE.search(os.path.basename(mp)):
        return False                                  # protected200/145: never touch
    lockf = _locked(mp)                               # shared writer/expirer serialization (sender participates)
    if lockf is None:
        return False
    try:
        try:
            fd = os.open(mp, os.O_RDONLY | os.O_NOFOLLOW)
        except OSError:
            return False                              # missing, symlink, or otherwise unopenable: stays busy
        try:
            st = os.fstat(fd)                         # pinned identity; every later check uses this, not the path
            if not _stat.S_ISREG(st.st_mode):
                return False
            if st.st_uid != os.geteuid():
                return False                          # existing ownership: only our own markers expire
            if time.time() - st.st_mtime <= EXPIRY_AGE_S:
                return False                          # under 24 h stays busy
            if not p.get('snapshot_fresh'):
                return False                          # stale snapshot stays busy
            if p.get('in_snapshot'):
                return False                          # a lane exists: not an orphan
            if p.get('seen_final'):
                return False                          # a final was seen: not releasable here
            if p.get('open_pr'):
                return False                          # landing PR open stays busy
            if p.get('closed_state') is not False:
                return False                          # need a SUCCESSFUL no-open-or-closed-PR check
            dest = mp + '.preserved'                  # exact-identity preservation name, same directory
            try:
                ph = os.open(dest, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            except OSError:
                return False                          # dest exists: a rename is never repeated, stays busy
            try:
                os.rename(mp, dest)                   # atomic: the single mutating op, no unlink window
            except OSError:
                try:
                    os.close(ph)
                    os.unlink(dest)                   # remove OUR placeholder, stay busy
                except OSError:
                    pass
                return False
            try:
                dst = os.stat(dest)
            except OSError:
                try:
                    os.close(ph)
                except OSError:
                    pass
                return False
            if (dst.st_dev, dst.st_ino) != (st.st_dev, st.st_ino):
                try:                                  # not our pinned marker: roll back under a recovered
                    rec = dest + '.recovered.%d.%d' % (os.getpid(), time.time_ns())
                    if not os.path.exists(rec):       # name, never delete, never release
                        os.rename(dest, rec)
                except OSError:
                    pass
                try:
                    os.close(ph)
                except OSError:
                    pass
                return False
            try:
                os.close(ph)                           # placeholder inode is unlinked by the rename; release it
            except OSError:
                pass
            return True
        finally:
            os.close(fd)
    finally:
        lockf.close()


def busy_partitions(passes):
    """Letters of every pass that pass_busy() holds; passes is a list of (letter, pass dict)."""
    return {letter for letter, p in passes if letter and pass_busy(p)}


# chief 4373 (C): row claims replace the whole-partition busy proof. The rows come ONLY from the netcup-owned T1 authority; a row is
# claimed by a busy pass, and an unclaimed row may be planned by a new pass. Live owners keep their whole letter unless they recorded
# data/<pass>/claim-rows; a finished pass with an open PR claims only the authority rows its PR changes in .beads/issues.jsonl
# (an empty PR claims nothing); anything unreadable claims the whole letter. Nothing is ever released on a timestamp.
ROW_MIN = int(os.environ.get('ROW_CLAIM_MIN', '2'))
ROW_CLAIMS_OFF = _fm_home_path('data', 'row-claims.off')
CLAIM_TTL = 7200   # chief 4386: a local pass's claim lapses after 2 h without an edit (its status or claim-rows file untouched); kill switch data/claim-expiry.off
CLAIM_EXPIRY_OFF = _fm_home_path('data', 'claim-expiry.off')


def _authority(path):
    rows, par, excl = {}, {}, set()
    for l in open(path):
        p = l.rstrip('\n').split('\t')
        if not p or not p[0].strip() or p[0].lstrip().startswith('#'):
            continue
        if p[0] == 'EXCLUDE':
            if len(p) > 1:
                excl.add(p[1])
            continue
        if len(p) >= 2 and p[1]:
            rows.setdefault(p[0], []).append(p[1])
            par[(p[0], p[1])] = p[2] if len(p) > 2 and p[2] not in ('', '-') else ''
    return rows, par, excl


def _pr_ids(clone, pid, ids_of_interest):
    """Authority row ids a pass branch changes in .beads/issues.jsonl against origin/main; None when it cannot be proved."""
    br = 'fm/' + pid
    if not re.fullmatch(r'[A-Za-z0-9._/-]+', br):
        return None
    ref = 'refs/rowclaim/' + re.sub(r'[^A-Za-z0-9]', '_', pid)
    try:
        for args in (['fetch', '-q', 'origin', '+refs/heads/main:refs/remotes/origin/main'], ['fetch', '-q', 'origin', '+refs/heads/%s:%s' % (br, ref)]):
            if subprocess.run(['git', '-C', clone] + args, capture_output=True, timeout=120).returncode != 0:
                return None
        r = subprocess.run(['git', '-C', clone, 'diff', 'origin/main...' + ref, '--', '.beads/issues.jsonl'], capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.SubprocessError):
        return None
    if r.returncode != 0:
        return None
    found = set(re.findall(r'^[+-].*?"id"\s*:\s*"' + re.escape(PFX) + r'([0-9][0-9.]*)"', r.stdout, re.M))
    return found & ids_of_interest


def row_claims(home, authority, busy, open_br, clone, letters):
    """Returns (letter, [rows]) for the first letter with at least ROW_MIN unclaimed rows, else None."""
    if os.path.exists(ROW_CLAIMS_OFF):
        return None
    rows, par, excl = _authority(authority)
    allrows = {r for rs in rows.values() for r in rs}
    claimed = set(); whole = set()
    for pid, letter in busy.items():
        cf = os.path.join(home, 'data', pid, 'claim-rows')
        have = os.path.exists(cf)
        meta = os.path.exists(os.path.join(home, 'state', pid + '.meta'))
        try:
            last = open(os.path.join(home, 'state', pid + '.status')).read().strip().splitlines()[-1]
        except (OSError, IndexError):
            last = ''
        final = last.split(' ', 1)[0].split('[', 1)[0].rstrip(':') in ('done', 'cancelled')
        torn = not meta and not os.path.exists(os.path.join(home, 'state', pid + '.status'))   # teardown removes both records
        finished = (final or torn) and '-bosgame-' not in pid
        if not finished and '-bosgame-' not in pid and not os.path.exists(CLAIM_EXPIRY_OFF):
            # chief 4386: no edit for 2 h returns the pass's rows to the pool. "Edit" = the pass touched its status or claim-rows file.
            marks = []
            for f in (os.path.join(home, 'state', pid + '.status'), cf):
                try:
                    marks.append(os.stat(f).st_mtime)
                except OSError:
                    pass
            if marks and time.time() - max(marks) > CLAIM_TTL:
                continue
        finished_pr = finished and open_br is not None and 'fm/' + pid in open_br
        if finished_pr:
            ids = _pr_ids(clone, pid, allrows)           # a finished pass owns exactly what its unlanded PR changes
            if ids is None:
                whole.add(letter)
            else:
                claimed |= ids
        elif have and not (finished and open_br is None):   # a finished pass with unknown PR state may still own an unlanded PR
            claimed |= {x.strip() for x in open(cf) if x.strip()}   # live owner that recorded its rows
        else:
            whole.add(letter)                            # live owner, bosgame pass, unknown PR state: the whole letter
    # chief 4386: data/row-owners.tsv is no longer an admission gate (kill switch: create data/row-owners-gate.on to restore FM 4377). Only DONE rows
    # stay out: data/rows-done.tsv, row<TAB>why. An unreadable file offers nothing.
    for name, active in (('rows-done.tsv', True), ('row-owners.tsv', os.path.exists(os.path.join(home, 'data', 'row-owners-gate.on')))):
        if not active:
            continue
        try:
            claimed |= {l.split('\t')[0].strip() for l in open(os.path.join(home, 'data', name)) if l.strip() and not l.startswith('#')}
        except FileNotFoundError:
            pass
        except (OSError, UnicodeError):
            return None
    claimed_par = {par[(L, r)] for L, rs in rows.items() for r in rs if (r in claimed or L in whole) and par.get((L, r))}
    for L in letters:
        if L in whole or L not in rows:
            continue
        free = [r for r in rows[L] if r not in claimed and r not in excl and not (par.get((L, r)) and par[(L, r)] in claimed_par)]
        if len(free) >= ROW_MIN:
            return L, sorted(free)
    return None


FREE_FIRST_OFF = _fm_home_path('data', 'free-first.off')   # kill switch: the old fixed Muse Spark free tier
ZERO_COST = ('glm-5.3-flash', 'mimo-v2.6-flash-free', 'ling-3.1-flash-free', 'longcat-2.5-preview-free')   # verified $0 opencode models (non-meta), preference order
MUSE = 'muse-spark-1.3-contributor-free'


def free_model(alive_file, n, eu_host, failed=False, hard=False):
    """chief 4369 B / 4379: the $0 model for a routine non-live start: round-robin over the non-meta models the last free-route-ping found alive.
    Muse Spark only on a recorded failure of the leaf or a hard flag, and never on an EU host (meta/Muse is refused there). Returns '' when
    none is usable (the caller then falls to the next tier); an unreadable or empty alive file is never a guess."""
    try:
        alive = [x.strip() for x in open(alive_file) if x.strip()]
    except (OSError, UnicodeError):
        return ''
    if (failed or hard) and not eu_host and MUSE in alive:
        return MUSE
    pool = [m for m in ZERO_COST if m in alive]
    return pool[n % len(pool)] if pool else ''


# Router v3. The injected dictionaries keep route_pick free of filesystem and
# clock reads; the CLI owns locking, persistence, and parsing YAML/JSON.
ROUTE_QUOTA_MAX_AGE = 6 * 3600
ROUTE_BENCH_SECONDS = 30 * 60
ROUTE_HARD_ROLES = {'plan', 'review', 't3'}
ROUTE_ROUTINE_ROLES = {'build', 'manager'}
ROUTE_SCARCE_POOLS = {'claude', 'codex', 'muse', 'grok'}
# pass-5 (chief): a 402 or an exhaustion phrase benches the binding until its pool's reset.
ROUTE_EXHAUST_RE = re.compile(r'insufficient credits|usage limit|weekly limit|quota exceeded', re.I)
ROUTE_EXHAUST_FALLBACK_SECONDS = 24 * 3600
ROUTE_FUNDS_BENCH_SECONDS = 24 * 3600
# Chief 4894/4895: planning is a fixed, paid, credential-safe chain.  These are
# deliberately code constants rather than YAML preference: a reordered or injected
# fleet row must not turn a planning pass into Grok, Claude, a free model, or a
# differently-bound lookalike.  The controller asks the bindings in this order on
# their stated hosts; route_pick also preserves the order for direct callers.
ROUTE_PLAN_CHAIN = (
    ('sol-plan@pi', 'sol-plan', 'openai-codex/gpt-6.1-sol', 'codex', 'openai-codex', 'pi', 'netcup'),
    ('muse-wonder-plan@muse', 'muse-wonder-plan', 'muse-wonder', 'muse', 'muse', 'muse', 'bosgame'),
    ('kimi-k3-plan@pi', 'kimi-k3-plan', 'kimi-code/k3', 'kimi', 'kimi-code', 'pi', 'netcup'),
)
ROUTE_PLAN_BINDINGS = {row[0]: row for row in ROUTE_PLAN_CHAIN}


def fm_path(rel, home=None):
    """Resolve one runtime path below FM_HOME and reject lexical or symlink escape."""
    home = os.path.realpath(home or os.environ.get('FM_HOME') or
                            FM_DEFAULT_HOME)
    if not isinstance(rel, str) or not rel or '\x00' in rel:
        raise ValueError('invalid FM_HOME path')
    # Reject lexical traversal before normalization can erase it (``state/../x``).
    if '..' in rel.replace('\\', '/').split('/'):
        raise ValueError('FM_HOME path contains ..')
    candidate = os.path.realpath(rel if os.path.isabs(rel) else os.path.join(home, rel))
    if candidate != home and not candidate.startswith(home + os.sep):
        raise ValueError('path escapes FM_HOME')
    return candidate


def _route_model_id(model_id, model):
    actual = model.get('id') if isinstance(model, dict) else None
    return actual if isinstance(actual, str) and actual else model_id


def route_family_ok(binding, model, host):
    """Unconditional host/family policy, independent of mutable fleet bans."""
    if str(host).lower() != 'netcup':
        return True, 'family allowed'
    family = str(model.get('family', '')).lower() if isinstance(model, dict) else ''
    surfaces = [family, _route_model_id('', model)]
    if isinstance(binding, dict):
        surfaces.extend(binding.get(k) for k in ('id', 'model', 'family', 'provider', 'harness'))
    if family in ('muse', 'composer') or any(re.search(r'(?:muse|composer)', str(x), re.I)
                                             for x in surfaces if x):
        return False, 'Muse/Composer forbidden on netcup'
    return True, 'family allowed'


def _route_stealth(binding, model):
    """Stealth is model/binding boolean ``stealth: true``, label ``stealth``, or identifier text."""
    for row in (model, binding):
        if not isinstance(row, dict):
            continue
        if row.get('stealth') is True or str(row.get('label', '')).lower() == 'stealth':
            return True
        labels = row.get('labels')
        if isinstance(labels, list) and any(str(x).lower() == 'stealth' for x in labels):
            return True
    surfaces = []
    for row in (model, binding):
        if isinstance(row, dict):
            surfaces.extend(row.get(k) for k in ('id', 'model', 'family', 'provider', 'harness'))
    return any('stealth' in str(x).lower() for x in surfaces if x)


def route_catalog_ok(binding, model, host, catalogs, now):
    """Validate host provenance, freshness, membership and strict free-model cost evidence."""
    host = str(host).lower()
    snap = catalogs.get(host) if isinstance(catalogs, dict) else None
    if not isinstance(snap, dict):
        return False, 'catalog missing'
    if str(snap.get('host', '')).lower() != host:
        return False, 'catalog host mismatch'
    try:
        observed = float(snap['observed_at'])
        max_age = float(snap.get('max_age_seconds', 86400))
    except (KeyError, TypeError, ValueError):
        return False, 'catalog provenance invalid'
    if not math.isfinite(observed) or not math.isfinite(max_age) or max_age < 0:
        return False, 'catalog provenance invalid'
    if observed > float(now) + 300 or float(now) - observed > max_age:
        return False, 'catalog stale'
    rows = snap.get('models')
    if not isinstance(rows, dict):
        return False, 'catalog models invalid'
    actual = _route_model_id(str(binding.get('model', '')), model)
    provider = str(binding.get('provider', ''))
    if not provider:
        return False, 'catalog provider missing'
    # Catalog provenance is provider/model. A bare model key cannot establish which provider
    # supplied the evidence; native launcher IDs are therefore looked up under provider/id.
    if '/' in actual:
        if actual.split('/', 1)[0].lower() != provider.lower():
            return False, 'catalog provider mismatch'
        keys = [actual]
    else:
        keys = [provider + '/' + actual]
    key = next((x for x in keys if x in rows), None)
    if key is None:
        return False, 'model absent from %s catalog' % host
    if '/' in key and provider and key.split('/', 1)[0].lower() != provider.lower():
        return False, 'catalog provider mismatch'
    if str(model.get('billing', '')).lower() == 'free':
        if actual.endswith('-free'):
            return True, 'catalog free suffix'
        rec = rows.get(key)
        cost = rec.get('cost') if isinstance(rec, dict) else None
        values = (cost.get('input'), cost.get('output')) if isinstance(cost, dict) else (None, None)
        if not all(type(v) in (int, float) and math.isfinite(v) and v == 0 for v in values):
            return False, 'free billing lacks strict numeric 0/0 catalog cost'
    return True, 'catalog eligible'


def route_funds_stall(http_status=None, message=''):
    try:
        is_402 = int(http_status) == 402
    except (TypeError, ValueError):
        is_402 = False
    text = str(message).strip()
    return is_402 or text.lower() == 'funds' or bool(re.search(r'insufficient balance', text, re.I))


def route_bench_apply(binding_id, reason, now, cfg, quota, bench):
    """Pure shared bench transition used by both route-bench and observed launch failures."""
    quota = copy.deepcopy(quota) if isinstance(quota, dict) else {'pools': {}}
    bench = copy.deepcopy(bench) if isinstance(bench, dict) else {}
    bench.setdefault('models', {})
    bench.setdefault('cursor', {})
    bench.setdefault('bindings', {})
    alerts = []
    text = str(reason or '')
    status = 402 if text.strip() == '402' else None
    if route_funds_stall(status, text):
        until, normalized = float(now) + ROUTE_FUNDS_BENCH_SECONDS, 'funds'
    elif text.strip() == '429':
        until, normalized = float(now) + ROUTE_BENCH_SECONDS, '429'
    elif ROUTE_EXHAUST_RE.search(text):
        bindings = cfg.get('bindings', {}) if isinstance(cfg, dict) else {}
        row = bindings.get(binding_id) if isinstance(bindings, dict) else None
        pool = route_binding_pool(binding_id, row or {})
        rec = (quota.get('pools') or {}).get(pool) if isinstance(quota.get('pools'), dict) else None
        try:
            reset_at = float(rec['reset_at'])
            if not math.isfinite(reset_at) or reset_at <= float(now):
                raise ValueError
        except (TypeError, KeyError, ValueError):
            reset_at = float(now) + ROUTE_EXHAUST_FALLBACK_SECONDS
            alerts.append('binding=%s pool=%s pool reset unknown for exhaustion' % (binding_id, pool))
        until, normalized = reset_at, 'exhaustion'
        if isinstance(row, dict):
            pools = quota.setdefault('pools', {})
            previous = pools.get(pool)
            pools[pool] = {'used_pct': 100, 'reset_at': reset_at, 'observed_at': float(now),
                           'source': 'bench', 'manual': bool(previous.get('manual'))
                           if isinstance(previous, dict) else False}
    else:
        until, normalized = float(now) + ROUTE_BENCH_SECONDS, 'failure'
    if float(until).is_integer():
        until = int(until)
    bench['bindings'][binding_id] = {'until': until, 'reason': normalized}
    return bench, quota, alerts


def _route_candidates(role_cfg):
    """Return [(tier, model id)] in the configured, fail-closed order. The tier lists and the
    'models' list are MERGED (pass-3 S8): a role that carries both keeps its named models; the
    metered tier is still enumerated so route_pick can refuse each row with a logged reason."""
    if isinstance(role_cfg, list):
        return [('models', x) for x in role_cfg]
    if not isinstance(role_cfg, dict):
        return []
    out = []
    for tier in ('free', 'flat', 'models', 'metered'):
        values = role_cfg.get(tier, [])
        if isinstance(values, list):
            out.extend((tier, x) for x in values)
    return out


def _route_banned(model_id, model, role, host, live_data, bans, binding=None, hard=False):
    # binding: the resolved binding row (or None for a bare model candidate); its id/provider/harness
    # join the match surface. hard: a ban row may carry hard: false to apply to ROUTINE picks only
    # (chief 4656: opencode-go/* and chief 4657c: gate-step Codex are routine bans, not hard-role bans).
    bid = binding.get('id') if isinstance(binding, dict) else None
    actual = {
        'model': model_id, 'model_id': model_id, 'family': model.get('family'),
        'billing': model.get('billing'), 'via': model.get('via'),
        'role': role, 'host': host, 'live_data': bool(live_data),
        'binding': bid, 'provider': binding.get('provider') if isinstance(binding, dict) else None,
        'harness': binding.get('harness') if isinstance(binding, dict) else None,
    }
    for row in bans if isinstance(bans, list) else ():
        if not isinstance(row, dict):
            continue
        if 'hard' in row and bool(row.get('hard')) != bool(hard):
            continue   # hard-scoped ban row: applies only on its side of the hard/routine line
        matched = True
        for key, wanted in row.items():
            if key == 'hard':
                continue
            if key == 'id_pattern':
                try:
                    pat = re.compile(str(wanted), re.I)
                except re.error:
                    matched = False
                else:
                    # pass-3 (M2): the pattern is matched against the MODEL ID AND the BINDING ID,
                    # plus the provider/harness ids (a binding like foo-k3@opencode on model cat-jam
                    # must not bypass a haiku|k3 ban).
                    # pass-7 (review): AND the EFFECTIVE LAUNCH IDS the launcher constructs from the
                    # resolved binding - '<provider>/<model>' and '<harness>/<model>'. A binding
                    # with model ds-flash on provider opencode-go launches as 'opencode-go/ds-flash'
                    # and must not bypass a '^opencode-go/' routine-build ban.
                    surfaces = [s for s in (model_id, bid, actual['provider'], actual['harness']) if s]
                    for join in (actual['provider'], actual['harness']):
                        if join:
                            surfaces.append('%s/%s' % (join, model_id))
                    matched = matched and any(pat.search(str(s)) for s in surfaces)
            elif key == 'via':
                # pass-3 (S10): a cline harness on the BINDING bans a Claude model even when the
                # model row itself says via: claude (the ban is about how the model is reached).
                # pass-9 (review): AND the binding's PROVIDER - a Claude binding on provider cline
                # with a non-cline harness still reaches the model through Cline.
                matched = matched and wanted in (actual[key], actual['harness'], actual['provider'])
            elif key in actual:
                # pass-8b (review): a scalar ban value prefixed with '!' NEGATES the condition
                # (host: '!netcup' matches every host except netcup). This is how the example's
                # manager-Claude ban spares the captain-configured netcup Sonnet row.
                if isinstance(wanted, str) and wanted.startswith('!'):
                    matched = matched and actual[key] != wanted[1:]
                else:
                    matched = matched and actual[key] == wanted
            else:
                matched = False
            if not matched:
                break
        if matched:
            return True
    return False


def _route_binding_weight(binding):
    try:
        w = int(binding.get('weight', 1))
    except (TypeError, ValueError):
        return 1
    return w if w >= 1 else 1


def route_reviewer(author_family, live_data=False):
    """chief 4658 + pass-3 (S11/S12/M5): the REVIEWER is chosen by the writer's family, not by quota
    rotation, and live data never lowers the bar (no free or Kimi reviewer on live picks).
    OpenAI-built (codex, gpt-6.1-sol, gpt-5.6-sol) -> the literal off-host request marker
    'muse-spark-1.3-contributor-via-firstmate' (Muse is blocked on netcup, so the review runs
    elsewhere via firstmate). Muse-built -> 'droid:gpt-6.1-sol'. Claude-built ->
    'droid-local:gpt-6.1-sol'. EVERY other writer family (Kimi, free-model, DeepSeek, unknown)
    still gets 'droid:gpt-6.1-sol' - never WAIT just because the writer family is unusual.
    Claude, free and Kimi models are never reviewers; the live-data guard enforces that for
    live picks too (returns None = WAIT only when the resolved reviewer would be free/Kimi)."""
    fam = str(author_family or '').lower().strip()
    if fam in ('codex', 'gpt-6.1-sol', 'gpt-5.6-sol', 'openai'):
        pick = 'muse-spark-1.3-contributor-via-firstmate'
    elif fam == 'claude':
        pick = 'droid-local:gpt-6.1-sol'
    else:
        # muse-built AND every other family (muse, kimi, free, deepseek, unknown, ''): the review
        # runs on droid gpt-6.1-sol.
        pick = 'droid:gpt-6.1-sol'
    if live_data and _REVIEWER_PICK_FAMILY.get(pick) in ('free', 'kimi'):
        return None   # live-data bans: no free, no Kimi - a reviewer pick is no exception
    return pick


# The family each reviewer pick resolves to, for the live-data guard. The Muse marker runs
# off-host via firstmate (request marker, not a netcup route), droid sol is an OpenAI-family model.
_REVIEWER_PICK_FAMILY = {
    'muse-spark-1.3-contributor-via-firstmate': 'muse',
    'droid:gpt-6.1-sol': 'openai',
    'droid-local:gpt-6.1-sol': 'openai',
}


def _route_quota_ok(pool_name, pool_cfg, quota_rec, role, now, hard):
    if not isinstance(pool_cfg, dict) or not isinstance(quota_rec, dict):
        return False, 'quota unknown'
    try:
        used = float(quota_rec['used_pct'])
        reset_at = float(quota_rec['reset_at'])
        observed = float(quota_rec['observed_at'])
    except (KeyError, TypeError, ValueError):
        return False, 'quota unknown'
    if not all(math.isfinite(x) for x in (used, reset_at, observed)):
        return False, 'quota unknown'
    if not isinstance(quota_rec.get('source'), str) or not quota_rec.get('source') or not isinstance(quota_rec.get('manual'), bool):
        return False, 'quota unknown'
    if now - observed > ROUTE_QUOTA_MAX_AGE or observed - now > 300:
        return False, 'quota stale'
    if not 0 <= used <= 100 or reset_at <= now:
        return False, 'quota unknown'
    if used >= 100:
        return False, 'quota exhausted'
    scarce = bool(pool_cfg.get('scarce', pool_name in ROUTE_SCARCE_POOLS))
    if hard or role in ROUTE_HARD_ROLES or not scarce or reset_at - now <= 86400:
        return True, 'quota available'
    try:
        period = float(pool_cfg['period_days']) * 86400
        reserve = float(pool_cfg.get('reserve', 30))
    except (KeyError, TypeError, ValueError):
        return False, 'quota pool config unknown'
    if not math.isfinite(period) or not math.isfinite(reserve) or period <= 0 or not 0 <= reserve <= 100:
        return False, 'quota pool config unknown'
    elapsed = (now - (reset_at - period)) / period
    allowed = (100 - reserve) * max(0.0, min(1.0, elapsed))
    if used > allowed:
        return False, 'reserve pace %.1f%% > %.1f%%' % (used, allowed)
    return True, 'within reserve pace'


def route_binding_pool(binding_id, binding):
    """pass-6: the ONE pool resolver shared by selection (route_pick), route-bench and the quota
    writes. A binding's pool is its fleet-table 'pool' key; when the table names none, the pool is
    the BINDING ID itself (every binding needs a pools-table row and a quota row under that name).
    The binding-id TEXT is never parsed and the model row's pool is never consulted for an explicit
    binding (in the example, model cat-jam's pool 'cat-jam' is not a pools-table key: reading it
    would update a row selection never sees)."""
    pool = binding.get('pool') if isinstance(binding, dict) else None
    return pool if isinstance(pool, str) and pool else binding_id


def route_binding_lane_row(row):
    """pass-8 (review): the ONE binding-row normalization, shared with the binding-lane CLI: a row
    with no harness defaults its harness to its provider (and a row with no provider defaults to
    its harness) - exactly what the sender prints and the launcher constructs. Ban evaluation must
    see the DEFAULTED row, not the raw one: a Claude binding with provider cline and no harness
    launches through cline and is denied by the Claude-via-Cline ban. Returns a normalized copy,
    or None when neither harness nor provider resolves."""
    if not isinstance(row, dict):
        return None
    harness = row.get('harness') or row.get('provider')
    provider = row.get('provider') or harness
    if not isinstance(harness, str) or not harness or not isinstance(provider, str) or not provider:
        return None
    out = dict(row)
    out['harness'] = harness
    out['provider'] = provider
    return out


def route_plan_binding_ok(entry, model_id, model, binding, host):
    """Validate an immutable planning-chain binding, including its host.

    This is intentionally stricter than the mutable fleet bans.  Planning has a
    named, paid three-step route; accepting a same-family or same-id row through a
    different provider/harness would make catalog and credential evidence ambiguous.
    """
    wanted = ROUTE_PLAN_BINDINGS.get(entry)
    if wanted is None:
        return False, 'binding is not in immutable plan chain'
    _, wanted_model, wanted_id, wanted_family, wanted_provider, wanted_harness, wanted_host = wanted
    if str(host).lower() != wanted_host:
        return False, 'plan binding is only allowed on %s' % wanted_host
    if model_id != wanted_model or _route_model_id(model_id, model) != wanted_id:
        return False, 'plan model does not match immutable chain'
    if str(model.get('family', '')).lower() != wanted_family:
        return False, 'plan family does not match immutable chain'
    if str(model.get('billing', '')).lower() == 'free':
        return False, 'free billing forbidden for plan'
    if binding.get('provider') != wanted_provider or binding.get('harness') != wanted_harness:
        return False, 'plan provider/harness does not match immutable chain'
    if binding.get('effort', model.get('effort')) != 'high':
        return False, 'plan effort must be high'
    return True, 'immutable plan binding'


def _route_bench_marks(bench_bindings, bench_models, entry, model_id):
    # pass-8 (review): the binding-specific mark and the model-wide mark are read INDEPENDENTLY
    # (the old 'first mark wins' chain let an EXPIRED binding mark mask an ACTIVE model mark).
    marks = [bench_bindings.get(entry), bench_models.get(entry)]
    if entry != model_id:
        marks.extend((bench_bindings.get(model_id), bench_models.get(model_id)))
    return [m for m in marks if m is not None]


def _route_bench_until(marks, now):
    """Returns (benched_until, invalid) over EVERY mark: benched when ANY mark is unexpired; any
    invalid mark fails closed."""
    until_max = 0.0
    for mark in marks:
        until = mark.get('until', 0) if isinstance(mark, dict) else mark
        try:
            until = float(until or 0)
            if not math.isfinite(until):
                raise ValueError
        except (TypeError, ValueError):
            return 0.0, True
        until_max = max(until_max, until)
    return until_max, False


def route_pick(role, host, author_family, live_data, now=None, cfg=None,
               quota=None, bench=None, hard=False, *, catalogs=None,
               only_binding=None, advance_cursor=True):
    """Pick one configured model, returning ``(model id or None, reason)``.

    pass-5 (chief): the ONE exception is role 'manager' - it returns a VERDICT, never a
    model id: ``('OK', reason)`` when at least one configured manager row passes every ban,
    bench and quota-window check, else ``(None, reasons)``. Managers run the captain's named
    choices (Muse, Sonnet), not a router rotation, so an 'OK' verdict must never be consumed
    as a spawn route.

    cfg, quota, bench, and now are injectable. ``bench`` is the caller-owned
    routing state; its cursor is advanced in memory only after a free pick.
    """
    now = time.time() if now is None else float(now)
    role = str(role).lower()
    host = str(host).lower()
    author_family = str(author_family or '').lower()
    live_data = bool(live_data)
    if not isinstance(cfg, dict):
        return None, 'fleet config missing or invalid'
    models = cfg.get('models')
    roles = cfg.get('roles')
    pools = cfg.get('pools')
    bans = cfg.get('bans')
    bindings = cfg.get('bindings')
    bindings = bindings if isinstance(bindings, dict) else {}
    if (not isinstance(models, dict) or not isinstance(roles, dict) or
            not isinstance(pools, dict) or not isinstance(bans, list)):
        return None, 'fleet config missing required tables'
    if (not all(isinstance(k, str) and isinstance(v, dict) for k, v in models.items()) or
            not all(isinstance(k, str) and isinstance(v, dict) for k, v in pools.items()) or
            not all(isinstance(k, str) and isinstance(v, dict) for k, v in bindings.items()) or
            not all(isinstance(row, dict) for row in bans)):
        return None, 'fleet config contains invalid rows'
    # pass-3 (S11/M5): the review role never rotates over the role table. It delegates to the same
    # writer-family policy as route-reviewer.sh (with live data threaded through), so an OpenAI-built
    # author can never receive codex-top by rotation and a netcup author never receives Grok.
    if role == 'review':
        reviewer = route_reviewer(author_family, live_data)
        if reviewer is None:
            return None, 'no approved reviewer for writer family %s' % (author_family or 'unknown')
        return reviewer, 'reviewer by writer family %s%s' % (
            author_family or 'unknown', '; live data' if live_data else '')
    role_cfg = roles.get(role)
    if isinstance(role_cfg, dict):
        if any(not isinstance(role_cfg.get(k, []), list) for k in ('free', 'flat', 'metered', 'models')):
            return None, 'role %s has an invalid model list' % role
    elif not isinstance(role_cfg, list):
        return None, 'role %s has no configured models' % role
    candidates = _route_candidates(role_cfg)
    if not candidates:
        return None, 'role %s has no configured models' % role
    quota_pools = quota.get('pools', {}) if isinstance(quota, dict) else {}
    bench = bench if isinstance(bench, dict) else {}
    if not isinstance(bench.get('models'), dict):
        bench['models'] = {}
    if not isinstance(bench.get('cursor'), dict):
        bench['cursor'] = {}
    if not isinstance(bench.get('bindings'), dict):
        bench['bindings'] = {}
    bench_models = bench['models']
    bench_bindings = bench['bindings']
    cursors = bench['cursor']
    effective_hard = bool(hard) or role in ROUTE_HARD_ROLES

    # chief 4661: resolve every candidate to a BINDING (model + provider + harness). A role entry that
    # names a binding id uses that row; a bare model id is one implicit binding for the model. The pick
    # returns the binding id; the 429 bench and the quota row are per binding.
    resolved = []
    for tier, entry in candidates:
        if not isinstance(entry, str):
            resolved.append((tier, entry, None, None, None, '%s: candidate invalid' % entry))
            continue
        if entry in bindings:
            b = bindings[entry]
            model_id = b.get('model')
            # pass-8 (review): normalize the row BEFORE bans/quota see it - a missing harness
            # defaults to the provider (the same default binding-lane applies), so a Claude
            # binding with provider cline and no harness is denied by the Claude-via-Cline ban.
            binding = route_binding_lane_row(b) or dict(b)
            binding['id'] = entry
        else:
            model_id = entry
            model_row = models.get(entry)
            binding = {'id': entry, 'model': entry, 'provider': None,
                       'harness': model_row.get('via') if isinstance(model_row, dict) else None,
                       'weight': 1}
            if isinstance(model_row, dict) and isinstance(model_row.get('pool'), str):
                binding['pool'] = model_row['pool']
        if not isinstance(model_id, str) or model_id not in models or not isinstance(models.get(model_id), dict):
            resolved.append((tier, entry, None, None, None, '%s: model unknown' % model_id))
            continue
        pool_name = route_binding_pool(entry, binding)
        resolved.append((tier, entry, model_id, binding, pool_name, None))
    if only_binding is not None:
        resolved = [r for r in resolved if r[1] == only_binding]
        if not resolved:
            return None, '%s: binding is not configured for role %s' % (only_binding, role)
    if role == 'plan':
        # Keep the immutable order even when YAML is maliciously reordered.  Unknown
        # entries remain in the list solely to produce an explicit refusal reason.
        ranks = {binding: index for index, binding in enumerate(ROUTE_PLAN_BINDINGS)}
        resolved.sort(key=lambda row: (ranks.get(row[1], len(ranks)), str(row[1])))

    # pass-5 (chief): the manager row is VERDICT-ONLY. Managers are not free models and the
    # router never picks a manager model: every configured row is checked against the bans, the
    # per-binding bench and the quota windows; the pick is 'OK' when at least one row passes,
    # else None (WAIT) with the refusal reasons. The returned 'OK' is a verdict, never a model id
    # and never a spawn route.
    if role == 'manager':
        rejected, eligible = [], []
        for tier, entry, model_id, binding, pool_name, resolve_error in resolved:
            if resolve_error:
                rejected.append(resolve_error)
                continue
            model = models[model_id]
            family_ok, family_why = route_family_ok(binding, model, host)
            if not family_ok:
                rejected.append('%s: %s' % (entry, family_why))
                continue
            if live_data and _route_stealth(binding, model):
                rejected.append('%s: stealth binding forbidden for credentials' % entry)
                continue
            if catalogs is not None:
                catalog_ok, catalog_why = route_catalog_ok(binding, model, host, catalogs, now)
                if not catalog_ok:
                    rejected.append('%s: %s' % (entry, catalog_why))
                    continue
            if tier == 'metered' or model.get('billing') == 'metered':
                rejected.append('%s: metered rows are never eligible' % entry)
                continue
            if _route_banned(model_id, model, role, host, live_data, bans, binding=binding, hard=effective_hard):
                rejected.append('%s: banned by fleet table' % entry)
                continue
            # pass-8 (review): BOTH the binding mark and the model mark are evaluated
            # INDEPENDENTLY - an expired binding-specific mark must not mask an active
            # model-wide mark.
            until, invalid = _route_bench_until(
                _route_bench_marks(bench_bindings, bench_models, entry, model_id), now)
            if invalid:
                rejected.append('%s: bench state invalid' % entry)
                continue
            if until > now:
                rejected.append('%s: benched until %d' % (entry, until))
                continue
            if not isinstance(pool_name, str) or pool_name not in pools:
                rejected.append('%s: pool unknown' % entry)
                continue
            ok, why = _route_quota_ok(pool_name, pools.get(pool_name), quota_pools.get(pool_name), role, now, hard)
            if not ok:
                rejected.append('%s: %s' % (entry, why))
                continue
            eligible.append(entry)
        if eligible:
            why = 'manager admission OK: %s' % ', '.join(eligible)
            if rejected:
                why += '; denied: ' + '; '.join(rejected)
            return 'OK', why
        return None, 'manager admission WAIT: %s' % ('; '.join(rejected) or 'nothing eligible')

    # Only the free tier rotates (across bindings, weighted). Start at the persisted cursor, then
    # retain the configured tier ordering so flat plans cannot jump ahead of free.
    free = [r for r in resolved if r[0] == 'free']
    rest = [r for r in resolved if r[0] != 'free']
    free_rot = []
    for r in free:
        free_rot.extend([r] * _route_binding_weight(r[3]))
    if free:
        try:
            start = int(cursors.get(role, 0) or 0) % len(free_rot)
        except (TypeError, ValueError):
            return None, 'rotation cursor invalid'
        # pass-3 (M3/S9): the cursor is an OFFSET IN THE WEIGHT-EXPANDED LIST and advances by one per
        # free pick. The old code stored the first index of the picked entry, so weights [2,1]
        # collapsed the cursor and starved the second binding forever.
        expanded = list(enumerate(free_rot))
        expanded = expanded[start:] + expanded[:start]
        ordered = [(i, r) for i, r in expanded] + [(None, r) for r in rest]
    else:
        ordered = [(None, r) for r in rest]

    rejected = []
    for idx, cand in ordered:
        tier, entry, model_id, binding, pool_name, resolve_error = cand
        if resolve_error:
            rejected.append(resolve_error)
            continue
        model = models[model_id]
        actual_id = _route_model_id(model_id, model)
        # K3 remains prohibited everywhere except its exact, non-credential planning
        # binding below.  This preserves the existing credential and general K3 guard
        # while allowing chief 4895's narrowly-scoped planner fallback.
        k3_surfaces = (entry, model_id, actual_id, binding.get('provider'), binding.get('harness'))
        if any('k3' in str(surface).lower() for surface in k3_surfaces if surface):
            if role != 'plan' or entry != 'kimi-k3-plan@pi':
                rejected.append('%s: K3 is reserved for the immutable plan binding' % entry)
                continue
        family_ok, family_why = route_family_ok(binding, model, host)
        if not family_ok:
            rejected.append('%s: %s' % (entry, family_why))
            continue
        if role == 'plan':
            plan_ok, plan_why = route_plan_binding_ok(entry, model_id, model, binding, host)
            if not plan_ok:
                rejected.append('%s: %s' % (entry, plan_why))
                continue
        if role == 'cloud' and binding.get('cloud_capable') is not True:
            rejected.append('%s: binding is not cloud capable' % entry)
            continue
        if live_data and _route_stealth(binding, model):
            rejected.append('%s: stealth binding forbidden for credentials' % entry)
            continue
        if catalogs is not None:
            catalog_ok, catalog_why = route_catalog_ok(binding, model, host, catalogs, now)
            if not catalog_ok:
                rejected.append('%s: %s' % (entry, catalog_why))
                continue
        if tier in ('free', 'flat') and model.get('billing') != tier:
            rejected.append('%s: %s row has %s billing' % (entry, tier, model.get('billing', 'unknown')))
            continue
        if tier == 'metered':
            # pass-3 (S7): Router v3 has NO metered tier - not for routine roles, not for hard
            # roles, not even for a hard=True pick. Metered rows are refused here with a reason;
            # they no longer appear in fleet.yaml.example.
            rejected.append('%s: metered rows are never eligible' % entry)
            continue
        if model.get('billing') == 'metered':
            rejected.append('%s: metered-billing model not allowed outside a metered row' % entry)
            continue
        if role == 'review' and author_family and str(model.get('family', '')).lower() == author_family:
            rejected.append('%s: author family excluded' % entry)
            continue
        if _route_banned(model_id, model, role, host, live_data, bans, binding=binding, hard=effective_hard):
            rejected.append('%s: banned by fleet table' % entry)
            continue
        # Per-binding 429 bench (30 min); a legacy MODEL-keyed bench mark applies to every binding of that model.
        # pass-8 (review): BOTH marks are evaluated INDEPENDENTLY - an expired binding-specific
        # mark must not mask an active model-wide mark (benched when EITHER is unexpired).
        until, invalid = _route_bench_until(
            _route_bench_marks(bench_bindings, bench_models, entry, model_id), now)
        if invalid:
            rejected.append('%s: bench state invalid' % entry)
            continue
        if until > now:
            rejected.append('%s: benched until %d' % (entry, until))
            continue
        if not isinstance(pool_name, str) or pool_name not in pools:
            rejected.append('%s: pool unknown' % entry)
            continue
        ok, why = _route_quota_ok(pool_name, pools.get(pool_name), quota_pools.get(pool_name), role, now, hard)
        if not ok:
            rejected.append('%s: %s' % (entry, why))
            continue
        if tier == 'free':
            if idx is None:
                return None, 'rotation state invalid'
            if advance_cursor:
                cursors[role] = (idx + 1) % len(free_rot)
            reason = 'free tier; %s' % why
            if rejected:
                reason += '; after ' + '; '.join(rejected)
            return entry, reason
        label = 'metered (explicit table row)' if tier == 'metered' else ('flat plan' if tier == 'flat' else 'named %s model' % role)
        reason = '%s; %s' % (label, why)
        if rejected:
            reason += '; after ' + '; '.join(rejected)
        return entry, reason
    return None, '; '.join(rejected) or 'nothing eligible'



def _route_paths():
    home = os.environ.get('FM_HOME')
    def path(env_name, default):
        explicit = os.environ.get(env_name)
        if not home:
            return None
        try:
            # Presence of an explicit override is authoritative, including an invalid value:
            # never fall back to a different state file after rejecting it.
            return fm_path(explicit if explicit is not None else default, home)
        except ValueError:
            return None
    fleet = path('FLEET_YAML', 'config/fleet.yaml')
    cfg = _load_fleet(fleet) if fleet else None
    bench_default = 'state/route-bench.json'
    routing_state = cfg.get('routing_state') if isinstance(cfg, dict) else None
    if isinstance(routing_state, dict) and 'bench' in routing_state:
        bench_default = routing_state.get('bench')
    return {
        'fleet': fleet,
        'quota': path('QUOTA_JSON', 'state/quota.json'),
        'bench': path('BENCH_JSON', bench_default),
        'alerts': path('ROUTE_ALERTS', 'state/route-alerts.log'),
        'lock': path('ROUTE_LOCK', 'state/route-pick.lock'),
    }


def _load_route_catalogs(cfg, home=None):
    """Load every configured host snapshot; invalid/missing rows remain explicit failures."""
    rows = cfg.get('catalogs') if isinstance(cfg, dict) else None
    if not isinstance(rows, dict):
        # Backward-compatible fixture seam. The production fleet has this table and therefore
        # always takes the fail-closed catalog path.
        return None
    out = {}
    for host, row in rows.items():
        if not isinstance(host, str) or not isinstance(row, dict):
            continue
        try:
            path = fm_path(row.get('path'), home)
        except ValueError:
            out[host.lower()] = None
            continue
        snap = _load_json(path, None)
        if isinstance(snap, dict):
            snap = dict(snap)
            snap['max_age_seconds'] = row.get('max_age_seconds', 86400)
        out[host.lower()] = snap
    return out


def _load_json(path, default):
    try:
        with open(path) as f:
            value = json.load(f)
        return value if isinstance(value, dict) else default
    except (OSError, ValueError, TypeError):
        return default


def _load_fleet(path):
    try:
        with open(path) as f:
            value = yaml.safe_load(f)
        return value if isinstance(value, dict) else None
    except (OSError, yaml.YAMLError, UnicodeError):
        return None


def _atomic_json(path, value):
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.%s.' % os.path.basename(path), suffix='.tmp', dir=directory)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(value, f, sort_keys=True)
            f.write('\n')
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _atomic_alert_append(path, line):
    """pass-5: one line appended atomically (a single write under O_APPEND) to the escalation log."""
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, line.encode('utf-8'))
    finally:
        os.close(fd)


def _route_lock(path):
    import fcntl
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    lock = open(path, 'a+')
    fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
    return lock


def _route_now():
    try:
        return float(os.environ.get('ROUTE_NOW', time.time()))
    except ValueError:
        return time.time()


def _binding_lane_fields(cfg, binding_id):
    """pass-9 (review): (harness, model, provider, effort) for a binding id in a loaded fleet table,
    or (None, why). Shared by the binding-lane CLI and route-pick (which resolves the pick under its
    lock from the same table it admitted it from). Effort defaults to medium."""
    bindings = cfg.get('bindings') if isinstance(cfg, dict) else None
    row = bindings.get(binding_id) if isinstance(bindings, dict) else None
    models = cfg.get('models') if isinstance(cfg, dict) else None
    model_row = models.get(row.get('model')) if isinstance(models, dict) and isinstance(row, dict) else None
    if (not isinstance(row, dict) or not isinstance(row.get('model'), str)
            or not isinstance(model_row, dict)):
        return None, 'unresolvable binding'
    # pass-8 (review): the SAME shared normalization route_pick applies before ban checks.
    norm = route_binding_lane_row(row)
    if norm is None:
        return None, 'binding row incomplete'
    effort = row.get('effort') if isinstance(row.get('effort'), str) and row.get('effort') else 'medium'
    launch_model = _route_model_id(row['model'], model_row)
    return (norm['harness'], launch_model, norm['provider'], effort), None


def _route_cli(a):
    paths = _route_paths()
    cmd = a[0]
    if cmd == 'binding-lane':
        # pass-5: `binding-lane <binding-id>` prints 'harness<TAB>model<TAB>provider<TAB>effort'
        # from the fleet.yaml bindings table (effort defaults to medium). Exit 2 when the binding
        # is unknown or invalid (or no fleet path exists), printing nothing on stdout - the sender
        # turns that into a refusal. Needs no lock: it reads only the fleet table.
        if len(a) != 2 or not paths['fleet']:
            return 2
        fields, err = _binding_lane_fields(_load_fleet(paths['fleet']), a[1])
        if fields is None:
            print('binding-lane: %s: %s' % (a[1], err), file=sys.stderr)
            return 2
        print('\t'.join(fields))
        return 0
    if not paths['lock']:
        print('WAIT\tFM_HOME is not set')
        return 0
    if cmd == 'route-pick':
        if len(a) != 5 or a[4].lower() not in ('yes', 'no'):
            print('WAIT\tusage: route-pick <role> <host> <author_family> <live_data yes|no>')
            return 0
        with _route_lock(paths['lock']):
            cfg = _load_fleet(paths['fleet']) if paths['fleet'] else None
            quota = _load_json(paths['quota'], {}) if paths['quota'] else {}
            bench = _load_json(paths['bench'], {'models': {}, 'cursor': {}}) if paths['bench'] else {'models': {}, 'cursor': {}}
            catalogs = _load_route_catalogs(cfg, os.environ.get('FM_HOME'))
            model, why = route_pick(a[1], a[2], a[3], a[4].lower() == 'yes', _route_now(), cfg, quota, bench,
                                    catalogs=catalogs)
            if model and paths['bench']:
                _atomic_json(paths['bench'], bench)
            # pass-9 (review): the ADMITTED binding's lane is resolved here, under the same lock
            # and from the same fleet table route_pick admitted it from, and printed after the
            # reason ('pick<TAB>why<TAB>harness<TAB>model<TAB>provider<TAB>effort'). The caller
            # uses these columns and never re-reads fleet.yaml for the pick. A bare-model pick
            # (or an unresolvable one) prints no lane columns.
            lane = _binding_lane_fields(cfg, model)[0] if model else None
        print('\t'.join([model or 'WAIT', why or '-'] + list(lane or ())))
        return 0
    if cmd == 'route-bench':
        # chief 4661: accepts a BINDING id (e.g. cat-jam@opencode); each binding carries its own 429
        # bench entry. Legacy model-id marks stay readable: a model mark applies to all its bindings.
        # pass-5 (chief): `route-bench <binding> [--reason 429|402|<text>]` classifies the reason.
        #   429 (or anything that is not an exhaustion signal): benched 30 min, nothing else changes.
        #   402 or exhaustion text ('insufficient credits', 'usage limit', 'weekly limit', 'quota
        #   exceeded', case-insensitive): benched until the binding's POOL reset_at, and the pool
        #   row in quota.json is written exhausted (used_pct 100, observed_at now, source 'bench').
        #   Pool reset unknown: benched 24 h AND one line is appended to state/route-alerts.log for
        #   escalation (the pool stays un-marked: a guessed exhaustion must not fake quota truth).
        if len(a) not in (2, 4) or (len(a) == 4 and a[2] != '--reason'):
            return 2
        reason = a[3] if len(a) == 4 else '429'
        now = _route_now()
        with _route_lock(paths['lock']):
            bench = _load_json(paths['bench'], {'models': {}, 'cursor': {}})
            cfg = _load_fleet(paths['fleet']) if paths['fleet'] else None
            quota_doc = _load_json(paths['quota'], {'pools': {}}) if paths['quota'] else {'pools': {}}
            bench, quota_doc, alerts = route_bench_apply(a[1], reason, now, cfg, quota_doc, bench)
            _atomic_json(paths['bench'], bench)
            if paths['quota'] and reason != '429' and not route_funds_stall(402 if reason == '402' else None, reason):
                _atomic_json(paths['quota'], quota_doc)
            for alert in alerts:
                if paths['alerts']:
                    _atomic_alert_append(paths['alerts'], '%d\t%s\n' % (now, alert))
        return 0
    if cmd == 'quota-set':
        if len(a) not in (5, 6) or (len(a) == 6 and a[5] != '--manual'):
            return 2
        try:
            used, reset = float(a[2]), float(a[3])
        except ValueError:
            return 2
        if (not math.isfinite(used) or not math.isfinite(reset) or
                not 0 <= used <= 100 or not a[1] or not a[4] or not paths['quota']):
            return 2
        with _route_lock(paths['lock']):
            doc = _load_json(paths['quota'], {'pools': {}})
            if not isinstance(doc.get('pools'), dict):
                doc['pools'] = {}
            doc['pools'][a[1]] = {
                'used_pct': used, 'reset_at': reset, 'source': a[4],
                'observed_at': _route_now(), 'manual': len(a) == 6,
            }
            _atomic_json(paths['quota'], doc)
        return 0
    if cmd == 'alerts':
        cfg = _load_fleet(paths['fleet']) if paths['fleet'] else None
        doc = _load_json(paths['quota'], {}) if paths['quota'] else {}
        now = _route_now()
        cfg_pools = cfg.get('pools', {}) if isinstance(cfg, dict) else {}
        quota_pools = doc.get('pools', {}) if isinstance(doc, dict) else {}
        cfg_pools = cfg_pools if isinstance(cfg_pools, dict) else {}
        quota_pools = quota_pools if isinstance(quota_pools, dict) else {}
        names = set(cfg_pools) | set(quota_pools)
        for name in sorted(names):
            rec = quota_pools.get(name)
            try:
                age = now - float(rec['observed_at'])
                used = float(rec['used_pct'])
            except (TypeError, KeyError, ValueError):
                print('STALE\t%s\tunknown' % name)
                continue
            if age > ROUTE_QUOTA_MAX_AGE:
                print('STALE\t%s\t%.1fh' % (name, age / 3600))
            if used >= 90:
                print('EXHAUSTION\t%s\t%.1f%%' % (name, used))
        return 0
    return None


def next_partition(used):
    for letter, text in PARTS:
        if letter not in used:
            return letter, text
    return None


CAN_START_LOAD5 = 6.0
CAN_START_MEM_KB = 4 * 1048576
CAN_START_PER_MIN = 2


def can_start(load5, mem_avail_kb, starts_last_minute):
    """The single start check (chief 4627 (1)): returns (n, why). n is how many netcup lane starts may happen now:
    0 when load5 >= 6 or MemAvailable < 4 GB, otherwise 2 minus the starts already made in the last 60 s (never below 0)."""
    if load5 >= CAN_START_LOAD5:
        return 0, 'load5 %.2f >= %g' % (load5, CAN_START_LOAD5)
    if mem_avail_kb < CAN_START_MEM_KB:
        return 0, 'MemAvailable %.1f GB < 4' % (mem_avail_kb / 1048576)
    n = max(0, CAN_START_PER_MIN - starts_last_minute)
    return n, ('ok' if n else '%d starts in the last minute (limit %d)' % (starts_last_minute, CAN_START_PER_MIN))


def starts_in_last_minute(ledger, now=None):
    """Starts in the last 60 s. A missing ledger is zero; any other read error counts as saturated (fail closed)."""
    now = time.time() if now is None else now
    try:
        return sum(1 for l in open(ledger) if l.strip().isdigit() and now - int(l) < 60)
    except FileNotFoundError:
        return 0
    except OSError:
        return CAN_START_PER_MIN


def ledger_writable(ledger):
    """True when a start can be recorded: the file is writable, or absent with a writable directory."""
    if os.path.exists(ledger):
        return os.access(ledger, os.R_OK | os.W_OK)
    return os.access(os.path.dirname(os.path.abspath(ledger)), os.W_OK | os.X_OK)


def note_start(ledger):
    """Record one start (epoch seconds), keep the last 50. Written via a temp file + os.replace in
    the ledger's own directory (pass-2 fix 6: the old open(ledger, 'w') truncated the ledger before
    rewriting). Returns True when the start was recorded; False when it could not be written - the
    caller (lane-refill one_start) then treats the start budget as exhausted, so a start that cannot
    be recorded stops every further start this pass."""
    try:
        if os.path.exists(ledger):
            with open(ledger) as f:
                existing = f.read().split()
        else:
            existing = []
        keep = [l for l in existing if l.isdigit()][-49:]
        content = '\n'.join(keep + [str(int(time.time()))]) + '\n'
        directory = os.path.dirname(os.path.abspath(ledger)) or '.'
        fd, tmp = tempfile.mkstemp(prefix='.refill-starts.', suffix='.tmp', dir=directory)
        try:
            with os.fdopen(fd, 'w') as f:
                f.write(content)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, ledger)
        except Exception:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise
        return True
    except OSError:
        return False


def _live_counter(path):
    return Counter(open(path).read().split())


def main(a):
    cmd = a[0]
    if cmd in ('route-admit', 'route-check', 'route-confirm', 'route-failure', 'route-cancel', 'route-ambiguous', 'route-classify'):
        import router_state_v31
        return router_state_v31.cli(a, sys.modules[__name__])
    if cmd == 'route-reviewer':   # route-reviewer <author_family> [live_data yes|no]: reviewer pick (or WAIT) by writer family (chief 4658)
        # pass-3 (S1): the local was named 'pick', which shadowed the pick() COMMAND in this scope
        # and made 'pick <cands.json> ...' raise UnboundLocalError. Renamed; the local name must
        # never collide with a command name again.
        if len(a) not in (2, 3) or (len(a) == 3 and a[2].lower() not in ('yes', 'no')):
            print('WAIT\tusage: route-reviewer <author_family> [live_data yes|no]')
            return 0
        reviewer_pick = route_reviewer(a[1], len(a) == 3 and a[2].lower() == 'yes')
        if reviewer_pick:
            print('%s\tapproved reviewer for writer family %s' % (reviewer_pick, a[1]))
        else:
            print('WAIT\tno approved reviewer for writer family %s' % a[1])
        return 0
    if cmd in ('route-pick', 'route-bench', 'quota-set', 'alerts', 'binding-lane'):
        return _route_cli(a)
    if cmd == 'can-start':   # can-start <ledger>  -> 'N<TAB>why', reading /proc/loadavg and /proc/meminfo
        la = float(open('/proc/loadavg').read().split()[1])
        mem = next(int(l.split()[1]) for l in open('/proc/meminfo') if l.startswith('MemAvailable:'))
        n, why = can_start(la, mem, starts_in_last_minute(a[1]))
        if n and not ledger_writable(a[1]):
            n, why = 0, 'start ledger %s is not writable (a start could not be recorded)' % a[1]
        print('%d\t%s' % (n, why))
    elif cmd == 'note-start':   # note-start <ledger>: record one start (epoch seconds), keep the last 50; exit 1 when the ledger could not be written
        return 0 if note_start(a[1]) else 1
    elif cmd == 'landed':
        sys.stdout.write(landed(open(a[1], errors='ignore').read()))
    elif cmd == 'supply':
        tracker, msgs, briefs, closed, live, t1 = a[1:7]
        prs = json.load(open(a[7])) if len(a) > 7 and a[7] else None   # main 2297: [{n,b,s,body}] from gh pr list --state all
        rows = {}
        for l in open(tracker):
            if l.strip():
                r = json.loads(l)
                rows[r['id']] = r
        closed_local = set()
        try:
            for l in open(closed):
                if l.strip():
                    q = json.loads(l)
                    if q.get('status') in ('closed', 'tombstone'):
                        closed_local.add(q['id'])
        except Exception:
            pass
        try:
            t1set = set(open(t1).read().split())
        except Exception:
            t1set = set()
        print(json.dumps(supply(rows, open(msgs, errors='ignore').read(), open(briefs, errors='ignore').read(), closed_local, _live_counter(live), t1set, prs)))
    elif cmd == 'pick':
        for host, c in pick(json.load(open(a[1])), _live_counter(a[2]), int(a[3]), int(a[4]), int(a[5]) if len(a) > 5 else 0):
            print(host, c['suf'], c['title'][:60])
    elif cmd == 'brief':
        p, cj, suf = a[1:4]
        c = [x for x in json.load(open(cj)) if x['suf'] == suf][0]
        t = open(p).read()
        if '{TASK}' in t and '{FIRSTMATE_SPEC}' in t:     # a retry after a failed spawn finds the brief already filled
            intent, spec = leaf_brief(c)
            spec += prior_attempts(c['id'], p)
            open(p, 'w').write(t.replace('{TASK}', intent, 1).replace('{FIRSTMATE_SPEC}', spec, 1))
    elif cmd == 'bosgame-reclaimable':
        print('\n'.join(sorted(BOSGAME_RECLAIMABLE)))
    elif cmd == 'bosgame-plan-live':
        # chief 2648 #2: a dos-planning*-bosgame-* .running marker counts only while bosgame's fresh snapshot shows that lane working;
        # with a stale or unreadable snapshot every marker counts (no undercount). Prints the marker paths that count.
        try:
            sd = json.load(open(a[1])); fresh = 0 <= time.time() - float(sd['ts']) <= SNAP_MAX_AGE
            lanes = {str(l.get('lane')): l for l in sd['lanes']}
        except (OSError, ValueError, KeyError, TypeError):
            fresh = False; lanes = {}
        for m in a[2:]:
            name = m.rsplit('/', 1)[-1][:-len('.running')]
            l = lanes.get(name)
            if not fresh or (l and is_working('state: working', str(l.get('last_verb') or ''), bool(l.get('agent_alive')))):
                print(m)
    elif cmd == 'bosgame-pending-sends':
        # chief 2648 #5: 'sent' rows under 45 min old whose leaf has no lane in the fresh snapshot (bosgame SM has not started it yet).
        # They count toward bos so a slow SM cannot take every leaf; after 45 min with no lane the send stops counting. Prints a count.
        try:
            sd = json.load(open(a[1]))
            names = {re.sub(r'^dos-bosgame-|-\d{4}$', '', str(l.get('lane', ''))) for l in sd['lanes']}
        except (OSError, ValueError, KeyError, TypeError):
            print(0); return
        last = {}
        for l in open(a[2]):
            f = l.rstrip('\n').split('\t')
            if len(f) >= 3 and f[0].isdigit():
                last[f[1]] = (int(f[0]), f[2])
        n = 0
        for leaf, (ts, st) in last.items():
            if st == 'sent' and time.time() - ts < 2700 and leaf.replace(PFX, '').replace('.', '-') not in names and leaf not in names:
                n += 1
        print(n)
    elif cmd == 'bosgame-live':
        # chief 2543: REST, not GraphQL (the GraphQL quota runs out under the fleet's load and the count then read 99 = no routing);
        # every PR updated recently, any state: open, merged or closed all mean the lane finished building (SO-5)
        done = set()
        for page in (1, 2, 3, 4):
            o = subprocess.run(['gh', 'api', 'repos/Authentis/decision-os/pulls?state=all&sort=updated&direction=desc&per_page=100&page=%d' % page,
                                '-q', '.[].head.ref'], capture_output=True, text=True, timeout=60)
            if o.returncode:
                print(99)
                return
            refs = o.stdout.split()
            done.update(refs)
            if len(refs) < 100:
                break
        print(bosgame_live(open(a[1], errors='ignore'), done, time.time()))
    elif cmd == 'open-prs':
        o = subprocess.run(['gh', 'pr', 'list', '--repo', 'Authentis/decision-os', '--state', 'open', '--limit', '200', '--json', 'headRefName'], capture_output=True, text=True, timeout=60)
        if o.returncode == 0:
            print('\n'.join(r['headRefName'] for r in json.loads(o.stdout)))
    elif cmd == 'bosgame-snapshot':
        n = bosgame_snapshot_live(a[1], time.time())
        print('none' if n is None else n)
    elif cmd == 'bosgame-gate-unknown':
        n = bosgame_gate_unknown(a[1])
        print('none' if n is None else n)
    elif cmd == 'free-model':
        # free-model <alive-file> <n> <eu 0|1> <failed 0|1> <hard 0|1>
        try:
            print(free_model(a[1], int(a[2]), a[3] == '1', a[4] == '1', a[5] == '1'))
        except (IndexError, ValueError):
            print('')
    elif cmd == 'alive':
        print(1 if has_agent(_procs(), a[1]) else 0)
    elif cmd == 'working':
        alive = {'1': True, '0': False}.get(a[3]) if len(a) > 3 else None
        print(1 if is_working(a[1], a[2] if len(a) > 2 else '', alive) else 0)
    elif cmd == 'busy-partitions':
        # chief 2692: gather every planning pass with a partition record and print the busy letters (one line, space separated)
        import glob, os
        home, snap, brf = a[1], a[2], a[3]
        try:
            sd = json.load(open(snap)); fresh = 0 <= time.time() - float(sd['ts']) <= SNAP_MAX_AGE
            lanes = {str(l.get('lane')): l for l in sd['lanes']}
        except (OSError, ValueError, KeyError, TypeError):
            fresh = False; lanes = {}
        try:
            open_br = set(open(brf).read().split())
        except OSError:
            open_br = None                            # unknown PR state: treat every pass as possibly landing (never undercount)
        passes = []; pids = []
        for pf in glob.glob(os.path.join(home, 'data', 'dos-planning*', 'partition')):
            pid = pf.split('/')[-2]
            letter = open(pf).read().strip()
            opr = True if open_br is None else any(b == 'fm/' + pid for b in open_br)
            if '-bosgame-' in pid:
                m = os.path.join(home, 'state', pid + '.running')
                age = time.time() - os.path.getmtime(m) if os.path.exists(m) else None
                l = lanes.get(pid)
                if l is None and age is None and not opr:
                    continue                          # never sent (no marker), no lane, no PR: an old record
                sf = os.path.join(home, 'data', pid, 'seen-final')
                v = str((l or {}).get('last_verb') or '').strip().split(' ', 1)[0].split('[', 1)[0].rstrip(':')
                if fresh and l is not None and v in ('done', 'cancelled') and not os.path.exists(sf):
                    try:
                        open(sf, 'w').write('%d %s\n' % (time.time(), v))   # FM 3244: remember a final pass after it leaves the snapshot
                    except OSError:
                        pass
                cs_eligible = age is not None and l is None and fresh and not opr
                cs = closed_pr_for('fm/' + pid) if cs_eligible else None   # tri-state: True proved / False proved-none / None unknown
                p = dict(kind='bosgame', status=str((l or {}).get('last_verb') or ''), open_pr=opr, in_snapshot=l is not None,
                         marker_age=age, marker_path=m if age is not None else None, snapshot_fresh=fresh, seen_final=os.path.exists(sf),
                         closed_pr=bool(cs) if cs is not None else False, closed_state=cs, pr_branch='fm/' + pid)
                if pass_busy(p) and try_expire_marker(p):
                    p = dict(p, expired=True)         # packet-4102 change 4: preservation rename succeeded, partition released
            else:
                if not os.path.exists(os.path.join(home, 'state', pid + '.meta')) and not os.path.exists(os.path.join(home, 'state', pid + '.status')):   # teardown removes both
                    if open_br is None:               # chief 2700: PR state unknown, so a torn-down pass may still have an open PR: reserve it
                        passes.append((letter, dict(kind='netcup', status='done', open_pr=True))); pids.append(pid)
                    continue                          # torn down: with a known PR list, the open-branch check below covers it
                try:
                    last = open(os.path.join(home, 'state', pid + '.status')).read().strip().splitlines()[-1]
                except (OSError, IndexError):
                    last = ''
                p = dict(kind='netcup', status=last, open_pr=opr)
            passes.append((letter, p)); pids.append(pid)
        # a torn-down netcup pass whose PR is still open keeps its range busy too
        for pf in glob.glob(os.path.join(home, 'data', 'dos-planning*', 'partition')):
            pid = pf.split('/')[-2]
            if '-bosgame-' not in pid and not os.path.exists(os.path.join(home, 'state', pid + '.meta')) and open_br is not None and ('fm/' + pid) in open_br:
                passes.append((open(pf).read().strip(), dict(kind='netcup', status='done', open_pr=True))); pids.append(pid)
        print(' '.join(sorted(busy_partitions(passes))))
        if len(a) > 4:                            # row claims (chief 4373): which passes are busy, by pass id
            json.dump({pid: letter for pid, (letter, p) in zip(pids, passes) if letter and pass_busy(p)}, open(a[4], 'w'))
    elif cmd == 'row-claims':
        # row-claims <home> <authority.tsv> <busy.json> <open-branches file> <clone> <letters...>: prints "<letter>|<row>,<row>,..." or nothing
        try:
            open_br = set(open(a[4]).read().split())
        except OSError:
            open_br = None
        r = row_claims(a[1], a[2], json.load(open(a[3])), open_br, a[5], a[6:])
        if r:
            print('%s|%s' % (r[0], ','.join(r[1])))
    elif cmd == 'partition':
        r = next_partition(set(a[1:]))
        print(f'{r[0]}|{r[1]}' if r else '')


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
