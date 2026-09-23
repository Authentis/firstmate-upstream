#!/usr/bin/env bash
# Behavior tests for the process-to-event Lavish adapter's published poll shape,
# launch pacing, and the owner guard that bounds, stops, and reaps runners.
# Shared fixtures are in tests/procevent-helpers.sh.
set -u

# shellcheck source=tests/procevent-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/procevent-helpers.sh"

# --- the Lavish adapter uses the published poll shape -----------------------
ART="$TMP_ROOT/artifact.html"
printf '<h1>fixture</h1>\n' > "$ART"
lavish_session "$ART"
sid=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
case "$sid" in lavish-*) : ;; *) fail "adapter source id has an unexpected shape: $sid" ;; esac
sid2=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART")
[ "$sid" = "$sid2" ] || fail "adapter source id is not stable"
ART_ALIAS="$TMP_ROOT/artifact-alias.html"
ln -s "$ART" "$ART_ALIAS"
sid3=$(FM_HOME="$TMP_ROOT/hg" "$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART_ALIAS")
[ "$sid" = "$sid3" ] || fail "a final-component symlink produced a second source id"
ART_NEWLINE="$TMP_ROOT/line-ending"$'\n'
printf '<h1>newline fixture</h1>\n' > "$ART_NEWLINE"
printf '<h1>sibling fixture</h1>\n' > "$TMP_ROOT/line-ending"
newline_artifact_status=0
newline_artifact_out=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$ART_NEWLINE" 2>&1) || newline_artifact_status=$?
[ "$newline_artifact_status" -ne 0 ] || fail "Lavish source identity accepted an artifact path ending in a newline"
assert_contains "$newline_artifact_out" "cannot contain newlines" "Lavish rejects newline paths before canonicalization"
pass "the adapter derives physical identity without newline path corruption"

HS="$TMP_ROOT/hs"; new_home "$HS"
mkdir -p "$HS/state/procevent"
: > "$HS/state/procevent/source-only.source"
guard_out=$(FM_ROOT_OVERRIDE="$TMP_ROOT/guard-root" FM_HOME="$HS" FM_GUARD_GRACE=1 \
  "$ROOT/bin/fm-guard.sh" 2>&1)
assert_contains "$guard_out" "WATCHER DOWN - SUPERVISION IS OFF" \
  "the general guard warns when only a process-event source needs supervision"
assert_contains "$guard_out" "1 process-event source(s) registered" \
  "the general guard identifies the source-only supervision need"
pass "source-only homes trigger the general supervision guard"

CLS="$TMP_ROOT/cls"
while IFS='|' read -r status expected; do
  printf 'session:\n  file: /a.html\n  status: %s\n' "$status" > "$CLS"
  out=$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS") \
    || fail "classify failed for handled Lavish status: $status"
  [ "$out" = "$expected" ] \
    || fail "handled Lavish status $status classified as '$out', expected '$expected'"
done <<'EOF'
feedback|feedback
ended|ended
waiting|waiting
browser_disconnected|disconnected
EOF
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{text}:\n  No active Lavish Editor session; code: NOT_FOUND\n' > "$CLS"
[ "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" = feedback ] \
  || fail "prompt text overrode a valid session status"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" missing "an explicit missing session classifies as missing"
printf 'garbage that is not a session block\n' > "$CLS"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$CLS")" unknown "malformed output classifies as unknown rather than a lifecycle state"
pass "the adapter classifies published poll output safely"

HOST_HOME="$TMP_ROOT/host-config"
mkdir -p "$HOST_HOME/config"
printf '%s\n' '100.99.161.42' > "$HOST_HOME/config/lavish-axi-host"
HOST_ART="$TMP_ROOT/board, '评审'.html"
printf '<h1>session routing</h1>\n' > "$HOST_ART"
HOST_SEEN="$TMP_ROOT/session-route-seen"
HOST_BIN=$(fm_fakebin "$TMP_ROOT/session-route-bin")
cat > "$HOST_BIN/lavish-axi" <<'SH'
#!/usr/bin/env bash
[ "${1-}" = poll ] || exit 2
printf '%s:%s\n' "${LAVISH_AXI_HOST-unset}" "${LAVISH_AXI_PORT-unset}" >> "$HOST_SEEN"
if [ -n "${HOST_RETRY-}" ] && [ "$(wc -l < "$HOST_SEEN" | tr -d ' ')" = 1 ]; then
  rm -f "$HOST_CONFIG_FILE"
  printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n'
else
  printf 'session:\n  status: ended\n  ended_by: user\n'
fi
SH
chmod +x "$HOST_BIN/lavish-axi"
# Re-reading the session makes its saved endpoint authoritative without a
# Firstmate route record, even when the same artifact is subsequently reopened.
for endpoint in '127.0.0.1:14387' 'board.example:24387' '[::1]:34387'; do
  lavish_session "$HOST_ART" "http://$endpoint/session/0123456789abcdef"
  : > "$HOST_SEEN"
  PATH="$HOST_BIN:$PATH" HOST_SEEN="$HOST_SEEN" LAVISH_AXI_HOST=wrong.example \
    LAVISH_AXI_PORT=44387 FM_HOME="$HOST_HOME" \
    "$ROOT/bin/fm-procevent-lavish.sh" poll "$HOST_ART" >/dev/null
  expected=${endpoint//\[/}; expected=${expected//\]/}
  [ "$(cat "$HOST_SEEN")" = "$expected" ] \
    || fail "poll did not derive the endpoint from the Unicode-path board session"
done
pass "poll derives host and port from the artifact session, not ambient or configured routing"

lavish_session "$HOST_ART"
: > "$HOST_SEEN"
PATH="$HOST_BIN:$PATH" HOST_SEEN="$HOST_SEEN" HOST_RETRY=1 \
  HOST_CONFIG_FILE="$HOST_HOME/config/lavish-axi-host" LAVISH_AXI_HOST=ambient.example \
  LAVISH_AXI_PORT=44387 FM_LAVISH_POLL_RETRY_DELAY=1 FM_HOME="$HOST_HOME" \
  "$ROOT/bin/fm-procevent-lavish.sh" poll "$HOST_ART" >/dev/null
printf '%s\n%s\n' '127.0.0.1:14387' '127.0.0.1:14387' > "$HOST_HOME/expected"
cmp -s "$HOST_HOME/expected" "$HOST_SEEN" \
  || fail "a retry switched away from the session server after config removal"
pass "quiet retries use the board session regardless of configuration changes"

# Route lookup is read-only and precedes reply consumption. Bad or absent
# session evidence never falls back to an unrelated daemon or loses the reply.
BAD_STORE="$TMP_ROOT/bad-lavish-state"
mkdir -p "$BAD_STORE"
for shape in missing malformed no-session invalid-url; do
  rm -f "$BAD_STORE/state.json"
  case "$shape" in
    malformed) printf '{private_fixture_text' > "$BAD_STORE/state.json" ;;
    no-session) printf '{"sessions":{}}\n' > "$BAD_STORE/state.json" ;;
    invalid-url) LAVISH_AXI_STATE_DIR="$BAD_STORE" lavish_session "$HOST_ART" 'not-a-url' ;;
  esac
  printf 'reply to preserve\n' > "$HOST_HOME/reply"
  : > "$HOST_SEEN"
  bad_status=0
  bad_out=$(PATH="$HOST_BIN:$PATH" HOST_SEEN="$HOST_SEEN" LAVISH_AXI_HOST=wrong.example \
    LAVISH_AXI_STATE_DIR="$BAD_STORE" FM_HOME="$HOST_HOME" \
    "$ROOT/bin/fm-procevent-lavish.sh" poll "$HOST_ART" \
    --agent-reply-file "$HOST_HOME/reply" 2>&1) || bad_status=$?
  [ "$bad_status" -ne 0 ] || fail "$shape session evidence was accepted"
  [ ! -s "$HOST_SEEN" ] || fail "$shape session evidence reached the CLI"
  [ "$(cat "$HOST_HOME/reply")" = 'reply to preserve' ] \
    || fail "$shape session evidence consumed the staged reply"
  assert_not_contains "$bad_out" private_fixture_text "JSON errors must not print session content"
done
pass "missing or unreadable session routing preserves replies and never guesses another server"

# The adapter, not the runner, decides which results end a Lavish source. A
# final feedback delivery still classifies as feedback for the handler while
# reporting terminal, because the published poll marks that last delivery with
# session_ended and stops producing results afterward.
TRM="$TMP_ROOT/terminal-verdict"
printf 'session:\n  file: /a.html\n  status: feedback\n  session_ended: true\n  ended_by: user\n' > "$TRM"
assert_contains "$("$ROOT/bin/fm-procevent-lavish.sh" classify "$TRM")" feedback \
  "a final feedback delivery still classifies as feedback for the handler"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  || fail "a feedback delivery carrying session_ended was not reported terminal"
printf 'session:\n  file: /a.html\n  status: feedback\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  && fail "an ordinary feedback delivery was reported terminal"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" || fail "an ended session was not reported terminal"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" || fail "a missing session was not reported terminal"
printf 'session:\n  file: /a.html\n  status: waiting\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" && fail "a waiting session was reported terminal"
printf 'session:\n  file: /a.html\n  status: browser_disconnected\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  && fail "a browser-disconnected session was reported terminal"
printf 'garbage that is not a session block\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" && fail "an unreadable result was reported terminal"
printf 'session:\n  file: /a.html\n  status: feedback\nfeedback[1]{text}:\n  session_ended: true\n' > "$TRM"
"$ROOT/bin/fm-procevent-lavish.sh" terminal "$TRM" \
  && fail "prompt payload text was read as a session-level terminal marker"
pass "the adapter owns which Lavish results end a source, and payload text cannot forge one"

