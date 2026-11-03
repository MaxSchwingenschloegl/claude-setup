#!/usr/bin/env bash
# PreToolUse hook (Bash, PowerShell): blocks a `git commit` whose changes hold a likely secret.
# The commit hook in .githooks needs gitleaks and is skipped by --no-verify; this one runs before
# the command does, in every repository, with nothing to install. Plain bash on purpose, like
# block-secrets.sh, with git and awk from Git for Windows. Exit 2 blocks the call and tells Claude
# why; exit 0 leaves it to the normal permission flow.
#
# A commit is a `git ... commit` at command position (lib/command-segments.sh): behind -C/-c and
# the other global options, wrappers and in compound commands, not inside a message. It runs in the
# payload's cwd, followed through `cd <dir>` before it and every `git -C <dir>`; when that folder
# does not exist (a variable) or is no repository, the commit is not checked.
# Scanned, as added lines only: the staged changes (`git diff --cached`, one git call); with -a,
# --all or paths on the commit also the unstaged changes of tracked files; and when a `git add`
# comes before the commit in the same command, the unstaged and untracked files that add names
# (up to 200 untracked files), since it stages them only after this hook ran.
# Secrets: GitHub tokens (ghp_, gho_, ghu_, ghs_, ghr_, github_pat_), AWS access keys (AKIA, ASIA),
# private key blocks (-----BEGIN ... PRIVATE KEY-----, PGP included), Slack tokens (xoxa/b/p/r/s-),
# minisign secret keys, and an assignment to a name ending in API_KEY, APIKEY, TOKEN or SECRET
# (any case, = or :) of a value of 20 or more characters with a letter and a digit, unless it
# reads like a placeholder (example, placeholder, changeme, dummy, redacted, your, xxxx, sample).
# Per repository, in its root:
#   .claude/secret-patterns.txt   one extended regular expression (gawk) per line, # comments
#   .claude/secret-allowlist.txt  one path or glob per line (relative to the root, * crosses /),
#                                 a line ending in / exempts a folder; for test fixtures
# The block names the file and the kind of secret, never the value.
# A missing or broken lib/command-segments.sh blocks every shell call, and a commit when git is
# not on PATH (exit 2), so a broken install shows instead of letting commits through unchecked.
#
# Not covered: binary files (git shows no lines for them), a commit that takes its changes another
# way (--amend of an older commit, merges, cherry-picks, `git commit` in a script), a staged secret
# undone in the working tree before `commit -a`, secrets without a recognisable shape, and
# --git-dir/--work-tree. It is a guard against accidents, not against a determined attacker.
# Blocked although harmless: a test fixture or a document that shows a realistic fake secret; list
# its path in .claude/secret-allowlist.txt.
# Tests: hooks/block-commit-secrets.test.sh

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=lib/command-segments.sh
source "$here/lib/command-segments.sh" || {
    echo "Blocked by the claude-setup commit secret guard: its library $here/lib/command-segments.sh is missing or broken, so no shell command can be checked. Tell the user: restore the claude-setup hooks folder (git checkout in claude-setup, then install.ps1)." >&2
    exit 2
}

read_input
field tool_name 4096
case $REPLY in
    Bash) shell=bash ;;
    PowerShell) shell=powershell ;;
    *) exit 0 ;;
esac
field command
command=$REPLY
# Fast path: no commit named anywhere
shopt -s nocasematch
[[ $command =~ (^|[^[:alnum:]_-])commit([^[:alnum:]_-]|$) ]] || exit 0
shopt -u nocasematch

field cwd 4096
resolve_path / "${REPLY:-$PWD}"
CS_CWD=$REPLY

