#!/usr/bin/env bash
# Tests for block-profile-wide-search.sh: each case feeds a PreToolUse payload and expects exit 2
# (blocked) or 0 (allowed). Run: bash hooks/block-profile-wide-search.test.sh
# The profile is a made-up one, so the cases hold on any machine. As in block-secrets.test.sh the
# halves mirror each other: the same command one folder over the line and one just short of it.

hook="$(dirname "$0")/block-profile-wide-search.sh"
fail=0
run=0
export HOME=/c/Users/tester
export OneDrive='C:\Users\tester\OneDrive - Contoso'
export OneDriveCommercial=
export OneDriveConsumer=
export PROFILE_SEARCH_GUARD_EXTRA='Contoso Group;Fabrikam'
project='C:\Users\tester\Documents\GitHub\proj'
# What `reg query` prints for the registered sync roots: the Windows code page, so the folder
# named Ölwerk arrives with a single byte 0xD6 where a command carries two bytes of UTF-8
reg_output=$(mktemp)
trap 'rm -f "$reg_output"' EXIT
printf '%b' 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\SyncRootManager\\OneDrive!S-1!Business1|abc\\UserSyncRoots\r\n    S-1-5-21-1    REG_SZ    C:\\Users\\tester\\\xd6lwerk\\Lib A\r\n\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\SyncRootManager\\Dropbox!S-1!x\r\n    IconResource    REG_SZ    C:\\Program Files\\Dropbox\\Dropbox.exe,-1\r\n    DisplayNameResource    REG_SZ    Dropbox\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\SyncRootManager\\Dropbox!S-1!x\\UserSyncRoots\r\n    S-1-5-21-1    REG_SZ    D:\\Sync\\Team Files\r\n' > "$reg_output"
export SEARCH_GUARD_REG_OUTPUT=$reg_output

