#!/usr/bin/env bash
# Tests for guard-git.sh: each case feeds a PreToolUse payload and expects exit 2 (blocked), 0 with
# nothing on stdout (allowed), or ask: exit 0 with the PreToolUse "ask" decision as JSON on stdout.
# Run: bash hooks/guard-git.test.sh
# As in block-secrets.test.sh the halves mirror each other: the same command shape once over the
# line and once just short of it, above all a forbidden command written as text that is no command.

hook="$(dirname "$0")/guard-git.sh"
fail=0
run=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
repo=$tmp/trepo   # its Windows path, the default cwd, holds \t, which must not turn into a tab
mkdir -p "$repo/.git" "$repo/sub/deeper" "$repo/libs/sm" "$repo/vendor/trepo"
: > "$repo/libs/sm/.git"   # a submodule: its .git is a file
: > "$repo/vendor/trepo/.git"   # a submodule named like the repository
trailer='Co-Authored-By: Claude <noreply@anthropic.com>'
generated='🤖 Generated with [Claude Code](https://claude.com/claude-code)'
printf 'Fix the parser\n\n%s\n' "$trailer" > "$repo/msg-ai.txt"
printf 'Fix the parser\n\nCo-Authored-By: Max <max@example.org>\n' > "$repo/msg-ok.txt"
printf '## Summary\n\nFaster parser.\n\n%s\n' "$generated" > "$repo/body-ai.md"
printf '## Summary\n\nFaster parser.\n' > "$repo/body-ok.md"

check() {  # expected exit, tool, command[, cwd]
    local json value=$3 cwd=${4:-$(cygpath -w "$repo")}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    cwd=${cwd//\\/\\\\}
    json="{\"session_id\":\"t\",\"cwd\":\"$cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$2\",\"tool_input\":{\"command\":\"$value\"}}"
    local out got ask='^\{"hookSpecificOutput":\{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"[^"\\[:cntrl:]]+"\}\}$'
    out=$(printf '%s' "$json" | bash "$hook" 2>/dev/null)
    got=$?
    run=$((run + 1))
    if [[ $1 == ask ]]; then
        [[ $got == 0 && $out =~ $ask ]] && return 0
    elif [[ $got == "$1" && ($1 != 0 || -z $out) ]]; then
        return 0
    fi
    fail=$((fail + 1))
    echo "FAIL expected $1 got $got${out:+ and stdout $out}: $2 ${3:0:160}"
}

# Blocked: AI attribution, wherever the message comes from
check 2 Bash "git commit -m \"Fix the parser\" -m \"$trailer\""
check 2 Bash "git commit -m \"\$(cat <<'EOF'
Fix the parser

$trailer
EOF
)\""
check 2 Bash "git add src/a.py && git commit -m \"\$(cat <<'EOF'
Fix the parser; \"quoted\" words

$generated
EOF
)\" && git push"
check 2 Bash 'git commit -m "x" -m "Claude-Session: https://claude.ai/code/session_123"'
check 2 Bash 'git commit -m "x" -m "Assisted-by: claude-opus"'
check 2 Bash "git commit -m 'x' --trailer 'Co-authored-by: Claude <noreply@anthropic.com>'"
# A merge, a tag and a note write a message too; the same commands without the line pass
check 2 Bash "git merge -m \"Merge feat\" -m \"$trailer\" feat"
check 2 Bash "git merge --no-ff --message=\"Merge feat: $trailer\" feat"
check 2 Bash 'git merge -F msg-ai.txt feat'
check 2 Bash 'git -C sub merge --file=../msg-ai.txt feat'
check 2 Bash "git tag -a v1 -m \"$trailer\""
check 2 Bash 'git notes add -F msg-ai.txt HEAD'
check 2 PowerShell "git merge -m 'x' -m '$trailer' feat"
check 2 Bash 'git tag -aF msg-ai.txt v1'
check 2 Bash 'git tag -sFmsg-ai.txt v1'
check 0 Bash 'git tag -aF msg-ok.txt v1'
check 0 Bash 'git tag -l "v1*"'
check 0 Bash 'git merge --abort'
check 0 Bash 'git merge -m "Merge feat" feat'
check 0 Bash 'git merge -F msg-ok.txt feat'
check 0 Bash 'git merge feat'
check 0 Bash 'git tag -a v1 -m "Release 1"'
check 0 Bash "git log --grep \"$trailer\""
check 2 Bash 'git commit --author="Claude <noreply@anthropic.com>" -m x'
check 2 Bash 'git -c user.name=Claude -c user.email=noreply@anthropic.com commit -m x'
check 2 Bash "git -C sub commit -F - <<EOF
Fix the parser

