#!/usr/bin/env bash
# PreToolUse hook (Bash, PowerShell, the GitHub MCP tools create_pull_request and
# merge_pull_request): blocks git and gh commands of a shape the git rules forbid,
# and asks the user before a push to main or the merge of a pull request. Rules alone are followed
# most of the time, and permission rules in settings.json match a command's start only (they miss
# `git -C dir push --force`); this is the hard stop for the rest. Plain bash on purpose, like
# block-secrets.sh: a hook that needed node or jq would stop guarding, silently, on a machine
# without them. Exit 2 blocks the call and tells Claude why; exit 0 with the PreToolUse decision
# "ask" as JSON on stdout puts the call to the user; exit 0 alone leaves it to the normal
# permission flow, whose deny and ask rules apply either way.
#
# Blocked:
# - AI attribution: a `...-by:` line naming Claude or Anthropic (Co-Authored-By and the like), a
#   `Claude-Session:` line, noreply@anthropic.com, and "Generated with/by Claude" in its
#   attribution forms (a footer line of its own, after the robot emoji, or with the link to Claude
#   Code; in prose it is no attribution), in `git commit` (its -m and --trailer values, a
#   here-document, what is piped into -F -, the file of -F/--file/-t/--template when it exists,
#   and what it takes from an existing commit, read with `git log` in the folder the commit runs
#   in: the message for -C, -c, --reuse-message, --reedit-message and --fixup=amend:/reword:, the
#   subject line for a plain --fixup and --squash), in `git merge`, `git tag` and `git notes`
#   (-m/--message, a here-document, the file of -F/--file), in `gh pr ...`, `gh issue ...` and
#   `gh release ...` (title, body, the file of --body-file/-F/--notes-file when it exists).
#   "CLAUDE.md" alone is no attribution.
# - A Claude or Anthropic identity (either word in the name or the address, a person called
#   Claude too): `git config user.name|user.email`, `git commit --author`, and the author a
#   commit keeps, from the commit -C, -c, --reuse-message or --reedit-message names or, with
#   --amend, from HEAD (not with --reset-author, the last of it and --no-reset-author counts).
# - Bulk staging: `git add` with -A, --all, -u, --update, --no-ignore-removal (also inside a group
#   of short flags such as -vA), with `.`, `./`, `:/`, `*`, with the root folder of the repository
#   (a submodule's folder is no root), or with exclude pathspecs only (`:!x`, `:^x`,
#   `:(exclude)x`), which stage everything else; `git commit` with -a, --all or -am.
# - Skipped hooks: --no-verify on any git subcommand, -n on `git commit` (on `git push`, -n is
#   --dry-run and stays allowed), and setting core.hooksPath: `git -c core.hooksPath=...`,
#   --config-env, a GIT_CONFIG_KEY_n / GIT_CONFIG_PARAMETERS prefix, `git config core.hooksPath
#   <value>`, --unset, --add, --replace-all, `git config set|unset`, --remove-section core.
#   Reading it (`git config core.hooksPath`, --get) stays allowed.
# - Rewriting the remote: `git push` with --force, -f (also in -fu), --force-with-lease[=...],
#   --mirror, a +refspec, or deleting main (`:main`, `+:main`, --delete/-d main; it gets its own
#   reason, as the merge path does not apply there); `gh pr update-branch
#   --rebase` and the GraphQL updatePullRequestBranch with updateMethod REBASE, which rebase the
#   pushed branch on GitHub's side. Plain `gh pr update-branch` merges main in and stays allowed.
# - A commit on main: `git commit`, `cherry-pick`, `revert`, `am`, `merge`, `pull` and `rebase`
#   while the repository the command acts on (its folder after cd and -C) has main checked out,
#   unless a word of theirs says they make no commit (check_commit lists them: --ff-only, --abort,
#   --quit, --squash, --no-commit, --dry-run and more). The branch is read from the HEAD file
#   (.git/HEAD, or the one in the folder a worktree's or submodule's .git file names), and a
#   `git switch` or `git checkout` earlier on the same line moves it for the commands after it. An
#   unborn main (before the first commit of a fresh repository) is not judged, nor is a folder a
#   `git init`, `git clone` or `git worktree add` earlier on the line makes; any other folder that
#   does not exist yet belongs to the repository above it.
# - A pull request without a filled closing check, once the closing-check skill is installed
#   (${CLAUDE_CONFIG_DIR:-~/.claude}/skills/closing-check/SKILL.md) and only in a repository
#   whose owner is the user gh is logged in as (`user:` in gh's hosts.yml, read as a file; the
#   owner from -R/--repo, a pull request's URL, the REST path, the MCP input, or the url of the
#   remote gh opens the pull request on, read from the repository's git config (the one marked
#   `gh-resolved = base`, else upstream, a fork's parent, else origin; a worktree's config through
#   its commondir)): `gh pr create` (its body in every form above, --body="..." too,
#   --fill and --web refused, as they carry none), `gh api` creating one (POST to
#   repos/<owner>/<repo>/pulls, GraphQL createPullRequest, which counts as own) and the MCP tool
#   create_pull_request. Filled: a line `## Closing check`, then the parts 1. to 8. in order up
#   to the next `## ` heading, each with at least one item `- [<state>] <text>` (done, open with
#   owner, issue #<n>, limitation, dropped, or `- [nothing] checked by ...`), no placeholder
#   (<...>, TODO, TBD, FIXME), and no [limitation] or [nothing] in part 5. The merge of such a
#   pull request (`gh pr merge`, the MCP tool merge_pull_request) is refused when its body, read
#   with `gh pr view` (the one process this hook starts, and only there), holds no filled section,
#   still an item [open with owner], or cannot be read within GUARD_GIT_GH_TIMEOUT seconds
#   (default 20).
# Asked: `git push` whose refspec reaches main (main, HEAD:main, x:main, refs/heads/main), a push
# from main without a refspec or of HEAD or @, --all, --branches, the matching refspec `:` and a
# wildcard over the branches (not as a dry run, which pushes nothing), `gh pr merge`, `gh api`
# calls that merge a pull request (.../pulls/<n>/merge, mergePullRequest) and the MCP tool
# merge_pull_request. A block anywhere in the command wins over the question.
# git and gh are found at command position only (lib/command-segments.sh): behind global options
# (`git -C dir`, `git -c k=v`, `--no-pager`), wrappers (env, sudo, timeout, xargs, bash -c, cmd /c,
# powershell -c, find -exec) and in compound commands. Text inside a quoted message or a
# here-document is scanned for attribution, never read as a command.
# A missing or broken lib/command-segments.sh blocks every shell call (exit 2) until it is
# restored, so a broken install shows instead of letting every command through unchecked.
#
# Not covered: a message git carries over by itself (`git commit --amend` without a new one keeps
# HEAD's, the SQUASH_MSG or MERGE_MSG a commit after `git merge --squash` or a conflict takes up,
# `git cherry-pick`, `git rebase`, a note copied with `git notes add -C/-c`), a commit taken from
# a repository chosen with GIT_DIR or --git-dir (it is looked up in the folder) or named by a
# command substitution (`-C "$(git rev-parse x)"`), a message from a command substitution
# ($(cat msg.txt)) or from a file the hook cannot find; a GraphQL query read from a file
# (`gh api graphql -F query=@q.graphql`, `--input q.json`) and a REBASE variable in JSON that is a
# quoted word or piped in (`echo '{...}' | gh api graphql --input -`); a plain `git push` from
# another branch whose upstream is main; for a commit on main, a repository chosen with GIT_DIR,
# --git-dir or --work-tree, `git checkout <file>` for a file that does not exist yet (read as a
# switch to a branch of that name), `git switch -` and `git checkout -` (the branch before is not
# known), `git branch -m` of the branch checked out, a switch inside a subshell (taken as if it
# lasted to the end of the line), a reftable repository (git 2.45+, whose HEAD file names no
# branch), and other default branches than main. The branch is rebuilt from the command text, so
# each form git knows and this list does not is a gap; git's own hooks would see the real ref, but
# core.hooksPath belongs to each repository, so a global one cannot sit beside them;
# abbreviated long options other than --no-veri/--no-verif (`--reuse` for
# --reuse-message among them); a commit made through the GitHub MCP tools; for the closing check,
# a merge through `gh api` (asked, its body not read), a pull request created in another tool,
# the owner's own `!` commands, which pass no hook, and a repository a `git clone` earlier on the
# same line makes (`git clone url x && cd x && gh pr create` is judged by the repository above
# x); aliases, scripts, variables. It is a
# guard against accidents, not against a determined attacker.
# Blocked although harmless: a commit message, pull request or issue text that quotes an
# attribution line (a text about this hook, say); `git add -A --dry-run`; a gh api call naming
# updatePullRequestBranch that passes another value starting with "rebase" (`-f b='Rebase ...'`);
# a plain `git pull` on main that could only fast-forward (pull.ff=only, or no commit of main's
# own): the hook does not read git's configuration, and the reason names `git pull --ff-only`;
# `git rebase --skip` and `git am --skip` on main, which go on committing there (`--abort` ends
# them); a `git switch` in a folder made by `mkdir` on the same line, whose commit is then judged
# by the repository above it; a filled closing check the hook cannot see: a `gh api` body read
# from a file (`--input pr.json`, `-F body=@pr.md`), a PowerShell body built with `n escapes
# (pass it with --body-file or a here-string), a section inside a command substitution, and
# `gh pr edit --body-file x && gh pr merge` on one line (the body is read before the line runs);
# a `- [x]` checklist right after part 8 without a `## ` heading between, read as part 8's items
# without a state.
# Rephrase, or ask the user.
# Tests: hooks/guard-git.test.sh

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=lib/command-segments.sh
source "$here/lib/command-segments.sh" || {
    echo "Blocked by the claude-setup git guard: its library $here/lib/command-segments.sh is missing or broken, so no shell command can be checked. Tell the user: restore the claude-setup hooks folder (git checkout in claude-setup, then install.ps1)." >&2
    exit 2
}

