#!/usr/bin/env bash
# Tests for block-denied-reads.sh: each case feeds a PreToolUse payload and expects exit 2
# (blocked) or 0 (allowed). Run: bash hooks/block-denied-reads.test.sh
# Everything happens in a made-up tree in a temporary folder, with its own user and project
# settings, so the cases hold on any machine; the files are empty stand-ins. As in the other
# suites the halves mirror each other: the same command once on the denied side, once beside it.

hook="$(dirname "$0")/block-denied-reads.sh"
fail=0
run=0
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
# The tree in the Windows spelling where there is one (C:/Users/...), as Claude Code sends it
win=$(cd "$root" && pwd -W 2> /dev/null) || win=$root
if [[ $win =~ ^([A-Za-z]):(.*)$ ]]; then abs=//${BASH_REMATCH[1],,}${BASH_REMATCH[2]}; else abs=/$win; fi
proj=$win/proj

mk() { mkdir -p "$root/${1%/*}" && : > "$root/$1"; }
mk proj/inbox/transcripts/private/a.md
mk proj/inbox/transcripts/shared/b.md
mk proj/inbox/recordings/x.m4a
mk proj/notes/n.md
mk proj/.editor/app.json
mk proj/.env
mk proj/.env.example
mk proj/certs/k.pem
mk proj/secret-notes/s.md
mk proj/allowed/ok.md
mk proj/plain/.env
mk proj/plain/code.txt
mk proj/Team\ Files/inbox/transcripts/private/t.md
mk depth/one/two/inbox/transcripts/private/d.md
mk proj/archive/2024/sealed/s.md
mk proj/archive/2023/open.md
mk proj/attic/old.md
mk Vault/inbox/Benchmark/b.wav
mk Vault/notes/o.md
mk home/personal/p.txt
mk empty-home/.claude/keep
mk proj2/src/a.txt
mk proj3/build/out.txt
mk proj4/old/a.txt
mk proj5/notes/n.md
mk proj6/secrets/s.txt
mk proj6/notes/n.md
for d in proj2 proj3; do
    mkdir -p "$root/$d/.claude"
    printf '%s\n' '{"permissions":{"deny":["Read(./build/**)"]}}' > "$root/$d/.claude/settings.json"
done
mkdir -p "$root/proj4/.claude" "$root/proj5/.claude" "$root/proj6/.claude"
printf '%s\n' '{"permissions":{"deny":["Read(./*(old)/**)"]}}' > "$root/proj4/.claude/settings.json"
for d in proj5 proj6; do
    printf '%s\n' '{"permissions":{"deny":["Read(**/secrets/**)"]}}' > "$root/$d/.claude/settings.json"
done

export HOME=$root/home
export CLAUDE_CONFIG_DIR=$win/home/.claude
export CLAUDE_PROJECT_DIR=$proj
mkdir -p "$root/home/.claude" "$root/proj/.claude"
# The Read rules of allow and ask come first and must not count
cat > "$root/home/.claude/settings.json" << EOF
{
  "permissions": {
    "allow": ["Read(//**/allowed/**)", "Bash(git status)"],
    "ask": ["Read(//**/notes/**)"],
    "deny": [
      "Read(//**/.env)",
      "Read(//**/_netrc)",
      "Read(//**/.credentials.json)",
      "Read(//**/.token)",
      "Read(~/.ssh/id_*)",
      "Read(//**/.secret.*)",
      "Read(//**/vault-secret/*.*)",
      "Read(//**/*.pem)",
      "Bash(ssh *)",
      "Read(//**/inbox/recordings/**)",
      "Read(//**/inbox/transcripts/private/**)",
      "Edit(//**/inbox/transcripts/shared/**)"
    ]
  },
  "autoMode": { "soft_deny": ["Read(//**/shared/**)"] }
}
EOF
printf '%s\n' '{' '  "permissions": {' '    "deny": [' '      "Read(./.editor/**)",' \
    '      "Read(/secret-notes/**)",' '      "Read(/archive/**/sealed/**)",' '      "Read(/config/_netrc)",' "      \"Read($abs/Vault/inbox/Benchmark/**)\"" '    ]' '  }' '}' > "$root/proj/.claude/settings.json"
