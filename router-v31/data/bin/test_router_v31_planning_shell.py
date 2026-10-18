#!/usr/bin/env python3
"""Run the real planning shell/controller with local endpoint and admission stubs."""
import json
import os
from datetime import datetime, timezone
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = Path(__file__).resolve().parent


def run_plan(admit='ok', account='ok', live='1', runner=True, cap=1, dry=0,
             sol='ok', muse='ok', kimi='ok', check_sol='ok', check_muse='ok',
             check_kimi='ok', daily_cap=False, start='ok', ready=0, free=2):
    home = Path(tempfile.mkdtemp(prefix='planning-shell-'))
    for rel in ('data', 'state', 'bin', 'work/clone/.beads'):
        (home / rel).mkdir(parents=True, exist_ok=True)
    (home / 'data/t1-plan-authority.tsv').write_text('A\tparent-a\troot-a\n')
    (home / 'work/clone/.beads/issues.jsonl').write_text(json.dumps(dict(id='parent-a', status='open', labels=['needs-spec'])) + '\n')
    (home / 'work/candidates.json').write_text(json.dumps([
        dict(suf='1.%d' % i, id='ready-%d' % i, title='ready leaf %d' % i, files=['core/src/x%d.py' % i]) for i in range(ready)]))
    clone = home / 'work/clone'
    for args in (('init', '-q'), ('config', 'user.email', 'fixture@example.invalid'),
                 ('config', 'user.name', 'Fixture'), ('add', '.beads/issues.jsonl'),
                 ('commit', '-qm', 'cached main fixture'),
                 ('update-ref', 'refs/remotes/origin/main', 'HEAD')):
        subprocess.run(['/usr/bin/git', '-C', str(clone), *args], check=True, capture_output=True)
    if runner:
        # The deployed runner lives beside the installed router scripts.  The
        # fixture records availability preflights separately from launches.
        endpoint = home / 'data/bin/fm-planning-runner.sh'
        endpoint.parent.mkdir(parents=True, exist_ok=True)
        endpoint.write_text('''#!/usr/bin/env bash
if [ "$1" = --capabilities ]; then printf '%s\\n' '{"v":1,"hard_token_cap":false,"hosts":["netcup","bosgame"]}'; exit 0; fi
if [ "$1" = --check ]; then
  printf '%s\\n' "$*" >> "$FIXTURE/checks"
  case "$*" in
    *openai-codex/gpt-6.1-sol*) [ "$CHECK_SOL_CASE" = ok ] ;;
    *muse-wonder*) [ "$CHECK_MUSE_CASE" = ok ] ;;
    *kimi-code/k3*) [ "$CHECK_KIMI_CASE" = ok ] ;;
  esac
  check_rc=$?
  [ "$check_rc" = 0 ] || printf 'quota stopped before launch\n' >&2
  exit "$check_rc"
fi
printf '%s\\n' "$*" > "$FIXTURE/argv"
if [ "$START_CASE" = refused ]; then exit 75; fi
printf 'spawned endpoint=planning-pane\\n'
''')
        endpoint.chmod(0o755)
    script = '''set -u
H=$FIXTURE; B=$BIN; W=$H/work; CLONE=$W/clone; PROJECT=/project
PLAN=1; DRY=$DRY_CASE; used=; pfree=$CAP_CASE; planw=0; free=$FREE_CASE; load5=0; sn=1
ROUTER_LIVE=$LIVE_CASE; RA_BINDING=; RA_MODEL=; RA_HOST=; RA_INCARNATION=inc-1; ROUTE_ARGV=()
say() { printf '%s\\n' "$*"; }
fresh_gate() { sn=1; }
route_leaf() {
  printf '%s\\n' "$2 $5 $4 $1 $3 $6" >> "$H/admit.log"
  [ "$ADMIT_CASE" = ok ] || return 75
  case "$6" in
    sol-plan@pi) [ "$SOL_CASE" = ok ] || return 75; RA_MODEL=openai-codex/gpt-6.1-sol; RA_HARNESS=pi ;;
    muse-wonder-plan@muse) [ "$MUSE_CASE" = ok ] || return 75; RA_MODEL=muse-wonder; RA_HARNESS=muse ;;
    kimi-k3-plan@pi) [ "$KIMI_CASE" = ok ] || return 75; RA_MODEL=kimi-code/k3; RA_HARNESS=pi ;;
  esac
  RA_BINDING=$6; RA_HOST=$1
  ROUTE_ARGV=(--harness "$RA_HARNESS" --model "$RA_MODEL" --effort high)
}
router_prelaunch() { :; }
router_cancel() { printf 'cancel\\n' >> "$H/cancel.log"; }
router_confirm_verified() { printf 'confirm\\n' >> "$H/confirm.log"; return 0; }
router_ambiguous() { printf 'ambiguous\\n' >> "$H/ambiguous.log"; }
one_start() { [ "$ACCOUNT_CASE" = ok ] || return 1; printf 'count\\n' >> "$H/events"; }
source "$B/router-planning.sh"
router_planning_tick
'''
    env = dict(os.environ, FM_HOME=str(home), FIXTURE=str(home), BIN=str(BIN), ADMIT_CASE=admit,
               ACCOUNT_CASE=account, LIVE_CASE=live, CAP_CASE=str(cap), FREE_CASE=str(free), DRY_CASE=str(dry), SOL_CASE=sol,
               MUSE_CASE=muse, KIMI_CASE=kimi, CHECK_SOL_CASE=check_sol,
               CHECK_MUSE_CASE=check_muse, CHECK_KIMI_CASE=check_kimi,
               PLANNING_DAILY_CAP_CASE='1' if daily_cap else '0', START_CASE=start)
    env.pop('FM_PLANNING_RUNNER', None)
    if runner:
        env['FM_PLANNING_RUNNER'] = str(endpoint)
    else:
        env['FM_PLANNING_RUNNER'] = str(home / 'missing-runner')
        # Exercise the real bundled backend's binary-missing path without
        # permitting it to connect or launch a child process.
        env['FM_PLANNING_PI'] = str(home / 'missing-pi')
        env['FM_PLANNING_SSH'] = str(home / 'missing-ssh')
    if daily_cap:
        (home / 'state/planning-v31.json').write_text(json.dumps({'v': 1, 'active': True, 'cycle': 1, 'passes': [
            {'task': 'spent', 'state': 'complete', 'tokens': 1000000,
             'day': datetime.now(timezone.utc).date().isoformat(),
             'reserved_at': 1800000000, 'completed_at': 1800000000, 'cycle': 0,
             'partition': 'old', 'rows': []}]}))
    result = subprocess.run(['bash', '-c', script], env=env, text=True, capture_output=True, timeout=15)
    return result, str(home)


