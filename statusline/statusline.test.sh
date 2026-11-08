#!/usr/bin/env bash
# Tests for statusline.sh: each case feeds a status line payload and compares the whole line.
# Run: bash statusline/statusline.test.sh
# Every case sets or unsets CLAUDE_CODE_BRIDGE_SESSION_ID itself, so a session with Remote Control
# connected, which has the variable set, runs the same cases as one without.

script="$(dirname "$0")/statusline.sh"
fail=0
run=0

payload='{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":23.4},"rate_limits":{"five_hour":{"used_percentage":41},"seven_day":{"used_percentage":63.9}}}'
early='{"model":{"display_name":"Opus 5.5"},"context_window":{"used_percentage":null}}'

check() {  # expected line, bridge session id ('' = unset, EMPTY = set but empty), payload
    local got
    if [[ $2 == EMPTY ]]; then
        got=$(printf '%s' "$3" | CLAUDE_CONFIG_DIR=/home/t/.claude-work CLAUDE_CODE_BRIDGE_SESSION_ID= \
            env -u STATUSLINE_NO_FIVE_HOUR bash "$script")
    elif [[ -n $2 ]]; then
        got=$(printf '%s' "$3" | CLAUDE_CONFIG_DIR=/home/t/.claude-work CLAUDE_CODE_BRIDGE_SESSION_ID=$2 \
            env -u STATUSLINE_NO_FIVE_HOUR bash "$script")
    else
        got=$(printf '%s' "$3" | CLAUDE_CONFIG_DIR=/home/t/.claude-work \
            env -u CLAUDE_CODE_BRIDGE_SESSION_ID -u STATUSLINE_NO_FIVE_HOUR bash "$script")
    fi
    run=$((run + 1))
    if [[ $got != "$1" ]]; then
        fail=$((fail + 1))
        echo "FAIL expected '$1' got '$got'"
    fi
}

# Without Remote Control the line is as before
check 'work · Opus 5.5 · context 23% · 5h 41% · week 63%' '' "$payload"
# With Remote Control connected, the mark stands right after the model
check 'work · Opus 5.5 · ⦿ remote · context 23% · 5h 41% · week 63%' 'session_test' "$payload"
# Early in a session, before Claude Code reports usage
check 'work · Opus 5.5' '' "$early"
check 'work · Opus 5.5 · ⦿ remote' 'session_test' "$early"
# An empty variable is no connection
check 'work · Opus 5.5' EMPTY "$early"

# STATUSLINE_NO_FIVE_HOUR hides the 5h part for a listed tier, read from a .claude.json the size
# of a real one; the bash reading it replaced took over 20 seconds on such a file.
tmp=$(mktemp -d)
mkdir -p "$tmp/.claude-work"
{
    printf '{"projects":{'
    for i in $(seq 1 800); do printf '"C:/p/%04d":{"allowedTools":[],"history":["some earlier prompt text"]},' "$i"; done
    printf '"x":{}},"oauthAccount":{"emailAddress":"t@example.com","userRateLimitTier":"tier_without_5h"}}'
} > "$tmp/.claude-work/.claude.json"
tier_check() {  # expected line, STATUSLINE_NO_FIVE_HOUR
    local got start=$SECONDS
    got=$(printf '%s' "$payload" | CLAUDE_CONFIG_DIR="$tmp/.claude-work" STATUSLINE_NO_FIVE_HOUR=$2 \
        env -u CLAUDE_CODE_BRIDGE_SESSION_ID bash "$script")
    run=$((run + 1))
    if [[ $got != "$1" ]]; then
        fail=$((fail + 1))
        echo "FAIL expected '$1' got '$got'"
    elif ((SECONDS - start > 3)); then
        fail=$((fail + 1))
        echo "FAIL took $((SECONDS - start)) s, more than the 5 s refresh allows with room to spare"
    fi
}
tier_check 'work · Opus 5.5 · context 23% · week 63%' 'tier_without_5h'
tier_check 'work · Opus 5.5 · context 23% · 5h 41% · week 63%' 'some_other_tier'
rm -rf "$tmp"

echo "$run cases, $fail failed"
[[ $fail == 0 ]]