$trailer
EOF"
check 2 Bash "cat <<'EOF' | git commit -F -
Fix the parser

$trailer
EOF"
check 2 Bash 'git commit -F msg-ai.txt'
check 2 Bash 'git commit --file=msg-ai.txt'
check 2 Bash 'cd sub && git commit --file ../msg-ai.txt'
check 2 Bash "gh pr create --title \"Faster parser\" --body \"Faster.

$generated\""
check 2 Bash "gh pr create --title 'Faster parser' --body \"\$(cat <<'EOF'
## Summary
Faster.

$generated
EOF
)\""
check 2 Bash 'gh pr edit 12 --body-file body-ai.md'
check 2 Bash 'gh issue comment 5 -F body-ai.md'
check 2 Bash 'gh issue create -t "Bug" -b "Found it. Assisted-by: Claude"'
check 2 Bash "bash -c \"git commit -m 'x' -m 'Claude-Session: abc'\""
check 2 Bash 'git config user.email noreply@anthropic.com'
check 2 PowerShell "git commit -m @'
Fix the parser

$trailer
'@"
check 2 PowerShell "git commit -m 'Fix' -m '$generated'"
check 2 PowerShell "gh pr create --title Faster --body \"Faster.\`n\`n$generated\""

# Blocked: bulk staging, behind global options, wrappers and in compound commands
check 2 Bash 'git add -A'
check 2 Bash 'git add --all'
check 2 Bash 'git add .'
check 2 Bash 'git add ./'
check 2 Bash 'git add :/'
check 2 Bash 'git add -u'
check 2 Bash 'git add --update'
check 2 Bash 'git add -vA'
check 2 Bash 'git add *'
check 2 Bash 'git add -- .'
check 2 Bash "git add $repo"
check 2 Bash 'git add ..' "$repo/sub"
check 2 Bash 'git add ../..' "$repo/sub/deeper"
check 2 Bash 'git -C sub add -A'
check 2 Bash 'git -c core.autocrlf=false add .'
check 2 Bash 'git --no-pager add -A'
check 2 Bash 'git status && git add -A && git commit -m x'
check 2 Bash 'echo start; git add .'
check 2 Bash 'git diff | head
git add -A'
check 2 Bash '(cd sub && git add -A)'
check 2 Bash 'timeout 30 git add -A'
check 2 Bash 'GIT_TRACE=1 git add .'
check 2 Bash '"/c/Program Files/Git/cmd/git.exe" add -A'
check 2 Bash 'cmd //c "git add -A"'
check 2 Bash 'git commit -a -m x'
check 2 Bash 'git commit -am "x"'
check 2 Bash 'git commit --all -m x'
check 2 Bash 'git commit -qam x'
check 2 PowerShell 'git add -A; git commit -m x'
check 2 PowerShell '& "C:\Program Files\Git\cmd\git.exe" add .'
check 2 PowerShell 'Set-Location sub; git add -A'
check 2 PowerShell 'powershell -NoProfile -Command "git add ."'

# Blocked: skipped hooks
check 2 Bash 'git commit -m x --no-verify'
check 2 Bash 'git commit -n -m x'
check 2 Bash 'git commit -nm x'
check 2 Bash 'git push --no-verify'
check 2 Bash 'git push origin feature --no-verify'
check 2 Bash 'git merge --no-verify feature'
check 2 Bash 'GIT_TRACE=/tmp/t git commit --no-verify -m x | cat'
check 2 Bash 'git -c core.hooksPath=/dev/null commit -m x'
check 2 Bash 'git -c core.hookspath= push'
check 2 Bash 'git --config-env=core.hooksPath=EMPTY commit -m x'
check 2 Bash 'git config core.hooksPath .hooks'
check 2 Bash 'git config --global core.hooksPath ~/hooks'
check 2 Bash 'git config --unset core.hooksPath'
check 2 Bash 'git config set core.hooksPath x'
check 2 Bash 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=x git commit -m x'
check 2 PowerShell 'git commit -m "x" --no-verify'