class PlanningShell(unittest.TestCase):
    def test_applies_sol_high_cap_and_verified_receipt_in_both_live_modes(self):
        for live in ('0', '1'):
            p, path = run_plan(live=live)
            self.assertEqual(p.returncode, 0, p.stderr)
            home = Path(path)
            self.assertEqual((home / 'events').read_text(), 'count\n')
            self.assertIn('--max-tokens 300000', (home / 'argv').read_text())
            self.assertIn('--harness pi --model openai-codex/gpt-6.1-sol --effort high', (home / 'argv').read_text())
            state = json.loads((home / 'state/planning-v31.json').read_text())
            self.assertEqual(len(state['passes']), 1)
            task = state['passes'][0]['task']
            self.assertTrue((home / 'data' / task / 'planning-request.json').exists())
            self.assertEqual((home / 'data' / task / 'partition').read_text(), 'A\n')

    def test_low_ready_supply_with_free_slots_refills_planning_end_to_end(self):
        # 3 ready leaves, 9 building, 8 free netcup slots: the v3 router logged
        # planning-deferred here and never launched; v3.1 must reserve and start a pass.
        p, path = run_plan(ready=3, free=8)
        self.assertEqual(p.returncode, 0, p.stderr)
        home = Path(path)
        self.assertNotIn('deferred', p.stdout)
        self.assertEqual((home / 'events').read_text(), 'count\n')
        self.assertIn('--model openai-codex/gpt-6.1-sol --effort high', (home / 'argv').read_text())
        self.assertIn('PLANNING verified', p.stdout)
        state = json.loads((home / 'state/planning-v31.json').read_text())
        self.assertTrue(state['active'])
        self.assertEqual(len(state['passes']), 1)
        self.assertEqual(state['passes'][0]['supply'], 3)
        self.assertEqual(state['passes'][0]['state'], 'reserved')
        self.assertFalse((home / 'state/planning-blocked.alert').exists())

    def test_ready_supply_at_or_above_the_floor_does_not_start_planning(self):
        p, path = run_plan(ready=25, free=8)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse((Path(path) / 'events').exists())
        self.assertFalse((Path(path) / 'argv').exists())
        self.assertIn('supply above trigger', p.stdout)

    def test_unavailable_sol_checks_muse_then_k3_before_reserving(self):
        p, path = run_plan(check_sol='WAIT', check_muse='WAIT')
        self.assertEqual(p.returncode, 0, p.stderr)
        home = Path(path)
        self.assertIn('planning-blocked', p.stdout)
        self.assertIn('--model kimi-code/k3', (home / 'argv').read_text())
        admissions = (home / 'admit.log').read_text()
        self.assertIn('netcup no sol-plan@pi', admissions)
        self.assertIn('bosgame no muse-wonder-plan@muse', admissions)
        self.assertIn('netcup no kimi-k3-plan@pi', admissions)
        self.assertIn('muse-wonder', (home / 'checks').read_text())
        alert = (home / 'state/planning-blocked.alert').read_text()
        self.assertIn('host=netcup', alert)
        self.assertIn('host=bosgame', alert)
        self.assertIn('quota stopped before launch', alert)
        self.assertEqual((home / 'events').read_text(), 'count\n')

    def test_missing_override_falls_back_to_bundled_backend_and_tries_muse(self):
        p, path = run_plan(runner=False)
        self.assertEqual(p.returncode, 0, p.stderr)
        home = Path(path)
        self.assertFalse((home / 'events').exists())
        admissions = (home / 'admit.log').read_text()
        self.assertIn('netcup no sol-plan@pi', admissions)
        self.assertIn('bosgame no muse-wonder-plan@muse', admissions)
        alert = (home / 'state/planning-blocked.alert').read_text()
        self.assertGreaterEqual(alert.count('binary missing'), 3)
        self.assertIn('host=bosgame', alert)

    def test_capacity_and_dry_run_never_admit_or_start(self):
        for kwargs in (dict(cap=0), dict(dry=1)):
            p, path = run_plan(**kwargs)
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertFalse((Path(path) / 'admit.log').exists())
            self.assertFalse((Path(path) / 'events').exists())
            if kwargs.get('dry'):
                self.assertFalse((Path(path) / 'state/planning-v31.json').exists())

    def test_daily_cap_wait_writes_an_alert(self):
        p, path = run_plan(daily_cap=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        alert = (Path(path) / 'state/planning-blocked.alert').read_text()
        self.assertIn('daily token budget', alert)
        self.assertFalse((Path(path) / 'admit.log').exists())

    def test_definitive_unstarted_launch_alerts_and_tries_next_model(self):
        p, path = run_plan(start='refused')
        self.assertEqual(p.returncode, 0, p.stderr)
        home = Path(path)
        self.assertIn('runner refused before launch', (home / 'state/planning-blocked.alert').read_text())
        self.assertGreaterEqual((home / 'admit.log').read_text().count('plan plan'), 2)

    def test_accounting_failure_propagates_and_wait_does_not_count(self):
        p, path = run_plan(account='fail')
        self.assertNotEqual(p.returncode, 0)
        self.assertFalse((Path(path) / 'events').exists())
        p, path = run_plan(admit='WAIT')
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertFalse((Path(path) / 'events').exists())
        self.assertFalse((Path(path) / 'argv').exists())


if __name__ == '__main__':
    unittest.main()