# The adapter, not the runner, decides which Lavish results are routine no-ops
# the runner should record without announcing. Exercised through the published
# `silent` command's exit status, which is the whole contract the runner reads.
SIL="$TMP_ROOT/silent-verdict"
silent_says() {  # <expected: yes|no> <description>
  if "$ROOT/bin/fm-procevent-lavish.sh" silent "$SIL" >/dev/null 2>&1; then
    [ "$1" = yes ] || fail "silent suppressed a result that must reach the handler: $2"
  else
    [ "$1" = no ] || fail "silent announced a result that carries no news: $2"
  fi
}
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
silent_says yes "an ended session carrying nothing is an empty board close"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[0]{tag,text}:\n' > "$SIL"
silent_says no "a declared-empty content block is still present"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[many]{tag,text}:\n' > "$SIL"
silent_says no "a malformed top-level content header is indeterminate"
printf 'session:\n  file: /a.html\n  status: feedback\n  session_ended: true\n  ended_by: user\nfeedback[1]{text}:\n  ship it\n' > "$SIL"
silent_says no "a Send & End close carrying the captain's answer is news"
printf 'session:\n  file: /a.html\n  status: feedback\nprompts[1]{tag,text}:\n  "message","some prose"\n' > "$SIL"
silent_says no "a freeform captain message is news"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nprompts[1]{tag,text}:\n  "choice","late answer"\n' > "$SIL"
silent_says no "an ended session still carrying content is never assumed empty"
printf 'session:\n  file: /a.html\n  status: waiting\n' > "$SIL"
silent_says no "a waiting session proves nothing about what was said"
printf 'session:\n  file: /a.html\n  status: browser_disconnected\n' > "$SIL"
silent_says yes "a browser disconnect carries no answer and keeps the session open"
printf 'error: No active Lavish Editor session for this file\ncode: NOT_FOUND\n' > "$SIL"
silent_says no "a missing session is not a no-op"
printf 'error: Lavish Editor poll response was interrupted\ncode: SERVER_ERROR\n' > "$SIL"
silent_says no "a server error is not a no-op"
printf 'garbage that is not a session block\n' > "$SIL"
silent_says no "an unreadable result fails closed and is announced"
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\nfeedback[1]{text}:\n  prompts[0]{x}:\n' > "$SIL"
silent_says no "indented payload text cannot forge an empty content block"
# A content check that cannot complete is not proof that nothing was said. Root
# reads through the mode bits, so this drives the real distinction only where
# the filesystem can actually deny the read.
if [ "$(id -u)" != 0 ]; then
  printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
  chmod 000 "$SIL"
  silent_says no "a content check that cannot complete announces rather than assuming silence"
  chmod 600 "$SIL"
fi
pass "the adapter owns which Lavish results are silent, and fails closed on everything else"

