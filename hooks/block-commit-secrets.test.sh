#!/usr/bin/env bash
# Tests for block-commit-secrets.sh: each case builds a scratch repository, feeds a PreToolUse
# payload and expects exit 2 (blocked) or 0 (allowed). Run: bash hooks/block-commit-secrets.test.sh
# The fake secrets are put together at run time, so this file holds none that a scanner (this hook,
# gitleaks) would find. As in the other tests the halves mirror each other: the same secret once
# where the commit takes it and once where it does not.

hook="$(dirname "$0")/block-commit-secrets.sh"
fail=0
run=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
r=$tmp/trepo   # its Windows path, the default cwd, holds \t, which must not turn into a tab
elsewhere=$tmp/elsewhere
mkdir -p "$elsewhere"

github="ghp_$(printf 'a1B2%.0s' {1..10})"
fine_grained="github_pat_$(printf '11AbC_dE2%.0s' {1..8})"
aws="AKIA$(printf 'Q7%.0s' {1..8})"
key_block="-----BEGIN OPENSSH PRIV""ATE KEY-----"
slack="xoxb-$(printf '12345%.0s' {1..3})-AbCdEfGhIj"
minisign="untrusted comment: minisign encrypted sec""ret key"
assignment="SERVICE_API_KEY=q8Zr2mT5""vX9kL3pN7wY4"
json_assignment="\"client_secret\": \"Zr2mT5vX9""kL3pN7wY4q8\","

fresh() {  # a repository with one commit of a.txt
    rm -rf "$r"
    git init -q "$r"
    git -C "$r" config user.email test@example.org
    git -C "$r" config user.name test
    git -C "$r" config commit.gpgsign false
    git -C "$r" config core.autocrlf false
    echo base > "$r/a.txt"
    git -C "$r" add a.txt
    git -C "$r" commit -q -m init
}

stage() {  # file, content: written and staged
    mkdir -p "$(dirname "$r/$1")"
    printf '%s\n' "$2" > "$r/$1"
    git -C "$r" add -- "$1"
}

