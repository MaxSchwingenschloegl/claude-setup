#!/usr/bin/env bash
# Tests for block-remote-access.sh: each case feeds a PreToolUse payload and expects exit 2
# (blocked) or 0 (allowed). Run: bash hooks/block-remote-access.test.sh
# The host names are made up. As in the other tests the halves mirror each other: the same tool
# once with a remote target and once with a local one, and the same words once as a command and
# once as text.

hook="$(dirname "$0")/block-remote-access.sh"
fail=0
run=0

check() {  # expected exit, tool, command
    local json value=$3
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    json="{\"session_id\":\"t\",\"cwd\":\"C:\\\\Users\\\\tester\\\\proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$2\",\"tool_input\":{\"command\":\"$value\"}}"
    printf '%s' "$json" | bash "$hook" 2>/dev/null
    local got=$?
    run=$((run + 1))
    if [[ $got != "$1" ]]; then
        fail=$((fail + 1))
        echo "FAIL expected $1 got $got: $2 ${3:0:160}"
    fi
}

# Blocked: shells and terminals on another machine
check 2 Bash 'ssh deploy@build-01.example.net'
check 2 Bash 'ssh -p 2222 -i ~/.ssh/id_ed25519 admin@10.0.0.5 "systemctl restart app"'
check 2 Bash 'ssh build-01 uptime'
check 2 Bash 'ssh -T git@github.com ls'
check 2 Bash 'ssh git@build-01 "rm -rf /srv/app"'
check 2 Bash 'cd deploy && ssh build-01'
check 2 Bash 'git pull && ssh build-01 "cd /srv && ./deploy.sh"'
check 2 Bash 'timeout 10 ssh build-01 true'
check 2 Bash 'sshpass -p x ssh build-01'
check 2 Bash 'ssh-copy-id admin@build-01'
check 2 Bash 'mosh admin@build-01'
check 2 Bash 'sftp admin@build-01'
check 2 Bash 'echo put x | sftp -b - admin@build-01'
check 2 Bash 'plink -batch admin@build-01 uptime'
check 2 Bash 'telnet build-01 25'
check 2 Bash '/usr/bin/ssh build-01'
check 2 PowerShell 'ssh.exe admin@build-01'
check 2 PowerShell '& "C:\Windows\System32\OpenSSH\ssh.exe" build-01'
check 2 Bash 'cmd //c "ssh build-01 dir"'
check 2 Bash 'cmd /c ssh build-01'
check 2 Bash 'powershell -NoProfile -Command "ssh build-01"'
check 2 Bash 'pwsh -c "Enter-PSSession -ComputerName build-01"'
check 2 Bash 'bash -lc "ssh build-01 uptime"'
check 2 Bash 'wsl ssh build-01'
check 2 PowerShell 'Start-Process ssh -ArgumentList "build-01"'

# Blocked: copies with a remote side
check 2 Bash 'scp app.tar.gz admin@build-01:/srv/'
check 2 Bash 'scp -P 2222 build-01:/var/log/app.log ./logs/'
check 2 Bash 'scp -r "C:\work\dist" admin@build-01:/srv/app'
check 2 Bash 'pscp -pw x file.txt admin@build-01:/tmp/'
check 2 Bash 'rsync -avz ./dist/ admin@build-01:/srv/app/'
check 2 Bash 'rsync -e "ssh -p 2222" -a dist/ build-01:/srv/'
check 2 Bash 'rsync -a rsync://mirror.example.net/module/ ./mirror/'
check 2 Bash 'rsync -a build-01::module/ ./mirror/'
check 2 Bash 'rsync -a --exclude "*.tmp" ./dist/ [fe80::1]:/srv/'