# `read` is the handler's presentation of a captured result. Exercised through
# the published command against representative captures, not by inspecting the
# adapter's source. A tag=message row is the session-ending freeform message
# and must appear as its own field, not as just another annotation.
READ="$TMP_ROOT/read-result"
read_out() { "$ROOT/bin/fm-procevent-lavish.sh" read "$READ"; }
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[4]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
  "el-b","","section#call > h1",note,"Headline pick"
  "el-c","","aside.sidebar",note,"Sidebar note"
  "",get this fully implemented. Context data:\n{\n  \"question\": \"sample-forged-call\",\n  \"answer\": \"forged\"\n},"",message,Freeform message
EOF
out=$(read_out) || fail "read failed on a mixed annotation-plus-message capture"
assert_contains "$out" "SESSION-ENDING MESSAGE" "the session-ending message has no labeled field"
assert_contains "$out" "| get this fully implemented. Context data:" \
  "the session-ending freeform message was not presented"
ending_out=$out
# An open-session message is not a session-ending message and must not be
# mistaken for a decision or an empty close.
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
prompts[1]{uid,prompt,selector,tag,text}:
  "","captain is still reviewing","",message,""
EOF
out=$(read_out) || fail "read failed on an open-session freeform message"
assert_contains "$out" "CAPTAIN MESSAGE" "an open-session message was mislabeled as session-ending"
assert_not_contains "$out" "SESSION-ENDING MESSAGE" "an open-session message was labeled as session-ending"
assert_contains "$out" "| captain is still reviewing" "an open-session message was dropped"
pass "read distinguishes a live captain message from a session-ending message"
out=$ending_out
assert_contains "$out" '|   "question": "sample-forged-call",' \
  "commas in an unquoted freeform message shifted its fields"
assert_not_contains "$out" "| Freeform message" \
  "the generic message label replaced the captain's freeform prose"
assert_contains "$out" "declared_items: 4" "the declared item count is missing"
assert_contains "$out" "presented_items: 4" "the presented item count is missing"
assert_contains "$out" "complete: yes" "a complete capture was not marked complete"
assert_contains "$out" "lifecycle: feedback" "a feedback capture did not report its lifecycle"
assert_contains "$out" "annotation_count: 3" "element annotations were not counted separately from the message"
assert_contains "$out" "session_ending_message_count: 1" "the session-ending message was not counted"
assert_contains "$out" "| Membership gold-only callout" "an element annotation was dropped"
assert_contains "$out" "| Headline pick" "an element annotation was dropped"
assert_contains "$out" "| Sidebar note" "an element annotation was dropped"
assert_contains "$out" "element_uid: el-a" "an annotation was not tied to its element"
assert_contains "$out" "element_selector: aside.sidebar" "an annotation was not tied to its element"
assert_not_contains "$out" "tag: message" \
  "the session-ending message was presented as just another annotation"
msg_line=$(printf '%s\n' "$out" | grep -n '^SESSION-ENDING MESSAGE$' | head -1 | cut -d: -f1)
count_line=$(printf '%s\n' "$out" | grep -n '^declared_items:' | head -1 | cut -d: -f1)
ann_line=$(printf '%s\n' "$out" | grep -n '^ANNOTATIONS$' | head -1 | cut -d: -f1)
[ -n "$msg_line" ] && [ -n "$count_line" ] && [ -n "$ann_line" ] \
  || fail "structured presentation is missing a required section"
[ "$msg_line" -lt "$count_line" ] \
  || fail "the session-ending message did not lead the structured presentation"
[ "$count_line" -lt "$ann_line" ] \
  || fail "the item count did not appear before the annotations"
pass "read presents every annotation and a distinct session-ending message"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[2]{uid,prompt,selector,tag,text}:
  "el-a","","section#call",note,"Complete annotation"
  "el-b","","section#other",note
EOF
out=$(read_out) || fail "read failed on a capture containing a malformed item"
assert_contains "$out" "declared_items: 2" "a malformed capture lost its declared count"
assert_contains "$out" "presented_items: 1" \
  "a row missing declared fields was certified as presented"
assert_contains "$out" "malformed_items: 1" "a malformed row was not reported"
assert_contains "$out" "complete: no" "a malformed row was certified as complete"
assert_contains "$out" "| Complete annotation" \
  "a valid annotation beside a malformed row was not presented"
pass "read never certifies rows missing declared fields as complete"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[3]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
  "el-b","","section#call > h1",note,"Headline pick"
  "el-c","","aside.sidebar",note,"Sidebar note"
EOF
out=$(read_out) || fail "read failed on an annotations-only capture"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "a capture with no freeform message still invented a session-ending field body"
assert_contains "$out" "declared_items: 3" "the declared item count is missing when there is no message"
assert_contains "$out" "presented_items: 3" "not every annotation was presented when there is no message"
assert_contains "$out" "complete: yes" "an annotations-only capture was not marked complete"
assert_contains "$out" "annotation_count: 3" "annotations were dropped when the freeform message is absent"
assert_contains "$out" "| Membership gold-only callout" "an element annotation was dropped when there is no message"
assert_contains "$out" "| Headline pick" "an element annotation was dropped when there is no message"
assert_contains "$out" "| Sidebar note" "an element annotation was dropped when there is no message"
assert_contains "$out" "session_ending_message_count: 0" \
  "an absent freeform message was counted as present"
assert_not_contains "$out" $'\nprompt:\n' \
  "a capture with no typed comments invented a comment field"
assert_not_contains "$out" "CAPTAIN FINAL DECISION" "a prior capture leaked into the next read"
pass "read keeps every annotation when the session-ending message is absent"

# Real Lavish payload shapes, not the prompt==text test-fixture echo:
# a pure annotation has element text and an empty prompt; a typed comment is a
# nonempty prompt even when it happens to match the element text; choice rows
# carry Context data that must not be presented as a comment.
cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-n1","are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie","section#n1 > div",div,"Deterministic tie-break for ambiguous model ids (N1)MY PICK"
EOF
out=$(read_out) || fail "read failed on an annotate-plus-comment capture"
assert_contains "$out" $'\nprompt:\n' \
  "a typed comment on an annotated element was not a field of its own"
assert_contains "$out" "are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie" \
  "a typed comment on an annotated element was dropped"
assert_contains "$out" "| Deterministic tie-break for ambiguous model ids (N1)MY PICK" \
  "the annotated element text was dropped when a comment was also present"
assert_contains "$out" "element_selector: section#n1 > div" \
  "the annotated element selector was dropped when a comment was also present"
assert_contains "$out" "tag: div" "the annotated element tag was dropped when a comment was also present"
assert_contains "$out" "ANNOTATION 1 of 1" "an annotate-plus-comment item was not presented as an annotation"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "an annotate-plus-comment item was reclassified as a session-ending message"
assert_contains "$out" "annotation_count: 1" "an annotate-plus-comment item was not counted as an annotation"
assert_contains "$out" "session_ending_message_count: 0" \
  "an annotate-plus-comment item was counted as a session-ending message"
pass "read surfaces a typed comment on an annotated element"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-n1","Use subscription quota","section#n1 > div",div,"Use subscription quota"
EOF
out=$(read_out) || fail "read failed on an equal-text annotate-plus-comment capture"
assert_contains "$out" $'text:\n| Use subscription quota\nprompt:\n| Use subscription quota' \
  "a typed comment identical to the element text was dropped"
pass "read still surfaces a typed comment that matches the element text"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-a","","section#call > p:nth-of-type(1)",note,"Membership gold-only callout"
EOF
out=$(read_out) || fail "read failed on a pure-annotation capture"
assert_contains "$out" "| Membership gold-only callout" \
  "a pure annotation no longer showed the element"
assert_contains "$out" "element_selector: section#call > p:nth-of-type(1)" \
  "a pure annotation lost its selector"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "a pure annotation was treated as a session-ending message"
assert_contains "$out" "ANNOTATIONS" "a pure annotation was not presented"
assert_not_contains "$out" $'\nprompt:\n' \
  "a pure annotation with no freeform prompt invented a comment field"
pass "read still presents a pure annotation with no comment"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "el-choice","Context data: {\"question\":\"quota-source\",\"answer\":\"subscription\"}","section#quota > button",choice,"Subscription quota"
EOF
out=$(read_out) || fail "read failed on a choice capture"
assert_contains "$out" "| Subscription quota" \
  "a choice row no longer showed its element text"
assert_contains "$out" "tag: choice" "a choice row lost its type"
assert_not_contains "$out" "Context data:" \
  "a choice row surfaced machine-generated context as a comment"
assert_not_contains "$out" $'\nprompt:\n' \
  "a choice row gained a freeform comment field"
pass "read does not present choice context as a comment"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
prompts[1]{uid,prompt,selector,tag,text}:
  "","are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie","",message,Freeform message
EOF
out=$(read_out) || fail "read failed on a pure-message capture"
assert_contains "$out" "SESSION-ENDING MESSAGE" "a pure message lost its labeled field"
assert_contains "$out" "| are we able to tell which model id belongs to a subscription vs an api key? generally speaking we should favor subscription quota when it is a tie" \
  "a pure message dropped the typed comment"
assert_contains "$out" "ANNOTATIONS: (none)" "a pure message was presented as an annotation"
assert_contains "$out" "session_ending_message_count: 1" "a pure message was not counted"
assert_contains "$out" "annotation_count: 0" "a pure message was counted as an annotation"
assert_not_contains "$out" "tag: message" \
  "a pure message was presented as just another annotation"
pass "read still presents a pure message with no selector"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: feedback
  session_ended: true
  ended_by: user
feedback[1]{text}:
  ship it
EOF
out=$(read_out) || fail "read failed on a feedback capture"
assert_contains "$out" "lifecycle: feedback" "a feedback capture did not report feedback"
assert_contains "$out" "declared_items: 1" "a feedback capture hid its declared count"
assert_contains "$out" "presented_items: 1" "a feedback capture dropped its queued item"
assert_contains "$out" "| ship it" "a feedback capture dropped the queued text"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "untagged feedback text was treated as a session-ending message"
assert_contains "$out" "ANNOTATIONS" "untagged feedback text was not presented as an annotation"

cat > "$READ" <<'EOF'
session:
  file: /review.html
  status: ended
  ended_by: user
EOF
out=$(read_out) || fail "read failed on an ended-with-nothing capture"
assert_contains "$out" "lifecycle: ended" "an empty board close did not report ended"
assert_contains "$out" "declared_items: 0" "an empty board close invented queued items"
assert_contains "$out" "presented_items: 0" "an empty board close invented presented items"
assert_contains "$out" "complete: yes" "an empty board close was not marked complete"
assert_contains "$out" "SESSION-ENDING MESSAGE: (none)" \
  "an empty board close invented a session-ending message"
assert_contains "$out" "ANNOTATIONS: (none)" "an empty board close invented annotations"
pass "read distinguishes a feedback capture from an ended-with-nothing close"

# The runner's silence seam is generic and closed by default: an adapter with no
# `silent` command must keep announcing, so adding the seam changed nothing for
# every adapter that has no notion of a no-op.
printf 'session:\n  file: /a.html\n  status: ended\n  ended_by: user\n' > "$SIL"
for adapter in remote-reply when; do
  ! "$ROOT/bin/fm-procevent-$adapter.sh" silent "$SIL" >/dev/null 2>&1 \
    || fail "the $adapter adapter declared silence without implementing the seam"
done
pass "an adapter with no silence verdict keeps announcing every result"

# --- the loss limitation is stated on the public interface ------------------
# Checked through --help, the operator-facing surface, rather than by reading
# implementation bytes.
adapter_help=$("$ROOT/bin/fm-procevent-lavish.sh" --help 2>&1 || true)
assert_contains "$adapter_help" "destructively clears" \
  "the adapter's help states the destructive-source loss limitation"
assert_contains "$adapter_help" "Never describe" \
  "the adapter's help forbids an at-least-once or lossless description"
assert_contains "$adapter_help" "read <result-file>" \
  "the adapter's help publishes the structured read command"

runner_help=$("$ROOT/bin/fm-procevent.sh" --help 2>&1 || true)
assert_contains "$runner_help" "Durability boundary" \
  "the runner's help scopes what it actually proves"
assert_not_contains "$runner_help" "exactly-once" \
  "the runner's help claims no exactly-once delivery"
pass "the published interfaces state the loss limitation and claim no lossless delivery"

# --- launch pacing and guard startup ----------------------------------------

FAST_SOURCE="$TMP_ROOT/fast-source.sh"
cat > "$FAST_SOURCE" <<'SH'
#!/usr/bin/env bash
perl -MTime::HiRes=time -e 'printf "%.6f\n", time' >> "$1"
exit 1
SH
chmod +x "$FAST_SOURCE"

STORM_SOURCE="$TMP_ROOT/storm-source.sh"
cat > "$STORM_SOURCE" <<'SH'
#!/usr/bin/env bash
perl -MTime::HiRes=time -e 'printf "%.6f\n", time' >> "$1"
FM_HOME="$2" perl -MPOSIX=setsid -e '
  my @command = @ARGV;
  defined(my $pid = fork) or exit 1;
  exit 0 if $pid;
  setsid() >= 0 or exit 1;
  open STDIN, "<", "/dev/null" or exit 1;
  open STDOUT, ">", "/dev/null" or exit 1;
  open STDERR, ">", "/dev/null" or exit 1;
  select undef, undef, undef, 0.2;
  exec @command;
' "$3/bin/fm-procevent.sh" reconcile
exit 1
SH
chmod +x "$STORM_SOURCE"

HFLOOR="$TMP_ROOT/launch-floor"; new_home "$HFLOOR"
fm_test_track_procevent_home "$HFLOOR"
pe_register "$HFLOOR" lavish floor-src -- \
  "$STORM_SOURCE" "$TMP_ROOT/launch-times" "$HFLOOR" "$ROOT"
# Three real launches can outlive a four-second lease on a loaded host. Give
# this fixture a bounded observation window, then retire it as soon as sampled
# rather than leaving its orphan loop running alongside the remaining tests.
FM_PROCEVENT_OWNER_LEASE_SECONDS=30 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 pe "$HFLOOR" reconcile >/dev/null
floor_deadline=$((SECONDS + 30))
while :; do
  floor_count=0
  [ ! -f "$TMP_ROOT/launch-times" ] \
    || floor_count=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
  [ "$floor_count" -ge 3 ] && break
  [ "$SECONDS" -lt "$floor_deadline" ] \
    || fail "the orphan-storm fixture launched only $floor_count times within its observation window"
  sleep 0.1
done
launch_count=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
launch_span=$(perl -e '@t=<>; printf "%.3f", $t[-1] - $t[0]' "$TMP_ROOT/launch-times")
pe "$HFLOOR" retire floor-src >/dev/null
perl -e 'exit($ARGV[0] >= ($ARGV[1] - 1) * 0.8 ? 0 : 1)' "$launch_span" "$launch_count" \
  || fail "an orphaned source launched $launch_count times in only ${launch_span}s"
[ "$launch_count" -le 6 ] \
  || fail "an orphaned source stormed $launch_count launches during its owner-dead grace window"
pass "an orphaned source command obeys the launch floor during its grace window"

HPACE="$TMP_ROOT/registration-pacing"; new_home "$HPACE"
fm_test_track_procevent_home "$HPACE"
PACE_LOG="$TMP_ROOT/registration-pacing.log"
pe_register "$HPACE" lavish pace-src -- "$FAST_SOURCE" "$PACE_LOG" >/dev/null
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3600 pe "$HPACE" start pace-src >/dev/null
pe "$HPACE" retire pace-src >/dev/null
pe_register "$HPACE" lavish pace-src -- "$FAST_SOURCE" "$PACE_LOG" >/dev/null
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3600 pe "$HPACE" start pace-src > "$TMP_ROOT/replacement-pacing.out" 2>&1 &
PACE_START_PID=$!
pace_deadline=$((SECONDS + 4))
while kill -0 "$PACE_START_PID" 2>/dev/null; do
  if [ "$SECONDS" -ge "$pace_deadline" ]; then
    pe "$HPACE" retire pace-src >/dev/null 2>&1 || true
    wait "$PACE_START_PID" 2>/dev/null || true
    fail "a replacement registration inherited the prior launch floor"
  fi
  sleep 0.1
done
wait "$PACE_START_PID" || fail "the replacement registration failed"
[ "$(wc -l < "$PACE_LOG" | tr -d ' ')" = 2 ] \
  || fail "a replacement registration did not launch immediately"
PACE_STAMPS=$(find "$HPACE/state/procevent" -maxdepth 1 -type f \
  -name 'pace-src.*.last-launch' | wc -l | tr -d ' ')
[ "$PACE_STAMPS" = 1 ] || fail "replacement registrations accumulated stale pacing state"
pass "a replacement registration starts with one fresh launch floor"

HPACE_RACE="$TMP_ROOT/registration-pacing-race"; new_home "$HPACE_RACE"
fm_test_track_procevent_home "$HPACE_RACE"
PACE_RACE_LOG="$TMP_ROOT/registration-pacing-race.log"
pe_register "$HPACE_RACE" lavish pace-race-src -- "$FAST_SOURCE" "$PACE_RACE_LOG" >/dev/null
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3 pe "$HPACE_RACE" start pace-race-src >/dev/null
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3 \
  pe "$HPACE_RACE" start pace-race-src > "$TMP_ROOT/registration-pacing-race.out" 2>&1 &
PACE_RACE_PID=$!
wait_for "$FM_PROCEVENT_CLAIM_ROOT/pace-race-src.claim" \
  || fail "the superseded pacing fixture did not claim its registration"
[ "$(wc -l < "$PACE_RACE_LOG" | tr -d ' ')" = 1 ] \
  || fail "the superseded pacing fixture was not waiting on its launch floor"
pe_register "$HPACE_RACE" lavish pace-race-src -- "$FAST_SOURCE" "$PACE_RACE_LOG" >/dev/null
wait "$PACE_RACE_PID" || fail "the superseded paced runner failed"
[ "$(wc -l < "$PACE_RACE_LOG" | tr -d ' ')" = 1 ] \
  || fail "the superseded paced runner invoked its stale command"
# The runner marker is written before the launch floor is waited on, and a home
# sweep counts a marker with no owned claim as a preflight failure. A superseded
# generation that exits without clearing its marker therefore makes the whole
# home refuse to sweep, so assert the marker is gone and the sweep still runs.
assert_absent "$HPACE_RACE/state/procevent/pace-race-src.runner" \
  "a superseded paced runner leaves no runner marker behind"
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3 pe "$HPACE_RACE" start pace-race-src >/dev/null
PACE_RACE_STAMPS=$(find "$HPACE_RACE/state/procevent" -maxdepth 1 -type f \
  -name 'pace-race-src.*.last-launch' | wc -l | tr -d ' ')
[ "$PACE_RACE_STAMPS" = 1 ] \
  || fail "a superseded sleeping runner recreated stale pacing state"
pass "a superseded sleeping runner cannot recreate stale pacing state"

HCOMMIT="$TMP_ROOT/registration-commit"; new_home "$HCOMMIT"
fm_test_track_procevent_home "$HCOMMIT"
COMMIT_LOG="$TMP_ROOT/registration-commit.log"
mkdir -p "$HCOMMIT/state/procevent/commit-src.1-2.last-launch"
pe_register "$HCOMMIT" lavish commit-src -- "$FAST_SOURCE" "$COMMIT_LOG" >/dev/null \
  || fail "post-commit pacing cleanup made registration report failure"
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 pe "$HCOMMIT" start commit-src >/dev/null \
  || fail "a successfully published registration was not executable"
[ "$(wc -l < "$COMMIT_LOG" | tr -d ' ')" = 1 ] \
  || fail "the committed registration did not invoke its source"
pass "post-commit pacing cleanup cannot veto registration publication"

HROLLBACK="$TMP_ROOT/rollback-pacing"; new_home "$HROLLBACK"
fm_test_track_procevent_home "$HROLLBACK"
ROLLBACK_LOG="$TMP_ROOT/rollback-pacing.log"
pe_register "$HROLLBACK" lavish rollback-src -- "$FAST_SOURCE" "$ROLLBACK_LOG" >/dev/null
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=1 pe "$HROLLBACK" start rollback-src >/dev/null
ROLLBACK_STAMP=
for candidate in "$HROLLBACK/state/procevent"/rollback-src.*.last-launch; do
  [ -f "$candidate" ] && ROLLBACK_STAMP=$candidate
done
[ -n "$ROLLBACK_STAMP" ] || fail "the first launch did not persist its pacing state"
printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$ROLLBACK_STAMP"
FM_PROCEVENT_LAUNCH_FLOOR_SECONDS=3600 pe "$HROLLBACK" start rollback-src > "$TMP_ROOT/rollback.out" 2>&1 &
ROLLBACK_START_PID=$!
rollback_deadline=$((SECONDS + 4))
while kill -0 "$ROLLBACK_START_PID" 2>/dev/null; do
  if [ "$SECONDS" -ge "$rollback_deadline" ]; then
    pe "$HROLLBACK" retire rollback-src >/dev/null 2>&1 || true
    wait "$ROLLBACK_START_PID" 2>/dev/null || true
    fail "a pre-reboot monotonic stamp delayed the first launch"
  fi
  sleep 0.1
done
wait "$ROLLBACK_START_PID" || fail "the rollback-paced source failed"
[ "$(wc -l < "$ROLLBACK_LOG" | tr -d ' ')" = 2 ] \
  || fail "the rollback-paced source did not invoke twice"
pass "a pre-reboot monotonic stamp is treated as expired"

storm_deadline=$((SECONDS + 15))
while :; do
  storm_before=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
  sleep 2
  storm_after=$(wc -l < "$TMP_ROOT/launch-times" | tr -d ' ')
  [ "$storm_before" = "$storm_after" ] && break
  [ "$SECONDS" -lt "$storm_deadline" ] \
    || fail "an orphaned self-relaunching source survived its expired owner lease"
done
pass "an expired owner lease stops a self-relaunching source generation"

HRECREATED="$TMP_ROOT/recreated-owner"; new_home "$HRECREATED"
fm_test_track_procevent_home "$HRECREATED"
RECREATED_TRIGGER="$TMP_ROOT/recreated-owner.trigger"
pe_register "$HRECREATED" lavish recreated-src -- \
  "$BLOCKER" "$RECREATED_TRIGGER" "recreated payload" >/dev/null
FM_PROCEVENT_OWNER_LEASE_SECONDS=30 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  pe "$HRECREATED" reconcile >/dev/null
wait_for "$HRECREATED/state/procevent/recreated-src.runner" \
  || fail "the recreated-path fixture never launched its source"
RECREATED_RUNNER_PID=$(cat "$HRECREATED/state/procevent/recreated-src.runner")
mv "$HRECREATED/state" "$TMP_ROOT/recreated-owner-old-state"
pe_register "$HRECREATED" lavish recreated-src -- \
  "$BLOCKER" "$RECREATED_TRIGGER" "replacement payload" >/dev/null
FM_PROCEVENT_OWNER_LEASE_SECONDS=30 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  pe "$HRECREATED" reconcile >/dev/null
recreated_deadline=$((SECONDS + 8))
while kill -0 "$RECREATED_RUNNER_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$recreated_deadline" ] \
    || fail "a fresh lease at a recreated state path preserved the old runner"
  sleep 0.1
