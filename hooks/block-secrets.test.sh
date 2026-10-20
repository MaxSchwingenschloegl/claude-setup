#!/usr/bin/env bash
# Tests for block-secrets.sh: each case feeds a PreToolUse payload and expects exit 2 (blocked)
# or 0 (allowed). Run: bash hooks/block-secrets.test.sh
# A case is only worth something if it can fail, so the blocked and the allowed halves mirror
# each other: the same tool and field, one name over the line and one just short of it.

hook="$(dirname "$0")/block-secrets.sh"
fail=0
run=0

check() {  # expected exit, tool, field, value
    local json value=$4
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    json="{\"session_id\":\"t\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$2\",\"tool_input\":{\"$3\":\"$value\"}}"
    printf '%s' "$json" | bash "$hook" 2>/dev/null
    local got=$?
    run=$((run + 1))
    if [[ $got != "$1" ]]; then
        fail=$((fail + 1))
        echo "FAIL expected $1 got $got: $2 $3=$4"
    fi
}

# Blocked
check 2 Read file_path 'C:\Users\max\project\.env'
check 2 Read file_path 'C:\Users\max\project\.env.local'
check 2 Read file_path 'C:\Users\max\project\.env.production'
check 2 Read file_path '/home/max/.ssh/id_rsa'
check 2 Read file_path 'C:\Users\max\.ssh\id_ed25519'
check 2 Read file_path 'C:\certs\server.pem'
check 2 Read file_path 'C:\Users\max\.claude-privat\.credentials.json'
check 2 Read file_path '/home/max/.git-credentials'
check 2 Read file_path 'C:\Users\max\_netrc'
check 2 Bash command 'cat .env'
check 2 Bash command 'grep KEY ./apps/api/.env.local | head'
check 2 Bash command 'source .env && npm start'
check 2 Bash command 'docker compose --env-file .env up'
check 2 Bash command 'cp ~/.claude-privat/.credentials.json /tmp/x'
check 2 PowerShell command 'Get-Content .env'
check 2 PowerShell command 'Get-Content "C:\Users\max\.ssh\id_rsa"'
check 2 Grep path 'C:\Users\max\project\.env'
check 2 Grep glob '.env*'
check 2 Read file_path 'C:\Users\max\project\.ENV'
check 2 Read file_path 'C:\Users\max\.ssh\ID_RSA'
check 2 Read file_path 'C:\Users\max\project\.env::$DATA'
check 2 Bash command 'echo start\ncat .env'
check 2 PowerShell command 'sls KEY -Path *.env'
check 2 Grep glob '*.env*'
check 2 Grep glob '.env{,.local}'
check 2 Read file_path '/home/max/.ssh/id_ed25519_sk'
check 2 Read file_path 'C:\certs\server.key'
check 2 Read file_path 'C:\certs\client.pfx'
check 2 Read file_path 'C:\Users\max\project\.env~'
check 0 Read file_path '/home/max/.ssh/id_ed25519_sk.pub'
check 0 Read file_path 'C:\Users\max\project\keyboard.md'
check 0 Bash command 'npm run build --if-present'

# Allowed
check 0 Read file_path 'C:\Users\max\project\.env.example'
check 0 Read file_path 'C:\Users\max\project\.envrc.md'
check 0 Read file_path '/home/max/.ssh/id_rsa.pub'
check 0 Read file_path 'C:\Users\max\project\README.md'
check 0 Read file_path 'C:\Users\max\.claude-privat\.claude.json'
check 0 Bash command 'cp .env.example .env.example.bak'
check 0 Bash command 'node -e "console.log(process.env.HOME)"'
check 0 Bash command 'git status'
check 0 PowerShell command 'Write-Output $env:USERPROFILE'
check 0 Grep pattern '\.env'
check 0 Grep path 'C:\Users\max\project\src'
check 0 Write file_path 'C:\Users\max\project\.env'

echo "$((run - fail)) of $run passed"
[[ $fail == 0 ]]
