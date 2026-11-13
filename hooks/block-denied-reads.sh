#!/usr/bin/env bash
# PreToolUse hook (Bash, PowerShell): blocks a shell command that would read what a Read deny rule
# in the settings keeps from Claude, in the forms Claude Code's own check of shell commands lets
# through. Measured with Claude Code 2.1.322: it refuses cat, head, tail, sed, awk, grep, cp, ls,
# base64, `< file` and `$(< file)` on a denied path, also absolute, with backslashes, in other
# case, with .. and after a cd, but it ran `grep -r` and `rg` over the folder above a denied one,
# a glob (`cat dir/lok*/x`, `cat dir/*/x`), less, `bash -c`, `xargs cat`, `python -c`, `node -e`
# and `powershell -Command Get-Content`, and those read the file. The Grep and Glob tools leave
# denied files out by themselves. Plain bash, like the other hooks: one that needed node or jq
# would stop guarding, silently, on a machine without them. Exit 2 blocks the call and tells
# Claude why; exit 0 leaves it to the normal permission flow.
#
# Rules: the Read(...) entries of the first "deny" array in the user settings
# ($CLAUDE_CONFIG_DIR or ~/.claude, settings.json) and in the project's .claude/settings.json and
# .claude/settings.local.json ($CLAUDE_PROJECT_DIR, else the payload's cwd). //x is the absolute
# path /x (//c/Users/... on Windows), ~/x is below the home folder, /x, ./x and x are below the
# project. * and ? stay within a folder, ** spans folders, and a rule ending in /** denies a
# folder, the folder itself included. Case is ignored, as Windows does.
# Blocked: a reading program at command position (cat, less, more, head, tail, sed, awk, sort, wc,
# diff, od, xxd, strings, base64, jq, type, Get-Content, Select-String, Format-Hex, Import-Csv,
# findstr, the search tools, cp, rsync, tar, zip, 7z, gzip, copy, xcopy, robocopy, Copy-Item,
# Compress-Archive) with an argument that
#   - is a denied path (Claude Code checks that too; kept for the programs it does not know),
#   - is a glob that can name a denied path: compared with the rule part by part, never expanded
#     (`cat inbox/*/private/x`, `cat inbox/transcripts/*/x`). It counts against a rule with ** only
#     when it names one of the rule's plain parts after the ** (inbox, transcripts or private, or
#     a glob with two plain characters such as priv*), so that `ls docs/*/*` meets no such rule;
#     against the name of a file rule only with two plain characters (`cat dir/.e*` for .env,
#     not `cat dir/*`); against a glob in a rule when one plain start begins the other and the
#     command's plain end ends with the rule's (`cat ~/.ssh/id*` for id_*, `cat k*.pem` for
#     *.pem), or
#   - when the program descends into folders (find, du, tree, rg, ag, ack, fd, grep -r, ls -R,
#     Get-ChildItem -Recurse, dir /s, findstr /s, cp -r, rsync -r/-a, tar, zip -r, 7z, gzip -r,
#     diff -r, xcopy /s, robocopy /s /e /mir, Copy-Item -Recurse, Compress-Archive), is a folder
#     above the denied folder's fixed path when that is there, a folder with the rest of a **
#     rule straight in it (`grep -r x vault` for **/inbox/transcripts/private/** when
#     vault/inbox/transcripts/private exists; for a rule with a fixed start such as
#     ./**/secrets/** once the search is inside that start), or the start of that rest
#     (`grep -r x inbox`, `grep -r x inbox/*`); a search
#     filtered by a name glob (Get-ChildItem -Recurse *.md, dir /s x\*.md, findstr /s w *.md)
#     starts in the glob's folder;
# and python, py, node, perl, ruby and php whose inline code (-c, -e, -p, -r; else a here-document
# or the command piped into it) holds such a path or glob in a quoted string, its escapes read as
# the language reads them (not in r'...', and in perl, ruby and php single quotes only \\ and \'),
# a glob only with a / or a drive in it (a regular expression such as '.*' is no path); piped
# code arrives without its quotes, so each of its words with a / or \ counts. A PowerShell reader
# without a path of its own (Get-ChildItem x | Get-Content) reads the words piped into it. A path
# naming a denied folder itself counts for programs that list, search or read what is in a folder
# (ls, dir, Get-ChildItem, the recursive ones, robocopy, xcopy, copy, diff, and inline code when
# the string holds a / or \), not for cat, which only fails on a folder, nor for a bare word in
# code ('out' is mostly a key or a word); a listing without recursion shows a file's name, not its
# content, so file rules do not count for ls, dir and Get-ChildItem. The text of
# sed, awk, jq, Select-String and findstr and option values such as cut -d are no paths. Brace
# lists (x/{a,b}), PowerShell lists (a,b) and -Path:x name several or glued paths. Wrappers and
# nesting come from lib/command-segments.sh (bash -c, cmd /c, powershell -c, find -exec, timeout
# and the like, xargs with the words piped into it) and from this hook (uv, poetry, pipenv, pdm
# and hatch run). tar -x and tar -t read only the archive.
# A rule that names files rather than a folder (.env, *.pem) counts for paths and globs, not for a
# search over a folder: grep -r over a repository that holds a .env file would be refused in
# nearly every project otherwise, and block-secrets.sh guards those names already.
# Not covered: a path built at run time (variables, $( ) inside double quotes, eval), a script file
# or function that reads by itself, an interpreter's computed path (os.walk over the folder above),
# a search two or more folders above a ** rule's rest (`grep -r x Documents` for
# Documents/vault/inbox/transcripts/private), a ** rule whose rest holds a glob, a bare * or a glob
# with less than two plain characters against a file rule's name (Get-Content dir\* in PowerShell,
# where * names dot files, with a .env in dir), a glob that leaves open the plain end a rule's
# glob fixes (`cat k.*` for *.pem), a denied folder named in code by a bare word
# (os.listdir('out')), a glob made only of bare wildcards against a ** rule
# (`grep -r x */*` or `ls */*` above the folder), ForEach-Object blocks (% { Get-Content $_ }),
# a ** in the command spanning folders (it is one
# folder, as in bash without globstar), a glob in a redirection (cat < x/*), a pattern file
# (grep -f x), git grep, tar -C x with names relative to x, .NET calls in PowerShell
# ([IO.File]::ReadAllText), a link or junction into a denied folder, 8.3 short names, rules in
# managed settings or passed with --settings.
# A guard against accidents, not against a determined attacker.
# Blocked although harmless: a glob that could name a denied path where no such file exists
# (cat inbox/transcripts/*/x with x only outside private), a quoted glob the shell leaves alone
# (cat "a*"), a copy into a denied folder (cp x denied/), since every argument counts, a recursive
# glob over names whose starting folder holds a denied folder (Get-ChildItem -Recurse *.md beside
# it), and a search held above the denied folder by its own depth limit (find . -maxdepth 1).
# It never lists a folder or opens a file: a hook that walked folders would make a sync client
# download what it walks (block-profile-wide-search.sh refuses such searches, but only for
# Claude's commands, not for a hook's own look). It asks the file system only whether a few fixed
# paths exist, one stat each, and its message names the rule and the command's own word.
# Every call delays the tool: without a rule it ends after reading the settings, and the library
# is loaded only when the command holds the last plain name of a rule, a glob character or a
# program that descends into folders. A short command takes about as long as the other hooks
# (150 to 200 ms in Git Bash); a 30 KB script made of nothing but recursive searches or globs
# takes 4 to 7 s, so only one of about 140 KB would reach the 30 s timeout and go unchecked.
# Tests: hooks/block-denied-reads.test.sh