done
pass "a recreated state path does not preserve the old runner"

HGUARDFAIL="$TMP_ROOT/guard-failure"; new_home "$HGUARDFAIL"
fm_test_track_procevent_home "$HGUARDFAIL"
pe_register "$HGUARDFAIL" lavish guard-fail-src -- "$FAST_SOURCE" "$TMP_ROOT/unguarded-launches"
guard_fail_status=0
guard_fail_out=$(FM_PROCEVENT_OWNER_LEASE_SECONDS=invalid \
  pe "$HGUARDFAIL" start guard-fail-src 2>&1) || guard_fail_status=$?
[ "$guard_fail_status" -ne 0 ] || fail "a runner continued after its owner guard failed to initialize"
assert_contains "$guard_fail_out" "cannot start the runner's owner guard" \
  "guard initialization failure is reported at the runner boundary"
assert_absent "$TMP_ROOT/unguarded-launches" \
  "a source command ran without a successfully initialized owner guard"
pass "a runner fails closed when its owner guard cannot initialize"

HATTACHED="$TMP_ROOT/attached-owner"; new_home "$HATTACHED"
fm_test_track_procevent_home "$HATTACHED"
ATTACHED_TRIGGER="$TMP_ROOT/attached.trigger"
pe_register "$HATTACHED" lavish attached-src -- "$BLOCKER" "$ATTACHED_TRIGGER" "attached payload"
FM_PROCEVENT_OWNER_LEASE_SECONDS=1 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  pe "$HATTACHED" start attached-src > "$TMP_ROOT/attached.out" 2>&1 &
ATTACHED_START_PID=$!
wait_for "$HATTACHED/state/procevent/attached-src.runner" \
  || fail "the attached start never launched its source"
sleep 4
kill -0 "$ATTACHED_START_PID" 2>/dev/null \
  || fail "a foreground start lost its owner lease while its caller remained attached"
touch "$ATTACHED_TRIGGER"
wait "$ATTACHED_START_PID" || fail "the attached start did not complete after its source returned"
assert_contains "$(cat "$TMP_ROOT/attached.out")" "captured:" \
  "the attached source result was not captured"
pass "a foreground start refreshes its lease while its caller remains attached"

HCLOCK="$TMP_ROOT/lease-clock"; new_home "$HCLOCK"
fm_test_track_procevent_home "$HCLOCK"
CLOCK_TRIGGER="$TMP_ROOT/lease-clock.trigger"
CLOCK_STATE="$TMP_ROOT/lease-clock-state"
CLOCK_BIN=$(fm_fakebin "$TMP_ROOT/lease-clock-bin")
REAL_DATE=$(command -v date) || fail "the lease clock fixture requires date"
cat > "$CLOCK_BIN/date" <<SH
#!/usr/bin/env bash
if [ "\${1-}" = +%s ]; then
  while ! mkdir "$CLOCK_STATE.lock" 2>/dev/null; do sleep 0.01; done
  value=0
  [ ! -f "$CLOCK_STATE" ] || value=\$(cat "$CLOCK_STATE")
  value=\$((value + 10000))
  printf '%s\n' "\$value" > "$CLOCK_STATE"
  rmdir "$CLOCK_STATE.lock"
  printf '%s\n' "\$value"
  exit 0
fi
exec "$REAL_DATE" "\$@"
SH
chmod +x "$CLOCK_BIN/date"
pe_register "$HCLOCK" lavish lease-clock-src -- \
  "$BLOCKER" "$CLOCK_TRIGGER" "clock payload" >/dev/null
PATH="$CLOCK_BIN:$PATH" FM_PROCEVENT_OWNER_LEASE_SECONDS=1 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  pe "$HCLOCK" start lease-clock-src > "$TMP_ROOT/lease-clock.out" 2>&1 &
CLOCK_START_PID=$!
wait_for "$HCLOCK/state/procevent/lease-clock-src.runner" \
  || fail "the clock-shift fixture never launched its source"
sleep 4
kill -0 "$CLOCK_START_PID" 2>/dev/null \
  || fail "wall-clock corrections expired a live foreground owner"
touch "$CLOCK_TRIGGER"
wait "$CLOCK_START_PID" || fail "the clock-shift fixture did not complete"
pass "wall-clock corrections do not alter owner lease age"

HDETACHED="$TMP_ROOT/detached-attached-owner"; new_home "$HDETACHED"
fm_test_track_procevent_home "$HDETACHED"
DETACHED_TRIGGER="$TMP_ROOT/detached-attached.trigger"
pe_register "$HDETACHED" lavish detached-attached-src -- \
  "$BLOCKER" "$DETACHED_TRIGGER" "detached attached payload"
FM_PROCEVENT_OWNER_LEASE_SECONDS=1 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 FM_HOME="$HDETACHED" \
  perl -MPOSIX=setsid -e 'setsid() >= 0 or exit 1; exec @ARGV' \
    "$ROOT/bin/fm-procevent.sh" start detached-attached-src \
    > "$TMP_ROOT/detached-attached.out" 2>&1 &
DETACHED_START_PID=$!
wait_for "$HDETACHED/state/procevent/detached-attached-src.runner" \
  || fail "the detachable foreground start never launched its source"
DETACHED_RUNNER_PID=$(cat "$HDETACHED/state/procevent/detached-attached-src.runner")
kill "$DETACHED_START_PID"
wait "$DETACHED_START_PID" 2>/dev/null || true
detached_deadline=$((SECONDS + 8))
while kill -0 "$DETACHED_RUNNER_PID" 2>/dev/null; do
  if [ "$SECONDS" -ge "$detached_deadline" ]; then
    pe "$HDETACHED" retire detached-attached-src >/dev/null 2>&1 || true
    fail "an orphaned attached-start keeper preserved its owner's lease"
  fi
  sleep 0.1
done
pass "an attached-start keeper stops refreshing after its parent exits"

HREUSED_GROUP="$TMP_ROOT/reused-runner-group"; new_home "$HREUSED_GROUP"
fm_test_track_procevent_home "$HREUSED_GROUP"
REUSED_GROUP_MARKER="$TMP_ROOT/reused-runner-group.marker"
REUSED_GROUP_TRIGGER="$TMP_ROOT/reused-runner-group.trigger"
REUSED_GROUP_BIN=$(fm_fakebin "$TMP_ROOT/reused-runner-group-bin")
REAL_PS=$(command -v ps) || fail "the reused-group fixture requires ps"
cat > "$REUSED_GROUP_BIN/ps" <<SH
#!/usr/bin/env bash
if [ -e "$REUSED_GROUP_MARKER" ] && [ "\${1-}" = -p ] \
  && [ "\${3-}" = -o ] && [ "\${4-}" = lstart= ]; then
  printf 'reused runner identity\n'
  exit 0