printf '%s\r\n' '{' '  "permissions": { "deny": ["Read(~/personal/**)"] }' '}' > "$root/proj/.claude/settings.local.json"

check() {  # expected exit, tool, command[, cwd]
    local json value=$3 cwd=${4:-$proj}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    json="{\"session_id\":\"t\",\"cwd\":\"${cwd//\\/\\\\}\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"$2\",\"tool_input\":{\"command\":\"$value\"}}"
    printf '%s' "$json" | bash "$hook" 2> /dev/null
    local got=$?
    run=$((run + 1))
    if [[ $got != "$1" ]]; then
        fail=$((fail + 1))
        echo "FAIL expected $1 got $got: $2 $3 (cwd ${4:-proj})"
    fi
}

# A glob that expands to a denied file, which Claude Code's own check lets through
check 2 Bash 'cat inbox/transcripts/priv*/a.md'
check 0 Bash 'cat inbox/transcripts/shar*/b.md'
check 2 Bash 'cat inbox/transcripts/*/a.md'
# A glob is compared, never expanded: one that could name the denied folder is refused even
# where the file it names lies elsewhere
check 2 Bash 'cat inbox/transcripts/*/b.md'
check 0 Bash 'cat inbox/transcripts/sh*/b.md'
check 2 Bash 'cat inbox/*/private/*'
# inbox/*/shared/* may be inbox/recordings/shared/x
check 2 Bash 'cat inbox/*/shared/*'
check 0 Bash 'cat inbox/transcripts/shared/*'
check 2 Bash 'head -n 3 inbox/transcripts/*/a.md'
check 2 Bash 'cat inbox/transcripts/pr?vate/a.md'
check 2 Bash 'cat inbox/transcripts/[p]rivate/a.md'
check 2 Bash 'wc -l inbox\transcripts\*\a.md'
check 2 Bash "cat $win/proj/inbox/transcripts/*/a.md"
check 2 Bash 'cd inbox/transcripts && cat */a.md'
check 2 Bash 'cd inbox/transcripts && cat */b.md'
check 0 Bash 'cd inbox/transcripts && cat sh*/b.md'
check 2 Bash 'cd inbox && sort transcripts/*/*.md'
check 2 Bash 'cat inbox/transcripts/private/none*'
check 0 Bash 'cat inbox/transcripts/shared/none*'
check 2 PowerShell 'Get-Content inbox\transcripts\*\a.md'
check 2 PowerShell 'Get-Content inbox\transcripts\*\b.md'
check 0 PowerShell 'Get-Content inbox\transcripts\sh*\b.md'
check 2 PowerShell 'gc -Path inbox/transcripts/priv*/a.md -Raw'
check 2 Bash 'cat certs/*.pem'
check 0 Bash 'cat certs/*.crt'
check 2 Bash 'cat .env*'
check 0 Bash 'cat .env.ex*'
check 2 Bash 'cat .editor/*'
check 2 Bash 'cat secret-notes/*.md'
check 0 Bash 'cat notes/*.md'
check 2 Bash 'cat ~/personal/*'
check 2 Bash "cat $win/Vault/inbox/Bench*/*"
check 0 Bash "cat $win/Vault/notes/*"
check 0 Bash 'cat allowed/*'
# In bash * names no dot file. In PowerShell it does, but a bare * is never counted against a
# file rule's name (see comp_compat), so that Get-Content dir\* stays usable: a known gap
check 0 Bash 'cat plain/*'
check 0 PowerShell 'Get-Content plain\*'
check 2 PowerShell 'Get-Content plain\.e*'
check 0 Bash 'cat plain/*.txt'
check 2 Bash 'cat plain/.e*'