# Blocked: PowerShell remoting
check 2 PowerShell 'Enter-PSSession -ComputerName build-01'
check 2 PowerShell 'etsn build-01'
# A parameter name is never quoted: quoted text that looks like one is a value
check 0 PowerShell 'Set-Content -Path notes.txt -Value "-Session"'
check 0 PowerShell "Write-Output '-ComputerName build-01'"
check 0 PowerShell 'Add-Content log.txt "-cn build-01 is down"'
check 2 PowerShell 'Get-Service -ComputerName build-01'
check 2 PowerShell 'Invoke-Command -Session $s -ScriptBlock { hostname }'
# ...but a quoted value glued to an unquoted name with a colon is still that parameter
check 2 PowerShell 'Invoke-Command -ComputerName:"srv" { hostname }'
check 2 PowerShell "Invoke-Command -ComputerName:'srv' { hostname }"
check 2 PowerShell 'Get-Service -cn:"srv"'
check 2 PowerShell 'Invoke-Command -Session:"$s" { hostname }'
check 2 Bash "pwsh -c 'Get-Service -ComputerName:\"srv\"'"
check 2 PowerShell '$s = New-PSSession -ComputerName build-01; Invoke-Command -Session $s -ScriptBlock { Get-Service }'
check 2 PowerShell 'Invoke-Command -ComputerName build-01 -ScriptBlock { hostname }'
check 2 PowerShell 'icm -cn build-01 { hostname }'
check 2 PowerShell 'Invoke-Command -HostName admin@build-01 -ScriptBlock { uname }'
check 2 PowerShell 'Copy-Item .\app.zip -Destination C:\srv -ToSession $s'
check 2 PowerShell 'Get-Service -ComputerName:build-01'
check 2 PowerShell 'Restart-Computer -ComputerName build-01 -Force'

# Blocked: remote engines and clusters
check 2 Bash 'docker -H ssh://admin@build-01 ps'
check 2 Bash 'docker --host=tcp://build-01:2376 ps'
check 2 Bash 'docker --context prod compose up -d'
check 2 Bash 'docker context use prod'
check 2 Bash 'DOCKER_HOST=ssh://admin@build-01 docker ps'
check 2 Bash 'export DOCKER_HOST=ssh://admin@build-01 && docker ps'
check 2 PowerShell '$env:DOCKER_HOST = "ssh://admin@build-01"; docker ps'
check 2 Bash 'docker-compose -H ssh://build-01 up'
check 2 Bash 'kubectl --context prod get pods'
check 2 Bash 'kubectl get pods --kubeconfig ~/.kube/prod.yaml'
check 2 Bash 'kubectl config use-context prod'
check 2 Bash 'KUBECONFIG=~/.kube/prod kubectl get pods'
check 2 Bash 'helm upgrade app ./chart --kube-context prod'
check 2 Bash 'kubectl -s https://build-01:6443 get pods'

# Blocked: a computer name by position, and remote tools behind xargs, find -exec and watch
check 2 PowerShell 'icm build-01 { hostname }'
check 2 PowerShell 'Invoke-Command build-01 {hostname}'
check 2 PowerShell 'Invoke-Command build-01 -ScriptBlock { hostname }'
check 2 Bash 'cat hosts.txt | xargs -I{} ssh {} uptime'
check 2 Bash 'xargs ssh build-01 < commands.txt'
check 2 Bash 'cat hosts.txt | xargs -n 1 ssh build-01 uptime ; echo done'
check 2 Bash "find . -name '*.log' -exec scp {} admin@build-01:/logs/ \\;"
check 2 Bash 'find dist -type f -execdir rsync -a {} build-01:/srv/ +'
check 2 Bash 'watch ssh build-01 uptime'
check 2 Bash 'watch -n 5 "ssh build-01 uptime"'
# Blocked: the git-host exemption only for git at the four hosts, and never with -o, -J or -F
check 2 Bash 'ssh -o ProxyCommand="ssh build-01 nc %h %p" git@github.com'
check 2 Bash 'ssh -oProxyJump=build-01 -T git@github.com'
check 2 Bash 'ssh -J build-01 git@github.com'
check 2 Bash 'ssh -T git@build-01'
check 2 Bash 'ssh -vT -p 443 git@ssh.github.com'
check 2 Bash 'ssh -T admin@github.com'

# Allowed: git to the repository host, gh, web requests, key tools
check 0 Bash 'git fetch origin && git pull --ff-only'
check 0 Bash 'git push origin feature'
check 0 Bash 'git clone git@github.com:owner/repo.git'
check 0 Bash 'GIT_SSH_COMMAND="ssh -i ~/.ssh/deploy" git fetch'
check 0 Bash 'ssh -T git@github.com'
check 0 Bash 'ssh -T git@gitlab.com'
check 0 Bash 'ssh -vT -p 22 git@bitbucket.org'
check 0 Bash 'ssh git@ssh.dev.azure.com'
check 0 Bash 'ssh -V'
check 0 Bash 'gh pr view 12'
check 0 Bash 'curl -fsSL https://api.example.net/health'
check 0 PowerShell 'Invoke-WebRequest -Uri https://example.net -SessionVariable web'
check 0 Bash 'ssh-keygen -t ed25519 -C "max@laptop" -f ~/.ssh/id_new'
check 0 Bash 'ssh-add -l'
check 0 PowerShell 'Get-Service ssh-agent'