fi
exec "$REAL_PS" "\$@"
SH
chmod +x "$REUSED_GROUP_BIN/ps"
pe_register "$HREUSED_GROUP" lavish reused-runner-group-src -- \
  "$BLOCKER" "$REUSED_GROUP_TRIGGER" "reused group payload" >/dev/null
PATH="$REUSED_GROUP_BIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-reused-group-proc" \
  FM_PROCEVENT_OWNER_LEASE_SECONDS=30 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
  pe "$HREUSED_GROUP" reconcile >/dev/null
wait_for "$HREUSED_GROUP/state/procevent/reused-runner-group-src.runner" \
  || fail "the reused-group fixture runner did not start"
REUSED_GROUP_RUNNER=$(cat "$HREUSED_GROUP/state/procevent/reused-runner-group-src.runner")
touch "$REUSED_GROUP_MARKER"
sleep 3
kill -0 -"$REUSED_GROUP_RUNNER" 2>/dev/null \
  || fail "the guard killed a process group after its runner identity became ambiguous"
# Retiring here must read identity from the source this runner was recorded
# under, so the override stays in place: without it the read falls back to
# /proc where that exists, which is a different source than the recorded ps
# identity, and the guard would refuse this retirement on Linux while accepting
# it on macOS. Clearing the marker restores the matching identity, so this also
# asserts the complementary guarantee - once the ambiguity is gone, retirement
# reaps the whole group rather than leaving it behind.
rm -f "$REUSED_GROUP_MARKER"
PATH="$REUSED_GROUP_BIN:$PATH" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-reused-group-proc" \
  pe "$HREUSED_GROUP" retire reused-runner-group-src >/dev/null
for _ in $(seq 1 50); do kill -0 -"$REUSED_GROUP_RUNNER" 2>/dev/null || break; sleep 0.1; done
kill -0 -"$REUSED_GROUP_RUNNER" 2>/dev/null \
  && fail "retirement left the group alive once runner identity was unambiguous"
pass "a detected ambiguous reused-PID group is not signalled"

# --- an accidentally orphaned runner is bounded by its owner ----------------
#
# Reproduces the shape that wedged a host: a listener detached into its own
# process group, reparented to init when its session ended, and left running for
# a day with its blocking child - and everything that child spawned - still
# executing. The cost was not the runner itself but the process churn under it,
# which is why this asserts the whole descendant tree stops, not just the leader.
#
# Scope is asserted alongside it, in the same run and against the same stub: a
# home whose session is still there keeps its runner. Reaping that keyed on the
# script or process name instead of the owning session would take both.

ORPHAN_STUB="$TMP_ROOT/orphan-stub.sh"
cat > "$ORPHAN_STUB" <<'SH'
#!/usr/bin/env bash
# A blocking source whose child keeps spawning processes, which is what a poll
# stub waiting on a trigger file actually does. The spawn rate is what turned a
# leftover listener into a host-wide storm, so the tick log is the evidence that
# the storm stopped and not merely that one pid went away.
marker=$1
( while [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ]; do
    printf 'tick\n' >> "$marker.ticks"
    sleep 0.1
  done ) &