# Readers Claude Code does not know, on a plain denied path
check 2 Bash 'less inbox/transcripts/private/a.md'
check 0 Bash 'less inbox/transcripts/shared/b.md'
check 2 Bash 'more inbox/transcripts/private/a.md'
check 2 Bash 'xxd inbox/transcripts/private/a.md'
check 2 PowerShell 'type inbox\transcripts\private\a.md'
check 2 PowerShell 'Get-Content -LiteralPath "inbox\transcripts\private\a.md"'
check 0 PowerShell 'Get-Content -LiteralPath "inbox\transcripts\shared\b.md"'
check 2 PowerShell 'Select-String -Path inbox\transcripts\private\a.md -Pattern x'
check 2 Bash 'cat INBOX/TRANSCRIPTS/PRIVATE/a.md'
check 2 Bash 'cat inbox/transcripts/shared/../private/a.md'
check 2 Bash 'ls inbox/transcripts/private'
check 0 Bash 'ls inbox/transcripts'
check 2 PowerShell 'Get-ChildItem inbox\transcripts\private'
check 0 PowerShell 'Get-ChildItem inbox\transcripts'

# A search that descends into a denied folder from above it
check 2 Bash 'grep -rn word inbox/transcripts'
check 0 Bash 'grep -rn word inbox/transcripts/shared'
check 2 Bash 'grep -r word inbox'
check 2 Bash 'grep -r word .'
check 0 Bash 'grep -r word notes'
check 0 Bash 'grep word inbox/transcripts'
check 2 Bash 'grep --recursive word inbox'
check 2 Bash 'grep -d recurse word inbox'
check 2 Bash 'rg word'
check 2 Bash 'rg word inbox'
check 0 Bash 'rg word notes'
check 0 Bash 'rg inbox notes'
check 2 Bash 'find inbox -name "*.md"'
check 2 Bash 'find . -name "*.md"'
check 0 Bash 'find notes -name "*.md"'
check 2 Bash 'ls -R inbox'
check 0 Bash 'ls -l inbox'
check 2 Bash 'tree inbox'
check 2 Bash 'du -sh inbox'
check 2 Bash 'fd md inbox'
check 2 Bash 'tar -cf out.tar inbox'
check 0 Bash 'tar -cf out.tar notes'
check 2 Bash 'zip -r out.zip inbox'
check 0 Bash 'zip out.zip inbox'
check 2 Bash '7z a out.7z inbox'
check 2 Bash 'cp -r inbox /tmp/copy'
check 2 Bash 'cp -a inbox /tmp/copy'
check 0 Bash 'cp --parents notes/n.md /tmp/copy'
check 0 Bash 'cp -r notes /tmp/copy'
check 2 Bash 'rsync -a inbox/ /tmp/copy/'
check 2 Bash 'diff -r inbox /tmp/other'
check 0 Bash 'diff notes/n.md /tmp/other'
check 2 Bash 'gzip -r inbox'
check 2 PowerShell 'Get-ChildItem -Recurse inbox'
check 2 PowerShell 'gci inbox -rec'
check 0 PowerShell 'gci notes -Recurse'
check 2 PowerShell 'Copy-Item -Recurse inbox C:\copy'
check 0 PowerShell 'Copy-Item inbox\transcripts\shared\b.md C:\copy'
check 2 PowerShell 'Compress-Archive -Path inbox -DestinationPath out.zip'
check 2 Bash 'cmd /c dir /s inbox'
check 0 Bash 'cmd /c dir inbox'
check 2 Bash 'cmd /c "xcopy inbox C:\copy /s"'
check 2 Bash 'robocopy inbox C:/copy /e'
check 0 Bash 'robocopy inbox C:/copy'
check 2 Bash 'cmd /c findstr /s word inbox\*'
check 2 Bash 'grep -r word proj' "$win"
check 2 Bash 'cd .. && grep -r word proj'
check 0 Bash 'cd .. && grep -r word Vault/notes'
check 2 Bash "grep -r word '$win/proj/Team Files'"
check 2 Bash 'grep -r word Team\ Files'
# The rest of a ** rule straight below the searched folder; deeper it is not looked for, as that
# would mean listing folders
check 2 Bash "grep -r word $win/depth/one/two"
check 0 Bash "grep -r word $win/depth/one"
check 0 Bash "grep -r word $win/depth"
# A rule with a fixed start and a ** inside: any search inside that start may reach it
# The rest after a fixed start's ** is looked for straight below, as for a rule starting with **
check 0 Bash 'grep -r word archive'
check 2 Bash 'grep -r word archive/2024'
check 0 Bash 'grep -r word archive/2023'
check 0 Bash 'grep -r word attic'
check 2 Bash 'cat archive/*/sealed/s.md'
# archive/*/open.md names no plain part after the rule's ** (sealed), so it does not count
check 0 Bash 'cat archive/*/open.md'
check 0 Bash 'cat attic/*/open.md'
check 2 Bash "grep -r word $win/Vault"
check 2 Bash "grep -r word $win"
check 0 Bash "grep -r word $win/Vault/notes"
check 2 Bash 'grep -r word inbox/*'
check 2 Bash 'grep -r word inbox/tr*'
check 0 Bash 'grep -r word inbox/sh*'
check 0 Bash 'grep -r word notes/*'
check 2 Bash 'grep -r word .editor'
check 2 Bash 'grep -r word secret-notes'
check 2 Bash 'grep -r word ~'
# A folder that holds only a denied file: file rules count for paths and globs, not for searches
check 0 Bash 'grep -r word plain'
check 0 Bash 'rg word certs'

