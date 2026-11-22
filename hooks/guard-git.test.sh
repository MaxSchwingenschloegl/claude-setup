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
# No closing-check skill and no gh login unless a case sets them: the user's own must not count
export CLAUDE_CONFIG_DIR=$tmp/cfg-off GH_CONFIG_DIR=$tmp/nogh APPDATA=$tmp/nogh
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

# A message taken from an existing commit is read from the repository: -C, -c, --reuse-message and
# --reedit-message take the whole message, --fixup=amend:/reword: too, a plain --fixup and --squash
# only the subject line. Commits made with plumbing, so no hook and no identity are needed.
real=$tmp/real
git init -q "$real"
export GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.org GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.org
tree=$(git -C "$real" mktree < /dev/null)
mkcommit() {  # tag, message
    local c
    c=$(printf '%s\n' "$2" | git -C "$real" commit-tree "$tree")
    git -C "$real" tag "$1" "$c"
}
mkcommit ai "Fix the parser"$'\n\n'"$trailer"
mkcommit ok "Fix the parser"$'\n\n'"Co-Authored-By: Max <max@example.org>"
mkcommit aisubject "$generated"
# -C, -c, --reuse-message and --reedit-message take over the author too, unless --reset-author
GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com mkcommit aiauthor "Fix the parser"
GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=claude@anthropic.com mkcommit aiant "Fix the parser"
GIT_AUTHOR_NAME="Claude Code" GIT_AUTHOR_EMAIL=claude@users.noreply.github.com mkcommit aigh "Fix the parser"
# on a branch, so these cases test the message and the author, not the commit on main
git -C "$real" update-ref refs/heads/work "$(git -C "$real" rev-parse ai)"
git -C "$real" symbolic-ref HEAD refs/heads/work
realw=$(cygpath -w "$real")
check 2 Bash 'git commit -C ai' "$realw"
check 2 Bash 'git commit -c ai' "$realw"
check 2 Bash 'git commit -Cai' "$realw"
check 2 Bash 'git commit -sC ai' "$realw"
check 2 Bash 'git commit --amend -C HEAD' "$realw"
check 2 Bash 'git commit --reuse-message=ai' "$realw"
check 2 Bash 'git commit --reuse-message ai' "$realw"
check 2 Bash 'git commit --reedit-message=ai' "$realw"
check 2 Bash 'git commit --fixup=amend:ai' "$realw"
check 2 Bash 'git commit --fixup reword:ai' "$realw"
check 2 Bash 'git commit --fixup aisubject' "$realw"
check 2 Bash 'git commit --squash=aisubject' "$realw"
check 2 Bash "git commit -C $(git -C "$real" rev-parse ai)" "$realw"
check 2 Bash 'git add a.txt && git commit -C ai' "$realw"
check 2 Bash "git -C '$realw' commit -C ai"
check 2 PowerShell 'git commit -C ai' "$realw"
check 2 Bash 'git commit -C aiauthor' "$realw"
check 2 Bash 'git commit -c aiauthor' "$realw"
check 2 Bash 'git commit --reuse-message=aiauthor' "$realw"
check 2 Bash 'git commit --reedit-message aiauthor' "$realw"
check 0 Bash 'git commit -C aiauthor --reset-author' "$realw"
check 2 Bash 'git commit -C aiauthor --reset-author --no-reset-author' "$realw"
check 0 Bash 'git commit --no-reset-author -C aiauthor --reset-author' "$realw"
check 2 Bash 'git commit -C ai --reset-author' "$realw"
# A Claude or Anthropic identity, as `git config user.name|user.email` reads it
check 2 Bash 'git commit -C aiant' "$realw"
check 2 Bash 'git commit -C aigh' "$realw"
check 2 Bash 'git commit --author "Claude <claude@anthropic.com>" -m x'
check 2 Bash 'git commit --author="Anthropic Bot <bot@example.org>" -m x'
check 0 Bash 'git commit --author "Max Example <max@example.org>" -m x'
# --amend keeps HEAD's author unless --reset-author
realc=$tmp/realc
git init -q "$realc"
c=$(printf 'Fix the parser\n' | GIT_AUTHOR_NAME=Claude GIT_AUTHOR_EMAIL=noreply@anthropic.com git -C "$realc" commit-tree "$(git -C "$realc" mktree < /dev/null)")
git -C "$realc" update-ref refs/heads/work "$c"
git -C "$realc" symbolic-ref HEAD refs/heads/work
realcw=$(cygpath -w "$realc")
check 2 Bash 'git commit --amend -m "Fix it"' "$realcw"
check 2 Bash 'git commit --amend --no-edit' "$realcw"
check 0 Bash 'git commit --amend --reset-author -m "Fix it"' "$realcw"
check 0 Bash 'git commit --amend -m "Fix it"' "$realw"
check 0 Bash 'git commit -m "Fix it"' "$realcw"
check 2 Bash 'git commit --fixup=amend:ai --reset-author' "$realw"
check 0 Bash 'git commit --fixup=amend:aiauthor' "$realw"
check 0 Bash 'git commit --squash aiauthor' "$realw"
check 0 Bash 'git commit -C ok' "$realw"
check 0 Bash 'git commit -c ok' "$realw"
check 0 Bash 'git commit --reuse-message=ok' "$realw"
check 0 Bash 'git commit --fixup=amend:ok' "$realw"
check 0 Bash 'git commit --fixup ai' "$realw"
check 0 Bash 'git commit --squash ai' "$realw"
check 0 Bash 'git commit -C no-such-commit' "$realw"
# The value is a commit, never an option of the command that reads it: read as one, git would
# print the message of HEAD, which carries the trailer
check 0 Bash 'git commit -C --format=%B' "$realw"
check 0 Bash 'git log -C ai' "$realw"
check 0 Bash 'git commit -m "taken from -C ai"' "$realw"
check 0 Bash 'git commit -C ai'