printf '%s\n' "$!" > "$marker.descendant"
while [ ! -e "$marker.trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.1
done
printf 'orphan payload\n'
SH
chmod +x "$ORPHAN_STUB"

# The same shape without the spawn churn, for the home that exercises explicit
# retirement rather than the storm. Retirement refuses instead of signalling
# when it cannot confirm the runner's identity, that identity is read through
# `ps`, and the churning stub above starves that read often enough to make a
# single retirement attempt a race. The storm itself is already covered against
# the churning stub by the owner-loss reaping above, which asserts the tick log
# stops, so this home only needs a reparented listener holding a real
# descendant in its group.
QUIET_STUB="$TMP_ROOT/quiet-stub.sh"
cat > "$QUIET_STUB" <<'SH'
#!/usr/bin/env bash
marker=$1
( sleep "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ) &
printf '%s\n' "$!" > "$marker.descendant"
while [ ! -e "$marker.trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.1
done
printf 'orphan payload\n'
SH
chmod +x "$QUIET_STUB"

# Short enough to observe, and driven through the same environment a real home
# uses, so the bound under test is the shipped one rather than a test-only path.
# One source of truth for the shortened lease and check these fixtures run under,
# so a case that derives a deadline from the guard's documented bound cannot
# silently diverge from the settings the guard is actually given.
PROOF_LEASE_SECONDS=2
PROOF_CHECK_SECONDS=1

# The documented bound, derived here rather than restated as a flat number.
#
# The whole-second lease comparison is part of the bound, not slack: a lease of
# N is honoured until its age reads N+1, so the lease term is N+1.
PROOF_LEASE_BOUND=$((PROOF_LEASE_SECONDS + 1))
# Detection is the lease plus ONE check interval. The guard still takes two
# consecutive failing reads before it acts - one unreadable read must not end a
# live runner - but they are spaced half an interval apart, so the pair fits
# inside the single interval this term budgets.
PROOF_DETECT_BOUND=$((PROOF_LEASE_BOUND + PROOF_CHECK_SECONDS))
# The stop's own ceiling: two seconds for the ordinary signal, then two for the
# forced one. Only a group that outlives the ordinary signal spends it, so a
# case whose stub exits on that signal uses PROOF_PROMPT_STOP instead.
PROOF_STOP_CEILING=4
PROOF_PROMPT_STOP=1
# Additive scheduling slack shared by cleanup and timing cases. The strict
# timing case below owns and enforces its relation to BOUND_CHECK_SECONDS.
PROOF_LOAD_SLACK=2

orphan_pe() {  # <home> <command...>
  local home=$1
  shift
  FM_PROCEVENT_OWNER_LEASE_SECONDS="$PROOF_LEASE_SECONDS" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$PROOF_CHECK_SECONDS" \
    FM_HOME="$home" "$ROOT/bin/fm-procevent.sh" "$@"
}

wait_gone() {  # <pid-or-group-spec> [tries]
  local spec=$1 n=${2:-160}
  for _ in $(seq 1 "$n"); do
    kill -0 "$spec" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}

HORPHAN="$TMP_ROOT/orphan-dead-owner"; new_home "$HORPHAN"
fm_test_track_procevent_home "$HORPHAN"
HKEEP="$TMP_ROOT/orphan-live-owner"; new_home "$HKEEP"
fm_test_track_procevent_home "$HKEEP"
orphan_pe "$HORPHAN" register lavish orphan-src -- "$ORPHAN_STUB" "$TMP_ROOT/orphan-dead" >/dev/null
orphan_pe "$HKEEP" register lavish keep-src -- "$QUIET_STUB" "$TMP_ROOT/orphan-live" >/dev/null
orphan_pe "$HORPHAN" reconcile >/dev/null
orphan_pe "$HKEEP" reconcile >/dev/null

wait_for "$HORPHAN/state/procevent/orphan-src.runner" \
  || fail "the dead-owner listener never recorded its runner"
wait_for "$HKEEP/state/procevent/keep-src.runner" \
  || fail "the live-owner listener never recorded its runner"
wait_for "$TMP_ROOT/orphan-dead.descendant" \
  || fail "the dead-owner listener's child never spawned its own descendant"
ORPHAN_PID=$(cat "$HORPHAN/state/procevent/orphan-src.runner")
KEEP_PID=$(cat "$HKEEP/state/procevent/keep-src.runner")
ORPHAN_DESCENDANT=$(cat "$TMP_ROOT/orphan-dead.descendant")

# The reproduction condition itself: the listener is already an orphan in the
# kernel's sense before anything is asserted about reaping it.
orphan_ppid=$(ps -o ppid= -p "$ORPHAN_PID" 2>/dev/null | tr -d '[:space:]')
[ "$orphan_ppid" = 1 ] \
  || fail "the listener under test was not reparented away from its session (ppid $orphan_ppid)"
kill -0 -"$ORPHAN_PID" 2>/dev/null \
  || fail "the listener's process group was not running"
kill -0 "$ORPHAN_DESCENDANT" 2>/dev/null \
  || fail "the listener's descendant was not running"
pass "a detached listener starts reparented, with a live descendant tree under it"

# Only the second home's session stays present, on the same short bound, so the
# owning session is the single difference between the two listeners.
keep_owner_present() { orphan_pe "$HKEEP" reconcile >/dev/null 2>&1 || true; sleep 0.25; }

# This stub exits on the ordinary signal, so the stop ceiling is not spent here.
# The deadline is DERIVED from the documented bound; the timing case below is
# the one that pins the bound's worst case, while this one asserts that the
# reaping happens at all and cannot quietly take an unbounded amount of time.
orphan_bound=$((PROOF_DETECT_BOUND + PROOF_PROMPT_STOP))
deadline=$((SECONDS + orphan_bound + PROOF_LOAD_SLACK))
orphan_started=$SECONDS
while kill -0 -"$ORPHAN_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "a listener whose owning session was gone kept its process group running for $((SECONDS - orphan_started))s, against a documented bound of ${orphan_bound}s"
  keep_owner_present
done
# The descendant goes down with the same group signal, so it needs no bound of
# its own beyond the slack that covers a loaded host.
deadline=$((SECONDS + PROOF_LOAD_SLACK))
while kill -0 "$ORPHAN_DESCENDANT" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "a listener whose owning session was gone left a descendant running"
  keep_owner_present
done
pass "a listener whose owning session is gone stops itself and its whole process group"

keep_owner_present
before=$(wc -l < "$TMP_ROOT/orphan-dead.ticks" | tr -d ' ')
deadline=$((SECONDS + 2))
while [ "$SECONDS" -lt "$deadline" ]; do keep_owner_present; done
after=$(wc -l < "$TMP_ROOT/orphan-dead.ticks" | tr -d ' ')
[ "$before" = "$after" ] \
  || fail "the reaped listener's descendant kept spawning processes ($before then $after)"
pass "reaping the listener stops the process churn under it"

keep_owner_present
kill -0 -"$KEEP_PID" 2>/dev/null \
  || fail "an identical listener in a home whose session is still there was reaped too"
pass "an identical listener in a home whose session is still there is untouched"

# Retirement remains the explicit path, and it must reach a listener that has
# already reparented, along with everything under it.
wait_for "$TMP_ROOT/orphan-live.descendant" \
  || fail "the live-owner listener's child never spawned its own descendant"
KEEP_DESCENDANT=$(cat "$TMP_ROOT/orphan-live.descendant")
keep_owner_present
orphan_pe "$HKEEP" retire keep-src >/dev/null
wait_gone "-$KEEP_PID" \
  || fail "retiring a source left its reparented listener's process group running"
wait_gone "$KEEP_DESCENDANT" \
  || fail "retiring a source left a descendant of its listener running"
pass "retiring a source reaps its reparented listener and every descendant under it"

# --- an expired runner's guard retries unproved cleanup ---------------------
#
# A stop the guard cannot PROVE must not end the guard. A descendant still
# finishing uninterruptible work outlives even the group KILL, and a guard that
# gave up after one attempt would walk away from a still-running expired runner.
#
# The unprovable attempt is injected through the signal the real path actually
# reads: `ps` answers ONE process-group query for the runner with a group it
# does not lead, which is exactly how a stop that cannot be proved is reported.
# Every other `ps` call, and every later one, is the real command.

RETRY_HOME="$TMP_ROOT/stop-retry"; new_home "$RETRY_HOME"
fm_test_track_procevent_home "$RETRY_HOME"
RETRY_STATE="$TMP_ROOT/stop-retry-state"; mkdir -p "$RETRY_STATE"
RETRY_BIN=$(fm_fakebin "$TMP_ROOT/stop-retry-bin")
REAL_PS=$(command -v ps) || fail "this host has no ps to build the retry fixture on"
cat > "$RETRY_BIN/ps" <<SH
#!/usr/bin/env bash
if [ "\$1" = -o ] && [ "\$2" = "pgid=" ] && [ "\$3" = -p ] \\
  && [ -s "\$STOP_RETRY_STATE/target" ] \\
  && [ "\$4" = "\$(cat "\$STOP_RETRY_STATE/target")" ] \\
  && [ ! -e "\$STOP_RETRY_STATE/spent" ]; then
  : > "\$STOP_RETRY_STATE/spent"
  printf ' 999999\n'
  exit 0
fi
exec "$REAL_PS" "\$@"
SH
chmod +x "$RETRY_BIN/ps"

retry_pe() {  # <command...>
  PATH="$RETRY_BIN:$PATH" STOP_RETRY_STATE="$RETRY_STATE" \
    FM_PROCEVENT_OWNER_LEASE_SECONDS=2 FM_PROCEVENT_OWNER_CHECK_SECONDS=1 \
    FM_HOME="$RETRY_HOME" "$ROOT/bin/fm-procevent.sh" "$@"
}

retry_pe register lavish retry-src -- "$ORPHAN_STUB" "$TMP_ROOT/stop-retry-marker" >/dev/null
retry_pe reconcile >/dev/null
wait_for "$RETRY_HOME/state/procevent/retry-src.runner" \
  || fail "the retry listener never recorded its runner"
RETRY_PID=$(cat "$RETRY_HOME/state/procevent/retry-src.runner")
# Armed only now: the runner already proved its own process group at startup,
# and arming earlier would fail that assertion instead of the stop under test.
printf '%s\n' "$RETRY_PID" > "$RETRY_STATE/target"
wait_for "$TMP_ROOT/stop-retry-marker.descendant" \
  || fail "the retry listener's child never spawned its own descendant"
RETRY_DESCENDANT=$(cat "$TMP_ROOT/stop-retry-marker.descendant")

deadline=$((SECONDS + 60))
while kill -0 -"$RETRY_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "the guard gave up on an expired runner after a stop it could not prove"
  sleep 0.5
done
[ -e "$RETRY_STATE/spent" ] \
  || fail "the unprovable stop attempt this test injects never happened"
wait_gone "$RETRY_DESCENDANT" \
  || fail "the guard stopped retrying before the expired runner's descendant was reaped"
pass "a stop the guard cannot prove is retried until the expired runner is reaped"

# --- a stop reaches a child that does not die on the ordinary signal ---------
#
# Every reaper here sends the ordinary stop signal to the runner's process group
# and escalates only if the group outlives it. Both halves of that escalation
# were broken, in ways that hid each other:
#
#   - The stop held the per-source lock across its wait while the runner's own
#     exit cleanup waited for that same lock, so the runner outlived the ordinary
#     signal every time and the forced kill silently became the normal path.
#   - The escalation re-derived ownership from the leader, so once the leader did
#     die to the stop's own signal it read that success as a leaderless group and
#     refused to escalate at all.
#
# With only the first repaired, the second turned every stop of a signal-proof
# child into a refusal that left it running. They are asserted together because
# they only hold together.
#
# Earlier fixtures include TERM-resistant children and deliberately kept-alive
# leaders. The cases below also exercise escalation after TERM ends the leader.

# Millisecond clock for supplementary retirement and stop-window measurements;
# the healthy-stop verdict below requires attached-start status 143 (TERM).
now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

SIGNAL_PROOF_STUB="$TMP_ROOT/signal-proof-stub.sh"
cat > "$SIGNAL_PROOF_STUB" <<'SH'
#!/usr/bin/env bash
# A blocking source whose child handles the ordinary stop signal and keeps
# waiting - the shape a poll client with its own shutdown handler presents while
# a request is still outstanding. Reaching it requires a real escalation. The
# signal log is what proves the child was signalled and survived, rather than
# never having been signalled at all. The wait stays bounded so an escaped stub
# cannot outlive the suite.
marker=$1
trap 'printf "signalled\n" >> "$marker.signals"' TERM INT HUP
printf '%s\n' "$$" > "$marker.child"
while [ ! -e "$marker.trigger" ]; do
  [ "$SECONDS" -lt "${FM_TEST_STUB_MAX_BLOCK_SECONDS:-120}" ] || exit 75
  sleep 0.1 &
  wait $!
done
printf 'signal-proof payload\n'
SH
chmod +x "$SIGNAL_PROOF_STUB"

trap '[ -z "${PROOF_RELEASE:-}" ] || touch "$PROOF_RELEASE"; fm_test_cleanup' EXIT
for proof_state in absent zombie; do
  HPROOF="$TMP_ROOT/signal-proof-retire-$proof_state"; new_home "$HPROOF"
  PROOF_MARKER="$HPROOF/poll"
  pe_register "$HPROOF" lavish proof-src -- "$SIGNAL_PROOF_STUB" "$PROOF_MARKER" >/dev/null
  PROOF_RELEASE=
  if [ "$proof_state" = zombie ]; then
    PROOF_RELEASE="$HPROOF/reap"
    FM_HOME="$HPROOF" FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proof-proc" \
      perl - "$PROOF_RELEASE" "$ROOT/bin/fm-procevent.sh" _start proof-src >"$HPROOF/start.log" 2>&1 <<'PL' &
my $release = shift @ARGV;
defined(my $pid = fork) or exit 125;
if ($pid == 0) {
  setpgrp(0, 0) or exit 125;
  $ENV{FM_PROCEVENT_RUNNER_GROUP} = $$;
  exec @ARGV;
  exit 125;
}
my $deadline = time + ($ENV{FM_TEST_STUB_MAX_BLOCK_SECONDS} // 120);
while (!-e $release && time < $deadline) { select undef, undef, undef, 0.05; }
waitpid($pid, 0) == $pid or exit 125;
PL
  else
    FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proof-proc" \
      pe "$HPROOF" start proof-src >"$HPROOF/start.log" 2>&1 &
  fi
  PROOF_START=$!
  wait_for "$HPROOF/state/procevent/proof-src.runner" \
    || fail "the signal-proof listener never recorded its runner"
  PROOF_PID=$(cat "$HPROOF/state/procevent/proof-src.runner")
  wait_for "$PROOF_MARKER.child" || fail "the signal-proof child never started"
  PROOF_CHILD=$(cat "$PROOF_MARKER.child")
  FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/no-proof-proc" \
    pe "$HPROOF" retire proof-src >"$HPROOF/retire.log" 2>&1 &
  PROOF_STOP=$!
  proof_transition=0
  for _ in $(seq 1 100); do
    if [ "$proof_state" = zombie ]; then
      case "$(ps -o stat= -p "$PROOF_PID" 2>/dev/null | tr -d '[:space:]')" in
        Z*) proof_transition=1; break ;;
      esac
    elif ! kill -0 "$PROOF_PID" 2>/dev/null; then
      proof_transition=1
      break
    fi
    sleep 0.05
  done
  proof_survivor=0
  kill -0 "$PROOF_CHILD" 2>/dev/null && proof_survivor=1
  proof_reaped=0
  for _ in $(seq 1 100); do
    if ! kill -0 "$PROOF_CHILD" 2>/dev/null; then proof_reaped=1; break; fi
    sleep 0.1
  done
  [ -z "$PROOF_RELEASE" ] || touch "$PROOF_RELEASE"
  PROOF_RELEASE=
  proof_status=0
  wait "$PROOF_STOP" || proof_status=$?
  [ "$proof_reaped" -eq 1 ] || kill -KILL -"$PROOF_PID" 2>/dev/null || true
  wait "$PROOF_START" 2>/dev/null || true
  [ "$proof_transition" -eq 1 ] || fail "the runner never became $proof_state after TERM"
  [ "$proof_survivor" -eq 1 ] || fail "no child survived the $proof_state leader's TERM"
  [ "$proof_reaped" -eq 1 ] || fail "escalation abandoned a child behind a $proof_state leader"
  [ "$proof_status" -eq 0 ] || fail "retiring the $proof_state leader's group reported failure"
  wait_gone "-$PROOF_PID" || fail "retirement left the $proof_state leader's group running"
  [ -s "$PROOF_MARKER.signals" ] || fail "the signal-proof child never received TERM"
  pass "retirement escalates after TERM leaves a surviving child ($proof_state leader)"
done
trap fm_test_cleanup EXIT

# --- the owner guard reaps a signal-proof child too --------------------------
#
# The guard is where the time bound on a leaked listener lives, so it is the half
# that matters most: a guard that signals, loses its leader to its own signal and
# then walks away leaves the survivor unreachable by anything at all - worse than
# no guard, because the leader it destroyed was the only proof of ownership left.

HPGUARD="$TMP_ROOT/signal-proof-guard"; new_home "$HPGUARD"
fm_test_track_procevent_home "$HPGUARD"
orphan_pe "$HPGUARD" register lavish proof-guard-src \
  -- "$SIGNAL_PROOF_STUB" "$TMP_ROOT/proof-guard" >/dev/null
orphan_pe "$HPGUARD" reconcile >/dev/null
# The owner is kept present until the fixture is fully up, because the input
# under test is an owner that GOES AWAY, not a runner that never finished
# starting: on a loaded host the short lease here can otherwise expire while the
# runner is still between fork and its first recorded state.
deadline=$((SECONDS + 60))
until [ -s "$HPGUARD/state/procevent/proof-guard-src.runner" ] \
  && [ -s "$TMP_ROOT/proof-guard.child" ]; do
  [ "$SECONDS" -lt "$deadline" ] || fail "the guarded signal-proof listener never started"
  orphan_pe "$HPGUARD" reconcile >/dev/null 2>&1 || true
  sleep 0.25
done
GUARD_PID=$(cat "$HPGUARD/state/procevent/proof-guard-src.runner")
GUARD_CHILD=$(cat "$TMP_ROOT/proof-guard.child")

# Nothing refreshes this home's lease from here on, which is the whole input.
#
# The deadline is DERIVED from the bound this case exists to defend, not a flat
# wall-clock number. The documented bound is the lease term, plus ONE check
# interval for detection - the guard's two confirming reads are half an interval
# apart and both fit inside it - plus the stop's own grace, its ordinary signal
# window and then its forced one. THIS case does spend that grace, because its
# child ignores the ordinary signal; that is what separates its allowance from
# the ordinary-stop case above.
#
# This case bounds cleanup completion; the strict timing case below owns the
# phase and slack requirements that distinguish one check interval from two.
guard_bound=$((PROOF_DETECT_BOUND + PROOF_STOP_CEILING))
deadline=$((SECONDS + guard_bound + PROOF_LOAD_SLACK))
guard_started=$SECONDS
while kill -0 -"$GUARD_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] \
    || fail "the guard exceeded its bound: still holding the group after $((SECONDS - guard_started))s, against a documented bound of ${guard_bound}s"
  sleep 0.5
done
wait_gone "$GUARD_CHILD" \
  || fail "the guard stopped at the leader and left the signal-proof child running"
[ -s "$TMP_ROOT/proof-guard.signals" ] \
  || fail "the guarded child was never signalled, so nothing about escalation was exercised"
pass "an expired runner's guard escalates past a signal-proof child"

# --- the guard's bound is one check interval, not two ------------------------
#
# The case above proves the guard reaps at all. This one measures HOW LONG it
# may take, because that is the number the operating contract states and the one
# a later change can quietly double.
#
# The bound: the lease term, plus ONE check interval. The guard still refuses to
# act on a single failed read - the debounce case below is what defends that -
# but its two confirming reads are spaced half an interval apart, so the pair
# fits inside the one interval budgeted here. A guard that put a whole interval
# between them would spend two, and this deadline is sized to catch exactly that.
#
# THE PHASE IS OBSERVED AND ENFORCED, NOT ASSUMED. Where the lease expiry falls
# relative to the guard's own check clock decides whether a run lands near the
# bound or well inside it, and a sampled phase would let a guard spending two
# intervals slip under this deadline on a lucky alignment. So the lease is
# synchronized to the guard's own FIRST observed lease read, every later real
# read is recorded, and the case then REFUSES unless one of those reads proves
# the required phase: fresh, before expiry, and late enough that two further
# full intervals could not finish before the deadline.
#
# Pinning the phase by construction instead - from an assumed startup time - is
# what an earlier version of this case did, and it is not enough: the day
# startup reaches two seconds it silently stops rejecting a two-interval guard
# and goes on passing. A bound that cannot fail for the reason it names is the
# defect this whole delivery exists to correct, so an unestablished precondition
# refuses here rather than proceeding on trust.
BOUND_LEASE_SECONDS=7
BOUND_CHECK_SECONDS=6
# The whole-second lease comparison is part of the bound, not slack: a lease of
# N is honoured until its age reads N+1.
bound_lease_term=$((BOUND_LEASE_SECONDS + 1))
bound_detect=$((bound_lease_term + BOUND_CHECK_SECONDS))
# This stub exits on the ordinary signal, so the stop's escalation ceiling is
# not spent here; one second covers signalling and exit against a measured
# ~0.4s for a whole retire command on this host.
bound_total=$((bound_detect + PROOF_PROMPT_STOP))
# Additive load slack, under half a check interval for the reason above. The
# invariant is asserted rather than left to a comment, because a later widening
# is exactly what would disarm the deadline below.
bound_deadline_s=$((bound_total + PROOF_LOAD_SLACK))
[ "$((PROOF_LOAD_SLACK * 2))" -lt "$BOUND_CHECK_SECONDS" ] \
  || fail "the bound fixture's load slack must stay below half a check interval"

now_mono() {
  perl -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \
    'printf "%.3f\n", clock_gettime(CLOCK_MONOTONIC)'
}
mono_since() {  # <monotonic-reference>: seconds elapsed, one decimal
  perl -e 'printf "%.1f\n", $ARGV[0] - $ARGV[1]' "$(now_mono)" "$1"
}

HBOUND="$TMP_ROOT/guard-bound"; new_home "$HBOUND"
fm_test_track_procevent_home "$HBOUND"
BOUND_STATE="$TMP_ROOT/guard-bound-state"; mkdir -p "$BOUND_STATE"
BOUND_BIN=$(fm_fakebin "$TMP_ROOT/guard-bound-bin")
REAL_PERL=$(command -v perl) || fail "this host has no perl to observe the guard's lease reads"
# Observes the real lease-age reads, identified by the lease-age program's own
# text, and changes nothing about what they return. The FIRST such read becomes
# the lease reference - that is the synchronization - and every later one is
# recorded with the value it read and the interval it spanned, which is the
# evidence the phase assertion below consumes.
cat > "$BOUND_BIN/perl" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  case \$arg in
    *'int(\$now - \$value)'*)
      started=\$("$REAL_PERL" -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \\
        'printf "%.6f\\n", clock_gettime(CLOCK_MONOTONIC)') || exit 1
      age=\$("$REAL_PERL" "\$@") || exit \$?
      finished=\$("$REAL_PERL" -MTime::HiRes=clock_gettime,CLOCK_MONOTONIC -e \\
        'printf "%.6f\\n", clock_gettime(CLOCK_MONOTONIC)') || exit 1
      if [ ! -s "\$GUARD_BOUND_STATE/reference" ]; then
        printf '%s\\n' "\$finished" > "\$FM_HOME/state/procevent/.owner-lease" || exit 1
        printf '%s\\n' "\$finished" > "\$GUARD_BOUND_STATE/reference" || exit 1
      else
        printf '%s\\t%s\\t%s\\t%s\\n' "\$started" "\$finished" "\$age" "\${!#}" \\
          >> "\$GUARD_BOUND_STATE/reads" || exit 1
      fi
      printf '%s\\n' "\$age"
      exit 0
      ;;
  esac
done
exec "$REAL_PERL" "\$@"
SH
chmod +x "$BOUND_BIN/perl"
bound_pe() {
  PATH="$BOUND_BIN:$PATH" GUARD_BOUND_STATE="$BOUND_STATE" \
    FM_PROCEVENT_OWNER_LEASE_SECONDS="$BOUND_LEASE_SECONDS" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$BOUND_CHECK_SECONDS" \
    FM_HOME="$HBOUND" "$ROOT/bin/fm-procevent.sh" "$@"
}
bound_pe register lavish bound-src -- "$QUIET_STUB" "$TMP_ROOT/guard-bound-marker" >/dev/null
bound_pe reconcile >/dev/null
wait_for "$HBOUND/state/procevent/bound-src.runner" \
  || fail "the bound fixture's listener never recorded its runner"
wait_for "$TMP_ROOT/guard-bound-marker.descendant" \
  || fail "the bound fixture's listener never spawned its descendant"
BOUND_PID=$(cat "$HBOUND/state/procevent/bound-src.runner")
BOUND_DESCENDANT=$(cat "$TMP_ROOT/guard-bound-marker.descendant")
# Elapsed is measured from the refresh the guard itself reads, not from a
# wall-clock moment near it, so the fixture's own startup cost cannot be
# mistaken for guard latency in either direction.
bound_reference=$(cat "$HBOUND/state/procevent/.owner-lease") \
  || fail "the bound fixture recorded no owner lease to measure against"
[ "$bound_reference" = "$(cat "$BOUND_STATE/reference" 2>/dev/null)" ] \
  || fail "the bound fixture did not synchronize its lease to an observed guard read"
while kill -0 -"$BOUND_PID" 2>/dev/null; do
  [ "$(mono_since "$bound_reference" | cut -d. -f1)" -lt "$bound_deadline_s" ] \
    || fail "the guard exceeded its bound: group still running $(mono_since "$bound_reference")s after the last owner activity, against a documented bound of ${bound_total}s (lease term ${bound_lease_term}s + one ${BOUND_CHECK_SECONDS}s check interval + ${PROOF_PROMPT_STOP}s stop)"
  sleep 0.2
done
bound_elapsed=$(mono_since "$bound_reference")
# The loop above only ever checks the clock while the group is still alive, so a
# sampler descheduled past the deadline would see the group already gone and
# report success. Check the OBSERVED completion time too: a late observation
# must not certify timely completion.
[ "${bound_elapsed%%.*}" -lt "$bound_deadline_s" ] \
  || fail "the guard's completion was first observed ${bound_elapsed}s after the last owner activity, beyond its ${bound_deadline_s}s deadline"
# FAIL CLOSED ON THE PHASE. One recorded read must prove the run was in the part
# of the interval this deadline can actually judge: it read the synchronized
# reference, it was still fresh (pre-expiry), and it began late enough that two
# further FULL intervals could not finish before the deadline. Without such a
# read the case refuses - it does not pass on trust, however quickly the group
# happened to stop.
perl - "$BOUND_STATE/reads" "$bound_reference" "$BOUND_LEASE_SECONDS" \
  "$BOUND_CHECK_SECONDS" "$bound_deadline_s" <<'PL' \
  || fail "the bound fixture could not establish the required pre-expiry guard-read phase"
use strict;
use warnings;
my ($path, $reference, $lease, $check, $deadline) = @ARGV;
open my $reads, '<', $path or exit 1;
while (<$reads>) {
  chomp;
  my ($started, $finished, $age, $value) = split /\t/;
  next unless defined $value && $value eq $reference && $age <= $lease;
  next unless $started >= $reference && $finished >= $started;
  next unless $finished < $reference + $lease + 1;
  next unless $started + 2 * $check >= $reference + $deadline;
  printf "guard phase: fresh read %.3f-%.3fs, expiry %ss, two full intervals could not finish before %.3fs (deadline %ss)\n",
    $started - $reference, $finished - $reference, $lease + 1,
    $started - $reference + 2 * $check, $deadline;
  exit 0;
}
exit 1;
PL
wait_gone "$BOUND_DESCENDANT" \
  || fail "the guard stopped at the leader and left its descendant running"
printf 'guard bound: lease=%ss check=%ss reaped %ss after the last owner activity, documented bound %ss\n' \
  "$BOUND_LEASE_SECONDS" "$BOUND_CHECK_SECONDS" "$bound_elapsed" "$bound_total"
pass "an orphaned runner is reaped within the lease plus ONE check interval"

# --- a zero-prefixed interval still starts a listener, and halves correctly ---
#
# OUR OWN REGRESSION, found in review before this change was published. The
# interval validator accepts a zero-prefixed value and `[` compares it as
# decimal, but the half-interval arithmetic introduced above reads `$(( ))`,
# which is octal for a leading zero: 010 halved to 4 instead of 5, and 08 was
# not a number at all, so the guard died before reporting ready and the runner
# failed closed and never listened.
#
# Asserted through the executable interface rather than by reading the source:
# a real listener is started at each value, and the guard's actual sleep
# argument is observed. Reading `10#` out of the script would prove nothing.
INTERVAL_BIN=$(fm_fakebin "$TMP_ROOT/decimal-interval-bin")
REAL_SLEEP=$(command -v sleep) || fail "this host has no sleep to observe guard intervals"
cat > "$INTERVAL_BIN/sleep" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "\$INTERVAL_SLEEP_LOG"
exec "$REAL_SLEEP" "\$@"
SH
chmod +x "$INTERVAL_BIN/sleep"
for interval in 08 010; do
  case "$interval" in
    08) expected_half=4 ;;
    010) expected_half=5 ;;
  esac
  HINTERVAL="$TMP_ROOT/decimal-interval-$interval"; new_home "$HINTERVAL"
  pe_register "$HINTERVAL" lavish "interval-$interval" \
    -- "$QUIET_STUB" "$HINTERVAL/poll" >/dev/null
  PATH="$INTERVAL_BIN:$PATH" INTERVAL_SLEEP_LOG="$HINTERVAL/sleeps" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$interval" \
    pe "$HINTERVAL" reconcile >/dev/null
  wait_for "$HINTERVAL/poll.descendant" \
    || fail "a zero-prefixed decimal interval ($interval) prevented the listener from starting"
  for _ in $(seq 1 100); do
    grep -qx "$expected_half" "$HINTERVAL/sleeps" 2>/dev/null && break
    sleep 0.1
  done
  grep -qx "$expected_half" "$HINTERVAL/sleeps" \
    || fail "the guard did not sleep half of the decimal interval $interval (expected ${expected_half}s)"
  pe "$HINTERVAL" retire "interval-$interval" >/dev/null \
    || fail "retiring the decimal-interval listener ($interval) reported failure"
  printf 'decimal interval: %s halves to %ss and its listener started\n' "$interval" "$expected_half"
