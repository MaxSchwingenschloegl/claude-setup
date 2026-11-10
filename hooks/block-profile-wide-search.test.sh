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
printf '%b' 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\SyncRootManager\\OneDrive!S-1!Business1|abc\\UserSyncRoots\r\n    S-1-5-21-1    REG_SZ    C:\\Users\\tester\\\xd6lwerk\\Lib A\r\n\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\SyncRootManager\\Dropbox!S-1!x\r\n    IconResource    REG_SZ    C:\\Program Files\\Dropbox\\Dropbox.exe,-1\r\n    DisplayNameResource    REG_SZ    Dropbox\r\nHKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\SyncRootManager\\Dropbox!S-1!x\\UserSyncRoots\r\n    S-1-5-21-1    REG_SZ    D:\\Sync\\Team Files\r\n    S-1-5-21-2    REG_SZ    C:\\Users\\tester\\Dropbox (Contoso)\r\n    S-1-5-21-3    REG_SZ    C:\\Users\\tester\\(Team) Files\r\n' > "$reg_output"
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
check 2 Bash command $'echo start\nfind ~ -name x'
check 2 PowerShell command $'Write-Output start\ngci ~ -r'
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
# A backslash before a shell character, a space or a backslash is an escape in bash, outside
# quotes; a backslash ending a line continues it; X:\ before one stays a drive, as cmd reads it
check 2 Bash command 'find ~ \( -name a -o -name b \) -print'
check 2 Bash command 'find \( -name a \) -print' 'C:\Users\tester'
check 2 Bash command 'find \! -name x' 'C:\Users\tester'
check 2 Bash command 'grep -rn foo\|bar ~'
check 2 Bash command 'grep -rn \<foo\> ~'
check 2 Bash command 'find /d/Sync/Team\ Files -name a'
check 2 Bash command 'find /c/Users/tester/Library/Mobile\ Documents -name a'
check 2 Bash command 'find /c/Users/tester/Ölwerk/Lib\ A -name a'
check 2 Bash command 'find ~/Dropbox\ \(Contoso\) -name x'
check 2 Bash command 'rg foo ~/Dropbox\ \(Contoso\)/Shared'
check 2 Bash command 'find \"~\" ~/Dropbox\ \(Contoso\) -name x'
check 2 Bash command 'find "C:\Users\tester\(Team) Files" -name a'
check 2 Bash command "find 'C:\Users\tester\(Team) Files' -name a"
check 2 Bash command 'find C:\\Users\\tester -name x'
check 2 Bash command 'find "C:\\Users\\tester\\" -name x'
check 2 Bash command 'ls -R "C:\\Users\\tester\\\\"'
check 2 Bash command 'find C:\ -name x'
check 2 Bash command 'cmd //c dir /s C:\ /b'
check 2 Bash command 'cmd //c dir /s /b C:\>files.txt'
check 2 Bash command $'grep -rn foo \\\n  ~'
check 2 Bash command $'find \\\n  ~ -name x'
check 2 Bash command $'find \\\n~ -name x'
check 2 Bash command $'echo a \\\n && find ~ -name x'
check 2 PowerShell command 'Get-ChildItem C:\ -Recurse'
check 2 PowerShell command 'gci -r C:\Users\tester\| Measure-Object'
# A cd into a synced folder reads its escapes as bash does, like the search after it
check 2 Bash command 'cd /d/Sync/Team\ Files && find . -name a'
check 2 Bash command 'cd ~/Dropbox\ \(Contoso\) && rg foo'
check 2 Bash command 'cd ~ && cd src && cd - && find . -name x'
# The command a wrapper or another shell runs is read, and so is one in backquotes or $( )
check 2 Bash command 'nohup find ~ -name x &'
check 2 Bash command 'bash -c "find ~ -name x"'
check 2 Bash command "sh -c 'grep -rn foo ~'"
check 2 Bash command 'powershell -c "gci ~ -r"'
check 2 Bash command 'echo `find ~ -name x`'
check 2 Bash command 'n=$(find ~ -name x | wc -l)'
check 2 Bash command 'find src -name x -exec grep -rn foo ~ \;'
check 2 Bash command 'grep -rn foo ~ 2>/dev/null'
check 2 Bash command $'bash <<\'EOF\'\nfind ~ -name x\nEOF'
check 2 PowerShell command 'cmd /c dir /s C:\Users\tester'
check 2 Bash command $'bash <<\'EOF\'\nbash -c \'find ~ -name x\'\nEOF'
# The argument of bash -c, cmd /c and powershell -c is read with bash's escapes first
check 2 Bash command 'bash -c "find \"/c/Users/tester\" -name x"'
check 2 Bash command 'powershell -Command "Get-ChildItem -Path \$env:USERPROFILE -Recurse -Filter *.log"'
check 2 Bash command 'cmd //c dir /s /b' 'C:\Users\tester'
# A redirection's target is no path to search, however it is quoted; an assignment before the
# program is no program, whatever its value holds
check 2 Bash command 'rg TODO > "todo.txt"' 'C:\Users\tester'
check 2 Bash command 'cd ~ && tree > "$TEMP/tree.txt"'
check 2 PowerShell command 'cd ~; Get-ChildItem -Recurse > "list.txt"'
check 2 Bash command 'TMPDIR=/tmp/x find ~ -name x | head'
check 2 Bash command 'RIPGREP_CONFIG_PATH="/c/x" rg foo ~ | head'
# A backslash ending a line joins the word around it, as bash reads it
check 2 Bash command $'find ~/One\\\nDrive -name x'
# Options as each tool reads them: case matters outside PowerShell
check 2 Bash command 'ls -1R ~'
check 2 Bash command 'grep -F -r foo ~'
check 2 Bash command 'find -- ~ -name x'
check 2 PowerShell command 'ls -r ~'
check 2 PowerShell command 'Get-ChildItem ~ -recurse'
check 2 Bash command 'pushd ~ && pushd src && popd && rg foo'
# PowerShell variables and cmd's %VAR% have no case
check 2 PowerShell command 'Get-ChildItem $Env:USERPROFILE -Recurse'
check 2 PowerShell command 'gci $env:userprofile -r'
check 2 PowerShell command 'Get-ChildItem $Home -Recurse'
check 2 PowerShell command 'cd $Home; gci -r'
check 2 Bash command 'cmd //c dir /s /b %UserProfile%'
# Each tool's own options: a flag of one is an option with a value in another
check 2 Bash command 'tree -a -d ~'
check 2 Bash command 'tree -d ~'
check 2 Bash command 'du -m ~'
check 2 Bash command 'ls -A -R ~'
check 2 Bash command 'grep -r -T foo ~'
check 2 Bash command "fd -g '*.pdf' ~"
check 2 Bash command 'ag -t foo ~'
check 2 Bash command 'ack -f ~'
check 2 Bash command 'ag -g foo ~'
check 2 Bash command 'env -u FOO find ~ -name x'
check 2 PowerShell command 'gci ~ -s -Filter *.pdf'
check 2 PowerShell command 'gci -re ~'
check 2 PowerShell command '$files = gci $HOME -r'
check 2 Bash command 'cmd //c "dir /b/s %USERPROFILE%"'
check 2 Bash command 'timeout -s KILL 10 find ~ -name x'
check 2 Bash command 'sudo -u x find ~ -name x'
check 2 Glob pattern 'C:/Users/tester/**/*.pdf'
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
check 0 Bash command 'find src docs \( -name node_modules -o -name .next \) -prune -o -type f -print'
check 0 Bash command 'find src \! -name x'
check 0 Bash command 'find src -name x -exec ls {} \;'
check 0 Bash command 'ls -R \(old\)'
check 0 Bash command 'find "\(" -name a' 'C:\Users\tester'
check 0 Bash command 'find /c/Users/tester/Dropbox\ \(Contoso\)-Archiv -name x'
check 0 Bash command 'find "C:\\Users\\tester\\Documents\\GitHub\\proj\\" -name x'
# In double quotes \" is a quote character, so this is a folder Dropbox (Contoso)" next to the root
check 0 Bash command 'find "/c/Users/tester/Dropbox (Contoso)\"/x" -name a'
# Unquoted, bash drops these backslashes: C:Userstester is no folder, the profile is not searched
check 0 Bash command 'find C:\Users\tester\ -name x'
check 0 Bash command $'grep -rn foo \\\nsrc/'
check 0 Bash command $'find src docs \\\n  -name x'
check 0 Bash command $'rg -n foo \\\n  src'
# The text of a here-document is not run, unless a shell reads it
check 0 Bash command $'git commit -F - <<\'EOF\'\ngrep -rn foo ~ is blocked now\nEOF'
check 0 Bash command $'cat > notes.md <<\'EOF\'\nfind ~ -name x lists every file\nEOF'
check 0 Bash command 'echo done # find ~ -name x'
check 0 Bash command 'cd /d/Sync/Team\ Files-Old && find . -name a'
# cd - goes back to the folder before, which is unknown at the start of the command
check 0 Bash command 'cd - && find . -name x'
check 0 Bash command 'cd ~/Documents/GitHub/other && cd - && find . -name x'
check 0 PowerShell command 'Push-Location ~; Get-ChildItem; Pop-Location; Get-ChildItem -Recurse'
check 0 Bash command 'rg TODO src > "C:\Users\tester\OneDrive - Contoso\todo.txt"'
check 0 Bash command 'command -v find' 'C:\Users\tester'
check 0 Bash command 'command -v rg >/dev/null && rg foo src' 'C:\Users\tester'
check 0 Bash command 'rg --version' 'C:\Users\tester'
check 0 Bash command 'ls -ltr ~'
check 0 Bash command 'ls -r ~'
# In cmd and PowerShell, find is the Windows FIND, which searches text and not folders
check 0 Bash command 'cmd //c "netstat -an | find /c \"LISTENING\""'
check 0 PowerShell command 'netstat -an | find /c "LISTENING"'
check 0 Bash command 'powershell -Command "Get-ChildItem -Path \".\" -Recurse -Filter *.json"'
check 0 Bash command 'cmd //c "cd /d C:\Users\tester\Documents\GitHub\proj && dir /s"' 'C:\Users\tester'
check 0 Bash command 'fd -e md . .claude' 'C:\Users\tester'
check 0 Bash command "fd -g '*.md' src" 'C:\Users\tester'
check 0 Bash command "tree -P '*.md' src" 'C:\Users\tester'
check 0 Bash command "tree -I '*.log' src" 'C:\Users\tester'
check 0 PowerShell command 'gci -r -inc *.md -path .\Documents' 'C:\Users\tester'
# A cd in a child shell ends with it; a here-document a script reads is its input
check 0 Bash command 'bash -c "cd ~" && rg foo'
check 0 Bash command "bash -c 'pushd ~' ; rg foo"
check 0 Bash command $'bash <<\'EOF\'\ncd ~\nEOF\nrg foo'
check 0 Bash command $'bash script.sh <<\'EOF\'\nfind ~ -name x\nEOF'
check 0 Glob pattern 'src/**/*.ts'
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