# The reason fits the push: a rewrite is answered with the merge path, deleting main or
# --mirror is the user's decision
says() {  # text the reason must hold, command[, cwd]
    local value=$2 cwd=${3:-$(cygpath -w "$repo")} json err
    cwd=${cwd//\\/\\\\}
    json="{\"session_id\":\"t\",\"cwd\":\"$cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$value\"}}"
    err=$(printf '%s' "$json" | bash "$hook" 2>&1 >/dev/null)
    run=$((run + 1))
    [[ $err == *"$1"* ]] && return 0
    fail=$((fail + 1))
    echo "FAIL expected a reason with '$1': $2 (got: ${err:0:160})"
}
says 'never rewritten' 'git push --force origin feature'
says 'git merge origin/main' 'git push origin +feature'
says "the user's decision" 'git push origin --delete main'
says "the user's decision" 'git push origin :main'
says "the user's decision" 'git push --mirror origin'
says "the user's decision" 'git push origin +:main'
says "the user's decision" 'git push -fd origin main'
says "the user's decision" 'git push --force --delete origin main'
says "the user's decision" 'git push --delete origin +main'
says 'never rewritten' 'git push --delete origin +feature'
check 0 Bash 'git push origin --delete feature'

# No commit on main: a repository whose HEAD names main, one on a branch, a linked worktree (its
# .git file names an absolute gitdir), a worktree on main (a relative gitdir) and a detached HEAD.
# HEAD is read as a file; the repository above has none, so its cases do not depend on a branch.
onmain=$tmp/onmain
onfeat=$tmp/onfeat
mkdir -p "$onmain/.git/worktrees/wt" "$onmain/.git/worktrees/wtmain" "$onmain/sub" "$onfeat/.git" \
    "$tmp/wt" "$tmp/wtmain" "$tmp/detached/.git"
printf 'ref: refs/heads/main\n' > "$onmain/.git/HEAD"
mkdir -p "$onmain/.git/refs/heads"
printf '0123456789abcdef0123456789abcdef01234567\n' > "$onmain/.git/refs/heads/main"   # main is born
: > "$onmain/a.py"
printf 'ref: refs/heads/feat/x\n' > "$onfeat/.git/HEAD"
printf 'ref: refs/heads/feat/wt\n' > "$onmain/.git/worktrees/wt/HEAD"
printf 'ref: refs/heads/main\n' > "$onmain/.git/worktrees/wtmain/HEAD"
printf 'gitdir: %s/.git/worktrees/wt\n' "$(cygpath -m "$onmain")" > "$tmp/wt/.git"
printf 'gitdir: ../onmain/.git/worktrees/wtmain\r\n' > "$tmp/wtmain/.git"
printf '0123456789abcdef0123456789abcdef01234567\n' > "$tmp/detached/.git/HEAD"
mkdir -p "$tmp/nonl/.git"
printf 'ref: refs/heads/main' > "$tmp/nonl/.git/HEAD"   # written without a closing line break
printf '# pack-refs with: peeled fully-peeled sorted\n0123456789abcdef0123456789abcdef01234567 refs/heads/main\n' > "$tmp/nonl/.git/packed-refs"
check 2 Bash 'git commit -m x' "$(cygpath -w "$tmp/nonl")"
m=$(cygpath -w "$onmain")
f=$(cygpath -w "$onfeat")
fm=$(cygpath -m "$onfeat")
mm=$(cygpath -m "$onmain")
check 2 Bash 'git commit -m x' "$m"
check 2 Bash 'git commit -m x' "$m\\sub"
check 2 Bash 'git add a.py && git commit -m "Fix the parser"' "$m"
check 2 Bash 'git commit --amend --no-edit' "$m"
check 2 Bash 'git cherry-pick abc123' "$m"
check 2 Bash 'git cherry-pick --continue' "$m"
check 2 Bash 'git revert HEAD' "$m"
check 2 Bash 'git am fix.patch' "$m"
check 2 Bash 'git merge feature' "$m"
check 2 Bash 'git merge --no-ff feature' "$m"
check 2 Bash 'git merge --ff feature' "$m"
check 2 Bash 'git pull' "$m"
check 2 Bash 'git pull --rebase origin main' "$m"
check 2 Bash "git -C $mm commit -m x" "$f"
check 2 Bash "git -C \"$m\" commit -m x" "$f"
check 2 Bash "cd $mm && git commit -m x" "$f"
check 2 Bash "cd $mm/sub && git commit -m x" "$f"
check 2 Bash 'bash -c "git commit -m x"' "$m"
check 2 Bash 'git commit -m x' "$(cygpath -w "$tmp/wtmain")"
check 2 Bash 'git checkout main && git commit -m x' "$f"
check 2 Bash 'git switch feat/y && git switch main && git commit -m x' "$m"
check 2 Bash 'git checkout -b feat/y && git checkout main && git merge feat/y' "$m"
check 2 PowerShell 'git commit -m x' "$m"
check 2 PowerShell "Set-Location '$m'; git commit -m x" "$f"
check 2 PowerShell 'git switch feat/y; git switch main; git commit -m x' "$m"
says 'git switch -c' 'git commit -m x' "$m"
says 'pull --ff-only' 'git pull' "$m"
# An exemption counts as a word of its own, never inside a message
check 2 Bash 'git commit -m "Handle --abort in the parser"' "$m"
check 2 Bash 'git merge feature -m "keep --ff-only out"' "$m"
check 2 Bash 'git merge feature -- --ff-only' "$m"
# A path is no branch: git checkout . or of a file or folder that exists stays on main
check 2 Bash 'git checkout . && git commit -m x' "$m"
check 2 Bash 'git checkout a.py && git commit -m x' "$m"
check 2 Bash 'git checkout sub && git commit -m x' "$m"
# The forms that write a commit stay blocked: -n of merge is --no-stat
check 2 Bash 'git merge -n feature' "$m"
# git checkout <tree-ish> <path> takes files from a commit and stays on the branch
check 2 Bash 'git checkout HEAD a.py && git commit -m x' "$m"
check 2 Bash 'git checkout HEAD . && git commit -m x' "$m"
check 2 Bash 'git checkout feat/x a.py && git commit -m x' "$m"
# A switch in a folder that does not exist yet does not move the repository above it
check 2 Bash 'git -C nosuch checkout -b feat && git commit -m x' "$m"
check 2 Bash 'git clone https://example.org/y.git y && git -C y switch -c feat && git commit -m x' "$m"
# The same repository spelled another way is the same repository
check 2 Bash "git -C ./ checkout main && git merge feature" "$f"
check 2 Bash "git -C ${fm^^} checkout main && git -C $fm merge feature" "$m"
# Born once anything was committed: a ref log is enough
mkdir -p "$tmp/logged/.git/logs"
printf 'ref: refs/heads/main\n' > "$tmp/logged/.git/HEAD"
: > "$tmp/logged/.git/logs/HEAD"
check 2 Bash 'git commit -m x' "$(cygpath -w "$tmp/logged")"
# A rebase on main rewrites it like a pull --rebase
check 2 Bash 'git rebase origin/main' "$m"
check 2 Bash 'git rebase -i HEAD~3' "$m"
# A fresh repository: main is born only once its ref exists, loose or packed
mkdir -p "$tmp/fresh/.git/refs/heads"
printf 'ref: refs/heads/main\n' > "$tmp/fresh/.git/HEAD"
check 0 Bash 'git add README.md && git commit -m "Initial commit"' "$(cygpath -w "$tmp/fresh")"
check 0 Bash 'git commit -m "Initial commit"' "$(cygpath -w "$tmp/fresh")"
# The same commands on a branch, in a worktree on one, detached, or with main brought up to date
check 0 Bash 'git commit -m x' "$f"
check 0 Bash 'git commit -m x' "$(cygpath -w "$tmp/wt")"
check 0 Bash 'git commit -m x' "$(cygpath -w "$tmp/detached")"
check 0 Bash 'git merge feature' "$f"
check 0 Bash 'git pull' "$f"
check 0 Bash 'git cherry-pick abc123' "$f"
check 0 Bash 'git status && git log --oneline -3 && git diff' "$m"
check 0 Bash 'git merge --ff-only origin/main' "$m"
check 0 Bash 'git pull --ff-only' "$m"
check 0 Bash 'git merge --abort' "$m"
check 0 Bash 'git merge --quit' "$m"
check 0 Bash 'git cherry-pick --abort' "$m"
check 0 Bash 'git revert --quit' "$m"
check 0 Bash 'git am --abort' "$m"
check 0 Bash 'git switch -c feat/y && git add a.py && git commit -m x' "$m"
check 0 Bash 'git checkout -b feat/y && git commit -m x' "$m"
check 0 Bash 'git checkout -B feat/y origin/main && git commit -m x' "$m"
check 0 Bash 'git switch --create feat/y && git commit -m x' "$m"
check 0 Bash 'git switch -c feat/y main && git commit -m x' "$m"
check 0 Bash 'git checkout -- a.py && git checkout feat/x && git commit -m x' "$m"
check 2 Bash 'git checkout feat/x -- a.py && git commit -m x' "$m"
check 0 Bash 'git switch feat/x && git commit -m x' "$m"
check 0 Bash 'git checkout --detach && git commit -m x' "$m"
check 0 Bash 'git switch --detach main && git commit -m x' "$m"
check 0 Bash 'git checkout -b feat/y main && git commit -m x' "$m"
check 0 Bash 'git switch --create=feat/y && git commit -m x' "$m"
check 0 Bash "git -C $fm commit -m x" "$m"
check 0 Bash "cd $fm && git commit -m x" "$m"
check 0 Bash 'git -C sub log' "$m"
check 0 Bash 'echo "git commit -m x" && grep -r "git merge feature" .' "$m"
check 0 Bash 'gh pr create --title "Fix the parser" --body "git commit on main"' "$m"
check 0 PowerShell "Set-Location '$f'; git commit -m x" "$m"
# The forms of these verbs that write no commit
check 0 Bash 'git cherry-pick -n abc123' "$m"
check 0 Bash 'git cherry-pick --no-commit abc123' "$m"
check 0 Bash 'git revert -n HEAD' "$m"
check 0 Bash 'git merge --squash feature' "$m"
check 0 Bash 'git merge --no-commit feature' "$m"
check 0 Bash 'git commit --dry-run' "$m"
check 0 Bash 'git commit -h' "$m"
check 0 Bash 'git merge --help' "$m"
check 0 Bash 'git am --show-current-patch' "$m"
check 0 Bash 'git am --show-current-patch=diff' "$m"
# A branch name glued to its flag, and a folder made on the same line (a new worktree inside the
# repository), where the command runs later and git reads that folder's HEAD
check 0 Bash 'git checkout -bfeat/y && git commit -m x' "$m"
check 0 Bash 'git switch -cfeat/y && git commit -m x' "$m"
check 0 Bash 'git worktree add .worktrees/x -b x && cd .worktrees/x && git commit -m x' "$m"
# Any other folder that does not exist yet belongs to the repository above it; git fails there
# anyway, so refusing costs nothing
check 2 Bash 'git -C no-such-folder commit -m x' "$m"
check 0 Bash 'git checkout feat/x && git commit -m x' "$m"
# The word after -b, -B or --orphan is a new branch even when a folder has its name
check 0 Bash 'git checkout -b sub && git commit -m x' "$m"
check 0 Bash 'git checkout -B sub origin/main && git commit -m x' "$m"
check 0 Bash 'git checkout --orphan sub && git commit -m x' "$m"
check 0 Bash 'git switch -c sub && git commit -m x' "$m"
check 0 Bash 'git -C . switch -c feat/y && git commit -m x' "$m"
check 0 Bash 'cd sub && git switch -c feat/y && cd .. && git commit -m x' "$m"
check 0 Bash 'git rebase --abort' "$m"
check 0 Bash 'git rebase main' "$f"
check 0 Bash 'git pull --dry-run' "$m"
check 0 Bash 'git pull --no-commit origin feature' "$m"
check 0 Bash 'git pull --squash origin feature' "$m"
# A repository made on the same line has an unborn main, also in a folder inside one on main
mkdir -p "$onmain/newproj"
check 0 Bash 'cd newproj && git init && git add a.txt && git commit -m init' "$m"
check 0 Bash 'git init newproj && git -C newproj commit -m init' "$m"
check 2 Bash 'git init newproj && git commit -m x' "$m"
check 0 Bash 'cd newproj && git init -b trunk && git commit -m init' "$m"
mkdir -p "$onmain/newproj/src"
check 0 Bash 'git init newproj && git -C newproj/src commit -m init' "$m"
# After -- every word is a path, also one that does not exist yet
check 2 Bash 'git checkout -- not-yet.txt && git commit -m x' "$m"
# Found by the narrow verification after round 2
check 2 Bash 'git checkout HEAD && git commit -m x' "$m"
check 2 Bash 'git checkout @ && git commit -m x' "$m"
check 2 Bash 'git switch Main && git commit -m x' "$m"
mkdir -p "$onfeat/main"
check 2 Bash 'git checkout main && git commit -m x' "$f"
check 2 Bash 'mkdir newdir && cd newdir && git commit -m x' "$m"
check 2 Bash 'mkdir -p newdir && git -C newdir commit -m x' "$m"
check 2 Bash 'git rebase feat/x main' "$f"
check 2 Bash 'git rebase --onto origin/main HEAD~2 main' "$f"
check 2 Bash 'git rebase --skip' "$m"
# A switch that may have failed: after ; || & a backquote or a line break that ends the command,
# the commands after it may run on the branch before it, so that one counts as well as the one
# it switched to. Windows PowerShell 5.1 has no &&, so there the commit after a switch from main
# takes a call of its own.
check 2 Bash 'git checkout feat/typo; git commit -m x' "$m"
check 2 Bash 'git checkout "feat/typo"; git commit -m x' "$m"
# A command substitution runs before the command around it, so its commit still lands on main
check 2 Bash 'git switch -c feat/y `git commit -m x`' "$m"
check 2 Bash 'git checkout -b feat/y || git commit -m x' "$m"
check 2 Bash 'git checkout -b feat/y
git commit -m x' "$m"
check 2 Bash 'git switch -c feat/y & git commit -m x' "$m"
check 2 Bash 'bash -c "git checkout feat/typo; git commit -m x"' "$m"
check 2 Bash 'git checkout -b feat/y; echo ok && git commit -m x' "$m"
check 2 Bash 'git switch -c a; git switch -c b; git commit -m x' "$m"
# An && chain of switches fails as a whole at its first link, so main from before it carries on
check 2 Bash 'git switch -c b && git switch -c c; git commit -m x' "$m"
check 2 Bash 'git checkout main && git switch -c y && git switch z; git commit -m x' "$f"
# || ends the chain also at the end of a line, and so does a line break after a command
check 2 Bash 'git switch -c feat/y ||
  git commit -m x' "$m"
check 2 Bash 'git switch -c feat/y && git add a.py
git commit -m x' "$m"
says 'would make a commit on main' 'git switch -c a; git switch -c b; git rebase origin/main main' "$m"
# A folder name is data, never code: bash expands a key inside arithmetic a second time, so a
# repository in a folder called x$(touch injmark)y must not make the hook run touch
inj="$tmp/x\$(touch injmark)y"
mkdir -p "$inj/.git/refs/heads"
printf 'ref: refs/heads/main\n' > "$inj/.git/HEAD"
printf '0123456789abcdef0123456789abcdef01234567\n' > "$inj/.git/refs/heads/main"
check 2 Bash 'git switch -c y; git commit -m x' "$(cygpath -w "$inj")"
run=$((run + 1))
if [[ -e injmark || -e $inj/injmark ]]; then   # touch runs in the hook's folder, which is this one
    fail=$((fail + 1))
    echo "FAIL a folder name ran as a command (injmark exists)"
    rm -f injmark "$inj/injmark"
fi
# Output redirected with &> and piped with |& stays inside the chain; a substitution or a subshell
# after a switch keeps its separators to itself; in PowerShell & calls a command
check 0 Bash 'git switch -c feat/y &>/dev/null && git commit -m x' "$m"
check 0 Bash 'git switch -c feat/y && git diff |& tail -1 && git commit -m x' "$m"
check 0 Bash 'git switch -c feat/y && echo `date` && git commit -m x' "$m"
check 0 Bash 'git switch -c feat/y && x=$(git rev-parse HEAD; echo) && git commit -m x' "$m"
check 0 Bash 'git switch -c feat/y && (
  git commit -m x
)' "$m"
check 0 PowerShell 'git switch -c feat/y && & git commit -m x' "$m"
check 2 Bash '(git checkout feat/typo; git commit -m x)' "$m"
check 2 PowerShell 'git switch -c feat/y; git commit -m x' "$m"
check ask Bash 'git switch -c feat/y; git push -u origin HEAD' "$m"
says 'may have failed' 'git checkout feat/typo; git commit -m x' "$m"
says 'call of its own' 'git checkout feat/typo; git commit -m x' "$m"
check 2 Bash 'git checkout main; git commit -m x' "$f"
# The other half: a switch the commit can only follow when it worked, or one from a branch to a
# branch, where a failure leaves the commit on a branch either way
check 0 Bash 'git checkout -b feat/y && echo ok && git commit -m x' "$m"
check 0 Bash 'git switch -c a; git switch -c b && git commit -m x' "$m"
check 0 Bash 'git checkout main; git checkout feat/x && git commit -m x' "$f"
check 0 Bash 'git checkout feat/x; git commit -m x' "$f"
check 0 Bash 'git fetch origin; git checkout -b feat/z; git commit -m x' "$f"
check 0 Bash 'git switch -c feat/z | git commit -m x' "$f"
check 0 PowerShell 'git switch -c feat/z; git commit -m x' "$f"
check 0 Bash 'git fetch origin; git commit -m x' "$f"
# An && or a pipe at the end of a line goes on with the next one, and a pipe inside the chain is
# one link of it: the commit still runs only after the switch worked
check 0 Bash 'git switch -c feat/y &&
  git add a.py &&
  git commit -m x' "$m"