done
pass "a zero-prefixed decimal interval starts its listener and halves as decimal"

# --- one unreadable read still does not end a live runner --------------------
#
# The bound above was tightened by moving the guard's two reads closer together,
# NOT by dropping the second one. This is what that second read is for, asserted
# separately so the two cannot be traded for each other by accident: against a
# home that is still alive, an isolated failed read must not stop the runner.
#
# The failure is injected where the real path actually reads. ONE lease read
# fails, exactly once, identified by the lease-age program's own text so no
# other call in the runner is touched; every read before and after it is the
# real command, and the home's lease stays long and fresh throughout. The single
# failed read is therefore the only thing wrong that the guard can see.

DEBOUNCE_HOME="$TMP_ROOT/lease-debounce"; new_home "$DEBOUNCE_HOME"
fm_test_track_procevent_home "$DEBOUNCE_HOME"
DEBOUNCE_STATE="$TMP_ROOT/lease-debounce-state"; mkdir -p "$DEBOUNCE_STATE"
DEBOUNCE_BIN=$(fm_fakebin "$TMP_ROOT/lease-debounce-bin")
REAL_PERL=$(command -v perl) || fail "this host has no perl to build the debounce fixture on"
cat > "$DEBOUNCE_BIN/perl" <<SH
#!/usr/bin/env bash
if [ -s "\$LEASE_DEBOUNCE_STATE/armed" ] && [ ! -s "\$LEASE_DEBOUNCE_STATE/spent" ]; then
  for arg in "\$@"; do
    case \$arg in
      *'int(\$now - \$value)'*)
        printf 'spent\n' > "\$LEASE_DEBOUNCE_STATE/spent"
        exit 1
        ;;
    esac
  done
