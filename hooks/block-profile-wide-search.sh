#!/usr/bin/env bash
# PreToolUse hook: blocks a recursive search over the user profile, anything above it, or a
# cloud-synced folder. A sync client (OneDrive, SharePoint libraries synced through it) keeps most
# files online-only and downloads each one a search opens, so a single `find ~ -name x` can fill
# the disk, and when the tool call times out Git Bash ends the shell but leaves find.exe running.
# Plain bash on purpose, like block-secrets.sh: a hook that needed node or jq would stop guarding,
# silently, on a machine without them. Exit 2 blocks the call and tells Claude why; exit 0 leaves
# it to the normal permission flow.
#
# Recursive: find, du, tree, rg, ag, ack, fd; grep with -r/-R/--recursive/-d recurse; ls with -R;
# Get-ChildItem/gci (and ls/dir in PowerShell) with -Recurse or -Depth, dir /s in cmd; the Grep
# and Glob tools always. In cmd and PowerShell find is the Windows FIND, a text search.
# Guarded: the profile ($HOME) itself, its parent and the drive or filesystem root above it, and a
# glob at any of those (`du -sh ~/*`); and every synced folder, a search starting in one or above
# one, since recursion reaches it from there. The synced folders are found, not configured: on
# Windows every client that keeps files online-only registers its folders with the Cloud Files API
# (OneDrive, SharePoint libraries synced through it, Dropbox, Google Drive, iCloud), and the
# registry lists them under SyncRootManager; it is read only for a command that is recursive. On
# macOS the File Provider folders live under ~/Library/CloudStorage and ~/Library/Mobile Documents.
# As a fallback where neither applies: folders named OneDrive* or SharePoint*, the folders the
# OneDrive* variables name, and any folder whose name contains a text listed in
# PROFILE_SEARCH_GUARD_EXTRA (';'-separated).
# The registry gives a name in the Windows code page and a command gives it in UTF-8 or as \uXXXX,
# so a character outside ASCII in a registered folder matches any text in its place.
# A search below the profile that reaches none of these, a project or ~/.claude, is left alone.
# It reads the command text and the registry, and opens no file of the profile itself.
#
# The command is split by lib/command-segments.sh, like the other shell guards: a search is found
# at command position only, also behind wrappers (timeout, nohup, env, sudo, xargs), in backquotes
# and $( ), behind bash/sh -c, cmd /c and powershell -c, in find -exec, and in the here-document a
# shell reads (bash <<'EOF'); the text of any other here-document or a quoted message is not a
# command. cd, pushd/popd and Set-Location before it set the folder a relative path starts from.
# Not covered: a path built at run time (a variable other than HOME/USERPROFILE, eval), $( ) inside
# double quotes, a script piped into a shell (cat <<'EOF' | bash), a cd inside a subshell, which
# is taken to last, findstr /s and where /r, a script or alias that searches by itself, and
# non-recursive reads, which open one file at a time.
# Blocked although harmless: a recursive search whose pattern happens to be a guarded path.
# A missing or broken lib/command-segments.sh blocks every call that names a search tool (exit 2)
# until it is restored.
# Every call of a hook delays the tool, so the common path starts no process: functions return in
# REPLY rather than through $(...), which forks in Git Bash, nothing is set up before it is needed
# (the library, 20 ms, only once a search tool is named), and the split is linear in the length
# of the command.
# Tests: hooks/block-profile-wide-search.test.sh

shopt -s nocasematch
set -f   # paths are split on / below, and a * in one must stay a *, not expand to file names
IFS= read -r -d '' input
search_tools='find|du|tree|rg|ag|ack|fd|fdfind|grep|egrep|fgrep|ls|get-childitem|gci|dir'
# Fast path: no search tool and no Glob named anywhere in the payload, where a line break is \n
[[ $input =~ (^|[^[:alnum:]_-]|\\[nrt])($search_tools|glob)([^[:alnum:]_-]|$) ]] || exit 0

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=lib/command-segments.sh
source "$here/lib/command-segments.sh" || {
    echo "Blocked by the claude-setup search guard: its library $here/lib/command-segments.sh is missing or broken, so no search can be checked. Tell the user: restore the claude-setup hooks folder (git checkout in claude-setup, then install.ps1)." >&2
    exit 2
}

