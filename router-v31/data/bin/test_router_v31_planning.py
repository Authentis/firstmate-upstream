#!/usr/bin/env python3
"""Offline tests for chief 4894/4895 planning feedback and budget controller."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(__file__).resolve().parent
MODULE = BIN / 'router_planning_v31.py'


class Planning(unittest.TestCase):
    def setUp(self):
        self.assertTrue(MODULE.exists(), 'planning trigger controller missing')
        spec = importlib.util.spec_from_file_location('planner', MODULE)
        self.P = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.P)
        self.home = Path(tempfile.mkdtemp(prefix='planning-'))
        (self.home / 'state').mkdir()
        (self.home / 'data').mkdir()
        self.now = 1800000000
        self.rows = [dict(id='parent-a', status='open', labels=['needs-spec']),
                     dict(id='parent-b', status='open', labels=['split-after']),
                     dict(id='parent-c', status='open', labels=['needs-spec']),
                     dict(id='ready', status='open', labels=['spec-ready'], description='FILES: core/a.py')]
        self.authority = {'A': ['parent-a'], 'B': ['parent-b'], 'C1': ['parent-c'], 'D': ['ready']}
        self.c = self.P.Controller(self.home)
        self.repo = self.home / 'repo'
        self.repo.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        (self.repo / '.beads').mkdir()
        (self.repo / '.beads/issues.jsonl').write_text('\n'.join(json.dumps(r) for r in self.rows) + '\n')
        self.git('add', '.beads/issues.jsonl'); self.git('commit', '-qm', 'before')
        self.git('update-ref', 'refs/remotes/origin/main', self.git('rev-parse', 'HEAD'))

    def git(self, *args):
        p = subprocess.run(['/usr/bin/git', '-C', str(self.repo), *args], text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def next(self, n, busy=()):
        return self.c.next(self.rows, [{'id': f'existing-{i}'} for i in range(n)], self.authority, busy, self.now, self.git('rev-parse', 'origin/main'))

    def reserve(self, request=None):
        request = request or self.next(24)
        return self.c.reserve(request, 'sol-plan@pi', 'openai-codex/gpt-6.1-sol', 'netcup', 'inc-1', self.now)

    def complete(self, request, count=0, tokens=10000):
        # Real local git history is the proof, no network or model invocation.
        repo = self.repo
        git = self.git
        tracker = repo / '.beads/issues.jsonl'
        fresh = [dict(id=f'landed-{request["task"]}-{i}', status='open', labels=['spec-ready'],
                      description='FILES: core/x.py', dependencies=[dict(type='parent-child', depends_on_id=request['rows'][0])]) for i in range(count)]
        tracker.write_text(tracker.read_text() + ''.join(json.dumps(r) + '\n' for r in fresh))
        git('add', '.beads/issues.jsonl'); git('commit', '--allow-empty', '-qm', 'plan leaves')
        commit = git('rev-parse', 'HEAD')
        git('update-ref', 'refs/remotes/origin/main', commit)
        result = dict(v=1, task=request['task'], incarnation='inc-1', model='openai-codex/gpt-6.1-sol',
                      tokens=tokens, token_cap=300000, landed_commit=commit)
        return self.c.complete(result, fresh, repo, self.now + 1)

    def test_definitive_failure_releases_yield_barrier_and_advances_model(self):
        req = self.next(1); self.reserve(req)
        self.assertTrue(hasattr(self.c, 'fail'), 'controller must reconcile definitive runner failures')
        self.c.fail(dict(v=1, task=req['task'], incarnation='inc-1',
                         model='openai-codex/gpt-6.1-sol', tokens=120,
                         reason='provider quota exhausted', definitive=True), self.now)
        nxt = self.next(1)
        self.assertEqual(nxt['action'], 'START')
        self.assertEqual(nxt['after_binding'], 'sol-plan@pi')
        self.assertEqual(nxt['partition'], 'A')
        self.assertNotEqual(nxt['task'], req['task'])
        self.assertEqual(self.c.load()['passes'][0]['tokens'], 120)

    def test_failure_marker_requires_exact_identity_and_terminal_proof(self):
        req = self.next(1); self.reserve(req)
        self.assertTrue(hasattr(self.c, 'fail'), 'controller failure reconciliation missing')
        for overrides in ({'incarnation': 'wrong'}, {'definitive': False}, {'tokens': -1}):
            record = dict(v=1, task=req['task'], incarnation='inc-1',
                          model='openai-codex/gpt-6.1-sol', tokens=300000,
                          reason='quota stop', definitive=True)
            record.update(overrides)
            with self.assertRaises(ValueError):
                self.c.fail(record, self.now)
        self.assertEqual(self.next(1)['reason'], 'last pass yield pending')

    def test_failed_overrun_keeps_real_usage_and_blocks_daily_budget(self):
        req = self.next(1); self.reserve(req)
        self.assertTrue(hasattr(self.c, 'fail'), 'controller failure accounting missing')
        self.c.fail(dict(v=1, task=req['task'], incarnation='inc-1',
                         model='openai-codex/gpt-6.1-sol', tokens=1000001,
                         reason='token overrun', definitive=True), self.now)
        self.assertEqual(self.c.load()['passes'][0]['tokens'], 1000001)
        self.assertEqual(self.next(1)['reason'], 'daily token budget')

    def test_usage_waits_for_matching_landed_task_trailer(self):
        req = self.next(1); p = self.reserve(req)
        self.assertTrue(hasattr(self.c, 'runner_completion'), 'metered runner landing reconciliation missing')
        usage = dict(v=1, task=p['task'], incarnation=p['incarnation'], model=p['model'],
                     tokens=12000, token_cap=300000, runner_exit=0)
        self.assertIsNone(self.c.runner_completion(p, usage, self.repo))
        tracker = self.repo / '.beads/issues.jsonl'
        tracker.write_text(tracker.read_text() + json.dumps(dict(id='new-leaf', status='open',
            labels=['spec-ready'], dependencies=[dict(type='parent-child', depends_on_id='parent-a')])) + '\n')
        self.git('add', '.beads/issues.jsonl')
        self.git('commit', '-qm', 'tracker planning\n\nPlanning-task: ' + p['task'])
        self.git('update-ref', 'refs/remotes/origin/main', 'HEAD')
        result = self.c.runner_completion(p, usage, self.repo)
        self.assertEqual(result['landed_commit'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(self.c.complete(result, [dict(id='new-leaf')], self.repo, self.now), 1)
        self.assertIsNone(self.c.runner_completion(p, dict(usage, incarnation='wrong'), self.repo))

    def test_next_cli_consumes_exited_quota_failure_and_offers_next_binding(self):
        self.now = __import__('time').time()
        req = self.next(1); self.reserve(req)
        directory = self.home / 'data' / req['task']; directory.mkdir()
        (directory / 'planning-failure.json').write_text(json.dumps(dict(v=1, task=req['task'],
            incarnation='inc-1', model='openai-codex/gpt-6.1-sol', tokens=123,
            reason='provider quota stopped', definitive=True)))
        (self.home / 'data/t1-plan-authority.tsv').write_text('A\tparent-a\troot-a\n')
        candidates = self.home / 'data/candidates.json'; candidates.write_text('[]')
        result = subprocess.run([__import__('sys').executable, str(MODULE), 'next',
            '--home', str(self.home), '--tracker', str(self.repo / '.beads/issues.jsonl'),
            '--candidates', str(candidates), '--clone', str(self.repo)],
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(result.stdout)['after_binding'], 'sol-plan@pi')
        self.assertIn('trying next model', result.stderr)
        self.assertIn('provider quota stopped', (self.home / 'state/planning-blocked.alert').read_text())
        self.assertEqual(self.c.load()['passes'][0]['state'], 'failed')

    def test_threshold_hysteresis_and_last_yield_required(self):
        self.assertEqual(self.next(25)['action'], 'WAIT')
        req = self.next(24)
        self.assertEqual(req['action'], 'START')
        self.reserve(req)
        self.assertEqual(self.next(40)['reason'], 'last pass yield pending')
        self.complete(req, count=2)
        self.assertEqual(self.next(40)['action'], 'START')
        self.assertEqual(self.next(50)['action'], 'WAIT')
        self.assertEqual(self.next(49)['action'], 'WAIT')

    def test_ambiguous_remote_launch_alerts_every_tick_and_keeps_reservation(self):
        self.now = __import__('time').time()
        req = self.next(1); p = self.reserve(req)
        directory = self.home / 'data' / req['task']; directory.mkdir()
        (directory / 'planning-blocked.json').write_text(json.dumps(dict(v=1, task=p['task'],
            incarnation=p['incarnation'], model=p['model'], reason='remote delivery ambiguous')))
        (self.home / 'data/t1-plan-authority.tsv').write_text('A\tparent-a\troot-a\n')
        candidates = self.home / 'data/candidates.json'; candidates.write_text('[]')
        for _ in range(2):
            result = subprocess.run([__import__('sys').executable, str(MODULE), 'next',
                '--home', str(self.home), '--tracker', str(self.repo / '.beads/issues.jsonl'),
                '--candidates', str(candidates), '--clone', str(self.repo)],
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)['reason'], 'last pass yield pending')
            self.assertIn('remote delivery ambiguous', result.stderr)
        self.assertEqual(len((self.home / 'state/planning-blocked.alert').read_text().splitlines()), 2)
        self.assertEqual(self.c.load()['passes'][0]['state'], 'reserved')

    def test_only_unspecced_or_split_rows_and_disjoint_partitions(self):
        self.assertEqual(self.next(24, ['A'])['partition'], 'B')
        self.assertEqual(self.next(24, ['A', 'B'])['partition'], 'C1')
        self.assertEqual(self.next(24, ['A', 'B', 'C1'])['action'], 'WAIT')
        self.rows[2]['labels'] = None
        self.assertEqual(self.next(24, ['A', 'B'])['action'], 'WAIT')
        self.assertEqual(self.next(24, ['X', 'Y', 'Z'])['action'], 'WAIT')
        self.authority['B'].append('parent-a')
        self.assertEqual(self.next(24)['action'], 'WAIT', 'shared authority rows must fail closed')

    def test_pass_and_daily_budget_reservations(self):
        req = self.next(1)
        self.assertEqual(req['token_budget'], 300000)
        self.reserve(req)
        self.complete(req, tokens=300000)
        for _ in range(2):
            req = self.next(1); self.reserve(req); self.complete(req, tokens=300000)
        self.next(50)  # close this three-partition cycle; daily cap spans cycles
        self.assertEqual(self.next(1)['reason'], 'daily token budget')
        self.now += 86400
        self.assertEqual(self.next(1)['action'], 'START')

    def test_actual_usage_releases_reservation_and_logs_yield_model_tokens(self):
        req = self.next(1); self.reserve(req)
        self.assertEqual(self.complete(req, count=3, tokens=12000), 3)
        log = [json.loads(l) for l in (self.home / 'data/planning-yields-v31.jsonl').read_text().splitlines()]
        self.assertEqual(log[-1]['yield'], 3)
        self.assertEqual(log[-1]['tokens'], 12000)
        self.assertEqual(log[-1]['model'], 'openai-codex/gpt-6.1-sol')
        self.assertEqual(self.next(40)['token_budget'], 300000)

    def test_three_completed_passes_under_floor_alert_chief(self):
        for _ in range(3):
            req = self.next(2); self.reserve(req); self.complete(req)
        self.assertEqual(self.next(2)['action'], 'WAIT')
        self.assertEqual(self.next(40)['action'], 'WAIT')
        self.now += 86400
        self.assertEqual(self.next(2)['action'], 'WAIT')
        alert = self.home / 'data/planning-chief-alert.txt'
        self.assertTrue(alert.exists())
        self.assertIn('3 passes', alert.read_text())
        self.assertIn('supply=2', alert.read_text())

    def test_pending_pass_blocks_a_new_cycle_after_target_reset(self):
        req = self.next(1); self.reserve(req)
        self.next(50)
        self.assertEqual(self.next(1)['action'], 'WAIT')
        self.assertEqual(self.next(1)['reason'], 'last pass yield pending')

    def test_completed_partitions_are_not_replanned_in_the_same_cycle(self):
        parts = []
        for _ in range(3):
            req = self.next(2)
            parts.append(req['partition'])
            self.reserve(req); self.complete(req)
        self.assertEqual(parts, ['A', 'B', 'C1'])
        self.assertEqual(self.next(2)['action'], 'WAIT')

    def test_overlapped_candidates_do_not_count_as_dispatchable_supply(self):
        candidates = [dict(id=f'blocked-{i}', overlap=['active-task']) for i in range(25)]
        req = self.c.next(self.rows, candidates, self.authority, [], self.now, self.git('rev-parse', 'origin/main'))
        self.assertEqual(req['action'], 'START')
        self.assertEqual(req['supply'], 0)
        self.assertEqual(req['before'], [])

    def test_old_landed_commit_cannot_release_a_new_pass_yield_barrier(self):
        req = self.next(1); self.reserve(req); self.complete(req, count=1)
        old = self.git('rev-parse', 'HEAD')
        req = self.next(1); self.reserve(req)
        result = dict(v=1, task=req['task'], incarnation='inc-1', model='openai-codex/gpt-6.1-sol',
                      tokens=10000, token_cap=300000, landed_commit=old)
        with self.assertRaises(ValueError):
            self.c.complete(result, [], self.repo, self.now)
        self.assertEqual(self.next(1)['reason'], 'last pass yield pending')

    def test_unknown_or_over_budget_usage_stays_pending(self):
        req = self.next(1); self.reserve(req)
        with self.assertRaises(ValueError):
            self.complete(req, tokens=300001)
        self.assertEqual(self.next(1)['reason'], 'last pass yield pending')

    def test_fail_closed_without_proof_of_landing(self):
        req = self.next(1); self.reserve(req)
        result = dict(v=1, task=req['task'], incarnation='inc-1', model='openai-codex/gpt-6.1-sol',
                      tokens=10000, token_cap=300000, landed_commit='a'*40)
        with self.assertRaises(ValueError):
            self.c.complete(result, [], self.home, self.now)
        self.assertEqual(self.next(1)['action'], 'WAIT')

    def test_yield_not_credited_for_unrelated_or_preexisting_dispatchable(self):
        req = self.next(24); self.reserve(req)
        self.assertEqual(self.complete(req, count=0), 0)

    def test_midnight_usage_is_charged_to_completion_day_too(self):
        req = self.next(1); self.reserve(req)
        self.now += 86400
        self.complete(req, tokens=300000)
        for _ in range(2):
            req = self.next(1); self.reserve(req); self.complete(req, tokens=300000)
        self.next(50)
        self.assertEqual(self.next(1)['reason'], 'daily token budget')

    def test_waiting_controller_does_not_reserve_a_priority_slot(self):
        src = (BIN / 'lane-refill-v2.sh').read_text()
        self.assertNotIn('PLANWANT', src)
        self.assertLess(src.index('router_planning_tick || exit 1'), src.index('# 3a. priority lanes:'))

    def test_lane_invokes_budgeted_controller_and_no_legacy_auto_planning(self):
        src = (BIN / 'lane-refill-v2.sh').read_text()
        self.assertIn('router-planning.sh', src)
        self.assertNotIn('spawn_retry "$id" "$PROJECT" $NM $PLAN_ROUTE', src)
        self.assertNotIn('BG_PLAN_SUPPLY="$supply"', src)
        helper = (BIN / 'router-planning.sh').read_text()
        self.assertIn('--max-tokens', helper)
        self.assertIn('router_confirm_verified', helper)
        self.assertIn('one_start', helper)
        self.assertIn('hard_token_cap', helper)


if __name__ == '__main__':
    unittest.main()
