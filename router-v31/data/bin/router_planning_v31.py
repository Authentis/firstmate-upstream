#!/usr/bin/env python3
"""Chief 4894/4895: durable planning demand, budget reservations and landed yield.

No provider calls. The lane adapter supplies verified launches. Completion needs
runner usage accounting AND a commit already reachable from cached origin/main.
"""
import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

FLOOR = 25
TARGET = 50
PASS_TOKENS = 300000
DAY_TOKENS = 1000000


def day(now):
    return datetime.fromtimestamp(now, timezone.utc).date().isoformat()


def read_rows(path):
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    if any(not isinstance(r, dict) or not isinstance(r.get('id'), str) for r in rows):
        raise ValueError('invalid tracker')
    return rows


class Controller:
    def __init__(self, home):
        self.home = Path(home).resolve()
        self.path = self.home / 'state/planning-v31.json'
        self.path.parent.mkdir(parents=True, exist_ok=True)

    @contextmanager
    def locked(self):
        with self.path.with_suffix('.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def load(self):
        if not self.path.exists():
            return dict(v=1, active=False, cycle=0, passes=[])
        state = json.loads(self.path.read_text())
        if state.get('v') != 1 or not isinstance(state.get('passes'), list):
            raise ValueError('invalid planning state')
        return state

    def save(self, state):
        tmp = self.path.with_name(self.path.name + f'.tmp-{os.getpid()}')
        with tmp.open('w') as f:
            json.dump(state, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)

    def next(self, rows, candidates, authority, busy, now, baseline):
        with self.locked():
            state = self.load()
            candidates = [r for r in candidates if not r.get('overlap')]
            supply = len(candidates)
            def wait(reason):
                self.save(state)
                return dict(action='WAIT', reason=reason, supply=supply)
            if supply >= TARGET:
                state['active'] = False
                return wait('target reached')
            if any(p['state'] not in ('complete', 'failed') for p in state['passes']):
                return wait('last pass yield pending')
            if not state['active']:
                if supply >= FLOOR:
                    return wait('supply above trigger')
                state['active'] = True
                state['cycle'] += 1
            history = [p for p in state['passes'] if p['cycle'] == state['cycle'] and p['state'] != 'failed']
            attempts = [p for p in state['passes'] if p['cycle'] == state['cycle']]
            last_failure = attempts[-1] if attempts and attempts[-1]['state'] == 'failed' else None
            completed = [p for p in history if p['state'] == 'complete']
            if len(completed) >= 3 and supply < FLOOR:
                alert = self.home / 'data/planning-chief-alert.txt'
                alert.parent.mkdir(parents=True, exist_ok=True)
                alert.write_text(f'chief 4894/4895: {len(completed)} passes left supply={supply} under 25; inspect planning-yields-v31.jsonl\n')
            if len(history) >= 3:
                return wait('three planning passes exhausted')
            used_partitions = {p['partition'] for p in history}
            used_rows = {i for p in history for i in p['rows']}
            # Every next pass must inspect the previous LANDED yield, including
            # zero-yield completions. Unlanded PRs never release this barrier.
            if history and history[-1]['state'] != 'complete':
                return wait('last pass yield pending')
            spent = sum(p.get('tokens', PASS_TOKENS) for p in state['passes']
                        if p['state'] not in ('complete', 'failed') or p['day'] == day(now) or day(p.get('completed_at', p['reserved_at'])) == day(now))
            if spent + PASS_TOKENS > DAY_TOKENS:
                return wait('daily token budget')
            if len(set(busy)) >= 3:
                return wait('three partitions busy')
            by_id = {r['id']: r for r in rows}
            owner = {}
            for part, ids in authority.items():
                for row in ids:
                    if row in owner and owner[row] != part:
                        return wait('authority partitions overlap')
                    owner[row] = part
            # Shared parents/ancestry also violate partition disjointness.
            parents = {}
            for row_id, part in owner.items():
                for dep in by_id.get(row_id, {}).get('dependencies', []):
                    if dep.get('type') == 'parent-child':
                        parent = dep.get('depends_on_id')
                        if parent in owner and owner[parent] != part:
                            return wait('authority parents overlap')
                        if parent in parents and parents[parent] != part:
                            return wait('authority parents overlap')
                        parents[parent] = part
            for partition, ids in authority.items():
                if partition in busy or partition in used_partitions or set(ids) & used_rows:
                    continue
                selected = []
                for row_id in ids:
                    r = by_id.get(row_id, {})
                    labels = r.get('labels')
                    if (r.get('status') != 'open' or r.get('assignee') or
                        not isinstance(labels, list) or any(not isinstance(x, str) for x in labels)):
                        continue
                    desc = str(r.get('description') or '')
                    unspecced = 'needs-spec' in labels or ('spec-ready' not in labels and 'FILES:' not in desc)
                    split = any(x == 'split-after' or x.startswith('split-after:') for x in labels) or bool(re.search(r'\bsplit-after\b', desc, re.I))
                    if unspecced or split:
                        selected.append(row_id)
                if selected:
                    request = dict(action='START', task=f'dos-planning-v31-{len(state["passes"])+1}-{int(now)}',
                                   partition=partition, rows=selected, token_budget=PASS_TOKENS,
                                   supply=supply, cycle=state['cycle'], baseline=baseline,
                                   before=[r['id'] for r in candidates],
                                   after_binding=last_failure['binding'] if last_failure and last_failure['day'] == day(now) else '')
                    self.save(state)
                    return request
            return wait('no unspecced disjoint partition')

    def reserve(self, request, binding, model, host, incarnation, now):
        with self.locked():
            state = self.load()
            if request.get('action') != 'START' or request.get('token_budget') != PASS_TOKENS or request.get('cycle') != state['cycle']:
                raise ValueError('invalid planning request')
            if any(p['state'] not in ('complete', 'failed') for p in state['passes']):
                raise ValueError('last pass yield pending')
            spent = sum(p.get('tokens', PASS_TOKENS) for p in state['passes'] if p['state'] not in ('complete', 'failed') or p['day'] == day(now) or day(p.get('completed_at', p['reserved_at'])) == day(now))
            if spent + PASS_TOKENS > DAY_TOKENS:
                raise ValueError('daily token budget')
            if any(p['task'] == request['task'] for p in state['passes']):
                raise ValueError('duplicate task')
            row = dict(request, state='reserved', binding=binding, model=model, host=host,
                       incarnation=incarnation, day=day(now), reserved_at=now)
            state['passes'].append(row)
            self.save(state)
            return row

    def fail(self, result, now):
        """Release a definitely exited attempt; keep all usage charged.

        Ambiguous/running workers must never use this path. The runner writes
        this marker only for a definite local exit or authoritative rejection.
        """
        with self.locked():
            state = self.load()
            p = next((p for p in state['passes'] if p['task'] == result.get('task')), None)
            if p is None:
                raise ValueError('unknown failed planning task')
            if (result.get('v') != 1 or result.get('definitive') is not True or
                result.get('incarnation') != p['incarnation'] or result.get('model') != p['model'] or
                type(result.get('tokens')) is not int or result['tokens'] < 0 or
                not isinstance(result.get('reason'), str) or not result['reason']):
                raise ValueError('invalid definitive planning failure')
            if p['state'] == 'complete':
                raise ValueError('completed pass cannot be failed')
            if p['state'] == 'failed':
                return p
            p.update(state='failed', tokens=result['tokens'], failure=result['reason'], completed_at=now)
            self.save(state)
            return p

    def runner_completion(self, p, usage, clone):
        """Join provider usage to a task-attributed commit already cached on main."""
        if (usage.get('v') != 1 or usage.get('task') != p['task'] or
            usage.get('incarnation') != p['incarnation'] or usage.get('model') != p['model'] or
            usage.get('token_cap') != PASS_TOKENS or usage.get('runner_exit') != 0 or
            type(usage.get('tokens')) is not int or not 0 <= usage['tokens'] <= PASS_TOKENS):
            return None
        trailer = 'Planning-task: ' + p['task']
        commits = subprocess.run(['git', '-C', str(clone), 'log', '--format=%H',
                                  '--fixed-strings', '--grep=' + trailer,
                                  p['baseline'] + '..origin/main', '--', '.beads/issues.jsonl'],
                                 capture_output=True, text=True, timeout=20)
        if commits.returncode:
            return None
        for commit in commits.stdout.splitlines():
            body = subprocess.run(['git', '-C', str(clone), 'show', '-s', '--format=%B', commit],
                                  capture_output=True, text=True, timeout=20)
            if body.returncode == 0 and trailer in body.stdout.splitlines():
                return dict(v=1, task=p['task'], incarnation=p['incarnation'], model=p['model'],
                            token_cap=PASS_TOKENS, tokens=usage['tokens'], landed_commit=commit)
        return None

    def complete(self, result, candidates, clone, now):
        with self.locked():
            state = self.load()
            p = next((p for p in state['passes'] if p['task'] == result.get('task')), None)
            if p is None:
                raise ValueError('unknown planning result')
            if p['state'] == 'complete':
                self.publish_log(state)
                return p['yield']
            tokens = result.get('tokens')
            if (result.get('v') != 1 or result.get('incarnation') != p['incarnation'] or
                result.get('model') != p['model'] or result.get('token_cap') != PASS_TOKENS or
                type(tokens) is not int or not 0 <= tokens <= PASS_TOKENS):
                raise ValueError('usage receipt invalid or over budget')
            commit = result.get('landed_commit', '')
            if not re.fullmatch(r'[0-9a-f]{40,64}', commit):
                raise ValueError('landed commit missing')
            def git(*args):
                r = subprocess.run(['git', '-C', str(clone), *args], capture_output=True, text=True, timeout=20)
                if r.returncode:
                    raise ValueError('landed commit proof failed')
                return r.stdout
            git('merge-base', '--is-ancestor', commit, 'origin/main')
            baseline = p.get('baseline', '')
            if not re.fullmatch(r'[0-9a-f]{40,64}', baseline) or commit == baseline:
                raise ValueError('landing must follow pass baseline')
            git('merge-base', '--is-ancestor', baseline, commit)
            after = {r['id']: r for r in map(json.loads, git('show', commit + ':.beads/issues.jsonl').splitlines()) if r}
            before = {r['id']: r for r in map(json.loads, git('show', commit + '^:.beads/issues.jsonl').splitlines()) if r}
            changed = {i for i in after if before.get(i) != after[i]}
            def scoped(i, seen=None):
                seen = set() if seen is None else seen
                if i in seen:
                    return False
                if i in p['rows']:
                    return True
                seen.add(i)
                return any(scoped(d.get('depends_on_id'), seen) for d in after.get(i, {}).get('dependencies', []) if d.get('type') == 'parent-child')
            landed = sorted({r['id'] for r in candidates if not r.get('overlap') and r['id'] in changed and r['id'] not in p['before'] and scoped(r['id'])})
            p.update(state='complete', tokens=tokens, **{'yield': len(landed)}, landed=landed, landed_commit=commit, completed_at=now)
            # Write state first. JSONL rebuild is idempotent after interruption.
            self.save(state)
            self.publish_log(state)
            return len(landed)

    def publish_log(self, state):
        log = self.home / 'data/planning-yields-v31.jsonl'
        log.parent.mkdir(parents=True, exist_ok=True)
        temp = log.with_name(log.name + f'.tmp-{os.getpid()}')
        with temp.open('w') as f:
            for p in state['passes']:
                if p['state'] == 'complete':
                    f.write(json.dumps({k: p[k] for k in ('task', 'partition', 'binding', 'model', 'host', 'tokens', 'yield', 'landed_commit', 'completed_at')}) + '\n')
        os.replace(temp, log)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('command', choices=['next', 'reserve', 'fail'])
    parser.add_argument('--home', required=True)
    parser.add_argument('--tracker')
    parser.add_argument('--candidates')
    parser.add_argument('--clone')
    parser.add_argument('--busy', default='')
    parser.add_argument('--request')
    parser.add_argument('--binding')
    parser.add_argument('--model')
    parser.add_argument('--host')
    parser.add_argument('--incarnation')
    parser.add_argument('--task')
    parser.add_argument('--reason')
    parser.add_argument('--tokens', type=int, default=0)
    args = parser.parse_args()
    try:
        c = Controller(args.home)
        now = time.time()
        if args.command == 'fail':
            state = c.load()
            p = next((p for p in state['passes'] if p['task'] == args.task), None)
            if p is None:
                raise ValueError('unknown failed planning task')
            out = c.fail(dict(v=1, task=args.task, incarnation=args.incarnation,
                              model=p['model'], tokens=args.tokens, reason=args.reason, definitive=True), now)
        elif args.command == 'reserve':
            out = c.reserve(json.loads(Path(args.request).read_text()), args.binding, args.model, args.host, args.incarnation, now)
        else:
            candidates = json.loads(Path(args.candidates).read_text())
            state = c.load()
            for p in state['passes']:
                if p['state'] not in ('complete', 'failed'):
                    directory = c.home / 'data' / p['task']
                    failed = directory / 'planning-failure.json'
                    path = directory / 'planning-result.json'
                    if failed.exists():
                        result = json.loads(failed.read_text())
                        c.fail(result, now)
                        # Reconcile the canonical admission as well as the
                        # planning budget, so quota failures release capacity
                        # and bench the exhausted binding before fallback.
                        sidecar = c.home / 'state/route-launches' / (p['task'] + '.json')
                        if sidecar.exists():
                            observed = subprocess.run([sys.executable, str(Path(__file__).with_name('refill_lib_v2.py')),
                                'route-failure', p['task'], p['incarnation'], 'planning-runner-terminal',
                                '1', result.get('reason', 'runner failed')],
                                env=dict(os.environ, FM_HOME=str(c.home)), capture_output=True, text=True, timeout=20)
                            if observed.returncode:
                                raise ValueError('planning route failure reconciliation failed')
                        message = datetime.fromtimestamp(now, timezone.utc).isoformat() + ' reason=' + result['reason'] + ' model=' + p['model'] + '\n'
                        with (c.home / 'state/planning-blocked.alert').open('a') as alert:
                            alert.write(message)
                        print('PLANNING blocked: ' + result['reason'] + '; trying next model', file=sys.stderr)
                    elif path.exists():
                        c.complete(json.loads(path.read_text()), candidates, args.clone, now)
                    elif (directory / 'planning-usage.json').exists():
                        result = c.runner_completion(p, json.loads((directory / 'planning-usage.json').read_text()), args.clone)
                        if result is not None:
                            c.complete(result, candidates, args.clone, now)
                    blocked = directory / 'planning-blocked.json'
                    current = next(row for row in c.load()['passes'] if row['task'] == p['task'])
                    if blocked.exists() and current['state'] not in ('complete', 'failed'):
                        notice = json.loads(blocked.read_text())
                        if (notice.get('v') != 1 or notice.get('task') != p['task'] or
                            notice.get('incarnation') != p['incarnation'] or notice.get('model') != p['model'] or
                            not isinstance(notice.get('reason'), str) or not notice['reason']):
                            raise ValueError('invalid planning blocked marker')
                        reason = notice['reason'].replace('\n', ' ')[:400]
                        with (c.home / 'state/planning-blocked.alert').open('a') as alert:
                            alert.write(datetime.fromtimestamp(now, timezone.utc).isoformat() + ' reason=' + reason + ' model=' + p['model'] + '\n')
                        print('PLANNING blocked: ' + reason + '; reservation retained', file=sys.stderr)
            import refill_lib_v2 as R
            authority, parents, excludes = R._authority(c.home / 'data/t1-plan-authority.tsv')
            authority = {k: [i for i in ids if i not in excludes] for k, ids in authority.items()}
            # Authority parent proof covers parents absent from the tracker too.
            parent_owner = {}
            for (part, row), parent in parents.items():
                if parent and parent in parent_owner and parent_owner[parent] != part:
                    raise ValueError('authority parents overlap')
                if parent:
                    parent_owner[parent] = part
            baseline = subprocess.run(['git', '-C', args.clone, 'rev-parse', '--verify', 'origin/main'],
                                      capture_output=True, text=True, timeout=20)
            if baseline.returncode or not re.fullmatch(r'[0-9a-f]{40,64}', baseline.stdout.strip()):
                raise ValueError('cached main baseline unavailable')
            out = c.next(read_rows(args.tracker), candidates, authority, args.busy.split(), now, baseline.stdout.strip())
        print(json.dumps(out))
        return 0
    except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as e:
        print(json.dumps(dict(action='WAIT', reason=str(e))))
        return 75


if __name__ == '__main__':
    raise SystemExit(main())
