# Live observation: how the running no-mistakes gate (v1.84.0) delivers test.instructions

In this run (01M4GT2BP382WK5GDW1GR8PCBX), the Test agent's prompt contained a section
"Repository live-validation runbook (trusted, from the default branch):" whose text is
line-for-line identical to `test.instructions` parsed from base commit 8d9c436a
(see test-instructions-parsed.txt, first block). The Mac rule line from 3bee3975 was
NOT present, confirming the gate embeds test.instructions verbatim and sources it from
the default branch, not from the change under validation.

Consequence: the new first line ("On macOS (uname Darwin) run only single test files ...
under `taskpolicy -b` ... Full suites run only on the Linux hosts bosgame or netcup.")
parses cleanly as part of the same block scalar (second block) and will be delivered to
every Test agent once this change lands on main. disable_project_settings stays true, so
this trusted field is the only route by which gate agents see the rule.