check 0 Bash 'git switch -c feat/y && git diff --stat | tail -1 && git commit -m x' "$m"
check 0 Bash 'git switch -c feat/y && git diff |
  tail -1 && git commit -m x' "$m"
# Not covered, as before: a switch in a subshell or a pipeline counts on for the line
check 0 Bash '(git switch -c feat/y) && git commit -m x' "$m"
check 0 Bash 'git switch -c feat/y | git commit -m x' "$m"
# The first commit makes main born: what follows on the line is judged as on main
check 2 Bash 'git commit -m init && git commit -m second' "$(cygpath -w "$tmp/fresh")"
check ask Bash 'git commit -m init && git push -u origin HEAD' "$(cygpath -w "$tmp/fresh")"
check 0 Bash 'git rebase origin/main feat/x' "$m"
check 0 Bash 'git rebase --onto origin/main HEAD~2 feat/x' "$m"
check 0 Bash 'git rebase --edit-todo' "$m"
check 0 Bash 'git rebase --show-current-patch' "$m"
check 0 Bash 'git init --object-format sha256 newproj && git -C newproj commit -m init' "$m"
check 0 Bash 'git clone https://example.org/repo.git && cd repo && git commit -m x' "$m"
check 0 Bash 'git clone -b dev https://example.org/repo.git copy && git -C copy commit -m x' "$m"
check 0 Bash 'git worktree add ../wt2 -b feat/z && cd ../wt2 && git commit -m x' "$m"
# Found by the final narrow check
check 2 Bash 'git rebase origin/main refs/heads/main' "$f"
check 2 Bash 'git rebase --empty drop origin/main main' "$f"
check 2 Bash 'git rebase -C 3 origin/main main' "$f"
check 2 Bash 'git rebase origin/main Main' "$f"
check 0 Bash 'git rebase origin/main feat/x && git commit -m x' "$m"
mkdir -p "$onmain/sub2"
check 2 Bash 'cd sub2 && git init --help; git commit -m x' "$m"
check 0 Bash 'git commit --porcelain' "$m"
check 0 Bash 'git commit --short' "$m"
check 0 Bash 'git commit --long' "$m"
# git init in a repository only reinitialises it: main stays born
check 2 Bash 'git init && git commit -m x' "$m"
# A push from main without a refspec, or of HEAD, goes to main: the same question as a push to it
check ask Bash 'git push' "$m"
check ask Bash 'git push origin' "$m"
check ask Bash 'git push -u origin HEAD' "$m"
check ask Bash 'git push origin @' "$m"
check ask PowerShell 'git push' "$m"
check ask Bash 'git push --all origin' "$f"
check ask Bash 'git push --branches' "$f"
check 0 Bash 'git push' "$f"
check 0 Bash 'git push -u origin HEAD' "$f"
check 0 Bash 'git push origin feat/x' "$m"
check 0 Bash 'git switch -c feat/y && git push -u origin HEAD' "$m"
check 0 Bash 'git push --tags origin' "$m"
# git takes any unambiguous prefix of a long option and pushes with it (measured with git 2.31:
# --force-w rewrote the remote branch, --mi mirrored, --de deleted); an ambiguous one such as
# --forc or --force- it refuses itself, so nothing is pushed
check 2 Bash 'git push --force-w origin feature' "$f"
check 2 Bash 'git push --force-wi origin feature' "$f"
check 2 Bash 'git push --force-with origin feature' "$f"
check 2 Bash 'git push --force-with-l=feature origin feature' "$f"
check 2 PowerShell 'git push --force-w origin feature' "$f"
check 2 Bash 'git push --mi' "$f"
check 2 Bash 'git push --m origin' "$f"
check 2 Bash 'git push --de origin main' "$f"
check 2 Bash 'git push origin --dele main' "$f"
check ask Bash 'git push --al origin' "$f"
check ask Bash 'git push --br origin' "$f"
check 0 Bash 'git push --dr origin main' "$m"
check 0 Bash 'git push --ta origin' "$m"
check 0 Bash 'git push --forc origin feature' "$f"
check 0 Bash 'git push --force- origin feature' "$f"
check 0 Bash 'git push --force-i origin feature' "$f"
check 0 Bash 'git push --pu ci.skip origin feature' "$f"
check ask Bash 'git push --pu ci.skip origin main' "$f"
check ask Bash 'git push --pu=ci.skip origin main' "$f"
check 0 Bash 'git push --forcex origin feature' "$f"
# An option that takes a value takes the next word, written out or abbreviated; a negation undoes
# its option, so the push it leaves is judged; after -- nothing is an option
check ask Bash 'git push --pu ci.skip origin' "$m"
check ask Bash 'git push --rece x origin' "$m"
check ask Bash 'git push --recurse-submodules check origin' "$m"
check ask Bash 'git push --recu check origin' "$m"
check ask Bash 'git push -n --no-dry-run origin main' "$f"
check ask Bash 'git push --dry-run --no-dr origin main' "$f"
check ask Bash 'git push --tags --no-tags' "$m"
check ask Bash 'git push -d --no-delete origin HEAD' "$m"
check 0 Bash 'git push origin -- --mi' "$f"
# A dry run pushes nothing, so it is not asked
check 0 Bash 'git push --dry-run' "$m"
check 0 Bash 'git push -n' "$m"
check 0 Bash 'git push -nu origin HEAD' "$m"
check 0 Bash 'git push --dry-run origin main' "$m"
check ask Bash 'git push -u origin main' "$m"
# The matching refspec and a wildcard over the branches push main too
check ask Bash 'git push origin :' "$f"
check ask Bash "git push origin 'refs/heads/*:refs/heads/*'" "$f"
check 0 Bash "git push origin 'refs/tags/*:refs/tags/*'" "$f"
check 0 Bash "git push origin 'refs/heads/feat/*:refs/heads/feat/*'" "$f"
check ask Bash "git push origin 'feat\\x:refs/heads/*'" "$f"

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
secs=$((SECONDS - start))
if ((secs >= 5)); then
    # measured again, as timed() below does: a moment of load cannot fail it, a slow split can
    start=$SECONDS
    check 0 Bash "$long"
    run=$((run - 1))
    secs=$((SECONDS - start))
