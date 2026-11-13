# Sourced by guard-git.sh, block-commit-secrets.sh, block-remote-access.sh,
# block-profile-wide-search.sh and block-denied-reads.sh; not a hook itself.
# Splits a shell command line into simple commands, so that a guard looks only at the program at
# command position and its arguments. Text inside a quoted message or a here-document is never
# taken for a command: a `gh issue comment` whose body mentions `git push origin main`, or a
# `grep ssh`, is not what it mentions. Plain bash, like the hooks: no node, jq or python.
#
# split_command TEXT SHELL CALLBACK
#   SHELL is bash, powershell or cmd. Bodies of here-documents (<<EOF, <<-'EOF', also the
#   "$(cat <<'EOF' ... EOF)" form of a commit message) and of PowerShell here-strings (@' ... '@,
#   @" ... "@) are taken out first. The rest is split at && || ; | & ( ) and line breaks outside
#   quotes, in bash also at a backquote; a # starting a word comments out the rest of the line.
#   Redirections are dropped with their target. For every simple command the handler the hook
#   named for its program in CS_PROGRAMS (CS_PROGRAMS[git]=check_git), else CALLBACK when it is
#   not empty, runs with
#     words     its words, quotes removed and escapes kept (C:\x stays C:\x)
#     seg_raw   the raw text of each word that had quotes or escapes, at the same index; unset for
#               the others, whose raw text is the word (cs_unescape reads one as bash does)
#     sh        the shell the command runs in: bash, powershell or cmd
#     at        the index of the program: VAR=value assignments, keywords (if, then, do, !, {)
#               and wrappers (env, sudo, command, exec, nohup, nice, time, timeout, stdbuf, watch,
#               xargs) skipped
#     prog      the program's name: lower case, without folder and .exe
#     heredocs  the bodies of the here-documents and here-strings in it
#     stdin     the words and here-documents of the command piping into it, if one does
#     CS_CWD    the directory it runs in: set by the hook from the payload's cwd, followed through
#               every cd, pushd, chdir, Set-Location, sl and Push-Location before it, whose
#               target in bash is read with its escapes (cd Team\ Files); cd - goes back to the
#               folder before (CS_PREV), popd and Pop-Location to the one pushd left
#               (CS_STACK), and either stays put when that is not known; cmd's cd /d X goes to X
#   command -v and -V run nothing, so no handler sees the program they name.
#   A wrapper whose argument is a command line (bash/sh -c, cmd /c, powershell/pwsh -c or a bare
#   command, wsl, watch "...") is unwrapped one level: CALLBACK sees the commands inside, not the
#   wrapper; so is the command of find -exec/-execdir/-ok/-okdir.
#   A quote without its closing partner is skipped, so the rest is split strictly.
# Not modelled: $(...) and backquotes inside double quotes (only the here-documents found there),
# aliases, functions, variables, eval, scripts, and a cd inside a subshell, which is taken as if it
# lasted to the end of the line.
# Every call costs the tool time and Git Bash forks slowly, so nothing here starts a process, and
# the scan is linear in the length of the command (see _cs_fill).

nl=$'\n'
tab=$'\t'
declare -A CS_PROGRAMS=()
CS_PREV=
CS_STACK=()