# Behind wrappers, in other shells, piped into xargs
check 2 Bash "bash -c 'cat inbox/transcripts/*/a.md'"
check 2 Bash 'timeout 5 grep -r word inbox'
check 2 Bash 'echo start && grep -r word inbox | head'
check 2 Bash $'echo start\ngrep -r word inbox'
check 2 Bash 'echo inbox/transcripts/private/a.md | xargs cat'
check 0 Bash 'echo inbox/transcripts/shared/b.md | xargs cat'
check 2 Bash 'printf "%s\n" inbox/transcripts/priv*/a.md | xargs -n 1 less'
check 2 Bash 'powershell -Command "Get-Content inbox\transcripts\private\a.md"'
check 0 Bash 'powershell -Command "Get-Content inbox\transcripts\shared\b.md"'
check 2 Bash 'cmd /c type inbox\transcripts\private\a.md'
check 2 Bash 'find notes -exec cat inbox/transcripts/private/a.md \;'
check 2 Bash 'cat $(ls -d inbox/transcripts/priv*)/a.md'

# Inline code of an interpreter
check 2 Bash "python -c \"print(open('inbox/transcripts/private/a.md').read())\""
check 0 Bash "python -c \"print(open('inbox/transcripts/shared/b.md').read())\""
check 2 Bash "python -c \"import glob; print(glob.glob('inbox/transcripts/*/*.md'))\""
check 2 Bash "python3 -X utf8 -c \"open(r'inbox\\transcripts\\private\\a.md')\""
check 2 Bash "node -e \"require('fs').readFileSync('inbox/transcripts/private/a.md')\""
check 2 Bash "perl -e 'print \`cat inbox/transcripts/private/a.md\`'"
check 0 Bash "python -c \"print('hello')\""
check 0 Bash "node -e \"console.log(1)\""
check 0 Bash 'python tools/report.py inbox/transcripts/private'

# Mentions, not reads, and programs that are no readers
check 0 Bash 'uv run mytool import inbox/recordings/x.m4a'
check 0 Bash 'echo "inbox/transcripts/private"'
check 0 Bash 'git status'
check 0 Bash 'git commit -m "cat inbox/transcripts/*/a.md and grep -r x inbox"'
check 0 Bash 'grep -rn "private" notes'
check 0 Bash 'grep -r "inbox/transcripts/private" notes'
check 0 Bash 'rg -g "*private*" word notes'
check 0 Bash 'mkdir -p out && ls out'
check 0 Bash 'cat <<EOF
grep -r word inbox
EOF'
check 0 PowerShell 'Write-Output "Get-Content inbox\transcripts\private\a.md"'

# Review round 1: the command's text is never run, not even inside the hook's own bookkeeping
check 0 Bash "grep -r word 'notes\$(touch $win/ran1)'"
check 0 Bash "grep -r word \"\$(touch $win/ran2)/notes\""
check 0 Bash "du -sh \"\`touch $win/ran3\`\""
check 0 Bash 'grep -r word "a]b"'
check 0 Bash "ls -R '[!'"
for m in ran1 ran2 ran3; do
    run=$((run + 1))
    [[ -e $root/$m ]] && { fail=$((fail + 1)); echo "FAIL the hook ran code from the command: $m exists"; }