field tool_name 4096
tool=$REPLY
case $tool in
    Bash | PowerShell)
        field command
        command=$REPLY
        # Named only elsewhere in the payload (cwd, description): nothing to parse
        [[ $command =~ (^|[^[:alnum:]_-])($search_tools)([^[:alnum:]_-]|$) ]] || exit 0
        ;;
    Grep | Glob) ;;
    *) exit 0 ;;
esac

# REPLY: the path in lower-case POSIX form, resolved against $cwd: C:\X and C:/X become /c/x, ~ and
# the profile variables become $HOME, . and .. are resolved.
norm() {
    local p=${1//\\//} lp out="" part pre
    lp=${p,,}
    # Without case, as PowerShell and cmd read them ($Env:USERPROFILE, %UserProfile%, $Home)
    for pre in '$userprofile' '${userprofile}' '$env:userprofile' '${env:userprofile}' '%userprofile%' '$home' '${home}' '$env:home' '~'; do
        if [[ $lp == "$pre" || $lp == "$pre"/* ]]; then
            p=$HOME${p:${#pre}}
            break
        fi
    done
    p=${p//\\//}
    if [[ $p =~ ^([A-Za-z]):(/.*)?$ ]]; then p=/${BASH_REMATCH[1]}${BASH_REMATCH[2]}; fi
    if [[ $p =~ ^/(cygdrive|mnt)/([A-Za-z])(/.*)?$ ]]; then p=/${BASH_REMATCH[2]}${BASH_REMATCH[3]}; fi
    [[ $p == /* ]] || p=$cwd/$p
    local IFS=/
    for part in $p; do
        case $part in
            '' | .) ;;
            ..) out=${out%/*} ;;
            *) out=$out/$part ;;
        esac
    done
    out=${out:-/}
    REPLY=${out,,}
}

field cwd 4096
start_dir=${REPLY:-$PWD}
cwd=/
norm "$start_dir"
cwd=$REPLY
norm "$HOME"
home=$REPLY
roots=("/" "${home:0:2}" "${home%/*}" "$home")
clouds=("$home/library/cloudstorage" "$home/library/mobile documents")
for v in "$OneDrive" "$OneDriveCommercial" "$OneDriveConsumer"; do
    [[ -n $v ]] && { norm "$v"; clouds+=("$REPLY"); }
done
extras=()
IFS=';' read -ra extras <<< "${PROFILE_SEARCH_GUARD_EXTRA:-}"

# The folders the Cloud Files API has registered, as lower-case patterns with every byte outside
# ASCII as *. SEARCH_GUARD_REG_OUTPUT names a file to read instead of the registry, for the tests.
synced=()
synced_loaded=0
load_synced() {
    ((synced_loaded)) && return
    synced_loaded=1
    # Bytes, not characters: the code page's 0xD6 is no valid UTF-8, and a UTF-8 match skips the line
    local line p roots_key=0 LC_ALL=C
    while IFS= read -r line; do
        line=${line%$'\r'}
        if [[ $line == HKEY_* ]]; then
            [[ $line == *\\UserSyncRoots ]] && roots_key=1 || roots_key=0
        elif ((roots_key)) && [[ $line =~ REG_SZ[[:space:]]+([A-Za-z]:\\.*)$ ]]; then
            p=${BASH_REMATCH[1]}
            norm "${p//[$'\x80'-$'\xff']/*}"
            synced+=("$REPLY")
        fi
    done < <(
        if [[ -n ${SEARCH_GUARD_REG_OUTPUT:-} ]]; then
            cat -- "$SEARCH_GUARD_REG_OUTPUT"
        elif command -v reg > /dev/null 2>&1; then
            MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' reg query 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\SyncRootManager' /s 2> /dev/null
        fi
    )
}

# REPLY: why a path is guarded, or empty
guarded() {
    local n part prefix="" r c e a
    norm "$1"
    n=$REPLY
    REPLY=
    for r in "${roots[@]}"; do
        [[ $n == "$r" ]] && { REPLY="$1 is the profile or above it"; return; }
    done
    for c in "${clouds[@]}"; do
        [[ $n == "$c" || $n == "$c"/* ]] && { REPLY="$1 is in the synced folder $c"; return; }
    done
    load_synced
    REPLY=   # load_synced normalises through norm, which leaves its last path here
    for c in "${synced[@]}"; do
        # Unquoted: the * a byte outside ASCII became is meant to match
        [[ $n == $c || $n == $c/* ]] && { REPLY="$1 is in the synced folder $c"; return; }
        a=$c
        while [[ $a == /*/* ]]; do
            a=${a%/*}
            [[ $n == $a ]] && { REPLY="$1 holds the synced folder $c"; return; }
        done
    done
    local IFS=/
    for part in ${n#/}; do
        if [[ $part == *[*?[]* ]]; then
            for r in "${roots[@]}"; do
                [[ ${prefix:-/} == "$r" ]] && { REPLY="$1 globs over the profile or above it"; return; }
            done
        fi
        [[ $part == onedrive* || $part == sharepoint* ]] && { REPLY="$1 is in a synced folder"; return; }
        for e in "${extras[@]}"; do
            [[ -n $e && $part == *"${e,,}"* ]] && { REPLY="$1 is in the synced folder $e"; return; }
        done
        prefix=$prefix/$part
    done
}

block() {
    echo "Blocked by the claude-setup search guard: a recursive search where $1. A sync client downloads every online-only file such a search opens, and a timed-out find keeps running. Search the project (\$CLAUDE_PROJECT_DIR) or a named folder below the profile instead, or ask the user." >&2
    exit 2
}

if [[ $tool == Grep || $tool == Glob ]]; then
    field path
    p=$REPLY
    if [[ -z $p && $tool == Glob ]]; then
        # An absolute pattern names its own folder (C:/Users/x/**/*.pdf)
        field pattern
        [[ $REPLY == [/\\~\$%]* || $REPLY =~ ^[A-Za-z]: ]] && p=$REPLY
    fi
    guarded "${p:-.}"
    [[ -n $REPLY ]] && block "$REPLY"
    exit 0
fi

# Options that take a value, per tool, between blanks: a flag of one tool is such an option of
# another (tree -d lists folders, du -d takes a depth)
declare -A value_opts=(
    [grep]=' -e -f -m -A -B -C -d -D --regexp --file --max-count --exclude --include --exclude-dir --exclude-from --label --binary-files --devices --directories --context --after-context --before-context '
    [rg]=' -e -f -g -t -T -m -A -B -C -d -j -r -M -E --regexp --file --glob --iglob --type --type-not --type-add --max-count --max-depth --maxdepth --threads --replace --max-columns --encoding --pre --ignore-file --sort --sortr --max-filesize --context --after-context --before-context '
    [ag]=' -A -B -C -G -g -m -p --depth --ignore --ignore-dir --file-search-regex --max-count --path-to-ignore --context --after --before --pager '
    [ack]=' -A -B -C -g -m --type --ignore-dir --ignore-file --match --max-count --output --context --after-context --before-context '
    [fd]=' -e -t -d -E -S -j -c -o --extension --type --max-depth --min-depth --exact-depth --exclude --size --threads --color --owner --changed-within --changed-before --base-directory --max-results --ignore-file --format '
    [tree]=' -L -P -I -o -H -T --filelimit --charset --sort --timefmt '
    [du]=' -d -B -t -X --max-depth --block-size --threshold --exclude --exclude-from --time-style --files0-from '
    [ls]=' -I -w -T --ignore --hide --width --tabsize --sort --format --block-size --time-style --time --quoting-style --indicator-style '
)

# Handler for a search tool (CS_PROGRAMS): words, at, prog, sh, seg_raw and CS_CWD come from
# split_command. In bash each word is read with its escapes, so \( is the word ( rather than a
# word \, which would read as the drive root, and ~/Team\ Files is one folder.
check_search() {
    local -a w=() paths=()
    local k i=1 t=$prog b=$prog n l skip_pattern=0 recursive=0 ps=0 p vals
    # In cmd and PowerShell, find is the Windows FIND, which searches text and not folders
    [[ $t == find && $sh != bash ]] && return
    # PowerShell's ls and dir are Get-ChildItem, whose options have no case
    [[ $t == get-childitem || $t == gci || ($sh == powershell && ($t == ls || $t == dir)) ]] && ps=1
    for ((k = at; k < ${#words[@]}; k++)); do
        if [[ $sh == bash && -n ${seg_raw[k]+x} ]]; then
            cs_unescape "${seg_raw[k]}"
            w+=("$REPLY")
        else
            w+=("${words[k]}")
        fi
    done
    cwd=/
    norm "$CS_CWD"
    cwd=$REPLY
    case $t in
        egrep | fgrep) b=grep ;;
        fdfind) b=fd ;;
        dir) b=ls ;;
    esac
    vals=${value_opts[$b]-}
    case $b in
        find | du | tree) recursive=1 ;;
        rg | ag | ack | fd) recursive=1; skip_pattern=1 ;;
        grep) skip_pattern=1 ;;
    esac
    while ((i < ${#w[@]})); do
        n=${w[i]}
        l=${n,,}
        if ((ps)); then
            # Parameters may be cut short (-inc, -rec); -s is an alias of -Recurse
            case $l in
                -fi | -fil | -filt* | -inc* | -exc*) ((i += 2)); continue ;;
                -dep*) recursive=1; ((i += 2)); continue ;;
                -pa* | -li*) paths+=("${w[i+1]}"); ((i += 2)); continue ;;
                -r | -re | -rec* | -s) recursive=1 ;;
                -*) ;;
                *) paths+=("$n") ;;
            esac
            ((i++))
            continue
        fi
        if [[ $sh == cmd && $n == /* ]]; then
            # cmd's options, also glued (dir /s /b, dir /b/s); its paths never start with /
            [[ /$l/ == *'/s/'* ]] && recursive=1
            ((i++))
            continue
        fi
        # fd -x runs a command on each result: the rest is that command
        [[ $b == fd && ($n == -x || $n == -X || $n == --exec || $n == --exec-batch) ]] && break
        if [[ $t == find ]]; then
            # Options before the starting points; the first other dash word opens the expression
            case $n in
                -H | -L | -P | -O* | -D | --) [[ $n == -D ]] && ((i++)); ((i++)); continue ;;
                -* | '(' | '!') break ;;
            esac
        fi
        case $n in
            --version | --help | -V) return ;;
            --files) skip_pattern=0 ;;
            --recursive | --dereference-recursive) recursive=1 ;;
            --search-path) paths+=("${w[i+1]}"); ((i += 2)); continue ;;
            -*)
                if [[ $vals == *" $n "* ]]; then
                    # The pattern comes as this value, so the next word is a path
                    case $b:$n in
                        grep:-e | grep:-f | grep:--regexp | grep:--file | rg:-e | rg:-f | rg:--regexp | rg:--file | ag:-g | ack:-g) skip_pattern=0 ;;
                    esac
                    [[ $b == grep && $n == -d && ${w[i+1]} == recurse ]] && recursive=1
                    ((i += 2))
                    continue
                fi
                # ack -f lists the files, with no pattern. Case matters: ls -r sorts in reverse
                [[ $b == ack && $n == -f ]] && skip_pattern=0
                [[ $b == grep && $n =~ ^-[[:alnum:]]*[rR] ]] && recursive=1
                [[ $b == ls && $n =~ ^-[[:alnum:]]*R ]] && recursive=1
                ;;
            *)
                if ((skip_pattern)); then skip_pattern=0; else paths+=("$n"); fi ;;
        esac
        ((i++))
    done
    if ((recursive)); then
        ((${#paths[@]})) || paths=(.)
        for p in "${paths[@]}"; do
            guarded "$p"
            [[ -n $REPLY ]] && block "$REPLY"
        done
    fi
}

# Handler for a shell: the here-document it reads is a script (bash <<'EOF'), read as a command
# line of its own, so a bash -c in it is unwrapped too. It runs in a child process, so a cd in it
# ends with it. A script named after the shell reads the here-document as its input instead.
check_shell() {
    local body k CS_CWD=$CS_CWD CS_PREV=$CS_PREV
    local -a CS_STACK=("${CS_STACK[@]}")
    for ((k = at + 1; k < ${#words[@]}; k++)); do
        [[ ${words[k]} == -* ]] || return
    done
    for body in "${heredocs[@]}"; do
        split_command "$body" bash "" 0
    done
}

for p in find du tree rg ag ack fd fdfind grep egrep fgrep ls get-childitem gci dir; do CS_PROGRAMS[$p]=check_search; done
for p in bash sh zsh dash ksh; do CS_PROGRAMS[$p]=check_shell; done

# In bash X:\ before a shell character or a space stays a drive root, as cmd /c would get it,
# rather than escaping that character. PowerShell has no such escape (`dir C:\ -Recurse`).
if [[ $tool == Bash && $command == *:\\* ]]; then
    for c in ' ' '(' ')' '|' '&' ';' '<' '>' '!'; do command=${command//":\\$c"/":\\\\$c"}; done
fi
resolve_path / "$start_dir"
CS_CWD=$REPLY
shopt -u nocasematch
split_command "$command" "${tool,,}" ""
exit 0
