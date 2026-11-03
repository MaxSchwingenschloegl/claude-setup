#!/usr/bin/env bash
# PreToolUse hook (Bash, PowerShell): blocks a command that reaches a server from this machine.
# Server work is the user's own; Claude prepares it and the user runs it. Plain bash on purpose,
# like block-secrets.sh: a hook that needed node or jq would stop guarding, silently, on a machine
# without them. Exit 2 blocks the call and tells Claude why; exit 0 leaves it to the normal
# permission flow, whose deny rules may be stricter (a `Bash(ssh *)` rule refuses even the git
# host's greeting this hook lets through).
#
# Blocked, at command position only (lib/command-segments.sh: compound commands, wrappers such as
# env, sudo, timeout, xargs, watch, find -exec, and one level of bash -c, cmd /c, powershell/pwsh
# -c and wsl):
# - ssh, slogin, autossh, sshpass, ssh-copy-id, mosh, sftp, plink, putty, telnet, ftp, winscp,
#   always, apart from `ssh -V` and `ssh [options] git@<host>` without a command for the git hosts
#   github.com, gitlab.com, bitbucket.org and ssh.dev.azure.com (their greeting, as
#   `ssh -T git@github.com` asks for it), and that only without -o, -J or -F, which can route the
#   connection through another machine
# - scp, pscp, rsync when an argument is a remote spec: host:path, user@host:path, host::module,
#   rsync:// or ssh:// (C:\x, C:/x, /c/x and ./a:b are local paths)
# - Enter-PSSession, New-PSSession (etsn, nsn); Invoke-Command/icm with a computer name in first
#   place; any Verb-Noun cmdlet or icm with -ComputerName, -Cn, -HostName, -ConnectionUri,
#   -SSHConnection naming another machine (localhost, 127.0.0.1, ::1 and . are this one), or with
#   -Session, -CimSession, -ToSession, -FromSession; Start-Process/start/saps of a program above
# - docker and docker-compose with -H/--host or -c/--context before the subcommand, `docker context
#   use`; a DOCKER_HOST or DOCKER_CONTEXT prefix, export, set, setx or $env: assignment. A local
#   engine (npipe://, unix://, the context `default`) stays allowed.
# - kubectl and helm with --context, --kube-context, --kubeconfig or --cluster, kubectl with
#   --server/-s (helm's -s is a template name), `kubectl config use-context`, a KUBECONFIG prefix
# Not blocked: git fetch/pull/push/clone (they reach the repository host, which is allowed), gh,
# curl, Invoke-WebRequest, ssh-keygen, ssh-add, ssh-agent, and any command that only mentions ssh
# inside quotes, a message or a here-document.
# A missing or broken lib/command-segments.sh blocks every shell call (exit 2) until it is
# restored, so a broken install shows instead of letting every command through unchecked.
#
# Not covered: plain kubectl or docker whose current context already points at a server, a
# connection made by a script, a program the list does not name (nc, a database client, Python),
# powershell -EncodedCommand and -File, Test-NetConnection, a computer name in a variable. It is a
# guard against accidents, not against a determined attacker.
# Blocked although harmless: an ssh, scp or rsync that only reaches this machine or a local VM.
# Tests: hooks/block-remote-access.test.sh

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=lib/command-segments.sh
source "$here/lib/command-segments.sh" || {
    echo "Blocked by the claude-setup remote-access guard: its library $here/lib/command-segments.sh is missing or broken, so no shell command can be checked. Tell the user: restore the claude-setup hooks folder (git checkout in claude-setup, then install.ps1)." >&2
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
# Fast path: no remote tool named anywhere
shopt -s nocasematch
fast='ssh|scp|sftp|plink|putty|mosh|rsync|telnet|ftp|winscp|pssession|etsn|nsn|icm|invoke-command|computer|-cn|session|hostname|connectionuri|docker|kubectl|helm|kubeconfig'
[[ $command =~ $fast ]] || exit 0
# Cmdlets and $env: assignments are not known by name: only then every command goes to the check
other=
[[ $command =~ [a-z]-[a-z]|\$env: ]] && other=on_segment
shopt -u nocasematch

field cwd 4096
resolve_path / "${REPLY:-$PWD}"
CS_CWD=$REPLY

block() {
    echo "Blocked by the claude-setup remote-access guard: $1 reaches a server, and the user does all server work himself. Do not try another way to connect; tell the user what to run there and why." >&2
    exit 2
}

# True for an argument that names a place on another machine
remote_spec() {
    local a=$1 before
    [[ ${a,,} =~ ^(rsync|ssh|sftp|scp):// ]] && return 0
    [[ $a =~ ^[A-Za-z]: ]] && return 1
    [[ $a == *:* ]] || return 1
    before=${a%%:*}
    [[ -z $before || $before == */* || $before == *\\* ]] && return 1
    return 0
}

# True for a DOCKER_HOST / -H value or a context name that stays on this machine
local_engine() {
    [[ ${1,,} =~ ^(npipe|unix|fd):// || ${1,,} == default ]]
}

# True for a computer name that is this machine
local_computer() {
    [[ ${1,,} == localhost || $1 == 127.0.0.1 || $1 == ::1 || $1 == . ]]
}

always_remote() {
    case $1 in
        ssh | slogin | autossh | sshpass | ssh-copy-id | mosh | sftp | plink | putty | telnet | ftp | winscp | winscp.com) return 0 ;;
    esac
    return 1
}

check_ssh() {
    local i n=${#words[@]} a dest="" more=0 routed=0
    for ((i = at + 1; i < n; i++)); do
        a=${words[i]}
        if [[ -z $dest ]]; then
            case $a in
                -V) return 0 ;;
                -[oJF]) routed=1; ((i++)) ;;
                -[oJF]?*) routed=1 ;;
                -[bcDEeIiLlmOpQRSWwB]) ((i++)) ;;
                -*) ;;
                *) dest=$a ;;
            esac
        else
            more=1
        fi
    done
    if ((!routed && !more)) && [[ ${dest,,} =~ ^(ssh://)?git@(github\.com|gitlab\.com|bitbucket\.org|ssh\.dev\.azure\.com)(:[0-9]+)?$ ]]; then
        return 0
    fi
    block "\`ssh ${dest:-...}\`"
}

check_copy() {  # scp, pscp, rsync: block when an argument is a remote spec
    local i n=${#words[@]} a
    for ((i = at + 1; i < n; i++)); do
        a=${words[i]}
        case $a in
            -[PiFocSJlDX] | -e | -f | -B | -M | -T | --rsh | --filter | --exclude | --include | --exclude-from | --include-from | --files-from | --chown | --usermap | --groupmap | --port | --password-file | --log-file | --chmod | --remote-option | --compare-dest | --copy-dest | --link-dest | --backup-dir | --suffix | --temp-dir | --block-size) ((i++)) ;;
            -*) ;;
            *) remote_spec "$a" && block "\`${words[at]} ... $a\`" ;;
        esac
    done
}

check_docker() {
    local i n=${#words[@]} a v
    for ((i = 0; i < at; i++)); do
        a=${words[i]}
        [[ ${a^^} == DOCKER_HOST=* || ${a^^} == DOCKER_CONTEXT=* ]] && ! local_engine "${a#*=}" && block "\`$a\`"
    done
    for ((i = at + 1; i < n; i++)); do
        a=${words[i]}
        case $a in
            -H | --host | -c | --context) v=${words[i+1]}; local_engine "$v" || block "\`${words[at]} $a $v\`"; ((i++)) ;;
            -H=* | --host=* | -c=* | --context=*) local_engine "${a#*=}" || block "\`${words[at]} $a\`" ;;
            --config | -l | --log-level | --tlscacert | --tlscert | --tlskey) ((i++)) ;;
            -*) ;;
            context)
                for ((i = i + 1; i < n; i++)); do
                    [[ ${words[i]} == -* ]] && continue
                    [[ ${words[i]} == use ]] && ! local_engine "${words[i+1]}" && block "\`docker context use ${words[i+1]}\`"
                    break
                done
                return 0 ;;
            *) return 0 ;;
        esac
    done
}

check_kube() {
    local i n=${#words[@]} a
    for ((i = 0; i < at; i++)); do
        [[ ${words[i]^^} == KUBECONFIG=* ]] && block "\`${words[i]} ${words[at]}\`"
    done
    for ((i = at + 1; i < n; i++)); do
        a=${words[i]}
        case $a in
            --context | --context=* | --kube-context | --kube-context=* | --kubeconfig | --kubeconfig=* | --cluster | --cluster=*) block "\`${words[at]} $a\`" ;;
            --server | --server=* | -s) [[ $prog == kubectl ]] && block "\`${words[at]} $a\`" ;;
            use-context) [[ ${words[i-1]} == config ]] && block "\`kubectl config use-context\`" ;;
        esac
    done
}

# PowerShell: a computer named by a parameter, or by position for Invoke-Command
check_cmdlet() {
    local i n=${#words[@]} a v
    if [[ $prog == icm || $prog == invoke-command ]]; then
        a=${words[at+1]}
        [[ -n $a && $a != -* && $a != '{'* ]] && ! local_computer "$a" && block "\`${words[at]} $a\`"
    fi
    for ((i = at + 1; i < n; i++)); do
        a=${words[i],,}
        case ${a%%:*} in
            -session | -cimsession | -tosession | -fromsession)
                block "\`${words[at]} ${words[i]}\`" ;;
            -computername | -computer | -cn | -hostname | -connectionuri | -sshconnection)
                if [[ $a == *:* ]]; then v=${words[i]#*:}; else v=${words[i+1]}; fi
                local_computer "$v" || block "\`${words[at]} ${words[i]} $v\`" ;;
        esac
    done
}

on_segment() {
    local i a n=${#words[@]}
    # Environment for the commands that follow: export/set/setx DOCKER_HOST=..., $env:DOCKER_HOST = ...
    case $prog in
        export | set | setx | '$env:docker_host'* | '$env:docker_context'*)
            for ((i = at; i < n; i++)); do
                a=${words[i]}
                if [[ ${a^^} =~ ^(\$ENV:)?(DOCKER_HOST|DOCKER_CONTEXT)(=(.*))?$ ]]; then
                    if [[ -n ${BASH_REMATCH[3]} ]]; then
                        local_engine "${BASH_REMATCH[4]}" || block "\`$a\`"
                    elif [[ ${words[i+1]} == = ]]; then
                        local_engine "${words[i+2]}" || block "\`$a = ${words[i+2]}\`"
                    elif [[ $prog == setx ]]; then
                        local_engine "${words[i+1]}" || block "\`setx $a ${words[i+1]}\`"
                    fi
                fi
            done
            return 0 ;;
    esac
    case $prog in
        ssh) check_ssh ;;
        slogin | autossh | sshpass | ssh-copy-id | mosh | sftp | plink | putty | telnet | ftp | winscp | winscp.com) block "\`$prog\`" ;;
        scp | pscp | rsync) check_copy ;;
        docker | docker-compose) check_docker ;;
        kubectl | helm) check_kube ;;
        enter-pssession | etsn | new-pssession | nsn) block "\`${words[at]}\`" ;;
        start-process | saps | start)
            for ((i = at + 1; i < n; i++)); do
                a=${words[i]##*[/\\]}
                a=${a,,}
                always_remote "${a%.exe}" && block "\`${words[at]} ${words[i]}\`"
            done ;;
        icm | *[a-z]-[a-z]*)
            [[ $prog == icm || $prog =~ ^[a-z]+-[a-z]+$ ]] && check_cmdlet ;;
    esac
}

for p in ssh slogin autossh sshpass ssh-copy-id mosh sftp plink putty telnet ftp winscp winscp.com \
    scp pscp rsync docker docker-compose kubectl helm enter-pssession etsn new-pssession nsn \
    start-process saps start icm invoke-command export set setx; do
    CS_PROGRAMS[$p]=on_segment
done
split_command "$command" "$shell" "$other"
exit 0
