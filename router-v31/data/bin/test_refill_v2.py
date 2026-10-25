#!/usr/bin/env python3
"""Tests for the v2 refill changes (chief 4627): can_start, explicit live-data label, start ledger. Fixture only: no network, gh or fm-* calls.
Run: python3 data/bin/test_refill_v2.py"""
import fcntl, json, os, pathlib, subprocess, sys, tempfile, time, unittest
from collections import Counter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import refill_lib_v2 as R

HERE = os.path.dirname(os.path.abspath(__file__))
P = R.PFX
GB = 1048576


def row(suf, labels=('free-ok', 'spec-ready'), desc=None):
    i = P + suf
    return i, dict(id=i, title='leaf ' + suf, status='open', priority=2, labels=list(labels), estimated_minutes=60,
                   description=desc if desc is not None else 'FILES: core/src/dos/a.py\nOWNER: x\n', dependencies=[])


def supply(*rs):
    return R.supply(dict(rs), '', '', set(), Counter(), set())


class CanStart(unittest.TestCase):
    def test_open_room_allows_two(self):
        self.assertEqual(R.can_start(2.5, 11 * GB, 0)[0], 2)

    def test_load_at_six_blocks(self):
        self.assertEqual(R.can_start(6.0, 11 * GB, 0)[0], 0)
        self.assertEqual(R.can_start(5.99, 11 * GB, 0)[0], 2)

    def test_memory_under_four_gb_blocks(self):
        self.assertEqual(R.can_start(1.0, 4 * GB - 1, 0)[0], 0)
        self.assertEqual(R.can_start(1.0, 4 * GB, 0)[0], 2)

    def test_two_per_minute(self):
        self.assertEqual(R.can_start(1.0, 8 * GB, 1)[0], 1)
        self.assertEqual(R.can_start(1.0, 8 * GB, 2)[0], 0)
        self.assertEqual(R.can_start(1.0, 8 * GB, 5)[0], 0)

    def test_swap_is_not_an_input(self):
        import inspect
        self.assertEqual(list(inspect.signature(R.can_start).parameters), ['load5', 'mem_avail_kb', 'starts_last_minute'])


class Ledger(unittest.TestCase):
    def test_counts_only_last_minute(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, 'starts.log')
            now = 1000000
            open(f, 'w').write('\n'.join(str(x) for x in (now - 120, now - 61, now - 59, now - 1)) + '\n')
            self.assertEqual(R.starts_in_last_minute(f, now), 2)

    def test_missing_ledger_is_zero(self):
        self.assertEqual(R.starts_in_last_minute('/nonexistent/x.log'), 0)

    def test_unreadable_ledger_counts_as_saturated(self):
        with tempfile.TemporaryDirectory() as d:   # a directory where the ledger should be: open() raises IsADirectoryError (an OSError)
            self.assertEqual(R.starts_in_last_minute(d), R.CAN_START_PER_MIN)

    def test_ledger_writable(self):
        with tempfile.TemporaryDirectory() as d:
            self.assertTrue(R.ledger_writable(os.path.join(d, 'new.log')))
            self.assertFalse(R.ledger_writable('/nonexistent-dir/x.log'))

    def test_note_start_appends_and_trims(self):
        with tempfile.TemporaryDirectory() as d:
            f = os.path.join(d, 'starts.log')
            open(f, 'w').write('\n'.join(['1'] * 80) + '\n')
            R.main(['note-start', f])
            lines = open(f).read().split()
            self.assertEqual(len(lines), 50)
            self.assertLess(time.time() - int(lines[-1]), 5)


class LiveLabel(unittest.TestCase):
    KEYWORDY = 'FILES: core/src/dos/a.py\nOWNER: x\nUses DOS_CORE_PG_DSN and the real book, needs an api key.\n'

    def test_credentials_keyword_makes_a_leaf_restricted_fail_closed(self):
        # v3.1 keeps ordinary live DB/book work portable.  Credentials are the
        # restricted surface, and keyword evidence remains fail-closed.
        c = supply(row('1', desc=self.KEYWORDY))[0]
        self.assertTrue(c['netcup_only'])

    def test_live_data_label_alone_stays_portable(self):
        for lab in ('live-data: yes', 'live-data:yes', 'Live-Data: Yes'):
            c = supply(row('2', labels=('spec-ready', lab)))[0]
            self.assertFalse(c['netcup_only'], lab)

    def test_explicit_credentials_label_is_restricted(self):
        for lab in ('credentials: yes', 'credentials:yes', 'Credentials: Yes'):
            c = supply(row('2b', labels=('spec-ready', lab)))[0]
            self.assertTrue(c['netcup_only'], lab)

    def test_other_values_stay_portable(self):
        # Labels are semantic, not keyword-scanned.  Only credentials: yes is
        # restricted by label in v3.1.
        for lab in ('live', 'offline', 'live-data: no', 'live-data'):
            c = supply(row('3', labels=('spec-ready', lab)))[0]
            self.assertFalse(c['netcup_only'], lab)

    def test_default_is_portable(self):
        self.assertFalse(supply(row('4'))[0]['netcup_only'])