shopt -s nocasematch
set -f   # a * in a rule or a word stays a *: nothing here is ever expanded
IFS= read -r -d '' input
[[ $input =~ \"tool_name\"[[:space:]]*:[[:space:]]*\"(Bash|PowerShell)\" ]] || exit 0
tool=${BASH_REMATCH[1]}

# REPLY: the JSON string value of the first key $1, unescaped as far as paths and rules need
json_field() {
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

home=${HOME//\\//}
project=${CLAUDE_PROJECT_DIR:-}
if [[ -z $project ]]; then
    json_field cwd
    project=$REPLY
fi
project=${project//\\//}
project=${project%/}

# The rules: RULE_TEXT as written, RULE_RX a regular expression over a path in compare form (see
# cmp_path), RULE_CMP the rule's path in compare form, RULE_DIR for a folder rule the folder in its
# own case, for the file system, RULE_FRAG the last part without a glob (a path the rule matches
# holds it), RULE_FROM the file
RULE_TEXT=()
RULE_RX=()
RULE_RX_IN=()
RULE_CMP=()
RULE_RC=()
RULE_PRX=()
# RULE_RC_IN, RULE_PRX_IN: for a folder rule, its parts for a path inside the folder (folder/*/**)
RULE_RC_IN=()
# RULE_AC, RULE_TC, RULE_KIND: see holds_denied
RULE_AC=()
RULE_TC=()
RULE_KIND=()
RULE_LITS=()
RULE_PRX_IN=()
RULE_DIR=()
RULE_FRAG=()
RULE_FROM=()

# REPLY: glob $1 as an anchored regular expression, without the closing $; * and ? stay within a
# folder, ** spans folders
glob_rx() {
    local g=$1 out= c i=0 n=${#1} cls
    while ((i < n)); do
        c=${g:i:1}
        case $c in
            '*')
                if [[ ${g:i:2} == '**' ]]; then
                    if [[ ${g:i+2:1} == / ]]; then out+='(.*/)?'; ((i += 3)); else out+='.*'; ((i += 2)); fi
                    continue
                fi
                out+='[^/]*' ;;
            '?') out+='[^/]' ;;
            '[')
                cls=${g:i+1}
                if [[ $cls == *']'* ]]; then
                    cls=${cls%%]*}
                    ((i += ${#cls} + 2))
                    [[ $cls == '!'* ]] && cls=^${cls:1}
                    out+="[$cls]"
                    continue
                fi
                out+='\[' ;;
            '\') out+='\\' ;;
            '.' | '+' | '(' | ')' | '|' | '{' | '}' | '$') out+="[$c]" ;;
            '^') out+='\^' ;;
            *) out+=$c ;;
        esac
        ((i++))
    done
    REPLY="^$out"
}

# REPLY: path $1 in compare form: lower case, forward slashes, C:/x as /c/x, . and .. resolved
cmp_path() {
    local p=${1//\\//} out= part
    p=${p,,}
    if [[ $p =~ ^([a-z]):(/.*)?$ ]]; then p=/${BASH_REMATCH[1]}${BASH_REMATCH[2]}; fi
    local IFS=/
    for part in $p; do
        case $part in
            '' | .) ;;
            ..) out=${out%/*} ;;
            *) out=$out/$part ;;
        esac
    done
    REPLY=${out:-/}
}

# REPLY: path $1 like cmp_path, but in its own case, for the file system (C:/X as /c/X)
case_path() {
    local p=${1//\\//} out= part
    if [[ $p =~ ^([A-Za-z]):(/.*)?$ ]]; then p=/${BASH_REMATCH[1],,}${BASH_REMATCH[2]}; fi
    local IFS=/
    for part in $p; do
        case $part in
            '' | .) ;;
            ..) out=${out%/*} ;;
            *) out=$out/$part ;;
        esac
    done
    REPLY=${out:-/}
}

add_rule() {   # rule settings-file
    local r=${1//\\//} p dir last
    case $r in
        //*) p=${r:1} ;;
        '~/'*) p=$home${r:1} ;;
        /*) p=$project$r ;;
        ./*) p=$project/${r:2} ;;
        *) p=$project/$r ;;
    esac
    dir=
    [[ $p == */'**' ]] && dir=${p%/'**'}
    cmp_path "$p"
    RULE_CMP+=("$REPLY")
    # Its parts, kept apart by \x1f, a folder rule's followed by **
    local -a rc
    if [[ -n $dir ]]; then cmp_path "$dir"; fi
    local IFS=/
    rc=(${REPLY#/})
    unset IFS
    [[ -n $dir ]] && rc+=('**')
    local IFS=$'\x1f'
    RULE_RC+=("${rc[*]}")
    unset IFS
    # For a rule **/<parts>[/**] a quick test of a glob (see glob_meets): the parts in a row, each
    # also met by a glob part of the command's word, which check_path marks \x03 when it has two
    # plain characters at its start or end and \x02 otherwise. The name of a file rule is met only
    # by \x03 (see comp_compat), unless it is a glob with no two plain characters at either end.
    local prx= part j k=${#rc[@]} open=0 any=$'\x02'$'|'$'\x03'
    if [[ ${rc[0]} == '**' ]]; then
        [[ ${rc[k - 1]} == '**' ]] && { open=1; ((k--)); }
        for ((j = 1; j < k; j++)); do
            part=${rc[j]}
            [[ $part == '**' ]] && { prx=; break; }
            glob_rx "$part"
            if ((!open && j == k - 1)); then
                # A glob without two plain characters at either end (secret/*) is met by any glob
                local pp=${part%%[*?[]*} ps=${part##*[]*?]}
                if [[ $part == *[*?[]* ]] && ((${#pp} < 2 && ${#ps} < 2)); then
                    prx+="/(${REPLY#^}|$any)"
                else
                    prx+="/(${REPLY#^}|"$'\x03'")"
                fi
            else
                prx+="/(${REPLY#^}|$any)"
            fi
        done
        [[ -n $prx ]] && { if ((open)); then prx="$prx(/|\$)"; else prx="$prx\$"; fi; }
    fi
    RULE_PRX+=("$prx")
    # The same for a path inside a folder rule's folder (see RULE_RC_IN)
    if [[ -n $prx && -n $dir ]]; then RULE_PRX_IN+=("${prx%'(/|$)'}/[^/]+(/|\$)"); else RULE_PRX_IN+=("$prx"); fi
    if [[ -n $dir ]]; then
        local IFS=$'\x1f'
        rc=("${rc[@]:0:${#rc[@]}-1}" '*' '**')
        RULE_RC_IN+=("${rc[*]}")
        unset IFS
    else
        RULE_RC_IN+=("${RULE_RC[-1]}")
    fi
    # For holds_denied: the folder's fixed start (the parts before its first **) and, for a folder
    # starting with **, its plain rest, and which of the cases of holds_denied the rule is
    local -a dc=() ac=() tc=()
    local kind=
    if [[ -n $dir ]]; then
        cmp_path "$dir"
        local IFS=/
        dc=(${REPLY#/})
        unset IFS
        for part in "${dc[@]}"; do
            [[ $part == '**' ]] && break
            ac+=("$part")
        done
        if ((${#ac[@]} == ${#dc[@]})); then
            kind=plain
        elif ((${#ac[@]})); then
            # archive/**/sealed: its rest after the **, looked for like that of a rule starting
            # with ** once a search is inside archive
            kind=start
            tc=("${dc[@]:${#ac[@]}}")
            while ((${#tc[@]})) && [[ ${tc[0]} == '**' ]]; do tc=("${tc[@]:1}"); done
        else
            tc=("${dc[@]}")
            while ((${#tc[@]})) && [[ ${tc[0]} == '**' ]]; do tc=("${tc[@]:1}"); done
            kind=rest
            ((${#tc[@]})) || kind=any
            for part in "${tc[@]}"; do [[ $part == '**' || $part == *[*?[]* ]] && kind=none; done
        fi
    fi
    local IFS=$'\x1f'
    RULE_AC+=("${ac[*]}")
    RULE_TC+=("${tc[*]}")
    unset IFS
    RULE_KIND+=("$kind")
    # The plain parts after the rule's first **: a glob must name one of them (literally or with
    # two plain characters) to count, or every a/*/*/b would meet every **/x/y/** rule
    local -a lits=()
    local seen=0
    for part in "${rc[@]}"; do
        [[ $part == '**' ]] && { seen=1; continue; }
        ((seen)) && [[ $part != *[*?[]* ]] && lits+=("$part")
    done
    local IFS=$'\x1f'
    RULE_LITS+=("${lits[*]}")
    unset IFS
    cmp_path "${dir:-$p}"
    glob_rx "$REPLY"
    # A folder rule denies the folder and everything in it
    if [[ -n $dir ]]; then REPLY+='(/.*)?$'; else REPLY+='$'; fi
    RULE_RX+=("$REPLY")
    # The same for a path inside the folder, for programs that do not list a folder they are given
    if [[ -n $dir ]]; then RULE_RX_IN+=("${REPLY%'(/.*)?$'}/.+\$"); else RULE_RX_IN+=("$REPLY"); fi
    RULE_TEXT+=("Read($1)")
    RULE_FROM+=("$2")
    RULE_DIR+=("$dir")
    # The longest run without a glob character in the last part that has one (.pem in *.pem, .env.
    # in .env.*, private in .../private/**): every path the rule matches holds it
    local rest=${dir:-$p} part piece
    last=
    while [[ -z $last && -n $rest ]]; do
        part=${rest##*/}
        rest=${rest%"$part"}
        rest=${rest%/}
        local IFS=$'\x02'
        for piece in ${part//[*?[\]]/$'\x02'}; do
            ((${#piece} > ${#last})) && last=$piece
        done
        unset IFS
    done
    RULE_FRAG+=("${last,,}")
}

read_rules() {   # settings-file
    local text= s re='"deny"[[:space:]]*:[[:space:]]*\[' str='^[[:space:],]*"((\\.|[^"\\])*)"'
    [[ -f $1 ]] || return 0
    IFS= read -r -d '' text < "$1"
    [[ $text =~ $re ]] || return 0
    text=${text#*"${BASH_REMATCH[0]}"}
    while [[ $text =~ $str ]]; do
        text=${text:${#BASH_REMATCH[0]}}
        s=${BASH_REMATCH[1]//\\\\/\\}
        s=${s//\\\"/\"}
        [[ $s == 'Read('*')' ]] && add_rule "${s:5:${#s}-6}" "$1"
    done
}

read_rules "${CLAUDE_CONFIG_DIR:-$home/.claude}/settings.json"
if [[ -n $project ]]; then
    read_rules "$project/.claude/settings.json"
    read_rules "$project/.claude/settings.local.json"
fi
((${#RULE_TEXT[@]})) || exit 0

json_field command
command=$REPLY
[[ -n $command ]] || exit 0
descending='find|du|tree|rg|ag|ack|fd|fdfind|grep|egrep|fgrep|ls|get-childitem|gci|dir|findstr|cp|copy|copy-item|cpi|robocopy|xcopy|rsync|tar|zip|7z|7za|gzip|diff|compress-archive'
named=0
if [[ $command == *[*?[]* || $command =~ (^|[^[:alnum:]_-])($descending)([^[:alnum:]_-]|$) ]]; then
    named=1
else
    for f in "${RULE_FRAG[@]}"; do
        [[ -z $f || $command == *"$f"* ]] && { named=1; break; }
    done
fi
((named)) || exit 0

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=lib/command-segments.sh
source "$here/lib/command-segments.sh" || {
    echo "Blocked by the claude-setup read guard: its library $here/lib/command-segments.sh is missing or broken, so no command can be checked against the Read deny rules. Tell the user: restore the claude-setup hooks folder (git checkout in claude-setup, then install.ps1)." >&2
    exit 2
}

block() {   # word what rule-index
    echo "Blocked by the claude-setup read guard: $prog with '$1' $2 that the rule ${RULE_TEXT[$3]} in ${RULE_FROM[$3]} keeps from Claude. Claude Code's own check does not see this form of the command. Do not look for another way to read it: work without it, or ask the user." >&2
    exit 2
}

# True when a fixed path exists. The only look at the file system: one stat per path, never a
# listing and never a file opened, so an online-only folder of a sync client stays as it is.
# READ_GUARD_NO_FS (for replays of recorded commands) answers no without looking.
exists() {
    [[ -z ${READ_GUARD_NO_FS-} ]] || return 1
    if [[ -z ${STATS[$1]+x} ]]; then
        if [[ -e $1 ]]; then STATS[$1]=0; else STATS[$1]=1; fi
    fi
    [[ ${STATS[$1]} == 0 ]]
}
# exists for folder $1 and the path $2 below it, one part at a time: inbox missing answers for
# inbox/transcripts/private and inbox/recordings alike
exists_below() {
    local path=$1 part
    local -a parts
    local IFS=/
    parts=($2)
    IFS=$' \t\n'
    for part in "${parts[@]}"; do
        [[ -n $part ]] || continue
        path+=/$part
        exists "$path" || return 1
    done
}
declare -A STATS=()

# True when a file name the command names by $1 (a word's part, lower case) can be one that the
# rule part $2 (lower case) names. A literal side is matched against the other as a pattern. Two
# globs count only when the command's is at least as narrow as the rule's: its plain start begins
# with the rule's and its plain end ends with the rule's (*.pem for *.pem, not * or k* for *.pem),
# or every `cat dir/*` would meet every *.pem rule. In bash a glob that does not start with a dot
# names no file that does, as the shell expands it.
comp_compat() {
    local a=$1 b=$2 pa sa
    [[ $a == "$b" ]] && return 0
    # In [[ ]] a pattern such as *(x) or @(a|b) is one of bash's extended patterns: in the side
    # used as the pattern, ( ) and | are escaped to plain characters
    if [[ $a != *[*?[]* ]]; then
        [[ $b == *[*?[]* ]] || return 1
        if [[ $b == *[\(\)\|]* ]]; then b=${b//\(/\\\(}; b=${b//\)/\\\)}; b=${b//\|/\\\|}; fi
        [[ $a == $b ]]
        return
    fi
    if [[ $b != *[*?[]* ]]; then
        [[ $sh == bash && $b == .* && $a != .* ]] && return 1
        if [[ -n $3 ]]; then
            # The name of a file rule (_netrc, .env): a bare * or .* counts against every file
            # rule, so the glob must share at least two plain characters at its start or end
            pa=${a%%[*?[]*}
            sa=${a##*[]*?]}
            ((${#pa} >= 2 || ${#sa} >= 2)) || return 1
        fi
        if [[ $a == *[\(\)\|]* ]]; then a=${a//\(/\\\(}; a=${a//\)/\\\)}; a=${a//\|/\\\|}; fi
        [[ $b == $a ]]
        return
    fi
    # Two globs: the command's plain start must begin with the rule's, or be the start of it and
    # two characters long (id* for id_*); its plain end must end with the rule's (*.pem for *.pem).
    # A glob that leaves open what a rule fixes (k.* or n* for *.pem, *.md for .env.*) is not
    # counted: it could name such a file, but so could nearly every glob. A rule's glob without
    # plain characters (secret/*) is met by any glob, a bare * included
    pa=${a%%[*?[]*}
    sa=${a##*[]*?]}
    local pb=${b%%[*?[]*} sb=${b##*[]*?]}
    [[ ($pa == "$pb"* || (${#pa} -ge 2 && $pb == "$pa"*)) && $sa == *"$sb" ]]
}

# True when some path matches both the components WC[$1..] of a path or glob and RC[$2..] of a
# rule, where a ** in the rule stands for any number of components
could_match() {
    local i=$1 j=$2
    if ((j == ${#RC[@]})); then
        ((i == ${#WC[@]}))
        return
    fi
    if [[ ${RC[j]} == '**' ]]; then
        could_match "$i" $((j + 1)) && return 0
        ((i < ${#WC[@]})) && could_match $((i + 1)) "$j"
        return
    fi
    ((i < ${#WC[@]})) || return 1
    local strict=
    ((j == ${#RC[@]} - 1)) && strict=1
    comp_compat "${WC[i]}" "${RC[j]}" $strict && could_match $((i + 1)) $((j + 1))
}

# WC: the components of compare-form path $1; RC: those of rule $2's path, a folder rule's folder
# followed by **
split_word() {
    local IFS=/
    WC=(${1#/})
}
split_rule() {
    local IFS=$'\x1f'
    if [[ -n $2 ]]; then RC=(${RULE_RC_IN[$1]}); else RC=(${RULE_RC[$1]}); fi
}

# True when a search starting in the folder whose parts are WC (compare form) and OC (its own
# case) may reach a folder of folder rule $1; $2 is 1 when that folder is a glob. By the rule's
# kind (see add_rule): plain (no **), the search starts above the folder and the folder is there
# (one stat); start (archive/**/sealed), it starts above the fixed start and that is there, or
# anywhere inside it, since the ** may reach anywhere below; rest (**/inbox/x/y), the rest lies
# straight in it (one stat of <folder>/inbox/x/y, a part at a time) or the folder is the start of
# that rest (inbox, inbox/x, also as a glob: inbox/*) and, for a plain path, the remainder is there.
# A denied folder deeper below, reached only through a **, is not looked for: that would mean
# listing folders. A glob is never stat'ed, only compared.
holds_denied() {
    local i=$1 glob=$2 kind=${RULE_KIND[$1]} j k n=${#WC[@]} m rest plain
    local -a ac tc
    [[ $kind == none ]] && return 1
    [[ $kind == any ]] && return 0
    local IFS=$'\x1f'
    ac=(${RULE_AC[i]})
    tc=(${RULE_TC[i]})
    IFS=$' \t\n'
    m=${#ac[@]}
    if ((m)); then
        if ((n < m)); then
            # Above the fixed start or beside it: it reaches the start when that is there
            for ((k = 0; k < n; k++)); do comp_compat "${WC[k]}" "${ac[k]}" || return 1; done
            rest=${RULE_DIR[i]%%/'**'*}
            [[ $rest == *[*?[]* ]] && return 0
            exists "$rest"
            return
        fi
        for ((k = 0; k < m; k++)); do comp_compat "${WC[k]}" "${ac[k]}" || return 1; done
        # Inside a plain rule's folder: the path check saw it. Inside the fixed start of a start
        # rule: its rest is looked for below, as for a rule starting with **
        [[ $kind == start ]] || return 1
        ((${#tc[@]})) || return 0
        for k in "${tc[@]}"; do [[ $k == '**' || $k == *[*?[]* ]] && return 1; done
    fi
    for ((j = 0; j < ${#tc[@]} && j <= n; j++)); do
        for ((k = 0; k < j; k++)); do
            comp_compat "${WC[n - j + k]}" "${tc[k]}" || continue 2
        done
        rest=
        plain=1
        for ((k = 0; k < n - j; k++)); do
            [[ ${OC[k]} == *[*?[]* ]] && plain=0
            rest+=/${OC[k]}
        done
        if ((plain)); then
            exists_below "$rest" "${RULE_DIR[i]##*'**'/}" && return 0
        elif ((j)) && names_part "$i"; then
            return 0
        fi
    done
    return 1
}

# True when the word's parts WC name one of rule $1's plain parts after its first **: as that
# part, or with a glob that has two plain characters at its start or end and matches it
names_part() {
    local lit w pa sa
    local -a lits
    [[ -n ${RULE_LITS[$1]} ]] || return 0
    local IFS=$'\x1f'
    lits=(${RULE_LITS[$1]})
    IFS=$' \t\n'
    for w in "${WC[@]}"; do
        if [[ $w != *[*?[]* ]]; then
            for lit in "${lits[@]}"; do [[ $w == "$lit" ]] && return 0; done
        else
            pa=${w%%[*?[]*}
            sa=${w##*[]*?]}
            ((${#pa} >= 2 || ${#sa} >= 2)) || continue
            for lit in "${lits[@]}"; do comp_compat "$w" "$lit" && return 0; done
        fi
    done
    return 1
}

# True when the glob components WC can name a path rule $1 denies, as could_match tells. Most
# rules are **/<parts> or **/<parts>/**: for those a window of WC is compared in a loop, with a
# call only where a glob meets a part, since each call costs time in Git Bash.
glob_meets() {
    split_rule "$1" "$2"
    local n=${#WC[@]} s j k open=0 w r strict
    local -a tc
    if [[ ${RC[0]} == '**' ]]; then
        tc=("${RC[@]:1}")
        if ((${#tc[@]})) && [[ ${tc[-1]} == '**' ]]; then
            open=1
            unset 'tc[-1]'
        fi
        k=${#tc[@]}
        if ((k)) && [[ " ${tc[*]} " != *' ** '* ]]; then
            for ((s = 0; s + k <= n; s++)); do
                ((open || s + k == n)) || continue
                for ((j = 0; j < k; j++)); do
                    w=${WC[s + j]} r=${tc[j]}
                    [[ $w == "$r" ]] && continue
                    [[ $w != *[*?[]* && $r != *[*?[]* ]] && continue 2
                    strict=
                    ((!open && j == k - 1)) && strict=1
                    comp_compat "$w" "$r" $strict || continue 2
                done
                return 0
            done
            return 1
        fi
    fi
    could_match 0 0
}

# Blocks when the path or glob $1, as the command names it, is or reaches a denied path; $2 is 1
# when the program descends into folders. $3 is 1 when it lists a folder it is given (ls, dir) and
# 2 when it reads what is in one (an interpreter, robocopy, xcopy, copy, diff): then a path or
# glob naming a denied folder itself counts, and for 1 a file rule does not, as a listing shows
# only a file's name. A glob is compared with the rules component by
# component, never expanded.
check_path() {
    local word=$1 deep=$2 fs cmp i low glob=0 marked w inside=1 prx pa sa names=
    ((deep || $3)) && inside=
    # A listing without recursion shows a file's name, not its content: file rules do not count
    ((!deep && $3 == 1)) && names=1
    [[ -n $word ]] || return 0
    resolve_path "$CS_CWD" "$word"
    fs=$REPLY
    cmp_path "$fs"
    cmp=$REPLY
    # A script names the same paths again and again: each one is checked once
    [[ -n ${SEEN[$deep$inside:$cmp]+x} ]] && return 0
    SEEN[$deep$inside:$cmp]=1
    [[ $cmp == *[*?[]* ]] && glob=1
    if ((glob)); then
        split_word "$cmp"
        # The word with each glob part as \x03 or \x02, for the quick test of glob_meets
        marked=
        for w in "${WC[@]}"; do
            if [[ $w != *[*?[]* ]]; then
                marked+=/$w
            else
                pa=${w%%[*?[]*}
                sa=${w##*[]*?]}
                if ((${#pa} >= 2 || ${#sa} >= 2)); then marked+=/$'\x03'; else marked+=/$'\x02'; fi
            fi
        done
        for i in "${!RULE_CMP[@]}"; do
            if [[ -n $inside ]]; then prx=${RULE_PRX_IN[i]}; else prx=${RULE_PRX[i]}; fi
            [[ -n $names && -z ${RULE_DIR[i]} ]] && continue
            [[ -z $prx || $marked =~ $prx ]] || continue
            names_part "$i" || continue
            glob_meets "$i" "$inside" && block "$word" "may read a path" "$i"
        done
    else
        # Only a path holding a rule's plain name can match it; most hold none
        low=${cmp,,}
        for i in "${!RULE_RX[@]}"; do
            [[ -z ${RULE_FRAG[i]} || $low == *"${RULE_FRAG[i]}"* ]] || continue
            [[ -n $names && -z ${RULE_DIR[i]} ]] && continue
            if [[ -n $inside ]]; then prx=${RULE_RX_IN[i]}; else prx=${RULE_RX[i]}; fi
            [[ $cmp =~ $prx ]] && block "$word" "would read a path" "$i"
        done
    fi
    ((deep)) || return 0
    split_word "$cmp"
    case_path "$fs"
    local IFS=/
    OC=(${REPLY#/})
    IFS=$' \t\n'
    for i in "${!RULE_DIR[@]}"; do
        [[ -n ${RULE_DIR[i]} ]] || continue
        # A script searches the same folder again and again: each answer is kept
        if [[ -z ${HOLDS[$i:$fs]+x} ]]; then
            holds_denied "$i" "$glob"
            HOLDS[$i:$fs]=$?
        fi
        # Compared as a string: in (( )) the key would be expanded again, and a $( ) in the
        # command's path would run inside the hook
        [[ ${HOLDS[$i:$fs]} == 0 ]] && block "$word" "would search a folder holding what" "$i"
    done
}
declare -A HOLDS=() SEEN=()

# CMD_WORDS: the words from the program on, in bash read with their escapes
command_words() {
    local k
    CMD_WORDS=()
    for ((k = at; k < ${#words[@]}; k++)); do
        if [[ $sh == bash && -n ${seg_raw[k]+x} ]]; then
            cs_unescape "${seg_raw[k]}"
            CMD_WORDS+=("$REPLY")
        else
            CMD_WORDS+=("${words[k]}")
        fi
    done
}

# Handler for every reading program (CS_PROGRAMS); words, at, prog, sh, seg_raw, stdin and CS_CWD
# come from split_command
check_read() {
    local -a paths=()
    local deep=0 w l k code= flags rest lit filter_last=0 lists=0 interp=0 IFS=$' \t\n'
    local -a list
    local re_lit="([rR]?)('((\\\\.|[^'\\\\])*)'|\"((\\\\.|[^\"\\\\])*)\"|\`([^\`]*)\`)" raw q piped=0
    case $prog in
        find | du | tree | rg | ag | ack | fd | fdfind | grep | egrep | fgrep | ls | get-childitem | gci | dir)
            if search_args; then
                paths=("${SEARCH_PATHS[@]}")
                deep=$SEARCH_RECURSIVE
                ((deep && ${#paths[@]} == 0)) && paths=(.)
                # Get-ChildItem -Recurse *.md and dir /s *.md filter names: the search starts in
                # the folder of the glob
                [[ $sh != bash || $prog == get-childitem || $prog == gci ]] && filter_last=1
                # ls, dir and Get-ChildItem list a folder they are given
                [[ $prog == ls || $prog == dir || $prog == get-childitem || $prog == gci ]] && lists=1
            elif [[ $prog == find && $sh != bash ]]; then
                # The Windows FIND: a text search in the files it names
                command_words
                for w in "${CMD_WORDS[@]:1}"; do [[ $w == /* ]] || paths+=("$w"); done
            else
                return 0
            fi ;;
        python | python3 | py | node | perl | ruby | php)
            # os.listdir(x), Path(x) / name: a folder the code names by a path is read (a bare word
            # such as 'out' is far more often a key or a word of a message, see check_read's end)
            lists=2
            interp=1
            case $prog in
                python | python3 | py) flags=' -c ' ;;
                node) flags=' -e --eval -p --print ' ;;
                perl) flags=' -e -E ' ;;
                ruby) flags=' -e ' ;;
                php) flags=' -r ' ;;
            esac
            command_words
            for ((k = 1; k < ${#CMD_WORDS[@]}; k++)); do
                w=${CMD_WORDS[k]}
                if [[ $flags == *" $w "* ]]; then code=${CMD_WORDS[k+1]}; break; fi
                case $prog:$w in
                    python*:-X | python*:-W | py:-X | py:-W | node:-r | node:--require | node:--import | ruby:-r | ruby:-I | perl:-I | perl:-M) ((k++)) ;;
                    *:-*) ;;
                    *) return 0 ;;   # a script file, which is not read here
                esac
            done
            # No code and no script: the program reads its code from stdin, a here-document or the
            # command piped into it (echo "..." | python3, cat <<'EOF' | python3)
            if [[ -z $code ]]; then
                local IFS=$nl
                code="${heredocs[*]}"
                IFS=$' \t\n'
            fi
            if [[ -z $code && -n $stdin ]]; then
                code=${stdin//$'\x1e'/ }
                piped=1
            fi
            [[ -n $code ]] || return 0
            # Every quoted string in the code is a path to check, and so is each word of one that
            # holds a command (os.system('cat x'), perl's `cat x`)
            rest=$code
            while [[ $rest =~ $re_lit ]]; do
                raw=${BASH_REMATCH[1]}
                q=${BASH_REMATCH[2]:0:1}
                lit=${BASH_REMATCH[3]}${BASH_REMATCH[5]}${BASH_REMATCH[7]}
                rest=${rest#*"${BASH_REMATCH[0]}"}
                # 'data\n' is data and a line break, '\u00dc' one letter: escapes are read as the
                # language reads them, except in a raw string (r'C:\x'); perl, ruby and php keep
                # them in single quotes, all but \\ and \'; a line break ends the word's use as a
                # path
                if [[ -z $raw && $lit == *\\* && $q != '`' ]]; then
                    if [[ $prog == python* || $prog == py || $prog == node || $q == '"' ]]; then
                        lit_unescape "$lit"
                        lit=$REPLY
                    else
                        lit=${lit//\\\\/\\}
                        lit=${lit//\\\'/\'}
                    fi
                fi
                [[ -n $lit && $lit != *$nl* ]] || continue
                # A glob without a / or a drive is a pattern of the code (a regular expression,
                # '*' * 40), not a path
                [[ $lit == *[*?[]* && $lit != */* && ! $lit =~ ^[A-Za-z]:\\ ]] && continue
                paths+=("$lit")
                # The words of a literal that holds a command or prose, each by the same test
                if [[ $lit == *[[:space:]]* ]]; then
                    for w in $lit; do
                        [[ $w == *[*?[]* && $w != */* ]] && continue
                        paths+=("$w")
                    done
                fi
            done
            # Piped code arrives without its quotes: every word in it with a / or \ is a path
            if ((piped)); then
                rest=$code
                local re_tok='[^][(){}<>"`,;|&$[:space:]=]*[/\\][^][(){}<>"`,;|&$[:space:]=]*'
                rest=${rest//\'/ }
                while [[ $rest =~ $re_tok ]]; do
                    paths+=("${BASH_REMATCH[0]}")
                    rest=${rest#*"${BASH_REMATCH[0]}"}
                done
            fi ;;
        *)
            command_words
            # Options whose value is no path (skip), and programs whose first plain argument is
            # their program text or pattern, unless an option gave it (sed -e, awk -f, -Pattern)
            local skip=0 first=0 extract=0 v
            local vals=${VALUE_OPTS[$prog]-}
            [[ " $FIRST_IS_TEXT " == *" $prog "* ]] && first=1
            if [[ $prog == tar ]]; then
                # Extracting and listing read only the archive: the folders it names are targets
                l=${CMD_WORDS[1],,}
                [[ $l == --extract || $l == --get || $l == --list || ($l != --* && ${l#-} == *[xt]*) ]] && extract=1
                for w in "${CMD_WORDS[@]:1}"; do [[ $w == --extract || $w == --get || $w == --list ]] && extract=1; done
            fi
            # sed -e x, awk -f x, jq -f x, Select-String -Pattern x, findstr /c:x: the text comes
            # from an option, and the first plain argument is a path again
            if ((first)); then
                for w in "${CMD_WORDS[@]:1}"; do
                    case $prog:${w,,} in
                        sed:-e | sed:--expression | sed:-f | sed:--file | sed:-e?* | sed:--expression=* | sed:--file=* | \
                        awk:-f | gawk:-f | mawk:-f | awk:--file | gawk:--file | jq:-f | jq:--from-file | \
                        select-string:-pat | select-string:-patt* | sls:-pat | sls:-patt* | findstr:/c:* | findstr:/g:*) first=0; break ;;
                    esac
                done
            fi
            local pathvals=${PATH_OPTS[$prog]-}
            for ((k = 1; k < ${#CMD_WORDS[@]}; k++)); do
                w=${CMD_WORDS[k]}
                l=${w,,}
                if ((skip == 1)); then skip=0; continue; fi
                if ((skip == 2)); then skip=0; paths+=("$w"); continue; fi
                case $prog:$l in
                    cp:--recursive | cp:--archive | rsync:--recursive | rsync:--archive | gzip:--recursive | diff:--recursive) deep=1 ;;
                    *:--*) ;;
                    cp:-*[ra]* | rsync:-*[ra]* | zip:-*r* | gzip:-*r* | diff:-*r* | \
                    copy-item:-r | copy-item:-re | copy-item:-rec* | cpi:-r | cpi:-re | cpi:-rec* | copy:-rec* | \
                    xcopy:/s | xcopy:/e | robocopy:/s | robocopy:/e | robocopy:/mir | findstr:/s) deep=1 ;;
                esac
                if [[ $sh == powershell && $w == -*:?* ]]; then
                    # -Path:x glues the value to the parameter
                    w=${w#*:}
                elif [[ $w == -* ]]; then
                    if [[ $vals == *" $l "* ]]; then
                        skip=1
                    elif [[ $pathvals == *" $l "* ]]; then
                        # -Path x, sed -f x, awk -f x: a path, and not the program text
                        skip=2
                    fi
                    continue
                fi
                # The switches of cmd's programs start with / and have no second one (/s, /c:x)
                case $prog in
                    xcopy | robocopy | findstr | more | type) [[ $w =~ ^/[^/]*$ ]] && continue ;;
                esac
                if ((first)); then first=0; continue; fi
                if ((extract)); then
                    # tar -x -C dir: a target, and the archive the only file read
                    [[ ${CMD_WORDS[k-1]} == -C || ${CMD_WORDS[k-1]} == --directory ]] && continue
                fi
                paths+=("$w")
            done
            case $prog in
                tar) ((extract)) || deep=1 ;;
                7z | 7za | compress-archive) deep=1 ;;
                findstr | xcopy) filter_last=1 ;;
            esac
            # robocopy x y, xcopy x y, copy x y and diff x y read the files of folder x
            case $prog in
                robocopy | xcopy | copy | diff) lists=2 ;;
            esac ;;
    esac
    # A PowerShell reader without a path of its own reads the objects piped into it
    # (Get-ChildItem .env* | Get-Content): the words of the command before it count, as for xargs
    if [[ $sh == powershell && ${#paths[@]} == 0 && -n $stdin ]]; then
        case $prog in
            get-content | gc | cat | type | select-string | sls | import-csv | ipcsv | format-hex | fhx | more)
                local IFS=$'\x1e \t\n'
                for w in $stdin; do [[ $w == -* ]] || paths+=("$w"); done
                IFS=$' \t\n'
                lists=0 ;;
        esac
    fi
    # xargs adds the words piped into it to the program's arguments; the library keeps them apart
    # with \x1e, as xargs splits them at blanks and line breaks
    for ((k = 0; k < at; k++)); do
        if [[ ${words[k],,} == xargs ]]; then
            local IFS=$'\x1e \t\n'
            for w in $stdin; do [[ $w == -* ]] || paths+=("$w"); done
            IFS=$' \t\n'
            break
        fi
    done
    for w in "${paths[@]}"; do
        list=("$w")
        # A PowerShell list (a,b) and a bash brace list (x/{a,b}/y) name several paths
        if [[ $sh == powershell && $w == *,* ]]; then
            local IFS=,
            list=($w)
            IFS=$' \t\n'
        elif [[ $sh == bash && $w == *'{'*,*'}'* ]]; then
            brace_list "$w"
            list=("${BRACED[@]}")
        fi
        for l in "${list[@]}"; do
            # For inline code, a bare word names a folder only for what is in it, not the folder
            if ((interp)) && [[ $l != */* && $l != *\\* ]]; then
                check_path "$l" "$deep" 0
            else
                check_path "$l" "$deep" "$lists"
            fi
            # A recursive search whose last part is a glob of names (Get-ChildItem -Recurse *.md,
            # dir /s x\*.md, findstr /s w *.md) starts in the folder before it
            if ((deep && filter_last)) && [[ ${l##*[/\\]} == *[*?[]* ]]; then
                if [[ $l == *[/\\]* ]]; then check_path "${l%[/\\]*}" 1; else check_path . 1; fi
            fi
        done
    done
}

# REPLY: string literal $1 of inline code with its escapes read: \\ is \, \n \t \r and the like
# a line break, \xNN \uNNNN \N{...} and octal one character (_), anything else kept as written
lit_unescape() {
    local s=$1 out= c
    while [[ $s == *\\* ]]; do
        out+=${s%%\\*}
        s=${s#*\\}
        c=${s:0:1}
        case $c in
            \\) out+=\\; s=${s:1} ;;
            n | t | r | a | b | f | v) out+=$nl; s=${s:1} ;;
            x | u | U | N | [0-7]) out+=_; s=${s:1} ;;
            *) out+=\\ ;;
        esac
    done
    REPLY=$out$s
}

# BRACED: word $1 with its brace lists spelled out (a/{b,c}/d is a/b/d and a/c/d), as bash does
# before anything else; nested lists and more than 64 words are left as they are
brace_list() {
    local w re='^(.*)\{([^{}]*,[^{}]*)\}(.*)$' alt
    local -a todo=("$1") alts
    BRACED=()
    while ((${#todo[@]})); do
        w=${todo[0]}
        todo=("${todo[@]:1}")
        if [[ $w =~ $re ]] && ((${#BRACED[@]} + ${#todo[@]} < 64)); then
            local IFS=,
            alts=(${BASH_REMATCH[2]})
            IFS=$' \t\n'
            local pre=${BASH_REMATCH[1]} post=${BASH_REMATCH[3]}
            for alt in "${alts[@]}"; do todo+=("$pre$alt$post"); done
        else
            BRACED+=("$w")
        fi
    done
}

# Options whose value is no path, per program, between blanks (the value of -f, -o and the like
# that name a file the program reads is a path and stays one)
declare -A VALUE_OPTS=(
    [sed]=' -e --expression -l --line-length '
    [awk]=' -F -v --field-separator --assign '
    [gawk]=' -F -v --field-separator --assign '
    [mawk]=' -F -v '
    [cut]=' -d -f -c -b --delimiter --fields --characters --bytes --output-delimiter '
    [sort]=' -t -k -o -S -T --field-separator --key --output --buffer-size --temporary-directory '
    [head]=' -n -c --lines --bytes '
    [tail]=' -n -c --lines --bytes '
    [jq]=' --arg --argjson --indent '
    [select-string]=' -pattern -patter -patte -patt -pat -encoding -context '
    [sls]=' -pattern -patter -patte -patt -pat -encoding -context '
    [get-content]=' -encoding -totalcount -head -tail -readcount -delimiter -first -last '
    [gc]=' -encoding -totalcount -head -tail -readcount -delimiter -first -last '
    [tar]=' -T --files-from -X --exclude-from --exclude '
    [zip]=' -x -i '
)
# Options whose value is a path the program reads, per program
declare -A PATH_OPTS=(
    [sed]=' -f --file '
    [awk]=' -f --file '
    [gawk]=' -f --file '
    [mawk]=' -f '
    [jq]=' -f --from-file '
    [select-string]=' -path -literalpath -lp '
    [sls]=' -path -literalpath -lp '
    [get-content]=' -path -literalpath -lp '
    [gc]=' -path -literalpath -lp '
    [tar]=' -f --file '
)
# Programs whose first plain argument is their script or pattern: sed's script, awk's program,
# jq's filter, Select-String's and findstr's pattern
FIRST_IS_TEXT='sed awk gawk mawk jq yq select-string sls findstr'

# Handler for a project runner: uv run, poetry run and the like run the command after run, which
# is read like any other (uv run python -c ...); options of the runner before it are skipped
check_runner() {
    local j=$((at + 1)) n=${#words[@]}
    [[ ${words[j]} == run ]] || return 0
    for ((j++; j < n; j++)); do
        case ${words[j]} in
            --with | --with-requirements | --python | -p | --project | --directory | --package | --extra | --group | --env-file | --index | --from | -e | --env) ((j++)) ;;
            --) ((j++)); break ;;
            -*) ;;
            *) break ;;
        esac
    done
    ((j < n)) || return 0
    local -a sub=()
    for ((; j < n; j++)); do
        if [[ $sh == bash && -n ${seg_raw[j]+x} ]]; then
            cs_unescape "${seg_raw[j]}"
            sub+=("$REPLY")
        else
            sub+=("${words[j]}")
        fi
    done
    _cs_sub "${sub[@]}"
    return 0
}

for p in $CS_SEARCH_TOOLS cat tac head tail less more most bat batcat nl od xxd hexdump strings base64 base32 \
    sed awk gawk mawk cut sort uniq wc diff cmp comm paste join file iconv jq yq type md5sum sha1sum sha256sum \
    get-content gc select-string sls format-hex fhx import-csv ipcsv findstr \
    cp copy copy-item cpi robocopy xcopy rsync tar zip 7z 7za gzip compress-archive \
    python python3 py node perl ruby php; do
    CS_PROGRAMS[$p]=check_read
done
for p in uv poetry pipenv pdm hatch; do CS_PROGRAMS[$p]=check_runner; done

# In bash X:\ before a shell character or a space stays a drive root, as in the search guard
if [[ $tool == Bash && $command == *:\\* ]]; then
    for c in ' ' '(' ')' '|' '&' ';' '<' '>' '!'; do command=${command//":\\$c"/":\\\\$c"}; done
fi
json_field cwd
resolve_path / "${REPLY:-$PWD}"
CS_CWD=$REPLY
shopt -u nocasematch
split_command "$command" "${tool,,}" ""
exit 0
