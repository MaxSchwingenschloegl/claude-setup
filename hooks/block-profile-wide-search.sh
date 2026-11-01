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
# Get-ChildItem/gci/dir with -Recurse or -Depth, dir /s; the Grep and Glob tools always.
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
# Not covered: a path built at run time (a variable other than HOME/USERPROFILE, $(...), eval), a
# script or alias that searches by itself, and non-recursive reads, which open one file at a time.
# Blocked although harmless: a recursive search whose pattern happens to be a guarded path.
# Every call of a hook delays the tool, so the common path starts no process: functions return in
# REPLY rather than through $(...), which forks in Git Bash, and nothing is set up before it is
# needed.
# Tests: hooks/block-profile-wide-search.test.sh

shopt -s nocasematch
set -f   # paths are split on / below, and a * in one must stay a *, not expand to file names
IFS= read -r -d '' input

# REPLY: the JSON string value of the first key with this exact name, unescaped
field() {
    local re='"'"$1"'"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"' s
    REPLY=
    [[ $input =~ $re ]] || return 0
    s=${BASH_REMATCH[1]}
    s=${s//\\\\/$'\x01'}
    s=${s//\\\"/\"}
    s=${s//\\n/$'\n'}
    s=${s//\\t/$'\t'}
    s=${s//\\r/}
    s=${s//\\\//\/}
    REPLY=${s//$'\x01'/\\}
}

field tool_name
tool=$REPLY
case $tool in
    Bash | PowerShell)
        field command
        command=$REPLY
        # Fast path: no recursive tool named anywhere, nothing to parse
        [[ $command =~ (^|[^[:alnum:]_-])(find|du|tree|rg|ag|ack|fd|fdfind|grep|egrep|fgrep|ls|get-childitem|gci|dir)([^[:alnum:]_-]|$) ]] || exit 0
        ;;
    Grep | Glob) ;;
    *) exit 0 ;;
esac

# REPLY: the path in lower-case POSIX form, resolved against $cwd: C:\X and C:/X become /c/x, ~ and
# the profile variables become $HOME, . and .. are resolved.
norm() {
    local p=${1//\\//} out="" part pre
    for pre in '$USERPROFILE' '${USERPROFILE}' '$env:USERPROFILE' '${env:USERPROFILE}' '%USERPROFILE%' '$HOME' '${HOME}' '$env:HOME' '~'; do
        if [[ $p == "$pre" || $p == "$pre"/* ]]; then
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

field cwd
cwd=/
norm "${REPLY:-$PWD}"
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
            [[ -n $e && $part == *"$e"* ]] && { REPLY="$1 is in the synced folder $e"; return; }
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
    guarded "${REPLY:-.}"
    [[ -n $REPLY ]] && block "$REPLY"
    exit 0
fi

# Words and separators, quotes kept together and removed afterwards
word='(([^][:space:]'"'"'";|&()<>]|[][])+|'"'"'[^'"'"']*'"'"'|"([^"\\]|\\.)*")+'
sep='&&|\|\||[;|&()<>]|'$'\n'
rest=$command
segment=()

check_segment() {
    local -a w=("${segment[@]}") paths=()
    local i=0 t n skip_pattern=0 recursive=0
    # Leading assignments and wrappers
    while ((i < ${#w[@]})); do
        case ${w[i]} in
            *=*) ((i++)) ;;
            timeout) ((i++)); while [[ ${w[i]} == -* || ${w[i]} =~ ^[0-9.]+[smhd]?$ ]]; do ((i++)); done ;;
            nice | command | sudo | exec | env | builtin | time) ((i++)) ;;
            cmd | cmd.exe) ((i++)); [[ ${w[i]} == /c || ${w[i]} == //c ]] && ((i++)) ;;
            *) break ;;
        esac
    done
    t=${w[i]##*/}
    t=${t%.exe}
    t=${t,,}
    ((i++))
    case $t in
        cd | pushd)
            if [[ -n ${w[i]} ]]; then norm "${w[i]}"; cwd=$REPLY; else cwd=$home; fi
            return ;;
        find | du | tree | rg | ag | ack | fd | fdfind) recursive=1 ;;
        grep | egrep | fgrep | ls | get-childitem | gci | dir) ;;
        *) return ;;
    esac
    [[ $t == rg || $t == ag || $t == ack || $t == fd || $t == fdfind || $t == grep || $t == egrep || $t == fgrep ]] && skip_pattern=1
    while ((i < ${#w[@]})); do
        n=${w[i]}
        if [[ $t == find ]]; then
            # Options before the starting points; the first other dash word opens the expression
            case $n in
                -H | -L | -P | -O* | -D) [[ $n == -D ]] && ((i++)); ((i++)); continue ;;
                -* | '(' | '!') break ;;
            esac
        fi
        case $n in
            -e | -f | --regexp | --file | -g | --glob | -t | --type | -T | --type-not | -m | --max-count | -A | -B | -C | --max-depth | --maxdepth | -d | --exclude | --include | --exclude-dir | -Filter | -Include | -Exclude | -Depth)
                [[ $n == -e || $n == -f || $n == --regexp || $n == --file ]] && skip_pattern=0
                [[ $n == -d && ${w[i+1]} == recurse ]] && recursive=1
                [[ $n == -Depth ]] && recursive=1
                ((i += 2)); continue ;;
            -Path | -LiteralPath)
                paths+=("${w[i+1]}"); ((i += 2)); continue ;;
            --files) skip_pattern=0 ;;
            --recursive | --dereference-recursive | -Recurse | -Recur* | /s) recursive=1 ;;
            --*) ;;
            -*)
                [[ $t == grep || $t == egrep || $t == fgrep ]] && [[ $n =~ ^-[A-Za-z]*[rR] ]] && recursive=1
                [[ ($t == ls || $t == dir) && $n =~ ^-[A-Za-z]*R ]] && recursive=1
                [[ ($t == get-childitem || $t == gci || $t == dir) && ($n == -r || $n == -rec*) ]] && recursive=1
                ;;
            *)
                if ((skip_pattern)); then skip_pattern=0; else paths+=("$n"); fi ;;
        esac
        ((i++))
    done
    ((recursive)) || return
    ((${#paths[@]})) || paths=(.)
    local p
    for p in "${paths[@]}"; do
        guarded "$p"
        [[ -n $REPLY ]] && block "$REPLY"
    done
}

while [[ -n $rest ]]; do
    rest=${rest#"${rest%%[![:space:]]*}"}
    if [[ $rest =~ ^($sep) ]]; then
        check_segment
        segment=()
        rest=${rest:${#BASH_REMATCH[0]}}
    elif [[ $rest =~ ^($word) ]]; then
        tok=${BASH_REMATCH[0]}
        rest=${rest:${#tok}}
        tok=${tok//\'/}
        tok=${tok//\"/}
        segment+=("$tok")
    else
        rest=${rest:1}
    fi
done
check_segment
exit 0