# The closing check section of a pull request body (the closing-check skill writes it): a line
# `## Closing check`, then the parts `1.` to `8.` in order, each with at least one item
# `- [<state>] <text>`, up to the next `## ` heading. Defined before the input is read, so the
# test-only entry point below can call them without a payload.
CC_STATES='done|open with owner|issue #[0-9]+|limitation|dropped|nothing'
# Placeholders: <what> and the like, lower-case words in angle brackets (not a link
# <https://...>, a type Vec<String> or `x < 5`), and the marker words
CC_PLACEHOLDER='(^|[^[:alnum:]])<[a-z][a-z ]*>|(^|[^[:alnum:]_])(TODO|TBD|FIXME)([^[:alnum:]_]|$)'

# CC_DEFECT: the first defect of the section in text $1, empty when it is filled; CC_OPEN: its
# first item `[open with owner]`, empty when none. One pass over the lines; CR line ends (a body
# written in PowerShell) are cut off. A numbered line is the next part only with the next part's
# number (any other is text: a numbered sub-step, a list after the section); an item may be
# indented under another; a second heading starts the section anew (a title that is the heading
# itself comes before the body). Part 5 (routine steps) takes no [limitation] or [nothing]: a step
# that was not run stays open with the owner until they drop it, which is how "live verification:
# not run" reached a merge.
closing_check_parse() {
    local line item part=0 items=0 found=0 state text
    CC_DEFECT= CC_OPEN=
    while IFS= read -r line; do
        line=${line%$'\r'}
        if [[ $line =~ ^'## Closing check'[[:space:]]*$ ]]; then
            found=1 part=0 items=0
            CC_DEFECT= CC_OPEN=
            continue
        fi
        ((found)) || continue
        [[ $line == '## '* ]] && break
        item=${line#"${line%%[![:space:]]*}"}
        if [[ $line =~ ^([1-8])\.[[:space:]] ]] && ((BASH_REMATCH[1] == part + 1)); then
            ((part && !items)) && CC_DEFECT=${CC_DEFECT:-"part $part has no item"}
            part=$((part + 1)) items=0
        elif [[ $line == '- '* || ($item == '- ['* && $item != "$line") ]]; then
            if ((!part)); then
                CC_DEFECT=${CC_DEFECT:-"item outside a part"}
                continue
            fi
            items=$((items + 1))
            if [[ $item =~ $CC_PLACEHOLDER ]]; then
                CC_DEFECT=${CC_DEFECT:-"placeholder in part $part"}
            elif [[ ! $item =~ ^-\ \[($CC_STATES)\]\ *(.*)$ ]]; then
                CC_DEFECT=${CC_DEFECT:-"item without a state in part $part"}
            else
                state=${BASH_REMATCH[1]} text=${BASH_REMATCH[2]}
                if ((part == 5)) && [[ $state == limitation || $state == nothing ]]; then
                    CC_DEFECT=${CC_DEFECT:-"[$state] in part 5: a routine step not run stays [open with owner] until the owner drops it"}
                elif [[ $state == nothing && $text != 'checked by '* ]]; then
                    CC_DEFECT=${CC_DEFECT:-"[nothing] without 'checked by' in part $part"}
                elif [[ $state == 'open with owner' || $state == 'issue #'* ]]; then
                    [[ $state == open* ]] && CC_OPEN=${CC_OPEN:-$line}
                    ((${#text} >= 3)) || CC_DEFECT=${CC_DEFECT:-"item too short in part $part"}
                else
                    ((${#text} >= 10)) || CC_DEFECT=${CC_DEFECT:-"item too short in part $part"}
                fi
            fi
        fi
    done <<< "$1"
    if ((!found)); then
        CC_DEFECT="no '## Closing check' heading"
    elif ((part < 8)); then
        CC_DEFECT=${CC_DEFECT:-"part $((part + 1)) missing"}
    elif ((!items)); then
        CC_DEFECT=${CC_DEFECT:-"part 8 has no item"}
    fi
}

# Status 0 when text $1 holds a filled section; else 1 with REPLY naming the first defect
closing_check_form() {
    closing_check_parse "$1"
    REPLY=$CC_DEFECT
    [[ -z $CC_DEFECT ]]
}

# Test-only entry point (guard-git.test.sh): on a text read from stdin, the first defect or ok
# (form), or the first item still open with the owner or none (open), as check_merge reads them
if [[ $GUARD_GIT_SELFTEST == form || $GUARD_GIT_SELFTEST == open ]]; then
    IFS= read -r -d '' cc_text
    closing_check_parse "$cc_text"
    if [[ $GUARD_GIT_SELFTEST == form ]]; then
        echo "${CC_DEFECT:-ok}"
    else
        echo "${CC_OPEN:-none}"
    fi
    exit 0
fi

read_input
field tool_name 4096
tool=$REPLY
case $tool in
    Bash) shell=bash ;;
    PowerShell) shell=powershell ;;
    mcp__*__create_pull_request | mcp__*__merge_pull_request) shell=mcp ;;
    *) exit 0 ;;
esac
if [[ $shell != mcp ]]; then
    field command
    command=$REPLY
    # Fast path: neither git nor gh named anywhere (no lower-case copy: on 60 KB each costs 50 ms)
    shopt -s nocasematch
    [[ $command =~ (^|[^[:alnum:]_.-])(git|gh)([^[:alnum:]_-]|$) ]] || exit 0
    shopt -u nocasematch
fi

field cwd 4096
resolve_path / "${REPLY:-$PWD}"
CS_CWD=$REPLY

block() {
    echo "Blocked by the claude-setup git guard: $1" >&2
    exit 2
}

# The first question wins; it is printed when nothing in the command was blocked. No quotes or
# backslashes in it, as it goes into JSON as it is.
ask_reason=
ask() {
    [[ -n $ask_reason ]] || ask_reason=$1
}

attribution_reason="the text carries an AI attribution. Commits, pull requests and issues carry only the user's name: remove the Co-Authored-By / Claude-Session / 'Generated with Claude Code' line and any Claude author or e-mail. If the text only quotes such a line, rephrase it."

# True when the text attributes the work to Claude or Anthropic
attributes_ai() {
    # Bytes, not characters: in a UTF-8 locale Git Bash lowercases a character outside the BMP
    # (the robot emoji) into something else, and the emoji form below never matched. Every
    # pattern is ASCII apart from the emoji, which is matched as its bytes.
    local LC_ALL=C
    local t=${1,,}
    t=${t//claude.md/}
    local by="(^|[^a-z])[a-z]+(-[a-z]+)*-by:[^$nl]*(claude|anthropic)"
    # "Generated with Claude" only in its attribution forms: a footer line of its own, after the
    # robot emoji, or with the link to Claude Code; in prose it is a sentence about something else
    local footer="(^|$nl)[[:space:]>*_#-]*generated (with|by) \\[?claude"
    local emoji="🤖[^$nl]*generated (with|by)"
    local link="generated (with|by) [^$nl]*claude\\.(com|ai)/(claude-)?code"
    [[ $t =~ $by || $t == *claude-session:* || $t =~ $footer || $t =~ $emoji || $t =~ $link || $t == *noreply@anthropic.com* ]]
}

# True when a name or e-mail address names Claude or Anthropic (a person called Claude as well;
# for a commit of theirs, --reset-author helps)
ai_identity() {
    [[ $1 =~ [Cc][Ll][Aa][Uu][Dd][Ee]|[Aa][Nn][Tt][Hh][Rr][Oo][Pp][Ii][Cc] ]]
}

# REPLY: the command's words, one per line so each starts a line as a footer would, then its
# here-documents and what is piped into it
segment_text() {
    local IFS=$nl
    REPLY="${words[*]}$nl${heredocs[*]}$nl$stdin"
}

# REPLY: the text plus the content of each existing file in $2..., resolved against directory $1
with_files() {
    local text=$REPLY dir=$1 f content
    shift
    for f in "$@"; do
        [[ -z $f || $f == - ]] && continue
        resolve_path "$dir" "$f"
        if [[ -f $REPLY ]]; then
            content=
            IFS= read -r -d '' content < "$REPLY"
            text+=$nl$content
        fi
    done
    REPLY=$text
}

# REPLY: what commits $3... in repository $1 hand on, in `git log` format $2 (%B the whole
# message, %s the subject line, %an <%ae> the author). A value git cannot resolve, or no git, adds
# nothing: git commit fails on that value too. --end-of-options keeps a value such as
# `--format=...` from being read as an option of git log. No prompt and no fetch: in a partial
# clone a commit that is not there yet would otherwise be fetched, perhaps behind a login dialog
# (GIT_NO_LAZY_FETCH needs git 2.44; older ones fetch, without asking).
commit_messages() {
    local dir=$1 format=$2 rev msg text=
    shift 2
    for rev in "$@"; do
        [[ -n $rev ]] || continue
        msg=$(GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never GIT_NO_LAZY_FETCH=1 git -C "$dir" --no-pager log -1 --no-show-signature --format="$format" --end-of-options "$rev" -- 2> /dev/null) && text+=$nl$msg
    done
    REPLY=$text
}

bulk_add() {
    block "\`git add $1\` stages everything, and a file nobody meant to commit rides along. Stage by path: \`git add path/one path/two\`; \`git status --short\` shows what changed."
}

force_push() {
    case $1 in
        --mirror | --delete* | :* | +:*)
            block "\`git push $1\` deletes main or overwrites every branch on the remote. That is the user's decision; ask them." ;;
        *)
            block "\`git push $1\` rewrites history on the remote, and a pushed branch is never rewritten. Push a new commit instead; to take main in, \`git fetch origin\`, \`git merge origin/main\` and a normal push." ;;
    esac
}

rebase_branch() {
    block "updating a pull request by rebase rewrites its pushed branch. Take main in by a merge instead: \`gh pr update-branch\` without --rebase, or \`git merge origin/main\` and a normal push."
}

# True when ref $1 names the branch main
is_main() {
    [[ $1 == main || $1 == refs/heads/main || $1 == heads/main ]]
}

# The branch each repository has checked out, by its root in norm_path's spelling: read from its
# HEAD file the first time it is needed, then what a `git switch` or `git checkout` earlier on the
# same line moved it to. @unborn for a main without a commit yet, empty for a detached HEAD or a
# branch that is not known.
declare -A BRANCH_OF=()
# The folders a `git init`, `git clone` or `git worktree add` earlier on the line makes a
# repository of, in norm_path's spelling: git reads their own HEAD, not the repository's above
declare -a MADE=()
# The root on_main looked at last, empty when it found none
ON_ROOT=

# REPLY: the root of the repository holding folder $1, in norm_path's spelling, so that `.`, a
# trailing /, C:/ or /c/ and the case of a letter name the same one. False when there is none and
# when a `git init`, `git clone` or `git worktree add` earlier on the line makes the folder or one
# above it a repository of its own. A folder that does not exist yet otherwise belongs to the
# repository above it (`mkdir x && cd x && git commit` commits there).
repo_of() {
    norm_path "$1"
    local d=$REPLY i
    for i in "${MADE[@]}"; do
        [[ $d == "$i" || $d == "$i"/* ]] && return 1
    done
    repo_root "$d"
}

# True when the repository holding folder $1 has main checked out, in any case of its letters
# (Windows keeps refs/heads/Main and main in one file). HEAD is read as a file, not through git,
# as every process costs the tool time: .git/HEAD, or for a linked worktree or a submodule the HEAD
# in the folder its .git file names (`gitdir: ...`, absolute or relative). A main without a commit
# yet (a fresh repository) counts as no main until a commit on the line makes it born: neither its
# ref, nor packed-refs, nor the ref log exists yet. Nothing more is read, as packed-refs can hold
# megabytes.
# shortcut: HEAD is read as a file, so a reftable repository (git 2.45+, whose HEAD file names no
# branch) is not judged; upgrade when one is used here.
on_main() {
    ON_ROOT=
    repo_of "$1" || return 1
    local r=$REPLY line head
    ON_ROOT=$r
    if [[ -z ${BRANCH_OF[$r]+x} ]]; then
        BRANCH_OF[$r]=
        head=$r/.git/HEAD
        if [[ ! -d $r/.git ]]; then
            # read fills line also when the file ends without a line break, only its status says so
            line=
            { IFS= read -r line; } 2>/dev/null < "$r/.git"
            line=${line%$'\r'}
            [[ $line == 'gitdir: '* ]] && resolve_path "$r" "${line#gitdir: }" && head=$REPLY/HEAD
        fi
        line=
        { IFS= read -r line; } 2>/dev/null < "$head"
        line=${line%$'\r'}
        [[ $line == 'ref: refs/heads/'* ]] && BRANCH_OF[$r]=${line#ref: refs/heads/}
        if [[ ${BRANCH_OF[$r],,} == main && -d $r/.git && ! -e $r/.git/refs/heads/main &&
            ! -e $r/.git/packed-refs && ! -e $r/.git/logs/HEAD ]]; then
            BRANCH_OF[$r]=@unborn
        fi
    fi
    [[ ${BRANCH_OF[$r],,} == main ]]
}

# A `git switch` or `git checkout` moves the branch for the commands after it on the line: with
# -c/-C/-b/-B/--orphan (or a value glued to one, -bname, or --create=, --force-create=, --orphan=)
# the new branch, else the first word that is no option; --detach leaves none, and so does `-`,
# whose branch is not known; HEAD and @ stay where they are. Paths switch nothing: anything after
# a `--`, a word of `git checkout` other than main that exists as a file or folder
# (`git checkout .`), and a second word of `git checkout` without a new branch
# (`git checkout HEAD a.py` takes a file from a commit). Nothing is recorded for a folder that
# does not exist yet.
track_branch() {
    local a b= named=0 create=0 detach=0
    for a in "${args[@]}"; do
        case $a in
            --) return 0 ;;
            -c | -C | -b | -B | --orphan | --create | --force-create) create=1 ;;
            --create=* | --force-create=* | --orphan=*) b=${a#*=}; named=1; create=1 ;;
            --detach | -d) detach=1 ;;
            -[bBcC]?*) ((named)) || { b=${a:2}; named=1; create=1; } ;;
            -*) ;;
            *)
                if ((named)); then
                    # the start point after a new branch, or a path
                    ((create)) || [[ ${words[GIT_VERB]} == switch ]] || return 0
                else
                    if ((!create)) && [[ ${words[GIT_VERB]} == checkout && ${a,,} != main ]]; then
                        resolve_path "$GIT_DIR_AT" "$a"
                        [[ -e $REPLY ]] && return 0
                    fi
                    b=$a
                    named=1
                fi ;;
        esac
    done
    ((named || detach)) || return 0
    ((!create)) && [[ $b == HEAD || $b == @ ]] && return 0
    [[ $detach == 1 || $b == - ]] && b=
    set_branch "$b"
}

# Records branch $1 as checked out where GIT_DIR_AT is, for the commands after it on the line;
# nothing for a folder that does not exist yet
set_branch() {
    norm_path "$GIT_DIR_AT"
    [[ -d $REPLY ]] && repo_of "$REPLY" && BRANCH_OF[$REPLY]=$1
    return 0
}

# The folder a `git init`, `git clone` or `git worktree add` makes a repository of: the first word
# that is no option, after the URL for clone, its last part without .git when no folder is named.
# The value options of each are skipped. A folder that holds a repository already is not recorded:
# git init only reinitialises it; -h and --help make nothing.
track_made() {
    local a i v=${words[GIT_VERB]} d=$GIT_DIR_AT url=
    local -a pos=()
    for ((i = 0; i < ${#args[@]}; i++)); do
        a=${args[i]}
        case $v:$a in
            *:--) ;;
            *:-h | *:--help) return 0 ;;
            init:-b | init:--initial-branch | init:--object-format | init:--ref-format | \
                init:--template | init:--separate-git-dir) ((i++)) ;;
            clone:-b | clone:--branch | clone:-o | clone:--origin | clone:-c | clone:--config | \
                clone:--depth | clone:--reference | clone:--reference-if-able | clone:-u | \
                clone:--upload-pack | clone:-j | clone:--jobs | clone:--template | \
                clone:--separate-git-dir | clone:--shallow-since | clone:--shallow-exclude | \
                clone:--filter | clone:--server-option | clone:--bundle-uri | clone:--ref-format) ((i++)) ;;
            worktree:-b | worktree:-B | worktree:--reason) ((i++)) ;;
            *:-*) ;;
            *) pos+=("$a") ;;
        esac
    done
    case $v in
        init) [[ -n ${pos[0]} ]] && { resolve_path "$GIT_DIR_AT" "${pos[0]}"; d=$REPLY; } ;;
        clone)
            url=${pos[0]%/}
            url=${url##*[/:]}
            url=${url%.git}
            [[ -n ${pos[1]} ]] && url=${pos[1]}
            [[ -n $url ]] || return 0
            resolve_path "$GIT_DIR_AT" "$url"
            d=$REPLY ;;
        worktree)
            # git worktree add <path>: the first word is the subcommand
            [[ ${pos[0]} == add && -n ${pos[1]} ]] || return 0
            resolve_path "$GIT_DIR_AT" "${pos[1]}"
            d=$REPLY ;;
    esac
    norm_path "$d"
    [[ $v != init || ! -e $REPLY/.git ]] && MADE+=("$REPLY")
    return 0
}

# A commit on main: the verbs that make one or rewrite main (rebase), unless a word of their own,
# before a `--`, says they make none: --abort, --quit, -h, --help, --ff-only and
# --show-current-patch for all of them (only merge and pull know --ff-only; the others refuse it
# and commit nothing), --squash and --no-commit for merge and pull, --dry-run for pull and commit
# (and --porcelain, --short and --long, which imply it), -n and --no-commit for cherry-pick and
# revert, --edit-todo for rebase. A rebase given a branch (`git rebase <upstream> <branch>`)
# switches to it first and rewrites that one, so it is judged by the branch's name, which is
# checked out afterwards. A commit that main allows while it is unborn makes it born for the
# commands after it on the line.
# shortcut: option values are not skipped, so a message that is exactly one of these words
# (`-m --abort`) passes, and short flags bundled with -n (`-nx`) are blocked; a plain `git pull`
# on main is blocked even where it could only fast-forward, as git's configuration is not read.
# Upgrade if one of them shows up in practice.
check_commit() {
    local a i v=${words[GIT_VERB]}
    local -a pos=()
    for a in "${args[@]}"; do
        case $v:$a in
            *:--) break ;;
            *:--abort | *:--quit | *:-h | *:--help | *:--ff-only) return 0 ;;
            *:--show-current-patch | *:--show-current-patch=* | rebase:--edit-todo) return 0 ;;
            merge:--squash | merge:--no-commit | pull:--squash | pull:--no-commit) return 0 ;;
            cherry-pick:-n | cherry-pick:--no-commit | revert:-n | revert:--no-commit) return 0 ;;
            commit:--dry-run | commit:--porcelain | commit:--short | commit:--long) return 0 ;;
            pull:--dry-run) return 0 ;;
        esac
    done
    if [[ $v == rebase ]]; then
        for ((i = 0; i < ${#args[@]}; i++)); do
            a=${args[i]}
            case $a in
                --) break ;;
                --onto | -s | --strategy | -X | --strategy-option | -x | --exec | --empty | -C) ((i++)) ;;
                -*) ;;
                *) pos+=("$a") ;;
            esac
        done
        if [[ -n ${pos[1]} ]]; then
            local b=${pos[1],,}
            is_main "$b" && commit_refused rebase
            set_branch "${pos[1]}"
            return 0
        fi
    fi
    on_main "$GIT_DIR_AT" && commit_refused "$v"
    [[ -n $ON_ROOT && ${BRANCH_OF[$ON_ROOT]} == @unborn ]] && BRANCH_OF[$ON_ROOT]=main
    return 0
}

commit_refused() {
    block "\`git $1\` would make a commit on main, and main moves only through a pull request or a fast-forward. Create a branch first (\`git switch -c <name>\`) and commit there. To bring main up to date: \`git merge --ff-only origin/main\` or \`git pull --ff-only\`."
}

# The closing check is on once the closing-check skill is installed: people who never installed
# it are not asked for a section they cannot fill
closing_check_on() {
    [[ -f ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/closing-check/SKILL.md ]]
}

# REPLY: the user gh is logged in as on github.com, from the hosts.yml gh itself reads (read as a
# file, no process): in the folder of the first that is set of $GH_CONFIG_DIR, $XDG_CONFIG_HOME/gh
# and %APPDATA%/GitHub CLI, else ~/.config/gh, as gh's ConfigDir picks it. False when it names
# none. `user:` counts at the first indent under `github.com:` only, not a key of the same name
# deeper in its `users:` map.
gh_login() {
    local f line indent key value
    if [[ -n $GH_CONFIG_DIR ]]; then f=$GH_CONFIG_DIR
    elif [[ -n $XDG_CONFIG_HOME ]]; then f=$XDG_CONFIG_HOME/gh
    elif [[ -n $APPDATA ]]; then f="$APPDATA/GitHub CLI"
    else f=$HOME/.config/gh
    fi
    REPLY=
    for f in "$f/hosts.yml"; do
        [[ -f $f ]] || continue
        local in=0
        indent=
        while IFS= read -r line; do
            line=${line%$'\r'}
            if [[ $line == github.com:* ]]; then
                in=1
                continue
            fi
            ((in)) || continue
            [[ $line =~ ^[^[:space:]] ]] && break
            [[ $line =~ ^([[:space:]]+)([^[:space:]:]+):[[:space:]]*([^[:space:]#]*) ]] || continue
            [[ -n $indent ]] || indent=${BASH_REMATCH[1]}
            key=${BASH_REMATCH[2]} value=${BASH_REMATCH[3]}
            if [[ ${BASH_REMATCH[1]} == "$indent" && $key == user ]]; then
                value=${value//\"/}
                REPLY=${value//\'/}
                break
            fi
        done < "$f"
        [[ -n $REPLY ]]
        return
    done
    return 1
}

# REPLY: the owner of the GitHub repository a pull request from folder $1 goes to, from the url of
# a remote (https://github.com/<owner>/... or git@github.com:<owner>/...) in its git config, read as
# a file: .git/config, or for a linked worktree the config in the folder its gitdir's commondir
# names. The remote is the one gh resolved as base (`gh-resolved = base`), else `upstream` (a fork's
# parent, where gh opens the pull request), else `origin`. False when there is no repository, no
# such remote or no GitHub url.
# shortcut: gh's own choice among other remote names (github, more than one fork) is not modelled;
# upgrade when a repository here has such remotes.
repo_owner_of() {
    local r g line name= key resolved= upstream= origin= url
    REPLY=
    norm_path "$1"
    repo_root "$REPLY" || return 1
    r=$REPLY g=$REPLY/.git
    if [[ ! -d $g ]]; then
        line=
        { IFS= read -r line; } 2>/dev/null < "$g"
        line=${line%$'\r'}
        [[ $line == 'gitdir: '* ]] || return 1
        resolve_path "$r" "${line#gitdir: }"
        g=$REPLY
        line=
        { IFS= read -r line; } 2>/dev/null < "$g/commondir"
        line=${line%$'\r'}
        if [[ -n $line ]]; then
            resolve_path "$g" "$line"
            g=$REPLY
        fi
    fi
    declare -A urls=()
    while IFS= read -r line; do
        line=${line%$'\r'}
        if [[ $line =~ ^[[:space:]]*\[ ]]; then
            name=
            [[ $line =~ ^[[:space:]]*\[remote[[:space:]]+\"([^\"]+)\"\] ]] && name=${BASH_REMATCH[1]}
        elif [[ -n $name && $line =~ ^[[:space:]]*([[:alnum:]-]+)[[:space:]]*=[[:space:]]*([^[:space:]]+) ]]; then
            key=${BASH_REMATCH[1],,}
            [[ $key == url && -z ${urls[$name]} ]] && urls[$name]=${BASH_REMATCH[2]}
            [[ $key == gh-resolved && ${BASH_REMATCH[2]} == base ]] && resolved=$name
        fi
    done 2>/dev/null < "$g/config"
    if [[ -n $resolved ]]; then url=${urls[$resolved]}; else url=${urls[upstream]:-${urls[origin]}}; fi
    [[ $url =~ github\.com[:/]+([^/]+)/ ]] || return 1
    REPLY=${BASH_REMATCH[1]}
}

CC_SKELETON="## Closing check
1. Questions to the owner
2. Findings
3. Promises (later, follow-up, I will)
4. Issue and definition of done
5. Routine steps
6. Changed after the last proof
7. Leftovers
8. Other sessions"

closing_check_refused() {
    block "this pull request needs a filled closing check in its body: $1. Run the closing-check skill first and put its list into the body (best with --body-file) as this section, every part with at least one item \`- [<state>] <text>\` (done, open with owner, issue #<n>, limitation, dropped) or \`- [nothing] checked by <what>\`:$nl$nl$CC_SKELETON"
}

# Refuses a pull request in one of the user's own repositories whose text $2 holds no filled
# section, once the skill is installed and gh names the user. $1 is the repository's owner, empty
# for the one the command runs in, @own for a call that names none (GraphQL).
closing_check_gate() {
    closing_check_on || return 0
    gh_login || return 0
    local login=$REPLY owner=$1
    if [[ -z $owner ]]; then
        repo_owner_of "$CS_CWD" || return 0
        owner=$REPLY
    fi
    [[ $owner == @own || ${owner,,} == "${login,,}" ]] || return 0
    closing_check_form "$2" || closing_check_refused "$REPLY"
}

# Refuses the merge of a pull request in one of the user's own repositories whose body holds no
# filled section or still an item open with the owner, once the skill is installed and gh names
# the user. $1 is the repository's owner and $2 the repository for -R, both empty for the one the
# command runs in; $3 the pull request (number, URL or branch; empty: the folder's branch). A URL
# names its owner itself. The body is read with `gh pr view`, the one process this hook starts and
# the one call that reaches the network (6.5 s measured), and only here, within
# GUARD_GIT_GH_TIMEOUT seconds (default 20, inside the hook's 30): a body that cannot be read in
# time refuses the merge, as a hook killed by its timeout would let it run without the question.
check_merge() {
    closing_check_on || return 0
    gh_login || return 0
    local login=$REPLY owner=$1 out status limit=${GUARD_GIT_GH_TIMEOUT:-20}
    local -a args=(pr view)
    [[ -n $3 ]] && args+=("$3")
    [[ -n $2 ]] && args+=(-R "$2")
    args+=(--json body --jq .body)
    [[ $3 =~ ^(https?://)?(www\.)?github\.com/([^/]+)/[^/]+/pull/[0-9]+ ]] && owner=${BASH_REMATCH[3]}
    if [[ -z $owner ]]; then
        repo_owner_of "$CS_CWD" || return 0
        owner=$REPLY
    fi
    [[ ${owner,,} == "${login,,}" ]] || return 0
    out=$(cd "$CS_CWD" 2> /dev/null; GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 timeout "$limit" gh "${args[@]}" 2>&1)
    status=$?
    ((status == 124)) && block "the pull request's body could not be read: gh did not answer within $limit s. A merge in the user's own repositories needs the filled closing check in its body; when gh cannot reach it, the user merges themselves."
    ((status == 0)) || block "the pull request's body could not be read: ${out%%$nl*}. A merge in the user's own repositories needs the filled closing check in its body; when gh cannot reach it, the user merges themselves."
    closing_check_parse "$out"
    [[ -z $CC_DEFECT ]] || block "the pull request's body holds no filled closing check: $CC_DEFECT. Run the closing-check skill, put its list into the body (\`gh pr edit <n> --body-file <file>\`) as this section, then merge in a command of its own (the hook reads the body before the line runs):$nl$nl$CC_SKELETON"
    [[ -z $CC_OPEN ]] || block "the pull request's closing check is still open with owner: $CC_OPEN. The owner decides that item first; then its state in the body changes and the merge can follow."
    return 0
}

# REPLY: the pull request a `gh pr merge` names: the first word after merge that is no option and
# no option's value, empty for the folder's branch
merge_ref() {
    local i a pos=0
    REPLY=
    for ((i = at + 1; i < n; i++)); do
        a=${words[i]}
        case $a in
            --) ;;
            -R | --repo | -b | --body | -F | --body-file | -t | --subject | -A | --author-email | --match-head-commit) ((i++)) ;;
            -*) ;;
            *) if ((++pos == 3)); then REPLY=$a; return; fi ;;
        esac
    done
}

# REPLY: the owner in a -R/--repo value ([HOST/]OWNER/REPO or a URL)
repo_flag_owner() {
    local v=${1%/}
    v=${v%.git}
    v=${v%/*}
    REPLY=${v##*/}
}

check_push() {
    local i k c a r dst del=0 force= all= tags=0 dry=0
    local -a pos=()
    for ((i = 0; i < ${#args[@]}; i++)); do
        a=${args[i]}
        case $a in
            --mirror) force_push "$a" ;;
            --force | --force-with-lease | --force-with-lease=*) force=${force:-$a} ;;
            --delete) del=1 ;;
            --all | --branches) all=$a ;;
            --tags) tags=1 ;;
            --dry-run) dry=1 ;;
            --repo | --receive-pack | --exec | --push-option) ((i++)) ;;
            --*) ;;
            -?*)
                for ((k = 1; k < ${#a}; k++)); do
                    c=${a:k:1}
                    case $c in
                        f) force=${force:-$a} ;;
                        d) del=1 ;;
                        n) dry=1 ;;
                        o) ((k == ${#a} - 1)) && ((i++)); break ;;
                    esac
                done ;;
            *) pos+=("$a") ;;
        esac
    done
    # The first word is the remote, the others are refspecs. Deleting main is answered before a
    # forced push, with or without -f or a +. A dry run (--dry-run, -n) pushes nothing, so it is
    # not asked; it is still blocked like the push it tries
    for a in "${pos[@]:1}"; do
        [[ $a == +* ]] && force=${force:-$a}
        r=${a#+}
        if ((del)); then
            is_main "$r" && force_push "--delete $a"
            continue
        fi
        dst=${r##*:}
        [[ $r == :* ]] && is_main "$dst" && force_push "$a"
        ((dry)) && continue
        [[ $r != :* ]] && is_main "$dst" && ask "A push to main changes the shared default branch. The user confirms it."
        [[ $r == HEAD || $r == @ ]] && on_main "$GIT_DIR_AT" && ask "A push of HEAD from main goes to main, the shared default branch. The user confirms it."
        # the matching refspec, and a wildcard over all branches, push main as well (not one over a
        # folder of them, refs/heads/feat/*); the reason names no refspec, as it goes into JSON
        if [[ $r == : || $dst == '*' || $dst == 'heads/*' || $dst == 'refs/heads/*' ]]; then
            ask "This push sends every matching branch, main included. The user confirms it."
        fi
    done
    [[ -n $force ]] && force_push "$force"
    ((dry)) && return 0
    [[ -n $all ]] && ask "git push $all pushes every branch, main included. The user confirms it."
    # Without a refspec git pushes the branch checked out, which on main is main
    if ((!tags && !del && ${#pos[@]} <= 1)) && on_main "$GIT_DIR_AT"; then
        ask "A push from main without a refspec goes to main, the shared default branch. The user confirms it."
    fi
    return 0
}

check_git() {
    local i n=${#words[@]} a s key mode wr
    local -a args=() pos=()
    # Every part of this runs once per git command; a long script can hold thousands, and every
    # bash operation costs in Git Bash, so loops that have nothing to do are not entered
    if ((at)); then
        for ((i = 0; i < at; i++)); do
            if [[ ${words[i],,} =~ ^git_config_(key_[0-9]+=core\.hookspath|parameters=.*core\.hookspath) ]]; then
                block "setting core.hooksPath through the environment switches the repository's git hooks off. Only the user changes it; ask them."
            fi
        done
    fi
    if [[ ${words[at+1]} == -* ]]; then
        git_split
    else
        GIT_DIR_AT=$CS_CWD
        GIT_SETTINGS=()
        GIT_VERB=$((at + 1))
    fi
    if ((${#GIT_SETTINGS[@]})); then
        for s in "${GIT_SETTINGS[@]}"; do
            [[ ${s,,} == core.hookspath* ]] && block "\`git -c core.hooksPath=...\` switches the repository's git hooks off. A failing hook is fixed or reported to the user, never skipped."
        done
    fi
    ((GIT_VERB < n)) || return 0
    args=("${words[@]:GIT_VERB+1}")
    if [[ " ${args[*]} " == *' --no-veri'* ]]; then
        for a in "${args[@]}"; do
            [[ $a == -- ]] && break
            [[ $a == --no-veri || $a == --no-verif || $a == --no-verify ]] && block "\`--no-verify\` skips the repository's git hooks (secret scan, tests, checks). A failing hook is fixed or reported to the user, never skipped."
        done
    fi
    case ${words[GIT_VERB]} in
        commit | cherry-pick | revert | am | merge | pull | rebase) check_commit ;;
        switch | checkout) track_branch ;;
        init | clone | worktree) track_made ;;
    esac
    case ${words[GIT_VERB]} in
        add)
            local after=0 p specs=0 positive=0
            if [[ $GIT_DIR_AT != "$root_of" ]]; then
                root_of=$GIT_DIR_AT
                root=
                root_base=$'\x01'
                if repo_root "$GIT_DIR_AT"; then
                    root=$REPLY
                    root_base=${root##*/}
                    root_base=${root_base,,}
                fi
            fi
            for a in "${args[@]}"; do
                if ((!after)); then
                    case $a in
                        --) after=1; continue ;;
                        -A | --all | -u | --update | --no-ignore-removal) bulk_add "$a" ;;
                        --*) continue ;;
                        -*) [[ ${a:1} == *[Au]* ]] && bulk_add "$a"; continue ;;
                    esac
                fi
                ((specs++))
                p=${a%[/\\]}
                case $p in
                    . | : | :/ | '*' | ':(top)' | ':/*' | './*') bulk_add "$a" ;;
                    ':!'* | ':^'* | ':('*exclude*')'*) continue ;;
                esac
                positive=1
                # The root folder of the repository; the name first, the file system only for a
                # name that could be it
                case ${p,,} in
                    *.. | *"$root_base")
                        resolve_path "$GIT_DIR_AT" "$a"
                        [[ -n $root && $REPLY -ef $root ]] && bulk_add "$a" ;;
                esac
            done
            ((specs && !positive)) && bulk_add "${args[*]}" ;;
        commit)
            commit_parse $((GIT_VERB + 1))
            ((COMMIT_ALL)) && block "\`git commit -a\` commits every changed tracked file. Stage by path (\`git add path/one\`) and commit without -a."
            ((COMMIT_NOVERIFY)) && block "\`git commit -n\` / \`--no-verify\` skips the repository's git hooks. A failing hook is fixed or reported to the user, never skipped."
            segment_text
            with_files "$GIT_DIR_AT" "${COMMIT_FILES[@]}"
            attributes_ai "$REPLY" && block "$attribution_reason"
            # The author: --author, and what -C and its kin take over, or --amend from HEAD,
            # unless --reset-author
            local -a from=("${COMMIT_REUSED[@]}")
            ((COMMIT_AMEND && ${#from[@]} == 0)) && from=(HEAD)
            REPLY=
            ((COMMIT_RESET_AUTHOR || ${#from[@]} == 0)) || commit_messages "$GIT_DIR_AT" '%an <%ae>' "${from[@]}"
            ai_identity "${COMMIT_AUTHORS[*]}$nl$REPLY" && block "the commit would carry a Claude or Anthropic author (from --author, from the commit -C, -c, --reuse-message or --reedit-message takes over, or from HEAD on --amend). Commits carry only the user's name: add --reset-author, or leave the author out."
            if ((${#COMMIT_REUSED[@]} + ${#COMMIT_MESSAGES[@]} + ${#COMMIT_SUBJECTS[@]})); then
                commit_messages "$GIT_DIR_AT" %B "${COMMIT_REUSED[@]}" "${COMMIT_MESSAGES[@]}"
                s=$REPLY
                commit_messages "$GIT_DIR_AT" %s "${COMMIT_SUBJECTS[@]}"
                attributes_ai "$s$nl$REPLY" && block "the message taken from an existing commit (-C, -c, --reuse-message, --reedit-message, --fixup, --squash) carries an AI attribution. Commits carry only the user's name: write the message yourself with -m or -F, without the Co-Authored-By / Claude-Session / 'Generated with Claude Code' line."
            fi ;;
        merge | tag | notes)
            # They write a message too: -m and --message among the words, the file of -F/--file
            local -a files=()
            local k valued
            # the short flags of each verb that take a value (-s signs a tag, but names a merge
            # strategy)
            case ${words[GIT_VERB]} in
                merge) valued=msX ;;
                tag) valued=mun ;;
                notes) valued=mcC ;;
            esac
            for ((i = 0; i < ${#args[@]}; i++)); do
                a=${args[i]}
                case $a in
                    --) break ;;
                    --file=*) files+=("${a#*=}") ;;
                    --file | -F) files+=("${args[i+1]}"); ((i++)) ;;
                    --*) ;;
                    -?*)
                        # a group of short flags: -F takes the rest of the word or the next one
                        # (`-aF msg.txt`); a flag before it that takes a value ends the group
                        for ((k = 1; k < ${#a}; k++)); do
                            case ${a:k:1} in
                                F)
                                    if ((k == ${#a} - 1)); then
                                        files+=("${args[i+1]}"); ((i++))
                                    else
                                        files+=("${a:k+1}")
                                    fi
                                    break ;;
                                *) [[ $valued == *"${a:k:1}"* ]] && break ;;
                            esac
                        done ;;
                esac
            done
            segment_text
            with_files "$GIT_DIR_AT" "${files[@]}"
            attributes_ai "$REPLY" && block "$attribution_reason" ;;
        push) check_push ;;
        config)
            mode=
            wr=0
            for ((i = 0; i < ${#args[@]}; i++)); do
                a=${args[i],,}
                case $a in
                    --unset | --unset-all | --replace-all | --add | --remove-section | --rename-section) wr=1 ;;
                    --get | --get-all | --get-regexp | --get-urlmatch | --list | -l) mode=read ;;
                    --file | -f | --blob | --type | --default | --comment | --value) ((i++)) ;;
                    -*) ;;
                    *) pos+=("${args[i]}") ;;
                esac
            done
            case ${pos[0],,} in
                set | unset | rename-section | remove-section) wr=1; pos=("${pos[@]:1}") ;;
                get | list) mode=read; pos=("${pos[@]:1}") ;;
            esac
            key=${pos[0],,}
            if [[ $key == core.hookspath || ($key == core && $wr == 1) ]]; then
                if ((wr)) || [[ $mode != read && ${#pos[@]} -ge 2 ]]; then
                    block "\`git config core.hooksPath\` switches the repository's git hooks off or replaces them. Only the user changes it; ask them."
                fi
            fi
            if [[ ($key == user.name || $key == user.email) && ${#pos[@]} -ge 2 ]] && ai_identity "${pos[*]:1}"; then
                block "commits carry only the user's name; never set a Claude or Anthropic identity."
            fi ;;
    esac
}

check_gh() {
    local i n=${#words[@]} a area="" verb="" repo="" owner=""
    local -a files=()
    for ((i = at + 1; i < n; i++)); do
        a=${words[i]}
        case $a in
            -R | --repo) repo=${words[i+1]}; ((i++)) ;;
            --repo=*) repo=${a#*=} ;;
            -R?*) repo=${a:2} ;;
            -F | --body-file | --notes-file) files+=("${words[i+1]}"); ((i++)) ;;
            --body-file=* | --notes-file=*) files+=("${a#*=}") ;;
            -F?*) files+=("${a:2}") ;;
            -*) ;;
            *) if [[ -z $area ]]; then area=$a; elif [[ -z $verb ]]; then verb=$a; fi ;;
        esac
    done
    case $area in
        pr | issue | release)
            segment_text
            with_files "$CS_CWD" "${files[@]}"
            attributes_ai "$REPLY" && block "$attribution_reason"
            if [[ $area == pr && $verb == create ]]; then
                # A body glued to its option (--body="...", -b"...") starts its own line here
                local text=$REPLY
                for ((i = at + 1; i < n; i++)); do
                    a=${words[i]}
                    case $a in
                        --body=*) text+=$nl${a#--body=} ;;
                        -b?*) text+=$nl${a:2} ;;
                    esac
                done
                [[ -n $repo ]] && { repo_flag_owner "$repo"; owner=$REPLY; }
                closing_check_gate "$owner" "$text"
            fi
            if [[ $area == pr && $verb == merge ]]; then
                [[ -n $repo ]] && { repo_flag_owner "$repo"; owner=$REPLY; }
                merge_ref
                check_merge "$owner" "$repo" "$REPLY"
                ask "Merging a pull request is the user's decision: gh pr merge."
            fi
            if [[ $area == pr && $verb == update-branch ]]; then
                for ((i = at + 1; i < n; i++)); do
                    a=${words[i],,}
                    [[ $a == -- ]] && break
                    # a boolean flag: --rebase=false and its spellings leave the merge
                    [[ $a == --rebase || ($a == --rebase=* && ! $a =~ ^--rebase=(false|f|0)$) ]] && rebase_branch
                done
            fi ;;
        api)
            # The query may come from a word, a here-document (-f query="$(cat <<'EOF' ...)") or
            # stdin (--input -), and REBASE from the query, a variable (-F m=REBASE, a default
            # `$m: ... = REBASE`) or the JSON of a here-document
            segment_text
            local t=${REPLY,,}
            local method='(updatemethod[[:space:]]*:[[:space:]]*|=[[:space:]]*|"[[:space:]]*:[[:space:]]*")rebase([^[:alnum:]_]|$)'
            [[ $t == *updatepullrequestbranch* && $t =~ $method ]] && rebase_branch
            if [[ $t =~ pulls/[0-9]+/merge || $t == *mergepullrequest* ]]; then
                ask "Merging a pull request is the user's decision: gh api ... merge."
            fi
            api_creates_pr && closing_check_gate "$owner" "$REPLY" ;;
    esac
}