check() {  # expected exit, tool, field, value[, cwd]
    local json value=$4 cwd=${5:-$project}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    cwd=${cwd//\\/\\\\}
    json="{\"session_id\":\"t\",\"cwd\":\"$cwd\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$2\",\"tool_input\":{\"$3\":\"$value\"}}"
    printf '%s' "$json" | bash "$hook" 2>/dev/null
    local got=$?
    run=$((run + 1))
    if [[ $got != "$1" ]]; then
        fail=$((fail + 1))
        echo "FAIL expected $1 got $got: $2 $3=$4 (cwd ${5:-project})"
    fi
}

# Blocked: the profile, above it, and synced folders, however the path is spelled
check 2 Bash command 'find /c/Users/tester -maxdepth 6 -name cycle_info.txt -not -path */node_modules/*'
check 2 Bash command 'find ~ -name x'
check 2 Bash command 'find ~/ -name x'
check 2 Bash command 'find $HOME -name x'
check 2 Bash command 'find "$HOME" -name x'
check 2 Bash command 'find ${HOME} -name x'
check 2 Bash command 'find $USERPROFILE -name x'
check 2 Bash command 'find C:\Users\tester -name x'
check 2 Bash command 'find C:/Users/tester/ -name x'
check 2 Bash command 'find -L ~ -name x'
check 2 Bash command 'find /c/Users -name x'
check 2 Bash command 'find /c -name x'
check 2 Bash command 'find / -name x'
check 2 Bash command 'timeout 60 find ~ -name x'
check 2 Bash command 'LC_ALL=C find ~ -name x'
check 2 Bash command 'echo start && find ~ -name x | head'
check 2 Bash command 'cd ~ && find . -name x'
check 2 Bash command 'cd /c/Users/tester; grep -rn foo'
check 2 Bash command 'cd; rg foo'
check 2 Bash command 'find . -name x' 'C:\Users\tester'
check 2 Bash command 'grep -r foo ~'
check 2 Bash command 'grep -rn foo /c/Users/tester/'
check 2 Bash command 'grep --recursive foo ~'
check 2 Bash command 'grep -d recurse foo ~'
check 2 Bash command 'rg foo ~'
check 2 Bash command 'rg -e foo ~'
check 2 Bash command 'ls -R ~'
check 2 Bash command 'ls -laR /c/Users/tester'
check 2 Bash command 'du -sh ~/*'
check 2 Bash command 'du -sh /c/Users/tester'
check 2 Bash command 'tree ~'
check 2 Bash command 'find "/c/Users/tester/OneDrive - Contoso/Docs" -name a'
check 2 Bash command 'find /c/Users/tester/OneDrive/Docs -name a'
check 2 Bash command 'ls -R "C:\Users\tester\SharePoint Sites"'
check 2 Bash command 'grep -r foo "/c/Users/tester/Contoso Group/Shared Documents"'
check 2 Bash command 'du -sh /c/Users/tester/Fabrikam'
check 2 Bash command 'find "/d/Sync/OneDrive - Contoso" -name a'
check 2 Bash command 'find "/c/Users/tester/Ölwerk Contoso Group" -name a'
check 2 Bash command 'find "/c/Users/tester/\u00d6lwerk Contoso Group" -name a'
# Registered sync roots, found in the registry rather than by name: inside, above, and in each
# spelling a command can carry the name in
check 2 Bash command 'find "/c/Users/tester/Ölwerk/Lib A" -name a'
check 2 Bash command 'find "/c/Users/tester/Ölwerk/Lib A/Sub" -name a'
check 2 Bash command 'grep -r foo "C:\Users\tester\Ölwerk"'
check 2 Bash command 'rg foo "/c/Users/tester/\u00d6lwerk"'
check 2 Bash command 'find "D:\Sync\Team Files" -name a'
check 2 Bash command 'du -sh /d/Sync'
check 2 Bash command 'find /c/Users/tester/Library/CloudStorage -name a'
check 2 PowerShell command 'Get-ChildItem -Path $env:USERPROFILE -Recurse -Filter x'
check 2 PowerShell command 'gci ~ -r'
check 2 PowerShell command 'Get-ChildItem C:\Users\tester -Depth 3'
check 2 Bash command 'cmd //c dir /s C:\Users\tester'
check 2 Grep path 'C:\Users\tester'
check 2 Grep path '/c/Users/tester/OneDrive - Contoso'
check 2 Glob path 'C:\Users\tester'
check 2 Glob path 'C:\Users\tester\Contoso Group\Docs'
check 2 Grep path '' 'C:\Users\tester'

# Allowed: the same tools one folder below the line, and the same paths without recursion
check 0 Bash command 'find /c/Users/tester/Documents/GitHub/proj -maxdepth 6 -name cycle_info.txt'
check 0 Bash command 'find . -name x'
check 0 Bash command 'find ~/.claude/plugins -name x'
check 0 Bash command 'find "$HOME/Documents/GitHub/proj" -name x'
check 0 Bash command 'cd ~/Documents/GitHub/proj && find . -name x'
check 0 Bash command 'grep -rn foo src/'
check 0 Bash command 'grep -rn "OneDrive" src/'
check 0 Bash command 'grep -r "~" src'
check 0 Bash command 'rg OneDrive'
check 0 Bash command 'rg foo /c/Users/tester/Documents/GitHub/proj'
check 0 Bash command 'grep foo ~/.bashrc'
check 0 Bash command 'grep -n foo ~/.bashrc'
check 0 Bash command 'ls ~'
check 0 Bash command 'ls -la /c/Users/tester'
check 0 Bash command 'ls -R /c/Users/tester/Documents/GitHub/proj'
check 0 Bash command 'du -sh /c/Users/tester/Documents/GitHub/proj'
check 0 Bash command 'cat ~/.bashrc'
check 0 Bash command 'echo find ~ -name x'
check 0 Bash command 'git grep foo'
check 0 Bash command 'find . -name x' 'C:\Users\tester\Documents\GitHub\proj'
check 0 Bash command 'find /c/Users/tester/Contoso-tools -name x'
check 0 Bash command 'find "/c/Users/tester/Ölwerk-Archiv" -name a'
check 0 Bash command 'find "/c/Users/tester/Ölwerk/Lib B" -name a'
check 0 Bash command 'find "D:\Sync\Team Files Old" -name a'
check 0 Bash command 'find "C:\Program Files\Dropbox" -name a'
check 0 Bash command 'ls "/c/Users/tester/Ölwerk/Lib A"'
check 0 PowerShell command 'Get-ChildItem -Path $env:USERPROFILE'
check 0 PowerShell command 'Get-ChildItem -Path C:\Users\tester\Documents\GitHub\proj -Recurse'
check 0 Grep path 'C:\Users\tester\Documents\GitHub\proj'
check 0 Grep path ''
check 0 Glob path 'C:\Users\tester\Documents\GitHub\proj\src'
check 0 Read file_path 'C:\Users\tester\OneDrive - Contoso\a.txt'

# A long command with a recursive tool in it still answers well inside the hook's timeout
long="python - <<'EOF'"$'\n'
for i in $(seq 1 400); do long+="print('grep -rn something in line $i of a long patch script, find nothing')"$'\n'; done
long+="EOF"
start=$SECONDS
check 0 Bash command "$long"
((SECONDS - start < 10)) || { fail=$((fail + 1)); echo "FAIL a long command took $((SECONDS - start)) s"; }

echo "$run cases, $fail failed"
((fail == 0))