class OldFilesKept(unittest.TestCase):
    def test_v1_still_infers_by_keyword(self):
        import refill_lib as V1
        self.assertTrue(V1.live_match(LiveLabel.KEYWORDY))


def write_exec(path, text):
    with open(path, 'w') as f:
        f.write(text)
    os.chmod(path, 0o755)


def route_leaf_source():
    """route_leaf's text from lane-refill-v2.sh (the real script, not a copy)."""
    out, on = [], False
    with open(os.path.join(HERE, 'lane-refill-v2.sh')) as f:
        text = f.read()
    for line in text.splitlines():
        if not on and line.startswith('route_leaf() {'):
            on = True
        if on:
            out.append(line)
            if line == '}':
                break
    assert on
    return '\n'.join(out) + '\n'


class Pass9AdmittedBindingFromSharedSeam(unittest.TestCase):
    """route_leaf consumes exactly the tuple supplied by router_admit.

    v3.1 moved stateful selection from route-pick into the shared admission
    seam.  This fixture deliberately has no fleet resolver: any second
    selection would fail the test.
    """

    def test_route_leaf_uses_one_admitted_tuple_without_reselection(self):
        with tempfile.TemporaryDirectory(dir='/tmp/claude-1000', prefix='refill-v2-test-') as tmp:
            calls = os.path.join(tmp, 'calls.log')
            script = os.path.join(tmp, 't.sh')
            with open(script, 'w') as f:
                f.write('set -u\nDRY=0\nsay() { echo "say: $*"; }\ndlog() { :; }\n'
                        'router_admit() {\n'
                        '  printf "%s\\n" "$*" >> "' + calls + '"\n'
                        '  RA_BINDING=odd@zzz; RA_REASON=fixture-admitted; RA_HARNESS=pi\n'
                        '  RA_MODEL=cat-jam; RA_PROVIDER=north; RA_EFFORT=high\n'
                        '  RA_ARGV=(--harness pi --model north/cat-jam --effort high)\n'
                        '  return 0\n}\n'
                        + route_leaf_source() +
                        'route_leaf bosgame 1.2 no build; echo "rc=$? args=$ROUTE_ARGS '
                        'bind=$ROUTE_BIND_HARNESS/$ROUTE_BIND_MODEL/$ROUTE_BIND_PROVIDER/$ROUTE_BIND_EFFORT"\n')
            r2 = subprocess.run(['bash', script], text=True, capture_output=True, timeout=60)
            self.assertIn('rc=0 args=--harness pi --model north/cat-jam --effort high '
                          'bind=pi/cat-jam/north/high', r2.stdout, r2.stdout + r2.stderr)
            with open(calls) as f:
                self.assertEqual(f.read().split(), ['1.2', 'build', 'build', 'bosgame', 'no'])


class Pass9ClaudeViaClineProvider(unittest.TestCase):
    """pass-9 error (2): the Claude-via-Cline ban checks the binding's PROVIDER, not just the harness."""
    NOW = 2_000_000_000

    def pick(self, provider):
        cfg = {'models': {'claude-top': {'family': 'claude', 'billing': 'flat', 'pool': 'claude', 'via': 'claude'}},
               'bindings': {'b': {'model': 'claude-top', 'provider': provider, 'harness': 'pi', 'weight': 1}},
               'roles': {'build': {'models': ['b']}},
               'pools': {'b': {'period_days': 7, 'scarce': False}},
               'bans': [{'family': 'claude', 'via': 'cline'}]}
        q = {'pools': {'b': {'used_pct': 0, 'reset_at': self.NOW + 86400, 'source': 't',
                             'observed_at': self.NOW, 'manual': False}}}
        return R.route_pick('build', 'bosgame', '', False, self.NOW, cfg, q, {'models': {}, 'cursor': {}})

    def test_cline_provider_with_another_harness_is_banned(self):
        model, why = self.pick('cline')
        self.assertIsNone(model)
        self.assertIn('banned', why)
        # control: the same row on a non-cline provider is reachable
        self.assertEqual(self.pick('droid')[0], 'b')