# Reads a unified diff on stdin (mode=diff) or whole files (mode=files) and prints
# "<path><TAB><kind>" once per file and kind of secret found
read -r -d '' scanner << 'AWK'
BEGIN {
    n = 0
    kind[++n] = "GitHub token";                re[n] = "gh[pousr]_[A-Za-z0-9]{36,}"
    kind[++n] = "GitHub fine-grained token";   re[n] = "github_pat_[A-Za-z0-9_]{60,}"
    kind[++n] = "AWS access key";              re[n] = "(AKIA|ASIA)[0-9A-Z]{16}"
    kind[++n] = "private key block";           re[n] = "-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----"
    kind[++n] = "Slack token";                 re[n] = "xox[abprs]-[A-Za-z0-9-]{10,}"
    if (extra != "") {
        k = 0
        while ((getline pat < extra) > 0) {
            k++
            sub(/\r$/, "", pat)
            if (pat ~ /^[ \t]*(#|$)/) continue
            kind[++n] = "pattern on line " k " of .claude/secret-patterns.txt"; re[n] = pat
        }
        close(extra)
    }
}
function found(what) {
    if (!((file, what) in seen)) { seen[file, what] = 1; print file "\t" what }
}
{
    if (mode == "diff") {
        if (substr($0, 1, 4) == "+++ ") {
            file = substr($0, 5); sub(/\t$/, "", file); gsub(/^"|"$/, "", file); sub(/^b\//, "", file)
            next
        }
        if (substr($0, 1, 1) != "+") next
        line = substr($0, 2)
    } else {
        file = FILENAME; sub(/^.*\/\.\//, "", file); line = $0
    }
    for (i = 1; i <= n; i++) if (line ~ re[i]) found(kind[i])
    lc = tolower(line)
    if (lc ~ /untrusted comment:[ \t]*minisign([ \t]+encrypted)?[ \t]+secret[ \t]+key/) found("minisign secret key")
    if (match(lc, /(^|[^a-z0-9])([a-z0-9]+[_-])*(api[_-]?key|token|secret)["']?[ \t]*[:=][ \t]*["']?/)) {
        v = substr(line, RSTART + RLENGTH)
        if (match(v, /^[A-Za-z0-9+\/_.=-]+/)) {
            v = substr(v, 1, RLENGTH)
            if (length(v) >= 20 && v ~ /[0-9]/ && v ~ /[A-Za-z]/ && tolower(v) !~ /example|placeholder|changeme|change_me|dummy|redacted|your|xxxx|sample/)
                found("secret assignment")
        }
    }
}
AWK

# Scans repository folder $1: git diff arguments after the first word; "untracked" before "--"
# reads the untracked files of the pathspecs after it instead. Appends findings to hits.
scan() {
    local dir=$1 root out line path entry exempt
    shift
    [[ -d $dir ]] || return 0
    repo_root "$dir" || return 0
    root=$REPLY
    local extra=$root/.claude/secret-patterns.txt
    [[ -f $extra ]] || extra=
    if [[ $1 == untracked ]]; then
        shift
        local -a files=()
        while IFS= read -r -d '' path; do
            files+=("$root/./$path")
            ((${#files[@]} >= 200)) && break
        done < <(git -C "$dir" ls-files -z --others --exclude-standard --full-name "$@" 2> /dev/null)
        ((${#files[@]})) || return 0
        out=$(LC_ALL=C awk -v mode=files -v extra="$extra" "$scanner" "${files[@]}" 2> /dev/null)
    else
        out=$(git -C "$dir" -c core.quotepath=false diff --unified=0 --no-color --no-ext-diff --no-textconv "$@" 2> /dev/null |
            LC_ALL=C awk -v mode=diff -v extra="$extra" "$scanner" 2> /dev/null)
    fi
    [[ -n $out ]] || return 0
    local -a allow=()
    if [[ -f $root/.claude/secret-allowlist.txt ]]; then
        while IFS= read -r entry || [[ -n $entry ]]; do
            entry=${entry%$'\r'}
            [[ -z ${entry//[[:space:]]/} || $entry == '#'* ]] && continue
            allow+=("$entry")
        done < "$root/.claude/secret-allowlist.txt"
    fi
    while IFS= read -r line; do
        path=${line%%$'\t'*}
        exempt=0
        for entry in "${allow[@]}"; do
            if [[ $entry == */ ]]; then
                [[ $path == "$entry"* ]] && exempt=1
            else
                # shellcheck disable=SC2053  # the entry is a glob on purpose
                [[ $path == $entry ]] && exempt=1
            fi
        done
        ((exempt)) || hits+="  $path: ${line#*$'\t'}$nl"
    done <<< "$out"
}

hits=""
adds=()   # "<folder><US><pathspec><US>..." of every git add before the commit
us=$'\x1f'

on_segment() {
    local i a after=0 entry
    local -a specs=() parts=()
    git_split
    case ${words[GIT_VERB]} in
        add)
            for ((i = GIT_VERB + 1; i < ${#words[@]}; i++)); do
                a=${words[i]}
                if ((!after)); then
                    case $a in
                        --) after=1; continue ;;
                        --chmod | --pathspec-from-file) ((i++)); continue ;;
                        -*) continue ;;
                    esac
                fi
                specs+=("$a")
            done
            ((${#specs[@]})) || specs=(":/")
            entry=$GIT_DIR_AT
            for a in "${specs[@]}"; do entry+=$us$a; done
            adds+=("$entry") ;;
        commit)
            if ! command -v git > /dev/null; then
                echo "Blocked by the claude-setup commit secret guard: git is not on the hook's PATH, so the changes of this commit cannot be checked. Tell the user: the hook runs in Git Bash, which brings git; check the Git for Windows install." >&2
                exit 2
            fi
            commit_parse $((GIT_VERB + 1))
            scan "$GIT_DIR_AT" --cached
            if ((COMMIT_ALL)); then
                scan "$GIT_DIR_AT"
            elif ((${#COMMIT_SPECS[@]})); then
                scan "$GIT_DIR_AT" -- "${COMMIT_SPECS[@]}"
            fi
            for entry in "${adds[@]}"; do
                IFS=$us read -r -a parts <<< "$entry"
                scan "${parts[0]}" -- "${parts[@]:1}"
                scan "${parts[0]}" untracked -- "${parts[@]:1}"
            done
            adds=()
            if [[ -n $hits ]]; then
                echo "Blocked by the claude-setup commit secret guard: the changes this commit takes look like they hold a secret:" >&2
                printf '%s' "$hits" >&2
                echo "Take the secret out of the file (an environment variable, the credential store, a gitignored file) and unstage it. If it is a test fixture or a placeholder, ask the user to list the path in .claude/secret-allowlist.txt." >&2
                exit 2
            fi ;;
    esac
}

CS_PROGRAMS[git]=on_segment
split_command "$command" "$shell" ""
exit 0