# A broken install blocks, so the gap shows, instead of letting every search through unchecked
tmp=$(mktemp -d)
trap 'rm -f "$reg_output"; rm -rf "$tmp"' EXIT
cp "$hook" "$tmp/block-profile-wide-search.sh"
saved=$hook
hook=$tmp/block-profile-wide-search.sh
check 2 Bash command 'find . -name x'
hook=$saved

# Large commands stay well inside the timeout: a hook that times out lets the command run unchecked.
# The limit catches a return of the old quadratic tokenizer (30 s at 28 KB), with room for a busy
# machine.
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
heredoc="python - <<'EOF'"$'\n'
for i in $(seq 1 400); do heredoc+="print('grep -rn something in line $i of a long patch script, find nothing')"$'\n'; done
heredoc+="EOF"
# One long quoted word full of backslashes
quoted='python -c "'
for i in $(seq 1 600); do quoted+="print(\\\"line $i Ölwerk\\\\n\\\"); "; done
quoted+='"; ls -R src'
# Many short commands, each a listing the hook has to look at
script=""
i=0
while ((${#script} < 30000)); do
    i=$((i + 1))
    script+="echo line $i with a few short words a b c d e f g; ls -la src/dir$i"$'\n'
done
timed "here-document of ${#heredoc} bytes" 5000 0 "$heredoc"
timed "quoted word of ${#quoted} bytes" 5000 0 "$quoted"
timed "script of ${#script} bytes" 5000 0 "$script"
timed "the same with a profile search at its end" 5000 2 "${script}find ~ -name x"

echo "$run cases, $fail failed"
((fail == 0))