# Allowed: local copies and local engines
check 0 Bash 'scp a.txt b.txt'
check 0 Bash 'scp C:\work\a.txt D:\backup\'
check 0 Bash 'scp C:/work/a.txt /c/backup/'
check 0 Bash 'rsync -a ./src/ /c/backup/src/'
check 0 Bash 'rsync -a ./a:b/ ./copy/'
check 0 Bash 'rsync -a --chown user:group ./src/ /tmp/x/'
check 0 Bash 'docker ps'
check 0 Bash 'docker compose up -d'
check 0 Bash 'docker run -h myhost -c 512 alpine hostname'
check 0 Bash 'docker context use default'
check 0 Bash 'DOCKER_HOST=npipe:////./pipe/docker_engine docker ps'
check 0 Bash 'kubectl get pods'
check 0 PowerShell 'Get-ChildItem -Recurse src'
check 0 PowerShell 'Invoke-Command -ScriptBlock { hostname }'
check 0 PowerShell 'Invoke-Command { hostname }'
check 0 PowerShell 'Invoke-Command -ScriptBlock { hostname } -ArgumentList x'
check 0 PowerShell 'icm localhost { hostname }'
check 0 PowerShell 'ConvertTo-Json -Compress $data'
check 0 PowerShell 'Test-Connection -ComputerName localhost'
check 0 PowerShell 'Get-Service -ComputerName . -Name ssh-agent'
check 0 PowerShell 'Get-CimInstance Win32_OperatingSystem -ComputerName 127.0.0.1'
check 0 PowerShell 'Test-Connection -ComputerName ::1'
check 0 Bash 'helm template ./chart -s templates/deployment.yaml'
check 0 Bash 'helm install app ./chart --set image.tag=1.2'
check 0 Bash "find . -name '*.log' -exec rm {} \\;"
check 0 Bash 'cat files.txt | xargs rm'
check 0 Bash 'watch git status'

# Allowed: the same words as text, not as a command
check 0 Bash 'echo "ssh build-01 uptime"'
check 0 Bash 'grep -rn "ssh " docs/'
check 0 Bash 'rg "scp .* admin@build-01:" scripts'
check 0 Bash 'git commit -m "Document how to ssh build-01 and rsync to build-01:/srv"'
check 0 Bash 'gh issue comment 5 --body "Run ssh build-01, then docker -H ssh://build-01 ps"'
check 0 Bash "cat > deploy.md <<'EOF'
ssh admin@build-01
scp app.tar.gz admin@build-01:/srv/
EOF"
check 0 PowerShell "Write-Output 'Enter-PSSession -ComputerName build-01'"
check 0 PowerShell "Set-Content notes.md @'
Invoke-Command -ComputerName build-01
'@"
check 0 Bash 'npm run session-report'
check 0 Read command 'ssh build-01'

# A broken install blocks, so the gap shows, instead of letting every command through unchecked
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp "$hook" "$tmp/block-remote-access.sh"
saved=$hook
hook=$tmp/block-remote-access.sh
check 2 Bash 'ls'
hook=$saved

# Large commands stay well inside the timeout: a hook that times out lets the command run unchecked
# The limit catches a return of the old quadratic split (47 s and more at 30 KB), with room for a
# busy machine: these commands take about 2 s under load, so a tighter limit only adds flaky runs.
timed() {  # name, limit in ms, expected exit, command: the hook process alone is timed
    local name=$1 limit=$2 value=$4 start ms got
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    printf '%s' "{\"session_id\":\"t\",\"cwd\":\"C:\\\\Users\\\\tester\\\\proj\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$value\"}}" > "$tmp/payload.json"
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
while ((${#compound} < 30000)); do compound+="ssh-keygen -l -f key.pub && echo 'one more harmless line of text' && "; done
compound+="true"
unclosed="echo \"unclosed "
i=0
while ((${#unclosed} < 60000)); do
    i=$((i + 1))
    unclosed+="echo step $i of the deploy notes >> notes.log ; rsync -a dist/ backup/$i/ ; docker ps"$'\n'
done
timed "compound command of ${#compound} bytes" 5000 0 "$compound"
timed "script of ${#unclosed} bytes after an unclosed quote" 5000 0 "$unclosed"
timed "the same with ssh at its end" 5000 2 "$unclosed ssh build-01"

echo "$run cases, $fail failed"
((fail == 0))