done
check 0 Bash 'for d in src docs; do grep -rn TODO "$d"; done'
check 0 Bash 'find "$TMPDIR" -name "*.log"'
check 0 Bash 'rg TODO "$PWD/src"'
# A bare * names every file, but counting it against every file rule would refuse each cat dir/*
check 0 Bash 'cat notes/*'
check 0 Bash 'grep -n TODO notes/*'
check 0 Bash 'wc -l notes/*'
check 0 PowerShell 'Get-Content notes\*'
check 0 Bash "python3 -c \"print('*' * 40)\""
check 0 Bash "python3 -c \"import re; print(re.findall('.*', 'ab'))\""
check 2 Bash 'cat notes/_net*'
check 2 Bash 'cat notes/*netrc'
check 2 Bash 'cat notes/.cred*'
# Inline code from a here-document, and an interpreter behind a runner
check 2 Bash $'python3 - <<\'PY\'\nprint(open(\'inbox/transcripts/private/a.md\').read())\nPY'
check 2 Bash $'python3 <<\'PY\'\nprint(open(\'inbox/transcripts/private/a.md\').read())\nPY'
check 2 Bash $'node <<\'JS\'\nrequire(\'fs\').readFileSync(\'inbox/transcripts/private/a.md\')\nJS'
check 0 Bash $'python3 - <<\'PY\'\nprint(\'hello\')\nPY'
check 2 Bash "uv run python -c \"print(open('inbox/transcripts/private/a.md').read())\""
check 2 Bash 'uv run --with rich python3 -c "open(\"inbox/transcripts/private/a.md\")"'
check 2 Bash 'poetry run cat inbox/transcripts/*/a.md'
check 0 Bash "uv run python -c \"print(open('notes/n.md').read())\""
# Windows recursion with a wildcard: the wildcard filters names, the search starts in its folder
check 2 PowerShell 'Get-ChildItem -Recurse *.md | Select-String word'
check 2 PowerShell 'Get-ChildItem *.md -Recurse | Get-Content'
check 0 PowerShell 'Get-ChildItem -Recurse *.md' "$proj/notes"
check 2 Bash 'cmd /c findstr /s word *.md'
check 2 Bash 'cmd /c dir /s /b *.md'
check 0 Bash 'cmd /c dir /s /b notes\*.md'
# Program text, patterns and separators are no paths
check 0 Bash "sed -i 's/inbox\\/transcripts\\/private/inbox\\/private/' notes/n.md"
check 0 Bash "awk '/\\.env/' notes/n.md"
check 0 Bash "cut -d '*' -f1 notes/n.md"
check 0 Bash "jq '.[] | .x' notes/n.md"
check 0 PowerShell "Select-String -Path notes\\*.md -Pattern 'inbox/transcripts/private'"
check 0 PowerShell "Select-String -Path notes\\*.md -Pattern '\\.env'"
check 2 Bash 'sed -n 1p inbox/transcripts/*/a.md'
check 2 Bash "sed -e 's/x/y/' inbox/transcripts/*/a.md"
check 2 Bash 'awk 1 inbox/transcripts/*/a.md'
check 2 Bash "jq . inbox/transcripts/*/a.md"
check 2 PowerShell 'Select-String -Path inbox\transcripts\*\a.md -Pattern x'
# A folder rule refuses a search above its folder only when the folder is there
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj2 check 0 Bash 'rg TODO' "$win/proj2"
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj2 check 0 Bash 'grep -rn TODO .' "$win/proj2"
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj3 check 2 Bash 'rg TODO' "$win/proj3"
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj3 check 2 Bash 'cat build/*' "$win/proj3"
# Extracting writes into a folder, it does not read it
check 0 Bash 'tar -xzf pkg.tgz -C .'
check 0 Bash 'tar -xf pkg.tar'
check 0 Bash 'tar --extract -f pkg.tar -C notes'
check 2 Bash 'tar -czf out.tgz .'
# Brace lists, PowerShell lists and glued values, a ** that spans folders
check 2 Bash 'cat inbox/transcripts/{private,shared}/a.md'
check 0 Bash 'cat inbox/transcripts/{shared,other}/b.md'
check 2 PowerShell 'Get-Content notes\n.md,inbox\transcripts\private\a.md'
check 2 PowerShell 'Get-Content -Path:inbox\transcripts\private\a.md'
check 2 Bash "python3 -c \"import glob; print(glob.glob('inbox/**/*.md', recursive=True))\""
check 0 Bash 'cat notes/**/*.md'