check() {  # expected exit, tool, command[, cwd]
    local json value=$3 cwd=${4:-$(cygpath -w "$r")}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    cwd=${cwd//\\/\\\\}
    json="{\"session_id\":\"t\",\"cwd\":\"$cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$2\",\"tool_input\":{\"command\":\"$value\"}}"
    printf '%s' "$json" | bash "$hook" 2>"$tmp/stderr"
    local got=$?
    run=$((run + 1))
    if [[ $got != "$1" ]]; then
        fail=$((fail + 1))
        echo "FAIL expected $1 got $got: $2 ${3:0:160}"
    fi
}

# Each kind of secret, staged, blocks a commit; the same file without it does not
for secret in "$github" "$fine_grained" "$aws" "$key_block" "$slack" "$minisign" "$assignment" "$json_assignment" "token: \"$github\""; do
    fresh
    stage config.txt "$secret"
    check 2 Bash 'git commit -m "Add config"'
done
fresh
stage config.txt 'nothing to see'
check 0 Bash 'git commit -m "Add config"'

# Placeholders and references are no secrets
for harmless in 'SERVICE_API_KEY=your-api-key-goes-here-123' 'GITHUB_TOKEN=${{ secrets.GITHUB_TOKEN }}' 'token = os.environ["API_TOKEN"]' 'API_TOKEN=<insert token>' 'SESSION_SECRET=changeme-changeme-2024' 'max_tokens: 4096' 'secret_name = "deployment-key-for-prod"' 'AWS_KEY=AKIAEXAMPLE'; do
    fresh
    stage config.txt "$harmless"
    check 0 Bash 'git commit -m "Add config"'
done

# The block names the file and the kind, never the value
fresh
stage src/settings.py "$github"
check 2 Bash 'git commit -m x'
grep -q 'src/settings.py: GitHub token' "$tmp/stderr" || { fail=$((fail + 1)); echo "FAIL the block does not name file and kind: $(cat "$tmp/stderr")"; }
grep -q "$github" "$tmp/stderr" && { fail=$((fail + 1)); echo "FAIL the block shows the secret"; }
run=$((run + 2))

# Where the commit runs: -C, cd, Set-Location, a compound command, PowerShell, a here-document
check 2 Bash "git -C $r commit -m x" "$elsewhere"
check 2 Bash "git -C \"$(cygpath -m "$r")\" -c core.editor=true commit -m x" "$(cygpath -w "$elsewhere")"
check 2 Bash "cd $r && git commit -m x" "$elsewhere"
check 2 Bash "git status && git diff --stat | tail -1; git commit -m x && git push"
check 2 PowerShell "Set-Location '$(cygpath -w "$r")'; git commit -m 'x'" "$(cygpath -w "$elsewhere")"
check 2 Bash 'git commit -F - <<EOF
Add settings
EOF'
check 2 Bash 'cmd //c "git commit -m x"'
# a folder the hook cannot resolve (a variable): the payload's cwd is scanned instead
check 2 Bash 'd=. && git -C "$d" commit -m x'
check 2 Bash 'cd "$d" && git commit -m x'
check 2 PowerShell 'Set-Location $d; git commit -m x'
check 0 Bash 'git -C "$d" commit -m x' "$elsewhere"
# ...the folder the shell was in before it, not the one it started in
check 2 Bash "cd $r && git -C \"\$d\" commit -m x" "$elsewhere"
check 0 Bash "cd $elsewhere && git -C \"\$d\" commit -m x"
check 0 Bash 'git commit -m x' "$elsewhere"
check 0 Bash 'git status'
check 0 Bash 'git diff --cached'
check 0 Bash 'echo git commit -m x'
check 0 Bash 'gh issue comment 1 --body "then git commit -m x"'
check 0 Bash 'git log --grep "commit"'

# Unstaged changes count for -a, -am, --all and paths on the commit, not for a plain commit
fresh
printf '%s\n' "$aws" >> "$r/a.txt"
check 0 Bash 'git commit -m x'
check 2 Bash 'git commit -am x'
check 2 Bash 'git commit -a -m x'
check 2 Bash 'git commit --all -m x'
check 2 Bash 'git commit -m x a.txt'
check 2 Bash 'git commit -m x -- a.txt'
check 2 Bash 'git add a.txt && git commit -m x'
check 0 Bash 'git add b.txt && git commit -m x'
# The value of an option that takes a commit is no path, even when it is named like one
check 0 Bash 'git commit --fixup a.txt'
check 0 Bash 'git commit --squash a.txt'
check 0 Bash 'git commit --fixup amend:a.txt'
check 0 Bash 'git commit -C a.txt'
check 0 Bash 'git commit --reuse-message a.txt'
check 0 Bash 'git commit --reedit-message a.txt'
check 2 Bash 'git commit --fixup=a.txt a.txt'

# Untracked files count when a git add in the same command names them
fresh
printf '%s\n' "$slack" > "$r/new.txt"
echo fine > "$r/other.txt"
check 0 Bash 'git commit -m x'
check 2 Bash 'git add new.txt && git commit -m x'
check 2 Bash 'git add . && git commit -m x'
check 2 PowerShell 'git add new.txt; git commit -m x'
check 0 Bash 'git add other.txt && git commit -m x'
check 0 Bash 'git add new.txt'

# Up to 200 untracked files are read; past them the commit is blocked instead of passing unread
fresh
for i in $(seq -w 1 200); do echo clean > "$r/f$i.txt"; done
check 0 Bash 'git add f*.txt && git commit -m x'
echo clean > "$r/f201.txt"
check 2 Bash 'git add f*.txt && git commit -m x'
grep -q 'more than 200 untracked files' "$tmp/stderr" || { fail=$((fail + 1)); echo "FAIL the cap block does not say why: $(cat "$tmp/stderr")"; }
run=$((run + 1))
check 0 Bash 'git add -u && git commit -m x'
check 0 Bash 'git add -n . && git commit -m x'
git -C "$r" add -- 'f*.txt'
check 0 Bash 'git commit -m x'

# A byte that is no valid UTF-8 next to the secret does not hide it
fresh
printf 'caf\xe9 %s\n' "$github" > "$r/latin1.txt"
git -C "$r" add latin1.txt
check 2 Bash 'git commit -m x'

# OpenAI and Anthropic keys in the shapes gitleaks uses; text that only starts like one is none
body20=$(printf 'Ab3dE%.0s' {1..4})
openai_project="sk-proj-${body20}_x9T3Blbk""FJ${body20}-y8"
openai_legacy="sk-${body20}T3Blbk""FJ${body20}"
anthropic="sk-ant-api03-$(printf 'Zr2mT5vX9k%.0s' {1..9})AA"
anthropic_oauth="sk-ant-oat01-$(printf 'Zr2mT5vX9k%.0s' {1..9})AA"
for secret in "$openai_project" "$openai_legacy" "$anthropic" "$anthropic_oauth""client = OpenAI(api_key=\"$openai_project\")"; do
    fresh
    stage config.txt "$secret"
    check 2 Bash 'git commit -m x'
done
for harmless in 'see sk-learn and the disk-usage-report-for-the-whole-cluster-nodes docs' "sk-proj-${body20}${body20}" 'sk-ant-api03-short'; do
    fresh
    stage config.txt "$harmless"
    check 0 Bash 'git commit -m x'
done

# A secret that became a file name: staged (also empty, which shows no diff line), or added in
# the same command; the block shows the path with the secret cut out
fresh
stage "notes/$github" 'C:\Users\someone\.config\key.txt'
check 2 Bash 'git commit -m x'
grep -q 'notes/<the secret>: GitHub token in the file name' "$tmp/stderr" || { fail=$((fail + 1)); echo "FAIL the block does not show the redacted name: $(cat "$tmp/stderr")"; }
grep -q "$github" "$tmp/stderr" && { fail=$((fail + 1)); echo "FAIL the block shows the secret from the file name"; }
run=$((run + 2))
# Every secret in a path is cut out before any line is printed: two in one name, and a name with
# a secret beside content with another; an exact allowlist entry still names the real path
fresh
stage "fixtures/k-$github-$aws.txt" 'x'
stage "src/k-$slack.txt" "$aws"
check 2 Bash 'git commit -m x'
grep -q -e "$github" -e "$aws" -e "$slack" "$tmp/stderr" && { fail=$((fail + 1)); echo "FAIL the block shows a secret from a path: $(cat "$tmp/stderr")"; }
grep -q 'src/k-<the secret>.txt: AWS access key' "$tmp/stderr" || { fail=$((fail + 1)); echo "FAIL the content finding does not show the cut path: $(cat "$tmp/stderr")"; }
run=$((run + 2))
mkdir -p "$r/.claude"
printf 'fixtures/k-%s-%s.txt\nsrc/\n' "$github" "$aws" > "$r/.claude/secret-allowlist.txt"
check 0 Bash 'git commit -m x'
fresh
: > "$r/$openai_legacy"
git -C "$r" add -- "$openai_legacy"
check 2 Bash 'git commit -m x'
fresh
printf 'x\n' > "$r/$aws"
check 0 Bash 'git commit -m x'
check 2 Bash "git add $aws && git commit -m x"
check 2 Bash 'git add . && git commit -m x'
git -C "$r" add -- "$aws"
git -C "$r" commit -q -m 'the key as a name'
git -C "$r" rm -q -- "$aws"
check 0 Bash 'git commit -m "Remove the file"'

# git add -f stages an ignored file, so its content counts; without -f git refuses to add it
fresh
printf 'local.txt\n' > "$r/.gitignore"
printf '%s\n' "$aws" > "$r/local.txt"
check 0 Bash 'git add local.txt && git commit -m x'
check 2 Bash 'git add -f local.txt && git commit -m x'
check 2 Bash 'git add --force local.txt && git commit -m x'
check 2 Bash 'git add --fo local.txt && git commit -m x'
check 2 PowerShell 'git add -vf local.txt; git commit -m x'

# Per-repository allowlist and extra patterns
fresh
stage tests/fixtures/token.txt "$github"
check 2 Bash 'git commit -m x'
mkdir -p "$r/.claude"
printf '# fixtures\ntests/fixtures/\n' > "$r/.claude/secret-allowlist.txt"
check 0 Bash 'git commit -m x'
stage src/real.txt "$github"
check 2 Bash 'git commit -m x'
printf 'tests/fixtures/\r\nsrc/*.txt\r\n' > "$r/.claude/secret-allowlist.txt"
check 0 Bash 'git commit -m x'
fresh
stage notes.txt 'internal id INTERNAL-123456'
check 0 Bash 'git commit -m x'
mkdir -p "$r/.claude"
printf '# our ticket keys\n\nINTERNAL-[0-9]{6}\r\n' > "$r/.claude/secret-patterns.txt"
check 2 Bash 'git commit -m x'
grep -q 'pattern on line 3' "$tmp/stderr" || { fail=$((fail + 1)); echo "FAIL the extra pattern is not named: $(cat "$tmp/stderr")"; }
run=$((run + 1))

# Not a repository: nothing to scan
check 0 Bash 'git commit -m x' "$elsewhere"
check 0 Read command 'git commit -m x'

# A broken install blocks a commit, so the gap shows, instead of letting it through unchecked:
# without the library, and without git to read the changes
mkdir -p "$tmp/nolib"
cp "$hook" "$tmp/nolib/block-commit-secrets.sh"
saved=$hook
hook=$tmp/nolib/block-commit-secrets.sh
check 2 Bash 'git commit -m x'
hook=$saved
fresh
stage config.txt 'nothing to see'
bash_exe=$(command -v bash)
saved_path=$PATH
cwd_win=$(cygpath -w "$r")
PATH=/nonexistent
check() {  # as above, with git out of reach
    local json value=$3 cwd=${cwd_win//\\/\\\\}
    json="{\"session_id\":\"t\",\"cwd\":\"$cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$2\",\"tool_input\":{\"command\":\"$value\"}}"
    printf '%s' "$json" | "$bash_exe" "$hook" 2> "$tmp/stderr"
    local got=$?
    run=$((run + 1))
    [[ $got == "$1" ]] || { fail=$((fail + 1)); echo "FAIL without git: expected $1 got $got: $2 $3"; }
}
check 2 Bash 'git commit -m x'
check 0 Bash 'git status'
PATH=$saved_path

# Large commands stay well inside the timeout: a hook that times out lets the commit go unchecked
# The limit catches a return of the old quadratic split (47 s and more at 30 KB), with room for a
# busy machine: these commands take about 2 s under load, so a tighter limit only adds flaky runs.
timed() {  # name, limit in ms, expected exit, command: the hook process alone is timed
    local name=$1 limit=$2 value=$4 cwd start ms got
    cwd=$(cygpath -w "$r")
    cwd=${cwd//\\/\\\\}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    printf '%s' "{\"session_id\":\"t\",\"cwd\":\"$cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$value\"}}" > "$tmp/payload.json"
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
compound=""
while ((${#compound} < 30000)); do compound+="git status --short && echo 'commit the next step after this one' && "; done
compound+="git commit -m x"
unclosed="echo \"unclosed "
i=0
while ((${#unclosed} < 60000)); do
    i=$((i + 1))
    unclosed+="echo step $i before the commit >> notes.log ; npm test -- --shard=$i ; git diff --stat"$'\n'
done
timed "compound command of ${#compound} bytes" 5000 0 "$compound"
timed "script of ${#unclosed} bytes after an unclosed quote, then a commit" 5000 0 "$unclosed git commit -m x"
stage config.txt "$github"
timed "the same with a staged secret" 5000 2 "$unclosed git commit -m x"

echo "$run cases, $fail failed"
((fail == 0))