# True when this `gh api` call creates a pull request; owner (check_gh's) then holds the
# repository's owner, empty for the folder's own repository, @own for GraphQL, and REPLY the
# call's text, with each field's value on its own (`-f body=...` without `body=`). REST: POST to repos/<owner>/<repo>/pulls, also implied by a field (gh posts as soon
# as one is given, unless -X says otherwise); `{owner}` is filled in by gh from the folder's
# repository. GraphQL: a text naming createPullRequest.
api_creates_pr() {
    local i a endpoint= method= fields=0 text pos=0 values=
    for ((i = at + 1; i < n; i++)); do
        a=${words[i]}
        case $a in
            -f | -F | --field | --raw-field) fields=1; values+=$nl${words[i+1]#*=}; ((i++)) ;;
            -f?* | -F?*) fields=1; a=${a:2}; values+=$nl${a#*=} ;;
            --field=* | --raw-field=*) fields=1; a=${a#*=}; values+=$nl${a#*=} ;;
            -X | --method) method=${words[i+1]^^}; ((i++)) ;;
            -X?*) method=${a:2}; method=${method^^} ;;
            --method=*) method=${a#*=}; method=${method^^} ;;
            --input) fields=1; ((i++)) ;;
            --input=*) fields=1 ;;
            -H | --header | -q | --jq | -t | --template | --hostname | -p | --preview | --cache) ((i++)) ;;
            -*) ;;
            *) ((++pos == 2)) && endpoint=$a ;;
        esac
    done
    segment_text
    text=$REPLY$values
    if [[ $endpoint =~ ^/?repos/([^/]+)/[^/]+/pulls/?$ ]]; then
        owner=${BASH_REMATCH[1]}
        [[ $owner == '{owner}' || $owner == :owner ]] && owner=
        [[ $method == POST || (-z $method && $fields == 1) ]] || return 1
    elif [[ $endpoint == graphql && ${text,,} == *createpullrequest* ]]; then
        owner=@own
    else
        return 1
    fi
    REPLY=$text
}

# The repository root of the folder a git add ran in last, kept for the next one
root_of=$'\x01'
root=
root_base=
# The GitHub MCP tools (any server's create_pull_request and merge_pull_request): their input
# names the owner, and the body or the pull request's number
check_mcp() {
    field owner
    local owner=$REPLY
    [[ -n $owner ]] || return 0
    case $tool in
        *__create_pull_request)
            field body
            closing_check_gate "$owner" "$REPLY" ;;
        *__merge_pull_request)
            # pullNumber is a JSON number, which field (strings only) does not read
            local number=
            [[ $input =~ \"pullNumber\"[[:space:]]*:[[:space:]]*\"?([0-9]+) ]] && number=${BASH_REMATCH[1]}
            field repo
            check_merge "$owner" "$owner/$REPLY" "$number"
            ask "Merging a pull request is the user's decision: ${tool##*__}." ;;
    esac
}

CS_PROGRAMS[git]=check_git
CS_PROGRAMS[gh]=check_gh
if [[ $shell == mcp ]]; then
    check_mcp
else
    split_command "$command" "$shell" ""
fi
if [[ -n $ask_reason ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}' "$ask_reason"
fi
exit 0