# input: the hook's payload from stdin. read takes a pipe byte by byte (200 ms for 60 KB), cat
# costs a process (40 ms): read takes the first 4 KB, cat the rest of a larger payload. In bytes:
# read -N in a UTF-8 locale damages a character outside ASCII in Git Bash, and ${#input} must
# count what read counted.
read_input() {
    local LC_ALL=C
    IFS= read -r -N 4096 input
    ((${#input} < 4096)) || input+=$(cat)
}

# REPLY: the JSON string value of the first key with this exact name, unescaped. With $2, it is
# looked for in the first $2 bytes first: a regular expression over a payload of 60 KB costs 100 ms,
# and tool_name and cwd come before the tool's input.
field() {
    local re='"'"$1"'"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"' s src=$input
    REPLY=
    if [[ -n $2 ]]; then
        src=${input:0:$2}
        [[ $src =~ $re ]] || src=$input
    fi
    [[ $src =~ $re ]] || return 0
    s=${BASH_REMATCH[1]}
    s=${s//\\\\/$'\x01'}
    s=${s//\\\"/\"}
    s=${s//\\n/$'\n'}
    s=${s//\\t/$'\t'}
    s=${s//\\r/}
    s=${s//\\\//\/}
    REPLY=${s//$'\x01'/\\}
}

# REPLY: path $2 seen from directory $1, with forward slashes; ~ and the profile variables expanded
resolve_path() {
    local p=${2//\\//} pre lp
    lp=${p,,}
    # Without case, as PowerShell and cmd read them ($Env:USERPROFILE, %UserProfile%, $Home)
    for pre in '$userprofile' '${userprofile}' '$env:userprofile' '${env:userprofile}' '%userprofile%' '$home' '${home}' '$env:home' '~'; do
        if [[ $lp == "$pre" || $lp == "$pre"/* ]]; then
            p=${HOME//\\//}${p:${#pre}}
            break
        fi
    done
    if [[ $p == /* || $p =~ ^[A-Za-z]: ]]; then REPLY=$p; else REPLY=${1%/}/$p; fi
}

# REPLY: the raw bash word $1 (from seg_raw) with its quotes removed and each escape read as bash
# reads it. Outside quotes a shell character, space, backslash or quote after \ is that character
# (`\(`, `Team\ Files`); before anything else the backslash stays, so C:\Users stays a path. In
# double quotes \ before \ " $ or ` is that character. It jumps from one \ ' " to the next, as one
# character at a time costs seconds on a long quoted word in Git Bash.
cs_unescape() {
    local s=$1 out= head nx
    while [[ -n $s ]]; do
        head=${s%%[\\\'\"]*}
        out+=$head
        s=${s:${#head}}
        case ${s:0:1} in
            "'")
                s=${s:1}
                head=${s%%\'*}
                out+=$head
                s=${s:${#head}+1} ;;
            '"')
                s=${s:1}
                while [[ -n $s ]]; do
                    head=${s%%[\\\"]*}
                    out+=$head
                    s=${s:${#head}}
                    [[ -z $s ]] && break
                    [[ ${s:0:1} == '"' ]] && { s=${s:1}; break; }
                    nx=${s:1:1}
                    [[ -n $nx && '\"$`' == *"$nx"* ]] || out+='\'
                    out+=$nx
                    s=${s:2}
                done ;;
            '\')
                nx=${s:1:1}
                [[ -n $nx && " ()|&;<>!\\'\"" == *"$nx"* ]] || out+='\'
                out+=$nx
                s=${s:2} ;;
        esac
    done
    REPLY=$out
}

# REPLY: an absolute path from resolve_path in one spelling, for comparing: C:/X and /c/x both
# become /c/x, . and .. are resolved, a trailing / goes
norm_path() {
    local p=${1,,} out="" part
    if [[ $p =~ ^([a-z]):(/.*)?$ ]]; then p=/${BASH_REMATCH[1]}${BASH_REMATCH[2]}; fi
    local IFS=/ -
    set -f
    for part in $p; do
        case $part in
            '' | .) ;;
            ..) out=${out%/*} ;;
            *) out=$out/$part ;;
        esac
    done
    REPLY=${out:-/}
}

# REPLY: the root of the repository holding folder $1 (the nearest folder with a .git, a file in a
# worktree or a submodule), or empty; false when there is none. Answers are kept per folder.
declare -A CS_ROOTS=()
repo_root() {
    local d=${1%/}
    if [[ -n ${CS_ROOTS[$d]+x} ]]; then
        REPLY=${CS_ROOTS[$d]}
        [[ -n $REPLY ]]
        return
    fi
    REPLY=
    local up=$d
    while [[ -n $up ]]; do
        if [[ -e $up/.git ]]; then REPLY=$up; break; fi
        [[ $up == */* ]] || break
        up=${up%/*}
    done
    CS_ROOTS[$d]=$REPLY
    [[ -n $REPLY ]]
}

# REPLY: the text with here-document and here-string bodies replaced by markers; the bodies are
# appended to HD, which split_command declares
_cs_extract() {
    local text=$1 out="" m lead dash delim prefix rest line after e body re_end q
    if [[ $2 == powershell ]]; then
        if [[ $text == *@[\'\"]* ]]; then
            local re_open="@(['\"])[ $tab]*$nl"
            while [[ $text =~ $re_open ]]; do
                m=${BASH_REMATCH[0]}
                q=${BASH_REMATCH[1]}
                prefix=${text%%"$m"*}
                after=${text:${#prefix}+${#m}}
                re_end="(^|$nl)$q@"
                if [[ $after =~ $re_end ]]; then
                    e=${BASH_REMATCH[0]}
                    body=${after%%"$e"*}
                    HD+=("$body")
                    out+="$prefix __HERESTRING_$((${#HD[@]} - 1))__ "
                    text=${after:${#body}+${#e}}
                else
                    out+=$prefix$m
                    text=$after
                fi
            done
        fi
    elif [[ $text == *'<<'* ]]; then
        local re_op="(^|[^<])<<(-?)[ $tab]*('([A-Za-z_][A-Za-z0-9_]*)'|\"([A-Za-z_][A-Za-z0-9_]*)\"|\\\\?([A-Za-z_][A-Za-z0-9_]*))"
        while [[ $text =~ $re_op ]]; do
            m=${BASH_REMATCH[0]}
            lead=${BASH_REMATCH[1]}
            dash=${BASH_REMATCH[2]}
            delim=${BASH_REMATCH[4]}${BASH_REMATCH[5]}${BASH_REMATCH[6]}
            prefix=${text%%"$m"*}
            rest=${text:${#prefix}+${#m}}
            [[ $rest == *"$nl"* ]] || break
            line=${rest%%"$nl"*}
            after=${rest#*"$nl"}
            if [[ -n $dash ]]; then re_end="(^|$nl)$tab*$delim($nl|\$)"; else re_end="(^|$nl)$delim($nl|\$)"; fi
            if [[ $after =~ $re_end ]]; then
                e=${BASH_REMATCH[0]}
                body=${after%%"$e"*}
                HD+=("$body")
                out+="$prefix$lead __HEREDOC_$((${#HD[@]} - 1))__ "
                text=$line$nl${after:${#body}+${#e}}
            else
                # No line ends it: an operator inside a quoted text, not a here-document
                out+=$prefix$m
                text=$rest
            fi
        done
    fi
    REPLY=$out$text
}

# The scan works on buf, about 1 KB of the text at a time, refilled from it in chunks. In this
# bash every ${s:pos:n} and ${#s} costs time in proportion to all of s, so a scan that indexed into
# the text, or cut a word off its front, per word was quadratic: a 60 KB command took minutes, the
# hook ran into its timeout, and the command went through unchecked. cpos is where buf ends in the
# text, blen the length of buf, kept by arithmetic for the same reason. Plain words are split by
# the shell's own word splitting, a whole run at a time, since every bash operation costs.

# Appends the next chunk of the text to buf; false when there is none
_cs_fill() {
    ((cpos < len)) || return 1
    local chunk=${text:cpos:1024}
    buf+=$chunk
    ((blen += ${#chunk}, cpos += ${#chunk}))
}

# Drops the first $1 bytes of buf; a buf grown large by a long word is cut back to one chunk
_cs_drop() {
    buf=${buf:$1}
    ((blen -= $1))
    if ((blen > 4096)); then
        ((cpos -= blen))
        buf=
        blen=0
        _cs_fill
    fi
}

# REPLY: the match of regex $1 (anchored with ^) at the start of buf. It is tried on a window of
# 256 bytes, widened fourfold while the word may go on past it (it fills the window, or stops at a
# quote that does not close inside it), so the work per word grows with the word.
_cs_match() {
    local size=256 win more
    while :; do
        while ((blen < size)) && _cs_fill; do :; done
        win=${buf:0:size}
        ((more = blen > size || cpos < len))
        if [[ $win =~ $1 ]]; then
            REPLY=${BASH_REMATCH[0]}
            ((more)) || return 0
            [[ ${#REPLY} -lt ${#win} && ${win:${#REPLY}:1} != [\'\"] ]] && return 0
        elif ((!more)) || [[ ${win:0:1} != [\'\"] ]]; then
            return 1
        fi
        ((size *= 4))
    done
}

# REPLY: buf up to the next line break, without it
_cs_line() {
    while [[ $buf != *"$nl"* ]] && _cs_fill; do :; done
    REPLY=${buf%%"$nl"*}
}


# REPLY: word $1 with its here-document markers taken out and their bodies added to heredocs;
# false when nothing is left of it (a bare <<EOF is a redirection, not a word)
_cs_marker() {
    local tok=$1
    while [[ $tok =~ __HERE(DOC|STRING)_([0-9]+)__ ]]; do
        heredocs+=("${HD[${BASH_REMATCH[2]}]}")
        marked=1
        if [[ ${BASH_REMATCH[1]} == DOC ]]; then
            tok=${tok/"${BASH_REMATCH[0]}"/}
        else
            tok=${tok/"${BASH_REMATCH[0]}"/__HERESTRING__}
        fi
    done
    REPLY=$tok
    [[ -n $tok ]]
}

# Takes plain text $1 (no quotes, escapes, redirections or comments): its words join the current
# command, its separators end it. The text is cut at the separators, and each piece becomes words
# by one word splitting: per word, even two operations made a 60 KB command take seconds.
_cs_plain() {
    local r=$1 piece p first handler at=0 prog stdin
    local - IFS
    set -f
    if ((skip)); then
        # The target of a redirection before it: its first word goes
        r=${r#"${r%%[!$' \t\r']*}"}
        first=${r%%[$' \t\r;|&()'$nl]*}
        r=${r:${#first}}
        # Only blanks: the target is the quoted or escaped word after them (> "out.txt")
        [[ -n $first || -n $r ]] && skip=0
    fi
    if [[ $r == *[\;\|\&\(\)$nl]* ]]; then
        # && and || end a command without piping into the next, as ; does
        r=${r//&&/$'\x1e;\x1e'}
        r=${r//||/$'\x1e;\x1e'}
        r=${r//;/$'\x1e;\x1e'}
        r=${r//|/$'\x1e|\x1e'}
        r=${r//&/$'\x1e&\x1e'}
        r=${r//(/$'\x1e(\x1e'}
        r=${r//)/$'\x1e)\x1e'}
        r=${r//$nl/$'\x1e;\x1e'}
    fi
    IFS=$'\x1e'
    local -a pieces=($r)
    for piece in "${pieces[@]}"; do
        case $piece in
            ';' | '&' | '|' | '(' | ')')
                # _cs_end, inlined: a function call costs about 60 microseconds in Git Bash. A
                # doubled separator (&&, ||, ;;) ends an empty command the second time; the second
                # | of || drops what the first one piped.
                if ((${#words[@]})); then
                    # Only a command some handler or the dispatch itself cares about is dispatched
                    p=${words[0],,}
                    case $p in
                        *=*) ;;   # an assignment, whose value may hold a / (TMPDIR=/tmp/x)
                        */* | *\\* | *.exe) p=${p##*[/\\]}; p=${p%.exe} ;;
                    esac
                    case $p in
                        *=* | '$'* | env | sudo | command | builtin | exec | nohup | nice | time | timeout | stdbuf | watch | xargs | if | then | else | elif | do | while | until | '!' | '{' | '}' | \
                        cd | pushd | popd | chdir | set-location | sl | push-location | pop-location | find | bash | sh | zsh | dash | ksh | cmd | powershell | pwsh | wsl)
                            IFS=' '
                            _cs_dispatch
                            IFS=$'\x1e' ;;
                        *)
                            # No prefix and no wrapper: the handler runs without the dispatch
                            handler=${CS_PROGRAMS[${p:-_}]:-$cb}
                            if [[ -n $handler ]]; then
                                IFS=' '
                                prog=$p
                                stdin=$stdin_text
                                "$handler"
                                IFS=$'\x1e'
                            fi ;;
                    esac
                    if [[ $piece == '|' ]]; then stdin_text="${words[*]}$nl${heredocs[*]}"; else stdin_text=; fi
                    words=()
                    if ((marked)); then
                        seg_raw=()
                        heredocs=()
                        marked=0
                    fi
                else
                    stdin_text=
                fi ;;
            *__HERE*)
                IFS=$' \t\r'
                for p in $piece; do
                    _cs_marker "$p" && words+=("$REPLY")
                done
                IFS=$'\x1e' ;;
            *)
                IFS=$' \t\r'
                words+=($piece)
                IFS=$'\x1e' ;;
        esac
    done
}

# REPLY: the raw words of the current command from index $1 on, joined by blanks. seg_raw holds
# the raw text only of words that had quotes or escapes; the others are their own raw text.
_cs_raw_from() {
    local k
    REPLY=
    for ((k = $1; k < n; k++)); do
        REPLY+="${seg_raw[k]-${words[k]}} "
    done
    REPLY=${REPLY% }
}

# REPLY: the command line that cmd /c or powershell -c gets from the words from index $1 on. A
# single quoted or escaped argument in bash is read as bash reads it (cmd //c "find /c \"x\""),
# else the raw words are joined and one pair of enclosing quotes goes.
_cs_inner() {
    if [[ $sh == bash && $1 -eq $((n - 1)) && -n ${seg_raw[$1]+x} ]]; then
        cs_unescape "${seg_raw[$1]}"
    else
        _cs_raw_from "$1"
        _cs_unquote "$REPLY"
    fi
}

split_command() {  # text shell callback [depth]
    local sh=$2 cb=$3 depth=${4:-0}
    local -a HD=() words=() seg_raw=() heredocs=()
    local text buf="" blen=0 cpos=0 len win c run trail tok raw op skip=0 glued=0 marked=0 stdin_text=""
    local plain esc dq re_word re_sep re_redir
    _cs_extract "$1" "$sh"
    text=$REPLY
    case $sh in
        powershell)
            text=${text//\`$nl/ }
            plain='[^][:space:]'"'"'"`;|&()<>]|[][]'; esc='`.'; dq='"([^"`]|`.)*"'
            re_sep="^(&&|\\|\\||;|\\||&|\\(|\\)|$nl)" ;;
        cmd)
            plain='[^][:space:]"^;|&()<>]|[][]'; esc='\^.'; dq='"[^"]*"'
            re_sep="^(&&|\\|\\||;|\\||&|\\(|\\)|$nl)" ;;
        *)
            # A backslash ending a line joins the lines, also inside a word (~/One\<newline>Drive).
            # shortcut: an escaped backslash at a line's end (echo a\\) joins too, which bash
            # does not do; count the backslashes before the line break if that shows up in use.
            text=${text//\\$nl/}
            plain='[^][:space:]'"'"'"`;|&()<>\]|[][]'; esc='\\.'; dq='"([^"\\]|\\.)*"'
            re_sep="^(&&|\\|\\||\\|&|;;|;|\\||&|\\(|\\)|\`|$nl)" ;;
    esac
    re_word="^(($plain)|$esc|'[^']*'|$dq)+"
    re_redir='^(\*|[0-9]*)(&>>|&>|>>|>\||>&|<&|<>|<<<|>|<)'
    len=${#text}
    while :; do
        ((blen < 256)) && _cs_fill
        ((blen > 0)) || break
        # Plain text up to the next quote, escape, redirection or comment, in one step
        case $sh in
            powershell) run=${buf%%[\'\"\`\<\>\#]*} ;;
            cmd) run=${buf%%[\"^\<\>\#]*} ;;
            *) run=${buf%%[\'\"\`\\\<\>\#]*} ;;
        esac
        if [[ -n $run ]]; then
            if ((${#run} < blen || cpos < len)); then
                # Its last word may go on past it (into a quote, an escape, a 2>, the next chunk):
                # the pattern below reads that one whole
                trail=${run##*[$' \t\r;|&()'$nl]}
                run=${run:0:${#run}-${#trail}}
            fi
            if [[ -n $run ]]; then
                _cs_drop ${#run}
                _cs_plain "$run"
                glued=0
                continue
            fi
        fi
        win=${buf:0:256}
        c=${win:0:1}
        if [[ $c == '#' && $glued == 0 ]]; then
            # A comment: skipped up to the line break, which then ends the command
            _cs_line
            _cs_drop ${#REPLY}
        elif [[ $c == [\<\>\&*0-9] && $win =~ $re_redir ]]; then
            op=${BASH_REMATCH[0]}
            _cs_drop ${#op}
            if [[ $op == *'&' && ${buf:0:32} =~ ^[0-9-]+ ]]; then _cs_drop ${#BASH_REMATCH[0]}; else skip=1; fi
            glued=0
        elif [[ $c == [\;\|\&\(\)\`$nl] && $win =~ $re_sep ]]; then
            op=${BASH_REMATCH[0]}
            _cs_drop ${#op}
            skip=0
            glued=0
            _cs_end "$op"
        elif _cs_match "$re_word"; then
            raw=$REPLY
            _cs_drop ${#raw}
            glued=1
            ((skip)) && { skip=0; continue; }
            tok=$raw
            if [[ $tok == *__HERE* ]]; then
                _cs_marker "$tok" || continue
                tok=$REPLY
            fi
            tok=${tok//\'/}
            tok=${tok//\"/}
            seg_raw[${#words[@]}]=$raw
            marked=1
            words+=("$tok")
        else
            _cs_drop 1
            glued=0
        fi
    done
    _cs_end ""
}

# Ends the current simple command at separator $1 and hands it on
_cs_end() {
    local piped=""
    if ((${#words[@]})); then
        _cs_dispatch
        [[ $1 == '|' || $1 == '|&' ]] && piped="${words[*]}$nl${heredocs[*]}"
    fi
    stdin_text=$piped
    words=()
    seg_raw=()
    heredocs=()
    marked=0
}

# REPLY: word $1 without one pair of enclosing quotes
_cs_unquote() {
    REPLY=$1
    if [[ ${#REPLY} -ge 2 && ($REPLY == \"*\" || $REPLY == \'*\') ]]; then
        REPLY=${REPLY:1:${#REPLY}-2}
    fi
}

# Runs the dispatch for the words $@ in place of the current ones (the command of find -exec)
_cs_sub() {
    local -a words=("$@") seg_raw=()
    _cs_dispatch
}

# Splits text $1 as shell $2 for a child process (bash -c, cmd /c, powershell -c, wsl, watch): a
# cd, pushd or popd inside it ends with it
_cs_child() {
    local CS_CWD=$CS_CWD CS_PREV=$CS_PREV
    local -a CS_STACK=("${CS_STACK[@]}")
    split_command "$1" "$2" "$cb" 1
}

_cs_dispatch() {
    local stdin=$stdin_text at=0 n=${#words[@]} j k prog target inner watched=0 handler wrapper
    # Assignments, keywords and wrappers in front of the program; most commands have none
    prog=${words[0],,}
    case $prog in
        *=* | '$'* | env | sudo | command | builtin | exec | nohup | nice | time | timeout | stdbuf | watch | xargs | if | then | else | elif | do | while | until | '!' | '{' | '}')
            while ((at < n)); do
                if [[ ${words[at]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
                    ((at++))
                    continue
                fi
                # A PowerShell assignment of a command's output: $files = Get-ChildItem ...; one
                # to $env: sets the environment, which a handler may read ($env:DOCKER_HOST = ...)
                if [[ $sh == powershell && ${words[at]} == '$'* && ${words[at],,} != '$env:'* && ${words[at+1]} =~ ^[-+*/]?=$ ]]; then
                    ((at += 2))
                    continue
                fi
                case ${words[at],,} in
                    env | sudo | command | builtin | exec | nohup | nice | time | timeout | stdbuf | watch)
                        wrapper=${words[at],,}
                        # command -v and -V look a program up and run nothing
                        [[ $wrapper == command && ${words[at+1]} =~ ^-p?[vV] ]] && return 0
                        [[ $wrapper == watch ]] && watched=1
                        ((at++))
                        while ((at < n)) && [[ ${words[at]} == -* || ${words[at]} =~ ^[0-9.]+[smhd]?$ ]]; do
                            # Options with a value (timeout -s KILL, sudo -u x, watch -n 2)
                            case $wrapper:${words[at]} in
                                watch:-n | watch:--interval | timeout:-s | timeout:--signal | timeout:-k | timeout:--kill-after | \
                                sudo:-u | sudo:--user | sudo:-g | sudo:--group | sudo:-h | sudo:--host | sudo:-p | sudo:--prompt | sudo:-C | sudo:-D | sudo:--chdir | \
                                env:-u | env:--unset | env:-C | env:--chdir) ((at++)) ;;
                            esac
                            ((at++))
                        done ;;
                    xargs)
                        ((at++))
                        while ((at < n)) && [[ ${words[at]} == -* ]]; do
                            case ${words[at]} in -I | -n | -P | -L | -d | -s | -E | -a | --max-args | --max-procs | --delimiter | --arg-file) ((at++)) ;; esac
                            ((at++))
                        done ;;
                    if | then | else | elif | do | while | until | '!' | '{' | '}') ((at++)) ;;
                    *) break ;;
                esac
            done ;;
    esac
    ((at < n)) || return 0
    if ((watched && depth == 0)) && [[ ${words[at]} == *' '* ]]; then
        # watch "ssh host": watch hands its text to sh -c
        _cs_child "${words[*]:at}" bash
        return 0
    fi
    ((at)) && prog=${words[at],,}
    prog=${prog##*[/\\]}
    prog=${prog%.exe}
    case $prog in
        popd | pop-location)
            # Back to the folder the matching pushd left, which is unknown before the first one
            if ((${#CS_STACK[@]})); then
                CS_CWD=${CS_STACK[-1]}
                unset 'CS_STACK[-1]'
            fi
            return 0 ;;
        cd | pushd | chdir | set-location | sl | push-location)
            target=
            for ((j = at + 1; j < n; j++)); do
                case ${words[j],,} in
                    -path | -literalpath) target=${words[j+1]}; break ;;
                    -) target=-; break ;;
                    /d) [[ $sh == cmd ]] && continue; target=${words[j]}; break ;;   # cmd's cd /d X
                    -*) ;;
                    *)
                        target=${words[j]}
                        if [[ $sh == bash && -n ${seg_raw[j]+x} ]]; then
                            cs_unescape "${seg_raw[j]}"
                            target=$REPLY
                        fi
                        break ;;
                esac
            done
            if [[ $target == - ]]; then
                # Back to the folder before, which is unknown before the first cd of the command
                if [[ -n $CS_PREV ]]; then
                    target=$CS_PREV
                    CS_PREV=$CS_CWD
                    CS_CWD=$target
                fi
            elif [[ -n $target ]]; then
                [[ $prog == pushd || $prog == push-location ]] && CS_STACK+=("$CS_CWD")
                CS_PREV=$CS_CWD
                resolve_path "$CS_CWD" "$target"
                CS_CWD=$REPLY
            elif [[ $prog == cd && $sh == bash ]]; then
                CS_PREV=$CS_CWD
                CS_CWD=${HOME//\\//}
            fi
            return 0 ;;
        find)
            for ((j = at + 1; j < n; j++)); do
                case ${words[j]} in
                    -exec | -execdir | -ok | -okdir)
                        for ((k = j + 1; k < n; k++)); do
                            [[ ${words[k]} == ';' || ${words[k]} == '\;' || ${words[k]} == '+' ]] && break
                        done
                        ((k > j + 1)) && _cs_sub "${words[@]:j+1:k-j-1}"
                        j=$k ;;
                esac
            done ;;
    esac
    if ((depth == 0)); then
        case $prog in
            bash | sh | zsh | dash | ksh)
                for ((j = at + 1; j < n; j++)); do
                    if [[ ${words[j]} =~ ^-[a-z]*c[a-z]*$ ]]; then
                        if [[ $sh == bash && -n ${seg_raw[j+1]+x} ]]; then
                            cs_unescape "${seg_raw[j+1]}"
                        else
                            _cs_unquote "${seg_raw[j+1]-${words[j+1]}}"
                        fi
                        _cs_child "$REPLY" bash
                        return 0
                    fi
                    [[ ${words[j]} == -* ]] || break
                done ;;
            cmd)
                for ((j = at + 1; j < n; j++)); do
                    case ${words[j],,} in
                        /c | //c | /k | //k)
                            _cs_inner $((j + 1))
                            _cs_child "$REPLY" cmd
                            return 0 ;;
                        /*) ;;
                        *) break ;;
                    esac
                done ;;
            powershell | pwsh)
                for ((j = at + 1; j < n; j++)); do
                    case ${words[j],,} in
                        -c | -co | -com | -comm | -comma | -comman | -command)
                            _cs_inner $((j + 1))
                            _cs_child "$REPLY" powershell
                            return 0 ;;
                        -f | -fi | -fil | -file | -e | -ec | -en* | -encodedcommand) break ;;
                        -executionpolicy | -ex | -ep | -windowstyle | -w | -workingdirectory | -wd | -configurationname | -outputformat | -o | -of | -inputformat | -if | -settingsfile | -version | -v) ((j++)) ;;
                        -*) ;;
                        *)
                            _cs_inner $j
                            _cs_child "$REPLY" powershell
                            return 0 ;;
                    esac
                done ;;
            wsl)
                for ((j = at + 1; j < n; j++)); do
                    case ${words[j],,} in
                        -e | --exec | --)
                            _cs_raw_from $((j + 1))
                            _cs_child "$REPLY" bash
                            return 0 ;;
                        -d | --distribution | -u | --user | --cd) ((j++)) ;;
                        -*) ;;
                        *)
                            _cs_raw_from $j
                            _cs_child "$REPLY" bash
                            return 0 ;;
                    esac
                done ;;
        esac
    fi
    handler=${CS_PROGRAMS[$prog]:-$cb}
    [[ -n $handler ]] && "$handler"
    return 0
}

# For a git command at words[at]: GIT_DIR_AT (the directory it runs in, CS_CWD followed through
# every -C), GIT_SETTINGS (the values of -c and --config-env) and GIT_VERB (the index of the
# subcommand, or n when there is none)
git_split() {
    local i=$((at + 1)) n=${#words[@]}
    GIT_DIR_AT=$CS_CWD
    GIT_SETTINGS=()
    while ((i < n)); do
        case ${words[i]} in
            -C) resolve_path "$GIT_DIR_AT" "${words[i+1]}"; GIT_DIR_AT=$REPLY; ((i += 2)) ;;
            -c | --config-env) GIT_SETTINGS+=("${words[i+1]}"); ((i += 2)) ;;
            --config-env=*) GIT_SETTINGS+=("${words[i]#*=}"); ((i++)) ;;
            --git-dir | --work-tree | --namespace | --super-prefix | --list-cmds) ((i += 2)) ;;
            -*) ((i++)) ;;
            *) break ;;
        esac
    done
    GIT_VERB=$i
}

# For the arguments of `git commit` from index $1 of words: COMMIT_ALL (-a, --all), COMMIT_NOVERIFY
# (-n, --no-verify), COMMIT_FILES (the files of -F, --file, -t, --template), COMMIT_SPECS (the
# paths it names), COMMIT_REUSED (the commits whose message and author it takes: -C, -c,
# --reuse-message, --reedit-message), COMMIT_AMEND (--amend: HEAD's author is kept),
# COMMIT_RESET_AUTHOR (--reset-author, the last of it and --no-reset-author: no author is taken
# over), COMMIT_AUTHORS (the values of --author), COMMIT_MESSAGES (the commits whose message only
# it takes: --fixup=amend:/reword:) and COMMIT_SUBJECTS (those whose subject line it takes: a plain
# --fixup, --squash). Option values are skipped, so a message is never read as an option.
commit_parse() {
    local j=$1 n=${#words[@]} a k c v after=0
    COMMIT_ALL=0
    COMMIT_NOVERIFY=0
    COMMIT_FILES=()
    COMMIT_SPECS=()
    COMMIT_REUSED=()
    COMMIT_AMEND=0
    COMMIT_RESET_AUTHOR=0
    COMMIT_AUTHORS=()
    COMMIT_MESSAGES=()
    COMMIT_SUBJECTS=()
    while ((j < n)); do
        a=${words[j]}
        ((j++))
        if ((after)); then
            COMMIT_SPECS+=("$a")
            continue
        fi
        case $a in
            --) after=1 ;;
            --all) COMMIT_ALL=1 ;;
            --no-veri | --no-verif | --no-verify) COMMIT_NOVERIFY=1 ;;
            --file=* | --template=*) COMMIT_FILES+=("${a#*=}") ;;
            --file | --template) COMMIT_FILES+=("${words[j]}"); ((j++)) ;;
            --reuse-message=* | --reedit-message=*) COMMIT_REUSED+=("${a#*=}") ;;
            --reuse-message | --reedit-message) COMMIT_REUSED+=("${words[j]}"); ((j++)) ;;
            --reset-author) COMMIT_RESET_AUTHOR=1 ;;
            --no-reset-author) COMMIT_RESET_AUTHOR=0 ;;
            --amend) COMMIT_AMEND=1 ;;
            --author=*) COMMIT_AUTHORS+=("${a#*=}") ;;
            --author) COMMIT_AUTHORS+=("${words[j]}"); ((j++)) ;;
            --fixup=* | --fixup | --squash=* | --squash)
                if [[ $a == *=* ]]; then
                    v=${a#*=}
                else
                    v=${words[j]}
                    ((j++))
                fi
                if [[ $a == --fixup* && ($v == amend:* || $v == reword:*) ]]; then
                    COMMIT_MESSAGES+=("${v#*:}")
                else
                    COMMIT_SUBJECTS+=("$v")
                fi ;;
            --message | --date | --cleanup | --trailer | --pathspec-from-file) ((j++)) ;;
            --*) ;;
            -?*)
                for ((k = 1; k < ${#a}; k++)); do
                    c=${a:k:1}
                    case $c in
                        a) COMMIT_ALL=1 ;;
                        n) COMMIT_NOVERIFY=1 ;;
                        m | F | C | c | t)
                            v=${a:k+1}
                            if [[ -z $v ]]; then v=${words[j]}; ((j++)); fi
                            [[ $c == F || $c == t ]] && COMMIT_FILES+=("$v")
                            [[ $c == C || $c == c ]] && COMMIT_REUSED+=("$v")
                            break ;;
                        S | u) break ;;
                    esac
                done ;;
            __HERESTRING__) ;;
            *) COMMIT_SPECS+=("$a") ;;
        esac
    done
}

# Options that take a value, per search tool, between blanks: a flag of one tool is such an option
# of another (tree -d lists folders, du -d takes a depth)
declare -A CS_SEARCH_VALUE_OPTS=(
    [grep]=' -e -f -m -A -B -C -d -D --regexp --file --max-count --exclude --include --exclude-dir --exclude-from --label --binary-files --devices --directories --context --after-context --before-context '
    [rg]=' -e -f -g -t -T -m -A -B -C -d -j -r -M -E --regexp --file --glob --iglob --type --type-not --type-add --max-count --max-depth --maxdepth --threads --replace --max-columns --encoding --pre --ignore-file --sort --sortr --max-filesize --context --after-context --before-context '
    [ag]=' -A -B -C -G -g -m -p --depth --ignore --ignore-dir --file-search-regex --max-count --path-to-ignore --context --after --before --pager '
    [ack]=' -A -B -C -g -m --type --ignore-dir --ignore-file --match --max-count --output --context --after-context --before-context '
    [fd]=' -e -t -d -E -S -j -c -o --extension --type --max-depth --min-depth --exact-depth --exclude --size --threads --color --owner --changed-within --changed-before --base-directory --max-results --ignore-file --format '
    [tree]=' -L -P -I -o -H -T --filelimit --charset --sort --timefmt '
    [du]=' -d -B -t -X --max-depth --block-size --threshold --exclude --exclude-from --time-style --files0-from '
    [ls]=' -I -w -T --ignore --hide --width --tabsize --sort --format --block-size --time-style --time --quoting-style --indicator-style '
)
CS_SEARCH_TOOLS='find du tree rg ag ack fd fdfind grep egrep fgrep ls get-childitem gci dir'

# For a search tool (one of CS_SEARCH_TOOLS) at words[at]: SEARCH_PATHS (the paths it names,
# read in bash with their escapes, so \( is the word ( and ~/Team\ Files one folder; the pattern of
# grep, rg, ag and ack and the values of options are none) and SEARCH_RECURSIVE (1 when it
# descends into folders: find, du, tree, rg, ag, ack and
# fd always, grep with -r/-R/--recursive/-d recurse, ls with -R, Get-ChildItem/gci and PowerShell's
# ls and dir with -Recurse or -Depth, dir /s in cmd). False when it searches nothing here: it only
# prints its version or help, or it is find in cmd or PowerShell, where find is the Windows FIND,
# a text search.
search_args() {
    local k i=1 t=$prog b=$prog n l skip_pattern=0 ps=0 vals
    local -a w=()
    SEARCH_PATHS=()
    SEARCH_RECURSIVE=0
    [[ $t == find && $sh != bash ]] && return 1
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
    case $t in
        egrep | fgrep) b=grep ;;
        fdfind) b=fd ;;
        dir) b=ls ;;
    esac
    vals=${CS_SEARCH_VALUE_OPTS[$b]-}
    case $b in
        find | du | tree) SEARCH_RECURSIVE=1 ;;
        rg | ag | ack | fd) SEARCH_RECURSIVE=1; skip_pattern=1 ;;
        grep) skip_pattern=1 ;;
    esac
    while ((i < ${#w[@]})); do
        n=${w[i]}
        l=${n,,}
        if ((ps)); then
            # Parameters may be cut short (-inc, -rec); -s is an alias of -Recurse
            case $l in
                -fi | -fil | -filt* | -inc* | -exc*) ((i += 2)); continue ;;
                -dep*) SEARCH_RECURSIVE=1; ((i += 2)); continue ;;
                -pa* | -li*) SEARCH_PATHS+=("${w[i+1]}"); ((i += 2)); continue ;;
                -r | -re | -rec* | -s) SEARCH_RECURSIVE=1 ;;
                -*) ;;
                *) SEARCH_PATHS+=("$n") ;;
            esac
            ((i++))
            continue
        fi
        if [[ $sh == cmd && $n == /* ]]; then
            # cmd's options, also glued (dir /s /b, dir /b/s); its paths never start with /
            [[ /$l/ == *'/s/'* ]] && SEARCH_RECURSIVE=1
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
            --version | --help | -V) return 1 ;;
            --files) skip_pattern=0 ;;
            --recursive | --dereference-recursive) SEARCH_RECURSIVE=1 ;;
            --search-path) SEARCH_PATHS+=("${w[i+1]}"); ((i += 2)); continue ;;
            -*)
                if [[ $vals == *" $n "* ]]; then
                    # The pattern comes as this value, so the next word is a path
                    case $b:$n in
                        grep:-e | grep:-f | grep:--regexp | grep:--file | rg:-e | rg:-f | rg:--regexp | rg:--file | ag:-g | ack:-g) skip_pattern=0 ;;
                    esac
                    [[ $b == grep && $n == -d && ${w[i+1]} == recurse ]] && SEARCH_RECURSIVE=1
                    ((i += 2))
                    continue
                fi
                # ack -f lists the files, with no pattern. Case matters: ls -r sorts in reverse
                [[ $b == ack && $n == -f ]] && skip_pattern=0
                [[ $b == grep && $n =~ ^-[[:alnum:]]*[rR] ]] && SEARCH_RECURSIVE=1
                [[ $b == ls && $n =~ ^-[[:alnum:]]*R ]] && SEARCH_RECURSIVE=1
                ;;
            *)
                if ((skip_pattern)); then skip_pattern=0; else SEARCH_PATHS+=("$n"); fi ;;
        esac
        ((i++))
    done
    return 0
}