# Blocked: force pushes and deleting main, in every spelling settings' prefix rules miss
check 2 Bash 'git push --force origin feature'
check 2 Bash 'git -C sub push --force'
check 2 Bash 'git push -f origin feature'
check 2 Bash 'git push -fu origin feature'
check 2 Bash 'git push -uf origin feature'
check 2 Bash 'git push --force-with-lease origin feature'
check 2 Bash 'git push --force-with-lease=main origin feature'
check 2 Bash 'git push --force-if-includes --force-with-lease origin feature'
check 2 Bash 'git push origin +feature'
check 2 Bash 'git push origin +HEAD:feature'
check 2 Bash 'git push --mirror'
check 2 Bash 'git push origin :main'
check 2 Bash 'git push origin --delete main'
check 2 Bash 'git push -d origin main'
check 2 Bash 'git status && git push --force'
check 2 PowerShell 'git push --force-with-lease origin feature'
# Blocked: updating a pull request by rebase, which rewrites its pushed branch on GitHub's side
check 2 Bash 'gh pr update-branch 12 --rebase'
check 2 Bash 'gh pr update-branch --rebase'
check 2 Bash 'gh -R owner/repo pr update-branch 12 --rebase=true'
check 2 Bash 'git fetch && gh pr update-branch feature --rebase'
check 2 PowerShell 'gh pr update-branch 12 --rebase'
check 2 Bash "gh api graphql -f query='mutation { updatePullRequestBranch(input: {pullRequestId: \"x\", updateMethod: REBASE}) { clientMutationId } }'"
check 2 Bash "gh api graphql -f query='mutation(\$m: PullRequestBranchUpdateMethod) { updatePullRequestBranch(input: {pullRequestId: \"x\", updateMethod: \$m}) { clientMutationId } }' -F m=REBASE"
check 2 Bash "gh api graphql -f query='mutation(\$m: PullRequestBranchUpdateMethod = REBASE) { updatePullRequestBranch(input: {pullRequestId: \"x\", updateMethod: \$m}) { clientMutationId } }'"
check 2 Bash "gh api graphql -f query=\"\$(cat <<'EOF'
mutation {
  updatePullRequestBranch(input: {pullRequestId: \"x\", updateMethod: REBASE}) { clientMutationId }
}
EOF
)\""
check 2 Bash "gh api graphql --input - <<'EOF'
{\"query\": \"mutation(\$id: ID!, \$m: PullRequestBranchUpdateMethod) { updatePullRequestBranch(input: {pullRequestId: \$id, updateMethod: \$m}) { clientMutationId } }\", \"variables\": {\"id\": \"x\", \"m\": \"REBASE\"}}
EOF"
check 2 PowerShell "gh api graphql -f query=@'
mutation { updatePullRequestBranch(input: {pullRequestId: \"x\", updateMethod: REBASE}) { clientMutationId } }
'@"
# Ask: a push to main and the merge of a pull request go to the user
check ask Bash 'git push origin main'
check ask Bash 'git -C sub push origin main'
check ask Bash 'git push origin HEAD:main'
check ask Bash 'git push origin feature:refs/heads/main'
check ask Bash 'git push -u origin main'
check ask Bash 'gh pr merge 12 --squash'
check ask Bash 'gh pr merge --merge --delete-branch'
check ask Bash 'gh api -X PUT repos/owner/repo/pulls/12/merge'
check ask Bash 'gh api -X PUT repos/owner/repo/pulls/12/merge -f merge_method=rebase'
check ask Bash "gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
check ask Bash "gh api graphql -f query=\"\$(cat <<'EOF'
mutation {
  mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId }
}
EOF
)\""
check ask PowerShell 'git push origin main'
# The refspec never goes into the JSON reason: a backslash or tab in it would make the JSON invalid
check ask PowerShell "git push origin 'feat\x:main'"
check ask Bash $'git push origin "feat	x:main"'
# A block elsewhere in the command wins over the question
check 2 Bash 'git push origin main && git add -A'
check 2 Bash 'gh pr merge 12 --body "Generated with Claude Code"'

# A payload larger than the 4 KB read in one go: the attribution at its end, outside ASCII
body=""
while ((${#body} < 6000)); do body+="Ä line of a long pull request body, with umlauts: äöüß. "; done
check 2 Bash "gh pr create --title Long --body \"$body

$generated\""
check 0 Bash "gh pr create --title Long --body \"$body\""

# Blocked: a pathspec that only excludes stages everything else
check 2 Bash 'git add -- ":!secret.txt"'
check 2 Bash "git add ':(exclude)*.log'"
check 2 Bash 'git add ":^dist"'
check 2 Bash 'git commit -m x -m "Generated with Claude Code"'
# The robot emoji without the link: lowercasing it in a UTF-8 locale damaged the emoji in Git Bash,
# so neither the emoji form nor the footer form matched
check 2 Bash "git commit -m x -m '🤖 Generated with Claude Code'"
check 2 PowerShell "gh pr create --title x --body 'Faster. 🤖 Generated with Claude'"
# A dated line is no trailer, even beside CLAUDE.md and the word claude
check 0 Bash "git commit -m 'Record the 2026-11-01: run' -m 'Touches CLAUDE.md and the claude rules'"
check 2 Bash 'git commit -m "Fix" -m "Built fast, generated with [Claude Code](https://claude.com/claude-code)"'

# Allowed: pushes that neither force nor reach main, merges by the user's own hand
check 0 Bash 'git push origin feature'
check 0 Bash 'git push -u origin feature/main-menu'
check 0 Bash 'git push origin main-fix'
check 0 Bash 'git push --force-if-includes origin feature'
check 0 Bash 'git push origin --delete old-feature'
check 0 Bash 'git push origin :old-feature'
check 0 Bash 'git push'
check 0 Bash 'gh pr view 12'
check 0 Bash 'gh pr update-branch 12'
check 0 Bash 'gh pr update-branch 12 --rebase=false'
check 0 Bash 'gh pr update-branch 12 --rebase=False'
check 0 Bash 'gh pr update-branch 12 --rebase=0'
check 0 Bash "gh api graphql -f query='mutation { updatePullRequestBranch(input: {pullRequestId: \"x\"}) { pullRequest { canBeRebased } } }'"
check 0 Bash "gh api graphql -f query='mutation { updatePullRequestBranch(input: {pullRequestId: \"x\", updateMethod: MERGE}) { clientMutationId } }' -F note=rebased"
check 0 Bash 'gh pr update-branch 12 -- --rebase'
check 0 Bash 'gh api repos/owner/repo/pulls/12 --jq .rebaseable'
check ask Bash 'gh pr merge 12 --rebase'
check 0 Bash 'gh pr comment 12 --body "never gh pr update-branch --rebase"'
check 0 Bash "gh api graphql -f query='mutation { updatePullRequestBranch(input: {pullRequestId: \"x\", updateMethod: MERGE}) { clientMutationId } }'"
check 0 Bash 'gh pr create --title Merge --body "merge main into feature"'
check 0 Bash 'gh api repos/owner/repo/pulls/12'
check 0 Bash 'git commit -m "push --force to main is never done"'
check 0 Bash 'gh issue comment 5 --body "do not git push --force origin main, never gh pr merge"'
check 0 Bash 'git add libs/sm'
check 0 Bash 'git add libs/sm/'
check 0 Bash 'git add vendor/trepo'
check 0 Bash 'git add src ":!src/secret.txt"'
check 0 Bash 'git commit -m "Remove the PR link generated by Claude Code"'
check 0 Bash 'git commit -m "Explain why text generated with Claude needs a review"'

# Allowed: the same shapes just short of the line
check 0 Bash 'git commit -m "Fix the parser"'
check 0 Bash 'git commit -m "Update the CLAUDE.md working rules"'
check 0 Bash 'git commit -m "x" -m "Co-Authored-By: Max <max@example.org>"'
check 0 Bash "git commit -m \"\$(cat <<'EOF'
Fix the parser; \"quoted\" words

Explain why, not what.
EOF
)\""
check 0 Bash 'git commit -F msg-ok.txt'
check 0 Bash 'git commit -F missing.txt'
check 0 Bash "echo \"$trailer\""
check 0 Bash "grep -rn \"$trailer\" docs/"
check 0 Bash "cat > notes.md <<'EOF'
$trailer
git add -A
git commit -am x --no-verify
EOF"
check 0 Bash 'gh pr edit 12 --body-file body-ok.md'
check 0 Bash 'gh pr view 12 --comments'
check 0 Bash 'gh issue comment 5 --body "Run git push origin main, then git add -A and git commit -am x --no-verify"'
check 0 Bash "gh pr create --title 'Guard' --body \"\$(cat <<'EOF'
Blocks git add -A; and git commit -a | --no-verify && git config core.hooksPath x
EOF
)\""
check 0 Bash 'git log --grep="add -A" --oneline'
check 0 Bash 'git commit -m "a \" ; git add -A \" b"'
check 0 Bash 'echo a\;git add -A'
check 2 Bash 'git add \
  -A'
check 2 Bash 'echo "a \" b" ; git add -A'
check 0 Bash 'git add src/a.py tests/test_a.py'
check 0 Bash 'git add ./src'
check 0 Bash 'git add .gitignore'
check 0 Bash 'git add sub'
check 0 Bash 'git add -p src'
check 0 Bash 'git add -N new.txt'
check 0 Bash 'git add -- src/x.py'
check 0 Bash 'legit add -A'
check 0 Bash 'echo "git add -A"'
check 0 Bash "printf 'git commit -a\\n'"
check 0 Bash 'git commit -m "-a is not used here"'
check 0 Bash 'git commit -m "--no-verify is forbidden"'
check 0 Bash 'git commit -mFix'
check 0 Bash 'git commit -m "nothing" -- src/a.py'
check 0 Bash 'git commit -c HEAD~1'
check 0 Bash 'git push -n origin feature'
check 0 Bash 'git push origin feature'
check 0 Bash 'git config core.hooksPath'
check 0 Bash 'git config --get core.hooksPath'
check 0 Bash 'git config user.name "Max Example"'
check 0 Bash 'git -C sub status && git diff --stat'
check 0 PowerShell 'Write-Output "git add -A"'
check 0 PowerShell "git commit -m 'Fix; then add -A'"
check 0 PowerShell 'git add src\a.ps1; git commit -m "Fix"'
check 0 Read command 'git add -A'

# A broken install blocks, so the gap shows, instead of letting every command through unchecked
mkdir -p "$tmp/nolib"
cp "$hook" "$tmp/nolib/guard-git.sh"
saved=$hook
hook=$tmp/nolib/guard-git.sh
check 2 Bash 'git status'
hook=$saved

# A long command with git in it still answers well inside the hook's timeout
long="git status && python - <<'EOF'"$'\n'
for i in $(seq 1 400); do long+="print('git add -A in line $i of a long patch script; nothing && more')"$'\n'; done
long+="EOF"
start=$SECONDS
check 0 Bash "$long"
((SECONDS - start < 5)) || { fail=$((fail + 1)); echo "FAIL a long command took $((SECONDS - start)) s"; }

# Large commands stay well inside the timeout: a hook that times out lets the command run unchecked
# The limit catches a return of the old quadratic split (47 s and more at 30 KB), with room for a
# busy machine: these commands take about 2 s under load, so a tighter limit only adds flaky runs.
timed() {  # name, limit in ms, expected exit, tool, command: the hook process alone is timed
    local name=$1 limit=$2 value=$5 cwd json start ms got
    cwd=$(cygpath -w "$repo")
    cwd=${cwd//\\/\\\\}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    json="{\"session_id\":\"t\",\"cwd\":\"$cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$4\",\"tool_input\":{\"command\":\"$value\"}}"
    printf '%s' "$json" > "$tmp/payload.json"
    start=$(date +%s%N)
    bash "$hook" < "$tmp/payload.json" > /dev/null 2>&1
    got=$?
    ms=$((($(date +%s%N) - start) / 1000000))
    run=$((run + 1))
    echo "timing: $name: $ms ms, exit $got"
    if [[ $got != "$3" ]] || ((ms >= limit)); then
        fail=$((fail + 1))
        echo "FAIL $name: expected exit $3 within $limit ms"
    fi
}
loop="for f in a b c; do"$'\n'
for i in $(seq 1 160); do loop+="  echo \"step $i of the loop\" | grep -q step && git diff --stat -- \"src/file$i.txt\""$'\n'; done
loop+="done"
compound=""
while ((${#compound} < 30000)); do compound+="git status --short && echo 'one more harmless line of text' && "; done
compound+="true"
unclosed="git status && echo \"unclosed "
i=0
while ((${#unclosed} < 60000)); do
    i=$((i + 1))
    unclosed+="echo step $i of the build >> build.log ; npm run build -- --module=$i ; git diff --stat -- src/module$i"$'\n'
done
dense="git status && echo \"unclosed "
while ((${#dense} < 60000)); do dense+="word && git add src/x.py ; "; done
timed "loop script of ${#loop} bytes" 5000 0 Bash "$loop"
timed "compound command of ${#compound} bytes" 5000 0 Bash "$compound"
timed "script of ${#unclosed} bytes after an unclosed quote" 5000 0 Bash "$unclosed"
timed "the same with git add -A at its end" 5000 2 Bash "$unclosed git add -A"
# The worst case: 60 KB of nothing but short git commands, 2,200 of them, each one checked
timed "${#dense} bytes of git add commands after an unclosed quote" 5000 2 Bash "$dense git add -A"

echo "$run cases, $fail failed"
((fail == 0))