fi
((secs < 5)) || { fail=$((fail + 1)); echo "FAIL a long command took $secs s"; }

# Closing check form: the section a pull request body needs before it is created or merged.
# GUARD_GIT_SELFTEST=form reads a text on stdin and prints ok or the first defect; =open prints
# the first item still open with the owner, or none.
skill_md="$(dirname "$0")/../templates/recommended/skills/closing-check/SKILL.md"
skeleton=
in_block=0
while IFS= read -r line; do
    line=${line%$'\r'}
    if ((in_block)); then
        [[ $line == '```'* ]] && break
        skeleton+=$line$'\n'
    elif [[ $line == '## Closing check' ]]; then
        in_block=1
        skeleton=$line$'\n'
    fi
done < "$skill_md"
[[ $skeleton == *'8. Other sessions'* ]] || { fail=$((fail + 1)); echo "FAIL no skeleton in $skill_md"; }
# The skeleton with one real item under every part instead of its placeholder line
fill() {
    local line out=
    while IFS= read -r line; do
        [[ $line == '- ['* ]] && continue
        out+=$line$'\n'
        [[ $line =~ ^([1-8])\. ]] && out+="- [done] part ${BASH_REMATCH[1]} walked, see commit 3b13627"$'\n'
    done <<< "$1"
    REPLY=$out
}
fill "$skeleton"
filled=$REPLY
form() {  # expected output, text[, mode]
    local out
    out=$(printf '%s' "$2" | GUARD_GIT_SELFTEST=${3:-form} bash "$hook" 2>&1)
    run=$((run + 1))
    [[ $out == "$1" ]] && return 0
    fail=$((fail + 1))
    echo "FAIL form expected '$1' got '${out:0:160}': ${2:0:80}"
}
form ok "$filled"
form ok "Abschluss der Arbeit, auf Deutsch.