# Mutation round: cases the first mutants survived
# The name of a file rule without ** in front: compared exactly, a bare * still does not count
check 0 Bash 'cat config/*'
check 2 Bash 'cat config/_net*'
check 0 Bash 'cat config/*.md'
# A glob with plain characters against a dot file: bash's * skips dot files, PowerShell's does not
check 0 Bash 'cat notes/*en'
check 2 PowerShell 'Get-Content notes\*en'
# A file rule's name is the last part: a glob meeting it in the middle names no such file
check 0 Bash 'cat notes/_net*/x.md'
# A search over a glob that ends in the start of a ** rule's rest
check 2 Bash 'grep -r word */inbox' "$win"
check 0 Bash 'grep -r word */notes' "$win"
# Where only the ** rule's rest can be reached: depth/one/two/inbox/transcripts/private
check 2 Bash 'grep -r word */inbox' "$win/depth/one"
check 0 Bash 'grep -r word */notes' "$win/depth/one"
# Select-String's pattern is its first plain argument unless -Pattern names it; -Path is no -Pattern
check 2 PowerShell 'Select-String -Path inbox\transcripts\private\a.md word'
check 0 PowerShell 'Select-String -Path notes\n.md inbox\transcripts\private\a.md'

# Replay round: a glob of bare wildcards names no plain part of a ** rule, so it does not count
check 0 Bash "python3 -c \"import glob; print(glob.glob('data/raw/*/*/x.gz'))\""
check 0 Bash 'ls docs/*/*'
check 0 Bash 'grep -n word src/*/*/*.cs'
check 2 Bash 'cat inbox/*/x'
check 2 Bash 'cat */recordings/x'
check 2 Bash 'cat inbox/rec*/x'
# A known gap that follows: a recursive search over bare wildcards that would reach the rest
check 0 Bash 'grep -r word */*' "$win/depth/one"
# ( ) and | in a word are characters, not bash's extended patterns
check 0 Bash "python3 -c \"re.sub(r'**(done,', '', s)\""
check 0 Bash 'cat notes/*(x)'
check 0 Bash 'cat notes/@(a|b)'
# A plain path naming a denied folder itself reads it only when listed or searched
# For inline code the folder itself counts when named by a path; a bare word is mostly a key or a
# word of a message, so os.listdir('secret-notes') is a known gap
check 0 Bash "python3 -c \"print(os.path.exists('secret-notes'))\""
check 2 Bash "python3 -c \"print(os.listdir('./secret-notes'))\""
check 0 Bash "python3 -c \"print('leave secret-notes out')\""
check 0 Bash "python3 -c \"print(d['secret-notes'])\""
check 0 Bash "python3 -c \"print('**s merge')\""
check 2 Bash "python3 -c \"os.system('cat secret-notes/s.md')\""
check 2 Bash "python3 -c \"print(open('secret-notes/s.md').read())\""
check 0 Bash 'cat secret-notes'
check 2 Bash 'ls secret-notes'
check 2 Bash 'grep -r word secret-notes'

# Replay round 2: escapes of inline code, patterns of the code, listings of files
check 0 Bash "python3 -c \"f.write('secret-notes\\n')\""
check 2 Bash "python3 -c \"open('secret-notes\\s.md')\""
check 0 Bash "python3 -c \"x = '**\\u00dcberholt'\""
check 0 Bash "python3 -c \"re.compile('*\\(')\""
check 2 Bash "python3 -c \"glob.glob('secret-notes/*')\""
check 0 Bash 'ls notes/.env*'
check 0 Bash 'ls -la .env'
check 0 PowerShell 'Get-ChildItem .env*'
check 2 Bash 'grep -n KEY .env*'
check 2 Bash 'ls -R .editor'

