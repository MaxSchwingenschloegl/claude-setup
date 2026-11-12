#!/usr/bin/env bash
# PreToolUse hook (Bash, PowerShell): blocks git and gh commands of a shape the git rules forbid,
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
# Asked: `git push` whose refspec reaches main (main, HEAD:main, x:main, refs/heads/main),
# `gh pr merge`, and `gh api` calls that merge a pull request (.../pulls/<n>/merge,
# mergePullRequest). A block anywhere in the command wins over the question.
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
# quoted word or piped in (`echo '{...}' | gh api graphql --input -`); a plain `git push` whose
# upstream is main; abbreviated long options other than --no-veri/--no-verif (`--reuse` for
# --reuse-message among them); a commit made through the GitHub MCP tools; aliases, scripts,
# variables. It is a guard against accidents, not against a determined attacker.
# Blocked although harmless: a commit message, pull request or issue text that quotes an
# attribution line (a text about this hook, say); `git add -A --dry-run`; a gh api call naming
# updatePullRequestBranch that passes another value starting with "rebase" (`-f b='Rebase ...'`).
# Rephrase, or ask the user.
# Tests: hooks/guard-git.test.sh

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=lib/command-segments.sh
source "$here/lib/command-segments.sh" || {
    echo "Blocked by the claude-setup git guard: its library $here/lib/command-segments.sh is missing or broken, so no shell command can be checked. Tell the user: restore the claude-setup hooks folder (git checkout in claude-setup, then install.ps1)." >&2
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
# Fast path: neither git nor gh named anywhere (no lower-case copy: on 60 KB each costs 50 ms)
shopt -s nocasematch
[[ $command =~ (^|[^[:alnum:]_.-])(git|gh)([^[:alnum:]_-]|$) ]] || exit 0
shopt -u nocasematch

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

check_push() {
    local i k c a r dst del=0 force=
    local -a pos=()
    for ((i = 0; i < ${#args[@]}; i++)); do
        a=${args[i]}
        case $a in
            --mirror) force_push "$a" ;;
            --force | --force-with-lease | --force-with-lease=*) force=${force:-$a} ;;
            --delete) del=1 ;;
            --repo | --receive-pack | --exec | --push-option) ((i++)) ;;
            --*) ;;
            -?*)
                for ((k = 1; k < ${#a}; k++)); do
                    c=${a:k:1}
                    case $c in
                        f) force=${force:-$a} ;;
                        d) del=1 ;;
                        o) ((k == ${#a} - 1)) && ((i++)); break ;;
                    esac
                done ;;
            *) pos+=("$a") ;;
        esac
    done
    # The first word is the remote, the others are refspecs. Deleting main is answered before a
    # forced push, with or without -f or a +
    for a in "${pos[@]:1}"; do
        [[ $a == +* ]] && force=${force:-$a}
        r=${a#+}
        if ((del)); then
            is_main "$r" && force_push "--delete $a"
            continue
        fi
        dst=${r##*:}
        [[ $r == :* ]] && is_main "$dst" && force_push "$a"
        [[ $r != :* ]] && is_main "$dst" && ask "A push to main changes the shared default branch. The user confirms it."
    done
    [[ -n $force ]] && force_push "$force"
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
    local i n=${#words[@]} a area="" verb=""
    local -a files=()
    for ((i = at + 1; i < n; i++)); do
        a=${words[i]}
        case $a in
            -R | --repo) ((i++)) ;;
            -F | --body-file | --notes-file) files+=("${words[i+1]}"); ((i++)) ;;
            --body-file=* | --notes-file=*) files+=("${a#*=}") ;;
            -*) ;;
            *) if [[ -z $area ]]; then area=$a; elif [[ -z $verb ]]; then verb=$a; fi ;;
        esac
    done
    case $area in
        pr | issue | release)
            segment_text
            with_files "$CS_CWD" "${files[@]}"
            attributes_ai "$REPLY" && block "$attribution_reason"
            [[ $area == pr && $verb == merge ]] && ask "Merging a pull request is the user's decision: gh pr merge."
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
            fi ;;
    esac
}

# The repository root of the folder a git add ran in last, kept for the next one
root_of=$'\x01'
root=
root_base=
CS_PROGRAMS[git]=check_git
CS_PROGRAMS[gh]=check_gh
split_command "$command" "$shell" ""
if [[ -n $ask_reason ]]; then
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}' "$ask_reason"
fi
exit 0