$filled
Danach geht es weiter."
form ok "${filled//$'\n'/$'\r\n'}"
# The CR of a CRLF line is no character of the item: nine characters stay too short
crlf=${filled/- \[done\] part 2 walked, see commit 3b13627/- [done] 123456789}
form "item too short in part 2" "${crlf//$'\n'/$'\r\n'}"
form "placeholder in part 1" "$skeleton"
# An HTML comment renders as nothing, so nothing inside one counts: a template's example items, an
# item hidden from the reader, a heading; an unclosed one hides the rest, as GitHub shows it
item2='- [done] part 2 walked, see commit 3b13627'
form ok "${filled/'## Closing check'/$'## Closing check\n<!-- How to fill it:\n  - [done] an example item\n  - [state] text\n-->'}"
form ok "${filled/'## Closing check'/$'<!-- ## Closing check -->\n## Closing check'}"
form "part 2 has no item" "${filled/"$item2"/"<!-- $item2 -->"}"
form "part 2 has no item" "${filled/"$item2"/$'<!--\n'"$item2"$'\n-->'}"
form ok "${filled/"$item2"/"$item2 <!-- a note -->"}"
form "placeholder in part 2" "${filled/"$item2"/"$item2 <!-- a note --> TODO"}"
form ok "${filled/"$item2"/"$item2"$'\n<!--\n## Notes\n- [x] a note\n-->'}"
form "part 3 missing" "${filled/"$item2"/"$item2"$'\n<!-- never closed'}"
form "part 2 has no item" "${filled/"$item2"/"<!-- a --> <!-- $item2 -->"}"
form none "$filled"$'<!-- - [open with owner] a hidden decision -->' open
form none "$filled"$'<!--\n- [open with owner] a hidden decision\n-->' open
form ok "${filled/"$item2"/"<!-- a -->$item2<!-- b -->"}"
form "placeholder in part 2" "${filled/"$item2"/"$item2 <!-- a --> TODO <!-- b -->"}"
# A comment inside a line ends there or is text: GitHub shows what follows, items included
spill=$'- [done] the parser now strips <!-- comments, see 3b13627\n- [open with owner] keep the retry or drop it\n- [done] a stray --> alone is kept as text'
form ok "${filled/"$item2"/"$spill"}"
form '- [open with owner] keep the retry or drop it' "${filled/"$item2"/"$spill"}" open
form ok "${filled/"$item2"/"- [done] the template now says <!-- is literal, see 3b13627"}"
form "placeholder in part 2" "${filled/"$item2"/"$item2 <!-- TODO"}"
form ok "${filled/"$item2"/"$item2 <!-- TODO later -->"}"
form "placeholder in part 2" "${filled/"$item2"/"$item2 <!--> TODO -->"}"
form "placeholder in part 2" "${filled/"$item2"/"$item2 <!---> TODO -->"}"
# In a fenced code block and in a line with a code span, <!-- is text GitHub shows
form '- [open with owner] decide on the release' "$filled"$'```html\n<!-- template start\n```\n- [open with owner] decide on the release' open
form '- [open with owner] decide on the release' "$filled"$'~~~\n  <!-- template start\n~~~\n- [open with owner] decide on the release' open
form none "$filled"$'```\nx\n```\n<!--\n- [open with owner] a hidden decision\n-->' open
form ok "${filled/"$item2"/'- [done] a `<!--` ends at `-->`'}"
# <!--> and <!---> are whole comments: the line holding them ends the comment
form '- [open with owner] decide on the release' "$filled"$'<!-->\n- [open with owner] decide on the release' open
form '- [open with owner] decide on the release' "$filled"$'<!--->\n- [open with owner] decide on the release' open
# A body written in PowerShell, with CRLF line ends
crlfc=${filled/'## Closing check'/$'## Closing check\n<!-- How to fill it:\n  - [done] an example item\n-->'}
form ok "${crlfc//$'\n'/$'\r\n'}"
crlfh=${filled/"$item2"/$'<!--\n'"$item2"$'\n-->'}
form "part 2 has no item" "${crlfh//$'\n'/$'\r\n'}"
form '- [open with owner] a decision that shows' "$filled"$'- [open with owner] a decision that shows\n<!-- a note -->' open
form "no '## Closing check' heading" "## Summary
1. Questions to the owner
- [done] nothing was asked in this session"
form "no '## Closing check' heading" "### Closing check
${filled#*$'\n'}"
form "part 8 missing" "${filled%%8. Other sessions*}"
form "part 8 missing" "${filled%%8. Other sessions*}## Testing
8. Other sessions
- [done] the hook suite ran green"
form "part 5 has no item" "${filled/5. Routine steps$'\n'- \[done\] part 5 walked, see commit 3b13627$'\n'/5. Routine steps$'\n'}"
form "part 3 missing" "${filled/3. Promises/9. Promises}"
# A numbered line counts as a part only with the next part's number; any other is text of the
# part it stands in (a numbered sub-step, a list after the section)
swapped=${filled/3. Promises/X}
swapped=${swapped/4. Issue/3. Promises}
form "part 4 missing" "${swapped/X/4. Issue}"
form ok "${filled/- \[done\] part 2 walked, see commit 3b13627/- [done] part 2 walked, in three steps:
1. a numbered sub-step
2. another one}"
form ok "$filled
1. a numbered list after the section
2. its second line"
# An item indented under another is an item too: checked, and found when still open
nested=${filled/- \[done\] part 2 walked, see commit 3b13627/- [done] part 2 walked, see commit 3b13627
  - [open with owner] the nested decision}
form ok "$nested"
form "  - [open with owner] the nested decision" "$nested" open
form "placeholder in part 2" "${nested/the nested decision/the nested TODO}"
form ok "${filled/- \[done\] part 2 walked, see commit 3b13627/- [done] part 2 walked, see commit 3b13627
  - a plain note under it}"
# Links, types and comparisons are no placeholders; <what> and the like are
form ok "${filled/part 2 walked, see commit 3b13627/part 2 walked, see <https://github.com/o/r/pull/3>}"
form ok "${filled/part 2 walked, see commit 3b13627/part 2: the parser takes Vec<String> now}"
form "placeholder in part 2" "${filled/part 2 walked, see commit 3b13627/part 2 walked, see <what you looked at>}"
# A second heading starts the section anew (a title that is the heading itself)
form ok "## Closing check
$filled"
form "item too short in part 2" "${filled/- \[done\] part 2 walked, see commit 3b13627/- [done] ok}"
form "item too short in part 4" "${filled/- \[done\] part 4 walked, see commit 3b13627/- [open with owner]}"
form "placeholder in part 3" "${filled/part 3 walked/TODO walked}"
form "placeholder in part 6" "${filled/part 6 walked/part 6 FIXME walked}"
form "placeholder in part 6" "${filled/part 6 walked/part <n> walked}"
form "placeholder in part 2" "${filled/- \[done\] part 2 walked, see commit 3b13627/- [issue #<n>] recorded there}"
form "item without a state in part 7" "${filled/- \[done\] part 7 walked/- part 7 walked}"
form "item without a state in part 7" "${filled/- \[done\] part 7 walked/- [later] part 7 walked}"
form "item outside a part" "## Closing check
- [done] an item before the first part
${filled#*$'\n'}"
form ok "${filled/- \[done\] part 7 walked, see commit 3b13627/- [nothing] checked by git status of every worktree}"
form "[nothing] without 'checked by' in part 3" "${filled/- \[done\] part 3 walked, see commit 3b13627/- [nothing] just the session extract}"
form ok "${filled/- \[done\] part 2 walked, see commit 3b13627/- [issue #12] recorded there
- [limitation] Windows only, written in README
- [dropped] the benchmark, the change touches docs only
- [open with owner] decide the release date}"
form ok "${filled/part 4 walked/part 4: x < 5 and y > 3, a->b, TODOs.md renamed}"
# A routine step that was not run stays open with the owner: "live verification not run" as a
# limitation is how the case that started this reached a merge
part5_reason='in part 5: a routine step not run stays [open with owner] until the owner drops it'
form "[limitation] $part5_reason" "${filled/- \[done\] part 5 walked/- [limitation] live verification not run, part 5 walked}"
form "[nothing] $part5_reason" "${filled/- \[done\] part 5 walked/- [nothing] checked by CLAUDE.md, part 5 walked}"
form ok "${filled/- \[done\] part 5 walked/- [dropped] live verification, the owner skipped it on 2026-11-15, part 5 walked}"
form none "$filled" open
form "- [open with owner] decide the release date" "${filled/- \[done\] part 2 walked, see commit 3b13627/- [open with owner] decide the release date}" open
form none "## Summary
- [open with owner] outside the section" open

