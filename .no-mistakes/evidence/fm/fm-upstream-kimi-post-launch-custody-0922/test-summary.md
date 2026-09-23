# Custody Fix Validation Summary

## Change Under Test
- **Branch**: fm/fm-upstream-kimi-post-launch-custody-0922
- **Target Commit**: 5fc3c7fe (fix(spawn): retain custody after failed endpoint close)
- **Base Commit**: 39f4c2af

## Key Scenarios

### Scenario 1: Post-Launch Delivery Failure (Kimi)
**Test**: `test_kimi_unconfirmed_delivery_fails_loudly`
- **Condition**: Kimi agent launched successfully, brief pointer delivery fails
- **Expected Behavior**: Task record is preserved for live worker (no cleanup/rollback)
- **Result**: ✅ PASS
- **Evidence**: Test output includes "ok - fm-spawn: Kimi preserves its authoritative task record after a silent pointer drop"

### Scenario 2: Post-Launch Endpoint Close Failure (Rovo)
**Test**: `test_rovo_cleanup_failure_preserves_live_endpoint_custody`
- **Condition**: Rovo agent launched, delivery fails, endpoint close fails
- **Expected Behavior**: Task record is preserved for live worker
- **Result**: ✅ PASS
- **Evidence**: Test output includes "ok - fm-spawn: a failed Rovo endpoint close preserves live endpoint custody"

### Scenario 3: Pre-Launch Readiness Failure (Kimi)
**Test**: `test_kimi_readiness_gate_precedes_pointer`
- **Condition**: Kimi launch command sent, but readiness signal never received (pre-launch failure)
- **Expected Behavior**: Normal rollback behavior retained
- **Result**: ✅ PASS
- **Evidence**: Test passes, readiness failures occur before SPAWN_AGENT_LAUNCHED is set

### Scenario 4: All Rovo Tests
**Test**: Full Rovo harness test suite
- **Result**: ✅ PASS (12/12 tests)
- **Key Tests**:
  - Unconfirmed delivery fails loudly
  - Failed close preserves custody
  - Silent pointer drop triggers teardown
  - Missing binary refuses before pane creation

## Boundary Behavior

The fix correctly implements the boundary between pre-launch and post-launch:

1. **SPAWN_AGENT_LAUNCHED=1** set at line 4887, after:
   - Launch file created
   - Launch command delivered
   - Launch command submitted (Enter key sent)

2. **Pre-launch failures** (before line 4887):
   - Full rollback via `spawn_fresh_commit_rollback()`
   - Task record cleaned up

3. **Post-launch failures** (after line 4887):
   - If endpoint close fails: custody preserved, task record stays
   - If delivery fails: custody preserved, task record stays
   - Error messages differentiate: "task record is preserved for the live worker"

## Conclusion

The change correctly implements the required behavior:
- ✅ After launch, failures preserve task record and endpoint
- ✅ Before launch, failures retain rollback behavior
- ✅ All tests pass