# Review round 2
# A project-relative ** rule: the rest is looked for straight below, not refused everywhere
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj5 check 0 Bash 'grep -rn TODO notes' "$win/proj5"
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj5 check 0 Bash 'rg TODO' "$win/proj5"
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj6 check 2 Bash 'rg TODO' "$win/proj6"
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj6 check 0 Bash 'grep -rn TODO notes' "$win/proj6"
# The folder itself, for programs that read what is in a folder they are given
check 2 Bash "python3 -c \"print(os.listdir('inbox/transcripts/private'))\""
check 2 Bash "python3 -c \"from pathlib import Path; print((Path('inbox/transcripts/private') / 'a.md').read_text())\""
check 0 Bash "python3 -c \"print(os.listdir('inbox/transcripts/shared'))\""
check 2 Bash 'robocopy inbox\transcripts\private C:\backup'
check 2 Bash 'cmd /c "xcopy inbox\transcripts\private C:\backup"'
check 2 Bash 'diff inbox/transcripts/private inbox/transcripts/shared'
check 0 Bash 'diff notes/n.md notes/n.md'
# Two globs meet when one plain start begins the other and one plain end ends the other
# A glob that leaves open the end a rule fixes is not counted (k.* for *.pem): a known gap
check 0 Bash 'cat certs/k.*'
check 0 Bash 'head certs/k.p*'
check 2 Bash 'cat certs/k*.pem'
check 2 PowerShell 'Get-Content certs\k*.pem'
check 2 Bash 'cat ~/.ssh/id*'
check 0 Bash 'cat ~/.ssh/known*'
# A PowerShell reader without a path reads what is piped into it
check 2 PowerShell 'Get-ChildItem .env* | Get-Content'
check 2 PowerShell 'Get-ChildItem certs\*.pem | Get-Content'
check 2 PowerShell 'Get-ChildItem plain\.env | Select-String TOKEN'
check 0 PowerShell 'Get-ChildItem notes | Get-Content'
# Perl, ruby and php keep \t and \n in single quotes as written
check 2 Bash "perl -e \"open F, 'inbox\\transcripts\\private\\a.md'; print <F>\""
check 2 Bash "ruby -e \"puts File.read('inbox\\transcripts\\private\\a.md')\""
# An escaped quote does not end a string of inline code
check 2 Bash "python3 -c \"print('it\\'s'); print(open('inbox/transcripts/private/a.md').read())\""
# Code piped into an interpreter
check 2 Bash $'cat <<\'EOF\' | python3\nprint(open(\'inbox/transcripts/private/a.md\').read())\nEOF'
check 2 Bash "echo \"print(open('inbox/transcripts/private/a.md').read())\" | python3"
check 0 Bash 'echo "print(1)" | python3'
# Mutants that survived: the window's end, bash's extended patterns, a glob of the folder itself
check 0 Bash 'cat .en*/ab*'
check 0 Bash 'cat "notes/*@(_netrc)"'
# A glob naming a denied folder itself, for a rule without ** in front
check 0 Bash 'cat secret-*'
check 2 Bash 'ls secret-*'
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj4 check 0 Bash 'cat old/*' "$win/proj4"
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/proj4 check 2 Bash 'cat "x(old)"/*' "$win/proj4"
check 0 Bash 'cat inbox/transcripts/*'
check 2 Bash 'ls inbox/transcripts/*'