# Closing check: a pull request in one of the user's own repositories is created only with a filled
# section, and only once the closing-check skill is installed. Own means the repository's owner is
# the user gh is logged in as (hosts.yml, read as a file).
mkdir -p "$tmp/cfg-on/skills/closing-check" "$tmp/cfg-off" "$tmp/gh" "$tmp/nohome"
: > "$tmp/cfg-on/skills/closing-check/SKILL.md"
printf 'github.com:\n    git_protocol: https\n    users:\n        owner1:\n    user: owner1\n' > "$tmp/gh/hosts.yml"
mkrepo() {  # folder, origin url[, upstream url[, the remote gh resolved as base]]
    mkdir -p "$1/.git"
    {
        printf '[core]\n\tbare = false\n'
        if [[ -n $3 ]]; then
            printf '[remote "upstream"]\n\turl = %s\n' "$3"
            [[ $4 == upstream ]] && printf '\tgh-resolved = base\n'
        fi
        printf '[remote "origin"]\n\turl = %s\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n' "$2"
        [[ $4 == origin ]] && printf '\tgh-resolved = base\n'
        printf '[branch "feature"]\n\tremote = origin\n'
    } > "$1/.git/config"
    printf 'ref: refs/heads/feature\n' > "$1/.git/HEAD"
}
mkrepo "$tmp/own" https://github.com/owner1/r.git
mkrepo "$tmp/own-ssh" git@github.com:Owner1/r.git
mkrepo "$tmp/other" git@github.com:other/r.git
# gh opens a pull request on the upstream remote when there is one (a fork's parent), unless
# gh-resolved names the base: the owner that counts is that remote's
mkrepo "$tmp/other-up" https://github.com/other/r.git https://github.com/owner1/up.git
mkrepo "$tmp/fork" https://github.com/owner1/proj.git https://github.com/other/proj.git
mkrepo "$tmp/fork-own-base" https://github.com/owner1/proj.git https://github.com/other/proj.git origin
mkrepo "$tmp/up-own-base" https://github.com/other/proj.git https://github.com/owner1/proj.git upstream
mkdir -p "$tmp/norepo"
mkdir -p "$tmp/own/.git/worktrees/wt" "$tmp/own-wt"
printf 'gitdir: %s\n' "$tmp/own/.git/worktrees/wt" > "$tmp/own-wt/.git"
printf '../..\n' > "$tmp/own/.git/worktrees/wt/commondir"
printf 'ref: refs/heads/wt\n' > "$tmp/own/.git/worktrees/wt/HEAD"
printf '## Summary\n\nFaster parser.\n' > "$tmp/own/pr-bare.md"
printf '## Summary\n\nFaster parser.\n\n%s' "$filled" > "$tmp/own/pr-filled.md"
own=$(cygpath -w "$tmp/own")
other=$(cygpath -w "$tmp/other")
cc() {  # expected, skill folder (cfg-on or cfg-off), tool, command[, cwd]
    local -x CLAUDE_CONFIG_DIR=$tmp/$2 GH_CONFIG_DIR=$tmp/gh
    check "$1" "$3" "$4" "${5:-$own}"
}
cc 2 cfg-on Bash 'gh pr create --title t --body "x"'
cc 2 cfg-on Bash 'gh pr create --fill'
cc 2 cfg-on Bash 'gh pr create --web'
cc 2 cfg-on Bash 'gh pr create --title t --body-file pr-bare.md'
cc 2 cfg-on Bash 'gh pr create -t t -F pr-bare.md'
cc 2 cfg-on PowerShell "gh pr create --title t --body 'x'"
cc 2 cfg-on Bash "gh pr create --title t --body \"${filled%%8. Other*}\""
cc 2 cfg-on Bash 'gh pr create --title t --body "x"' "$(cygpath -w "$tmp/own-wt")"
cc 2 cfg-on Bash 'gh pr create --title t --body "x"' "$(cygpath -w "$tmp/own-ssh")"
cc 2 cfg-on Bash 'gh pr create -R owner1/r --title t --body "x"' "$other"
cc 2 cfg-on Bash 'gh pr create --repo=owner1/r --title t --body "x"' "$other"
cc 2 cfg-on Bash 'gh -R github.com/owner1/r pr create --title t --body "x"' "$other"
cc 2 cfg-on Bash 'cd ../own && gh pr create --title t --body "x"' "$other"
cc 2 cfg-on Bash 'gh api repos/owner1/r/pulls -f title=t -f head=b -f base=main -f body=x' "$other"
cc 2 cfg-on Bash 'gh api --method POST /repos/owner1/r/pulls --input pr.json' "$other"
cc 2 cfg-on Bash 'gh api repos/{owner}/{repo}/pulls -f title=t -f body=x'
cc 2 cfg-on Bash "gh api graphql -f query='mutation { createPullRequest(input: {repositoryId: \"R_1\", baseRefName: \"main\", headRefName: \"b\", title: \"t\"}) { pullRequest { url } } }'" "$other"
cc 0 cfg-on Bash "gh pr create --title t --body \"$filled\""
cc 0 cfg-on Bash 'gh pr create --title t --body-file pr-filled.md'
cc 0 cfg-on Bash "gh pr create --title t --body \"\$(cat <<'EOF'
## Summary

Faster parser.