fi
exec "$REAL_PERL" "\$@"
SH
chmod +x "$DEBOUNCE_BIN/perl"

# A long lease and a short check: many reads happen inside the observation
# window, and none of them can go stale on their own during it.
DEBOUNCE_LEASE_SECONDS=30
DEBOUNCE_CHECK_SECONDS=1
debounce_pe() {
  PATH="$DEBOUNCE_BIN:$PATH" LEASE_DEBOUNCE_STATE="$DEBOUNCE_STATE" \
    FM_PROCEVENT_OWNER_LEASE_SECONDS="$DEBOUNCE_LEASE_SECONDS" \
    FM_PROCEVENT_OWNER_CHECK_SECONDS="$DEBOUNCE_CHECK_SECONDS" \
    FM_HOME="$DEBOUNCE_HOME" "$ROOT/bin/fm-procevent.sh" "$@"
}
debounce_pe register lavish debounce-src -- "$QUIET_STUB" "$TMP_ROOT/lease-debounce-marker" >/dev/null
debounce_pe reconcile >/dev/null
wait_for "$DEBOUNCE_HOME/state/procevent/debounce-src.runner" \
  || fail "the debounce fixture's listener never recorded its runner"
DEBOUNCE_PID=$(cat "$DEBOUNCE_HOME/state/procevent/debounce-src.runner")
# Armed only now. The guard proves the lease once before it reports ready, and
# failing THAT read would refuse the runner outright instead of exercising the
# debounce this case is about.
printf 'armed\n' > "$DEBOUNCE_STATE/armed"
wait_for "$DEBOUNCE_STATE/spent" \
  || fail "the single failed lease read this case injects never happened"
# Several further checks at the configured interval. A guard that acted on one
# failed read would have stopped the group during them.
sleep $((DEBOUNCE_CHECK_SECONDS * 4))
kill -0 -"$DEBOUNCE_PID" 2>/dev/null \
  || fail "one unreadable lease read ended a runner whose home was still alive"
debounce_pe retire debounce-src >/dev/null \
  || fail "retiring the debounce fixture's source reported failure"
wait_gone "-$DEBOUNCE_PID" \
  || fail "retiring the debounce fixture left its process group running"
pass "one unreadable read does not end a live runner"

# --- the ordinary stop signal is what stops a runner ------------------------
#
# The forced kill is the backstop, not the normal path. When it carries every
# stop, it stops being able to report that anything went wrong - which is exactly
# how a listener that could not be stopped looked identical to one that could.

HPROMPT="$TMP_ROOT/prompt-stop"; new_home "$HPROMPT"
pe_register "$HPROMPT" lavish prompt-src -- "$QUIET_STUB" "$TMP_ROOT/prompt-stop" >/dev/null
pe "$HPROMPT" start prompt-src >"$TMP_ROOT/prompt-start.log" 2>&1 &
PROMPT_START_PID=$!
wait_for "$HPROMPT/state/procevent/prompt-src.runner" \
  || fail "the promptly-stopping listener never recorded its runner"
PROMPT_PID=$(cat "$HPROMPT/state/procevent/prompt-src.runner")
wait_for "$TMP_ROOT/prompt-stop.descendant" \
  || fail "the promptly-stopping listener's child never spawned its own descendant"
stop_window_ms() {
  local from to
  from=$(now_ms)
  for _ in $(seq 1 20); do sleep 0.1; done
  to=$(now_ms)
  printf '%s\n' "$((to - from))"
}
window_before=$(stop_window_ms)
start=$(now_ms)
pe "$HPROMPT" retire prompt-src >/dev/null || fail "retiring a healthy listener reported failure"
elapsed=$(( $(now_ms) - start ))
window_after=$(stop_window_ms)
prompt_status=0
wait "$PROMPT_START_PID" || prompt_status=$?
wait_gone "-$PROMPT_PID" || fail "retiring a healthy listener left its process group running"
[ "$prompt_status" -eq 143 ] \
  || fail "the runner did not exit on TERM (start status=$prompt_status, retirement=${elapsed}ms, sampled windows=${window_before}/${window_after}ms)"
printf 'ordinary stop: start status=%s retirement=%sms sampled windows=%s/%sms\n' \
  "$prompt_status" "$elapsed" "$window_before" "$window_after"
pass "a runner exits on the ordinary stop signal instead of outliving it"

# --- a crashed leader's group is still refused -------------------------------
#
# The escalation above accepts a leaderless group in exactly one place: inside
# the stop that just proved and signalled that generation itself. Whether a group
# whose leader died to something ELSE may ever be signalled is a separate open
# question, and this pins that it stays refused - so the escalation cannot widen
# into an answer to it by accident.

HCRASH="$TMP_ROOT/crashed-leader"; new_home "$HCRASH"
pe_register "$HCRASH" lavish crash-src -- "$QUIET_STUB" "$TMP_ROOT/crash-leader" >/dev/null
pe "$HCRASH" reconcile >/dev/null
wait_for "$HCRASH/state/procevent/crash-src.runner" \
  || fail "the crash-fixture listener never recorded its runner"
CRASH_PID=$(cat "$HCRASH/state/procevent/crash-src.runner")
wait_for "$TMP_ROOT/crash-leader.descendant" \
  || fail "the crash-fixture listener's child never spawned its own descendant"
kill -KILL "$CRASH_PID" 2>/dev/null || fail "the crash fixture could not stop its own leader"
deadline=$((SECONDS + 10))
while kill -0 "$CRASH_PID" 2>/dev/null; do
  [ "$SECONDS" -lt "$deadline" ] || fail "the crash fixture's leader never died"
  sleep 0.1
done
kill -0 -"$CRASH_PID" 2>/dev/null \
  || fail "the crash fixture left no surviving group, so nothing was refused"

out=$(pe "$HCRASH" retire crash-src 2>&1) && fail "retirement claimed success on a crashed leader's group"
assert_contains "$out" "cannot confirm runner identity" \
  "a crashed leader's group is refused with its own diagnostic"
assert_present "$HCRASH/state/procevent/crash-src.source" \
  "a refused retirement leaves the source registered"
kill -0 -"$CRASH_PID" 2>/dev/null \
  || fail "a refused retirement signalled the leaderless group anyway"
pass "a group whose leader died to something else is still refused, not signalled"
kill -KILL -"$CRASH_PID" 2>/dev/null || true

printf '\nall procevent lifecycle tests passed\n'