class SenderHome(unittest.TestCase):
    """bosgame-leaf-send.sh against a fixture home: stub overlap check, stub bosgame-sm-send.sh (logs
    each delivery), and a refill_lib_v2.py whose can-start answers CAN_START (other commands run the
    real library). Legacy send (no binding)."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir='/tmp/claude-1000', prefix='refill-v2-test-')
        root = self.tmp.name
        self.home = os.path.join(root, 'home')
        b = os.path.join(self.home, 'data', 'bin')
        os.makedirs(b)
        self.cand = os.path.join(root, 'candidates.json')
        with open(self.cand, 'w') as f:
            json.dump([{'suf': '9.9.9', 'id': P + '9.9.9', 'title': 'leaf 9.9.9', 'files': ['core/src/x.py'],
                        'body': 'FILES: core/src/x.py\nOWNER: core\n'}], f)
        write_exec(os.path.join(b, 'lane-overlap-check.py'), '#!/usr/bin/env python3\nimport sys; sys.exit(0)\n')
        write_exec(os.path.join(b, 'refill_lib_v2.py'),
                   'import os, sys\nif sys.argv[1] == "can-start":\n    print(os.environ["CAN_START"]); sys.exit(0)\n'
                   'os.execv(sys.executable, [sys.executable, %r] + sys.argv[1:])\n' % R.__file__)
        self.sends = os.path.join(root, 'sm-send.log')
        write_exec(os.path.join(b, 'bosgame-sm-send.sh'),
                   '#!/usr/bin/env bash\ncat > /dev/null\necho "replied: leaf accepted" | tee -a "%s"\n' % self.sends)
        self.pk_lock = os.path.join(root, 'daily_packet_run.lock')
        os.makedirs(os.path.join(self.home, 'config'))
        with open(os.path.join(self.home, 'config', 'fleet.yaml'), 'w') as f:
            f.write('models:\n  cat-jam: {family: free, billing: free}\n'
                    'bindings:\n  b: {model: cat-jam, provider: north, harness: pi, effort: high}\n')

    def tearDown(self):
        self.tmp.cleanup()

    def send(self, can_start='2\tok'):
        env = dict(os.environ, BOSGAME_LEAF_HOME=self.home, FM_HOME=self.home, BOSGAME_CANDIDATES=self.cand,
                   BOSGAME_PACKET_LOCK=self.pk_lock, CAN_START=can_start)
        env.pop('ROUTER_LIVE', None)
        return subprocess.run(['bash', os.path.join(HERE, 'bosgame-leaf-send.sh'), '9.9.9',
                               '--binding', 'b', '--incarnation', 'inc-1'],
                              text=True, capture_output=True, env=env, timeout=60)

    def delivered(self):
        if not os.path.exists(self.sends):
            return 0
        with open(self.sends) as f:
            return len(f.read().splitlines())


class RemoteDeliveryAcknowledgment(SenderHome):
    """Delivery follows the v3 anchored acknowledgment contract."""

    def test_positive_acknowledgment_delivers_without_receipt_or_reconciliation(self):
        r = self.send()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.delivered(), 1)
        delivery = os.path.join(self.home, 'data', 'dos-bosgame-9-9-9-1001')
        self.assertFalse(os.path.exists(os.path.join(delivery, 'reconcile-required.txt')))
        self.assertIn('\tsent\t', open(os.path.join(self.home, 'data', 'bosgame-lanes.tsv')).read())

    def test_start_gates_still_refuse_before_transport(self):
        r = self.send(can_start='0\tload5 6.2 >= 6')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('can_start allows no start', r.stdout + r.stderr)
        hold = os.path.join(self.home, 'data', 'new-leaves.hold')
        open(hold, 'w').close()
        r = self.send()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('new-leaves.hold', r.stdout + r.stderr)
        os.rename(hold, hold + '.bak-test')
        with open(self.pk_lock, 'w') as lk:
            fcntl.flock(lk, fcntl.LOCK_EX)
            r = self.send()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('packet run holds', r.stdout + r.stderr)
        self.assertEqual(self.delivered(), 0)
        self.assertFalse(os.path.exists(os.path.join(self.home, 'data', 'bosgame-lanes.tsv')))


class DeliveryLedgerFailureDoesNotUndoDelivery(SenderHome):
    """A successful transport delivery remains successful if its ledger append fails."""

    def test_transport_delivery_is_not_reclassified_when_ledger_append_fails(self):
        os.makedirs(os.path.join(self.home, 'data', 'bosgame-lanes.tsv'))   # a directory: the append fails
        r = self.send()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.delivered(), 1)
        shown = r.stdout + r.stderr
        self.assertIn('WARNING: sent', shown)
        delivery = os.path.join(self.home, 'data', 'dos-bosgame-9-9-9-1001')
        self.assertTrue(os.path.exists(os.path.join(delivery, 'message.txt')))


if __name__ == '__main__':
    unittest.main()