$filled
EOF
)\""
cc 0 cfg-on PowerShell "gh pr create --title t --body @'
$filled
'@"
cc 0 cfg-on PowerShell "gh pr create --title t --body '${filled//$'\n'/$'\r\n'}'"
cc 0 cfg-on Bash "gh api repos/owner1/r/pulls -f title=t -f body=\"$filled\"" "$other"
cc 0 cfg-on Bash 'gh api repos/owner1/r/pulls' "$other"
cc 0 cfg-on Bash 'gh api repos/owner1/r/pulls/5/comments -f body=x' "$other"
cc 0 cfg-on Bash 'gh api -X GET repos/owner1/r/pulls -f state=open' "$other"
cc 0 cfg-on Bash 'gh pr view 5 --json body'
cc 0 cfg-on Bash 'gh pr list'
cc 0 cfg-off Bash 'gh pr create --title t --body "x"'
cc 0 cfg-off Bash 'gh api repos/owner1/r/pulls -f title=t -f body=x'
cc 0 cfg-on Bash 'gh pr create --title t --body "x"' "$other"
cc 2 cfg-on Bash 'gh pr create --title t --body "x"' "$(cygpath -w "$tmp/other-up")"
cc 0 cfg-on Bash 'gh pr create --title t --body "x"' "$(cygpath -w "$tmp/fork")"
cc 2 cfg-on Bash 'gh pr create --title t --body "x"' "$(cygpath -w "$tmp/fork-own-base")"
cc 2 cfg-on Bash 'gh pr create --title t --body "x"' "$(cygpath -w "$tmp/up-own-base")"
# The body glued to its option
cc 0 cfg-on Bash "gh pr create --title t --body=\"$filled\""
cc 0 cfg-on Bash "gh pr create --title t -b\"$filled\""
cc 2 cfg-on Bash 'gh pr create --title t --body="x"'
cc 0 cfg-on Bash 'gh pr create -t t -Fpr-filled.md'
cc 2 cfg-on Bash 'gh pr create -t t -Fpr-bare.md'
cc 0 cfg-on Bash "gh pr create --title '## Closing check' --body \"$filled\""
# gh posts a call with --input as it does one with fields
cc 2 cfg-on Bash 'gh api repos/owner1/r/pulls --input pr.json' "$other"
cc 0 cfg-on Bash 'gh pr create -R other/r --title t --body "x"'
cc 0 cfg-on Bash 'gh pr create --repo other/r --fill'
cc 0 cfg-on Bash 'gh api repos/other/r/pulls -f title=t -f body=x'
cc 0 cfg-on Bash 'gh pr create --title t --body "x"' "$(cygpath -w "$repo")"
# No logged-in user found: no check
nologin() {  # expected, command
    local -x CLAUDE_CONFIG_DIR=$tmp/cfg-on GH_CONFIG_DIR=$tmp/nogh APPDATA=$tmp/nogh HOME=$tmp/nohome
    check "$1" Bash "$2" "$own"
}
nologin 0 'gh pr create --title t --body "x"'
nologin 0 "gh api graphql -f query='mutation { createPullRequest(input: {title: \"t\"}) { pullRequest { url } } }'"
# gh's own order: GH_CONFIG_DIR alone when set, else XDG_CONFIG_HOME/gh, else the Windows
# AppData folder, else ~/.config/gh
mkdir -p "$tmp/appdata/GitHub CLI" "$tmp/xdg/gh" "$tmp/empty-gh"
cp "$tmp/gh/hosts.yml" "$tmp/appdata/GitHub CLI/hosts.yml"
cp "$tmp/gh/hosts.yml" "$tmp/xdg/gh/hosts.yml"
login_from() {  # expected, GH_CONFIG_DIR, XDG_CONFIG_HOME, APPDATA
    local -x CLAUDE_CONFIG_DIR=$tmp/cfg-on GH_CONFIG_DIR=$2 XDG_CONFIG_HOME=$3 APPDATA=$4 HOME=$tmp/nohome
    check "$1" Bash 'gh pr create --title t --body "x"' "$own"
}
login_from 0 "$tmp/empty-gh" '' "$tmp/appdata"
login_from 2 '' "$tmp/xdg" ''
login_from 0 '' "$tmp/empty-gh" "$tmp/appdata"
login_from 2 '' '' "$tmp/appdata"
# The refusal names the defect and gives the section's skeleton
cc_says() {  # text the reason must hold, command
    local -x CLAUDE_CONFIG_DIR=$tmp/cfg-on GH_CONFIG_DIR=$tmp/gh
    local value=${2//\"/\\\"} cwd=${own//\\/\\\\} json err
    json="{\"session_id\":\"t\",\"cwd\":\"$cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$value\"}}"
    err=$(printf '%s' "$json" | bash "$hook" 2>&1 >/dev/null)
    run=$((run + 1))
    [[ $err == *"$1"* ]] && return 0
    fail=$((fail + 1))
    echo "FAIL expected a reason with '$1': $2 (got: ${err:0:200})"
}
cc_says "no '## Closing check' heading" 'gh pr create --title t --body "x"'
cc_says '## Closing check' 'gh pr create --fill'
cc_says '1. Questions to the owner' 'gh pr create --fill'
cc_says '8. Other sessions' 'gh pr create --fill'
cc_says 'closing-check skill' 'gh pr create --fill'

# The same stop for the GitHub MCP tools, whose input names the owner
mcp() {  # expected, skill folder, tool, tool_input as JSON[, stdout pattern]
    local -x CLAUDE_CONFIG_DIR=$tmp/$2 GH_CONFIG_DIR=$tmp/gh
    local json out got
    json="{\"session_id\":\"t\",\"cwd\":\"${own//\\/\\\\}\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$3\",\"tool_input\":$4}"
    out=$(printf '%s' "$json" | bash "$hook" 2>/dev/null)
    got=$?
    run=$((run + 1))
    [[ $got == "$1" && (-z $5 && -z $out || -n $5 && $out == *"$5"*) ]] && return 0
    fail=$((fail + 1))
    echo "FAIL mcp expected $1${5:+ with $5} got $got${out:+ and stdout $out}: $3 ${4:0:120}"
}
json_text() {  # REPLY: $1 as the inside of a JSON string
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\r'/\\r}
    REPLY=${s//$'\n'/\\n}
}
json_text "$filled"
filled_json=$REPLY
create=mcp__plugin_github_github__create_pull_request
mcp 2 cfg-on $create '{"owner":"owner1","repo":"r","title":"t","head":"b","base":"main","body":"x"}'
mcp 2 cfg-on $create '{"owner":"Owner1","repo":"r","title":"t","head":"b","base":"main"}'
mcp 2 cfg-on mcp__github__create_pull_request '{"owner":"owner1","repo":"r","title":"t","body":"x"}'
mcp 0 cfg-on $create "{\"owner\":\"owner1\",\"repo\":\"r\",\"title\":\"t\",\"head\":\"b\",\"base\":\"main\",\"body\":\"$filled_json\"}"
json_text "${filled//$'\n'/$'\r\n'}"
mcp 0 cfg-on $create "{\"owner\":\"owner1\",\"repo\":\"r\",\"title\":\"t\",\"body\":\"$REPLY\"}"
mcp 0 cfg-on $create '{"owner":"other","repo":"r","title":"t","body":"x"}'
mcp 0 cfg-off $create '{"owner":"owner1","repo":"r","title":"t","body":"x"}'
mcp 0 cfg-on mcp__plugin_github_github__issue_write '{"method":"create","owner":"owner1","repo":"r","title":"t","body":"x"}'
mcp 0 cfg-on mcp__plugin_github_github__update_pull_request '{"owner":"owner1","repo":"r","pullNumber":5,"body":"x"}'
# A file written through the GitHub MCP tools is a commit on GitHub's side: on main (or with no
# branch, which is the default branch) it is refused in every repository, like a commit on main;
# its message is checked for an attribution like a commit's; any server's tools count
put=mcp__plugin_github_github__create_or_update_file
push=mcp__plugin_github_github__push_files
del=mcp__plugin_github_github__delete_file
mcp 2 cfg-on $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo","branch":"main"}'
mcp 2 cfg-on $push '{"owner":"owner1","repo":"r","branch":"main","files":[{"path":"a.md","content":"x"}],"message":"Fix a typo"}'
mcp 2 cfg-on $del '{"owner":"owner1","repo":"r","path":"a.md","message":"Drop a file","branch":"main"}'
mcp 2 cfg-on $put '{"owner":"other","repo":"r","path":"a.md","content":"x","message":"Fix a typo","branch":"main"}'
mcp 2 cfg-off $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo","branch":"main"}'
mcp 2 cfg-on $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo","branch":"refs/heads/main"}'
mcp 2 cfg-on $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo"}'
mcp 2 cfg-on $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo","branch":""}'
mcp 2 cfg-on mcp__github__push_files '{"owner":"owner1","repo":"r","branch":"main","files":[],"message":"x"}'
mcp 2 cfg-on $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo\n\nCo-Authored-By: Claude <noreply@anthropic.com>","branch":"feat/a"}'
mcp 2 cfg-on $push '{"owner":"owner1","repo":"r","branch":"feat/a","files":[],"message":"Fix\n\nGenerated with Claude Code"}'
mcp 0 cfg-on $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo","branch":"feat/a"}'
mcp 0 cfg-on $push '{"owner":"owner1","repo":"r","branch":"feat/a","files":[{"path":"a.md","content":"\"branch\":\"main\""}],"message":"Fix a typo"}'
mcp 2 cfg-on $push '{"owner":"owner1","repo":"r","branch":"main","files":[{"path":"a.md","content":"\"branch\":\"feat/x\""}],"message":"Fix a typo"}'
# Every key counts, a nested one too: it cannot stand in for the real branch or message
mcp 2 cfg-on $push '{"owner":"o","repo":"r","files":[{"path":"a","content":"x","branch":"feat/x"}],"branch":"main","message":"m"}'
mcp 2 cfg-on $push '{"owner":"o","repo":"r","branch":"feat/a","files":[{"path":"a","content":"x","message":"ok"}],"message":"Fix\n\nCo-Authored-By: Claude <noreply@anthropic.com>"}'
mcp 2 cfg-on $del '{"owner":"owner1","repo":"r","path":"a.md","message":"Drop\n\nGenerated with Claude Code","branch":"feat/a"}'
mcp 2 cfg-on $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo","branch":"heads/main"}'
mcp 2 cfg-on $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo","branch":null}'
# Another server's tool of the same name, without owner and repo, is no GitHub write, but its
# commit message is still one and checked
mcp 0 cfg-on mcp__gdrive__delete_file '{"fileId":"abc"}'
mcp 2 cfg-on mcp__gitlab__push_files '{"project_id":"7","files":[],"message":"Fix\n\nCo-Authored-By: Claude <noreply@anthropic.com>"}'
# Known limits, pinned: a nested branch stands in for a missing top-level one (the official server
# requires branch), and an empty nested one next to a valid top-level branch over-blocks
mcp 0 cfg-on $push '{"owner":"o","repo":"r","files":[{"path":"a","content":"x","branch":"feat/x"}],"message":"m"}'
mcp 2 cfg-on $push '{"owner":"o","repo":"r","files":[{"path":"a","content":"x","branch":""}],"branch":"feat/x","message":"m"}'
mcp 0 cfg-on $del '{"owner":"owner1","repo":"r","path":"main","message":"Drop main","branch":"feat/main-cleanup"}'
mcp 0 cfg-on $put '{"owner":"owner1","repo":"r","path":"a.md","content":"x","message":"Fix a typo","branch":"Main"}'
mcp 0 cfg-on mcp__plugin_github_github__create_branch '{"owner":"owner1","repo":"r","branch":"feat/b","from_branch":"main"}'
# A large file still answers well inside the hook's 30 s timeout, which would let it through
# unchecked: reading every key once cost time with the square of the size (84 s at 300 KB); now
# about 0.3 s. One run over the limit is measured again, as in timed() below.
big=$(head -c 307200 /dev/zero | tr '\0' 'a')
for try in 1 2; do
    start=$(date +%s%N)
    mcp 2 cfg-on $push "{\"owner\":\"owner1\",\"repo\":\"r\",\"files\":[{\"path\":\"a\",\"content\":\"$big\"}],\"message\":\"m\",\"branch\":\"main\"}"
    ms=$((($(date +%s%N) - start) / 1000000))
    echo "timing: push_files of 300 KB: $ms ms"
    ((ms >= 5000 && try == 1)) && run=$((run - 1)) || break
done
((ms < 5000)) || { fail=$((fail + 1)); echo "FAIL push_files of 300 KB took $ms ms"; }

# The merge stop: the hook reads the pull request's body with `gh pr view` (a fake gh here, first on
# PATH, that prints the file FAKE_GH_BODY names or fails like gh without a network) and refuses the
# merge without a filled section or with an item still open with the owner. After a pass the merge
# is still the user's decision.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
[[ -n $FAKE_GH_SLEEP ]] && sleep "$FAKE_GH_SLEEP"
if [[ -z $FAKE_GH_BODY ]]; then
    echo 'error connecting to api.github.com' >&2
    echo 'check your internet connection or https://githubstatus.com' >&2
    exit 1
fi
[[ -n $FAKE_GH_WARN ]] && echo "$FAKE_GH_WARN" >&2
printf '@author %s\n' "${FAKE_GH_AUTHOR:-owner1 owner1}"
cat "$FAKE_GH_BODY"
EOF
# What the hook asks gh for: a marked line with the pull request's author and its commits'
# authors, then the body
view='--json author,commits,body --jq "@author " + .author.login + " " + ([.commits[].authors[].login] | unique | join(",")) + "\n" + .body'
gh_log() {  # REPLY: the fake gh's log
    REPLY=$(<"$tmp/gh.log")
}
chmod +x "$tmp/bin/gh"
printf '## Summary\n\nFaster parser.\n\n%s' "$filled" > "$tmp/body-filled.md"
printf '## Summary\n\nFaster parser.\n\nlive benchmarks: not run\n' > "$tmp/body-bare.md"
printf '## Summary\n\n%s' "${filled/- \[done\] part 3 walked, see commit 3b13627/- [open with owner] run the live benchmark}" > "$tmp/body-open.md"
merge_ask='Merging a pull request'
gm() {  # expected (2, ask), body fixture (empty: gh fails), tool, command or tool_input[, skill folder[, cwd]]
    local -x CLAUDE_CONFIG_DIR=$tmp/${5:-cfg-on} GH_CONFIG_DIR=$tmp/gh PATH="$tmp/bin:$PATH" FAKE_GH_LOG=$tmp/gh.log
    local -x FAKE_GH_BODY=${2:+$tmp/$2}
    if [[ $3 == mcp__* ]]; then
        if [[ $1 == ask ]]; then mcp 0 "${5:-cfg-on}" "$3" "$4" '"permissionDecision":"ask"'; else mcp "$1" "${5:-cfg-on}" "$3" "$4"; fi
    else
        check "$1" "$3" "$4" "${6:-$own}"
    fi
}
: > "$tmp/gh.log"
gm ask body-filled.md Bash 'gh pr merge 5 --merge'
gm 2 body-bare.md Bash 'gh pr merge 5 --merge'
gm 2 body-open.md Bash 'gh pr merge 5 --squash --delete-branch'
gm 2 '' Bash 'gh pr merge 5 --merge'
gm 2 body-bare.md Bash 'gh pr merge --merge'
gm 2 body-bare.md Bash 'gh pr merge -t "Faster parser" --merge 5'
gm 2 body-bare.md PowerShell 'gh pr merge 5 --merge'
gm 2 body-bare.md Bash 'gh pr merge https://github.com/owner1/r/pull/5 --merge'
gm 2 body-bare.md Bash 'gh pr merge 5 -R owner1/r --merge'
gm ask body-bare.md Bash 'gh pr merge 5 -R other/r --merge'
gm ask body-bare.md Bash 'gh pr merge 5 --merge' cfg-off
# gh was asked for exactly the body of the pull request named, in the repository named
gh_log
gh_log=$REPLY
for want in "pr view 5 $view" "pr view https://github.com/owner1/r/pull/5 $view" "pr view 5 -R owner1/r $view" "pr view $view"; do
    run=$((run + 1))
    [[ $nl$gh_log$nl == *"$nl$want$nl"* ]] || { fail=$((fail + 1)); echo "FAIL gh was not called as: gh $want (log: ${gh_log//$nl/ | })"; }
done
run=$((run + 1))
[[ $gh_log != *other/r* ]] || { fail=$((fail + 1)); echo "FAIL gh read the body of another owner's pull request"; }
# The refusal says why
gm_says() {  # text the reason must hold, body fixture, command
    local -x CLAUDE_CONFIG_DIR=$tmp/cfg-on GH_CONFIG_DIR=$tmp/gh PATH="$tmp/bin:$PATH" FAKE_GH_LOG=$tmp/gh.log
    local -x FAKE_GH_BODY=${2:+$tmp/$2}
    cc_says "$1" "$3"
}
gm_says 'still open with owner: - [open with owner] run the live benchmark' body-open.md 'gh pr merge 5 --merge'
gm_says "could not be read: error connecting to api.github.com" '' 'gh pr merge 5 --merge'
gm_says "no '## Closing check' heading" body-bare.md 'gh pr merge 5 --merge'
# A gh that hangs (a stalled connection) refuses the merge instead of eating the hook's timeout
slow_says() {  # text the reason must hold, command
    local -x GUARD_GIT_GH_TIMEOUT=1 FAKE_GH_SLEEP=5
    gm_says "$1" body-filled.md "$2"
}
slow_says 'gh did not answer within 1 s' 'gh pr merge 5 --merge'
# A pull request named by its URL belongs to the URL's owner, wherever the command runs
: > "$tmp/gh.log"
gm 2 body-bare.md Bash 'gh pr merge https://github.com/owner1/r/pull/5 --merge' cfg-on "$(cygpath -w "$tmp/norepo")"
gm ask body-bare.md Bash 'gh pr merge https://github.com/other/x/pull/5 --merge'
gm ask body-bare.md Bash 'gh pr merge 5 --merge' cfg-on "$(cygpath -w "$tmp/fork")"
gm 2 body-bare.md Bash 'gh pr merge 5 --merge' cfg-on "$(cygpath -w "$tmp/other-up")"
run=$((run + 1))
[[ $(<"$tmp/gh.log") != *other/x* ]] || { fail=$((fail + 1)); echo "FAIL gh read the body of another owner's pull request named by URL"; }
merge=mcp__plugin_github_github__merge_pull_request
: > "$tmp/gh.log"   # the MCP cases alone show which pull request they read
gm ask body-filled.md $merge '{"owner":"owner1","repo":"r","pullNumber":5,"merge_method":"squash"}'
gm 2 body-bare.md $merge '{"owner":"owner1","repo":"r","pullNumber":5}'
gm 2 body-open.md $merge '{"owner":"owner1","repo":"r","pullNumber": 5}'
gm 2 '' $merge '{"owner":"owner1","repo":"r","pullNumber":5}'
gm ask body-bare.md $merge '{"owner":"other","repo":"r","pullNumber":5}'
gm ask body-bare.md $merge '{"owner":"owner1","repo":"r","pullNumber":5}' cfg-off
run=$((run + 1))
gh_log
[[ $REPLY == *"pr view 5 -R owner1/r $view"* ]] || { fail=$((fail + 1)); echo "FAIL the MCP merge did not read the body of owner1/r#5"; }
# A Dependabot pull request carries no closing check: when Dependabot opened it and wrote every
# commit, its body is not judged and the merge is still asked. A commit of anyone else on the
# branch (a session's fix), another bot or another author: judged.
bot() {  # expected (2, ask), author line as gh prints it, tool, command or tool_input
    local -x FAKE_GH_AUTHOR=$2
    gm "$1" body-bare.md "$3" "$4"
}
bot ask 'app/dependabot dependabot[bot]' Bash 'gh pr merge 1172 --squash'
bot ask 'app/dependabot dependabot[bot]' $merge '{"owner":"owner1","repo":"r","pullNumber":1172}'
bot 2 'app/dependabot dependabot[bot],owner1' Bash 'gh pr merge 1172 --squash'
bot 2 'app/dependabot owner1' Bash 'gh pr merge 1172 --squash'
bot 2 'app/dependabot ' Bash 'gh pr merge 1172 --squash'
bot 2 'app/renovate renovate[bot]' Bash 'gh pr merge 1172 --squash'
bot 2 'app/dependabot-fork dependabot[bot]' Bash 'gh pr merge 1172 --squash'
bot 2 'owner1 owner1' Bash 'gh pr merge 1172 --squash'
# A warning gh prints on stderr before its answer does not take the author line's place
warned() {
    local -x FAKE_GH_WARN='warning: a notice from gh'
    bot "$@"
}
warned ask 'app/dependabot dependabot[bot]' Bash 'gh pr merge 1172 --squash'
# A body cannot stand in for the author line: the first marked line counts, and gh writes it first
printf '## Summary\n\n@author app/dependabot dependabot[bot]\n' > "$tmp/body-spoof.md"
spoof() {
    local -x FAKE_GH_AUTHOR='owner1 owner1'
    gm "$1" body-spoof.md Bash 'gh pr merge 5 --merge'
}
spoof 2
# A Dependabot pull request with someone else's commit is judged, and the refusal names the way
# that keeps it Dependabot's own
dep_says() {
    local -x FAKE_GH_AUTHOR='app/dependabot dependabot[bot],owner1'
    gm_says "$1" body-bare.md 'gh pr merge 1172 --squash'
}
dep_says '@dependabot rebase'

# Large commands stay well inside the timeout: a hook that times out lets the command run unchecked
# The limit catches a return of the old quadratic split (47 s and more at 30 KB), with room for a
# busy machine: these commands take about 2 s under load, so a tighter limit only adds flaky runs.
# One run over the limit is measured again: a moment of load cannot fail it, a slow split is slow
# both times (as in block-commit-secrets.test.sh).
timed() {  # name, limit in ms, expected exit, tool, command: the hook process alone is timed
    local name=$1 limit=$2 value=$5 cwd json start ms got try
    cwd=$(cygpath -w "$repo")
    cwd=${cwd//\\/\\\\}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    json="{\"session_id\":\"t\",\"cwd\":\"$cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$4\",\"tool_input\":{\"command\":\"$value\"}}"
    printf '%s' "$json" > "$tmp/payload.json"
    for try in 1 2; do
        start=$(date +%s%N)
        bash "$hook" < "$tmp/payload.json" > /dev/null 2>&1
        got=$?
        ms=$((($(date +%s%N) - start) / 1000000))
        echo "timing: $name: $ms ms, exit $got"
        [[ $got == "$3" ]] && ((ms >= limit)) && ((try == 1)) || break
    done
    run=$((run + 1))
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