# Replay round 3: a rule with a plain start and an open end (.secret.*) meets no glob without a
# plain start of two characters, or every grep x src/*.ts would be refused
check 0 Bash 'grep -n word notes/*.md'
check 0 Bash 'wc -l *.md'
check 0 PowerShell 'Get-Content notes\*.md'
check 2 Bash 'cat notes/.secret.*'
check 2 Bash 'cat notes/.se*'
check 0 Bash 'cat ~/.ssh/*'
# A rule glob without plain characters (vault-secret/*.*) is met by a bare * too
check 2 Bash 'cat x/vault-secret/*'
check 2 Bash 'cat x/vault-secret/a.txt'
check 0 Bash 'cat x/vault-secret'
# The words of a prose string go through the same test as the string
check 0 Bash "python3 -c \"print('see .e* files')\""
check 0 Bash "python3 -c \"print('see .e* in a/b')\""

# Other tools are not this hook's
json="{\"session_id\":\"t\",\"cwd\":\"$proj\",\"tool_name\":\"Read\",\"tool_input\":{\"file_path\":\"$proj/inbox/transcripts/private/a.md\"}}"
printf '%s' "$json" | bash "$hook" 2> /dev/null
got=$?
run=$((run + 1))
[[ $got == 0 ]] || { fail=$((fail + 1)); echo "FAIL expected 0 got $got: the Read tool"; }

# Without a Read deny rule anywhere it stays out of the way
CLAUDE_CONFIG_DIR=$win/empty-home/.claude CLAUDE_PROJECT_DIR=$win/Vault check 0 Bash 'grep -r word inbox' "$win/proj"
# READ_GUARD_NO_FS (for replays) asks the file system nothing: a search the stat would refuse
# passes, a glob compared on paper is still refused
READ_GUARD_NO_FS=1 check 0 Bash "grep -r word $win/depth/one/two"
READ_GUARD_NO_FS=1 check 2 Bash 'cat inbox/transcripts/*/a.md'
# Without CLAUDE_PROJECT_DIR the project is the payload's cwd
CLAUDE_PROJECT_DIR= check 2 Bash 'cat secret-notes/*.md'
CLAUDE_PROJECT_DIR= check 0 Bash 'cat secret-notes/*.md' "$win/Vault"

# A missing library blocks a command it would have to read, and not one it would not
lone=$(mktemp -d)
cp "$hook" "$lone/block-denied-reads.sh"
for c in 'grep -r word inbox:2' 'git status:0'; do
    json="{\"session_id\":\"t\",\"cwd\":\"$proj\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"${c%:*}\"}}"
    printf '%s' "$json" | bash "$lone/block-denied-reads.sh" 2> /dev/null
    got=$?
    run=$((run + 1))
    [[ $got == "${c##*:}" ]] || { fail=$((fail + 1)); echo "FAIL expected ${c##*:} got $got without the library: ${c%:*}"; }
done
rm -rf "$lone"

# The message names the rule and the command's word, never a file it found by expanding
msg=$(printf '%s' "{\"cwd\":\"$proj\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"cat inbox/transcripts/*/a.md\"}}" | bash "$hook" 2>&1)
run=$((run + 1))
if [[ $msg != *'Read(//**/inbox/transcripts/private/**)'* || $msg != *"'inbox/transcripts/*/a.md'"* || $msg == *private/a.md* ]]; then
    fail=$((fail + 1))
    echo "FAIL message: $msg"
fi

# Time: a long command must stay well inside the hook's timeout
timed() {  # name limit-ms expected command
    local json value=$4 start ms got
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    json="{\"session_id\":\"t\",\"cwd\":\"$proj\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$value\"}}"
    start=$(date +%s%N)
    printf '%s' "$json" | bash "$hook" 2> /dev/null
    got=$?
    ms=$((($(date +%s%N) - start) / 1000000))
    run=$((run + 1))
    echo "timing: $1: $ms ms, exit $got"
    if [[ $got != "$3" ]] || ((ms >= $2)); then
        fail=$((fail + 1))
        echo "FAIL $1: expected exit $3 within $2 ms"
    fi
}
script=""
i=0
while ((${#script} < 30000)); do
    i=$((i + 1))
    script+="echo line $i; cat notes/n$i.md; ls -la notes/dir$i/*"$'\n'
done
timed "script of ${#script} bytes" 10000 0 "$script"
timed "the same with a glob into private at its end" 10000 2 "${script}cat inbox/transcripts/*/a.md"

echo "$run cases, $fail failed"
((fail == 0))
