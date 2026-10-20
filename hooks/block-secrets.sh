#!/usr/bin/env bash
# PreToolUse hook: blocks a Read, Grep, Bash or PowerShell call that reaches a secret file.
# Permission deny rules are best effort for Grep and do not reach shell commands at all, so this
# is the hard stop. Plain bash on purpose: Claude Code runs hooks through Git Bash on Windows, and
# a hook that needed node or jq would stop guarding, silently, on a machine without them.
# Exit 2 blocks the call and tells Claude why; exit 0 leaves it to the normal permission flow.
#
# Secret files: .env and .env.<anything> except the placeholder copies (.env.example, .env.sample,
# .env.template, .env.dist); private keys and certificates (*.pem, *.key, *.p12, *.pfx, id_rsa,
# id_dsa, id_ecdsa, id_ed25519 and their _sk variants, but not their .pub); the login files of
# Claude Code, git and curl (.credentials.json, .git-credentials, .netrc, _netrc); editor backups
# of all of these (a trailing ~).
# Not covered: a token file a workflow reads on purpose under its own name, a command that reads
# a secret without naming it (grep -r over a whole folder, a glob like .e*), and the Write and
# Edit tools. It is a guard against accidents, not against a determined attacker.
# Blocked although harmless: a command that only mentions such a name (a commit message, a line
# echoed into .gitignore); write that text with the file tools.
# Tests: hooks/block-secrets.test.sh

shopt -s nocasematch   # Windows file names ignore case: .ENV is .env
input=$(cat)

# Prints the JSON string value of the first key with this exact name
field() {
    local re='"'"$1"'"[[:space:]]*:[[:space:]]*"((\\.|[^"\\])*)"'
    [[ $input =~ $re ]] && printf '%s' "${BASH_REMATCH[1]}"
}

# Only the fields that name what the call touches; a Grep pattern is searched text, not a file
case $(field tool_name) in
    Read) subject=$(field file_path) ;;
    Grep) subject="$(field path) $(field glob)" ;;
    Bash | PowerShell) subject=$(field command) ;;
    *) exit 0 ;;
esac

# Placeholder copies and public keys are no secrets. Only when the text holds one at all: a
# substitution over a long command is slow in Git Bash, and a hook that runs into its timeout
# blocks nothing.
for placeholder in .env.example .env.sample .env.template .env.dist .pub; do
    [[ $subject == *"$placeholder"* ]] || continue
    if [[ $placeholder == .pub ]]; then
        for key in id_rsa id_dsa id_ecdsa id_ed25519 id_ecdsa_sk id_ed25519_sk; do
            subject=${subject//$key.pub/ }
        done
    else
        subject=${subject//$placeholder/ }
    fi
done

# A secret name as a whole path segment: bounded by start or end, a quote, whitespace, a path
# separator (a JSON-escaped backslash ends in a backslash too), a JSON escape for newline, return
# or tab, shell punctuation or a glob character (a Grep glob such as *.env* names the same files)
before='(^|["'"'"'[:space:]=:/\\(<>|&;`{,*?]|\\[nrt])'
names='(\.env(\.[A-Za-z0-9_.-]+)?|[A-Za-z0-9_.-]*\.(pem|key|p12|pfx)|id_(rsa|dsa|ecdsa|ed25519)(_sk)?|\.credentials\.json|\.git-credentials|[._]netrc)'
after='($|["'"'"'[:space:];|&)<>`\\*?,{}.:~])'
re="$before$names$after"

if [[ $subject =~ $re ]]; then
    echo "Blocked by the claude-setup secret guard: '${BASH_REMATCH[2]}' is a secret file and this call would read it. Ask the user to look it up themselves; do not try another way to read it." >&2
    exit 2
fi
exit 0
