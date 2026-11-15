#!/usr/bin/env bash
# Tests for closing-check-nudge.sh: each case feeds a Stop payload and expects the block decision
# on stdout (nudged) or nothing (let the session stop). Synthetic messages only, modelled on the
# measured phrase families; no transcript text.
# Run: bash hooks/closing-check-nudge.test.sh

hook="$(dirname "$0")/closing-check-nudge.sh"
fail=0
run=0
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/cfg-on/skills/closing-check" "$tmp/cfg-off"
: > "$tmp/cfg-on/skills/closing-check/SKILL.md"
block='{"decision":"block","reason":"Run the closing-check skill first, or say it was no such offer; that ends it."}'

json_text() {  # REPLY: $1 as the inside of a JSON string
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    REPLY=${s//$'\n'/\\n}
}

stop() {  # expected (nudge or pass), message[, skill folder[, stop_hook_active]]
    local json out got
    json_text "$2"
    json="{\"session_id\":\"t\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":${4:-false},\"last_assistant_message\":\"$REPLY\"}"
    out=$(printf '%s' "$json" | CLAUDE_CONFIG_DIR=$tmp/${3:-cfg-on} bash "$hook" 2>&1)
    got=$?
    run=$((run + 1))
    if [[ $got == 0 && (($1 == nudge && $out == "$block") || ($1 == pass && -z $out)) ]]; then
        return 0
    fi
    fail=$((fail + 1))
    echo "FAIL expected $1 got exit $got${out:+ and output $out}: ${2:0:120}"
}

# Offers of a clear or a handover, and "this session is done", in the measured German families
stop nudge 'Alles gemergt und aufgeräumt. Du kannst jetzt /clear machen.'
stop nudge 'Damit kannst du hier schließen.'
stop nudge 'Kannst du die Session zumachen? Von meiner Seite passt alles.'
stop nudge 'Fertig. Jetzt `/clear`, die Notiz liegt im Gedächtnis.'
stop nudge 'Ich empfehle ein `/clear`.'
stop nudge $'Nächste Schritte:\n1. `/clear`\n2. Startsatz einfügen'
stop nudge 'In dieser Session ist nichts mehr offen.'
stop nudge 'Für diese Session ist alles erledigt.'
stop nudge 'Diese Session ist damit abgeschlossen.'
stop nudge 'Für heute ist alles erledigt.'
stop nudge 'Hier ist nichts mehr offen, der Branch ist gelöscht.'
stop nudge 'Offen ist nichts mehr.'
stop nudge 'Startsatz für die neue Session: "Lies die Notiz und mach bei Task 4 weiter."'
stop nudge 'Übergabe zum Einfügen steht unten.'
stop nudge 'Nach dem /clear reicht: "weiter mit dem Plan".'
stop nudge 'Beim `/clear` geht nichts verloren, alles steht in der Notiz.'
stop nudge 'Die nächste Session setzt dort an, wo diese aufhört.'
stop nudge 'Mein Vorschlag bleibt: `/clear` und neu anfangen.'
stop nudge 'Soll ich eine Übergabe für die nächste Session schreiben?'
stop nudge 'Den Kontext leeren wäre jetzt sinnvoll.'
# Families of the first fresh sample's misses (2026-11-15), reworded
stop nudge 'Die Notiz ist ergänzt. Du kannst jetzt leeren.'
stop nudge 'Ja, mach zu. Hier ist alles erledigt.'
stop nudge 'Die nächste Sitzung fängt mit dem README an.'
stop nudge 'Den ganzen Stand findet die nächste Sitzung in der Projektnotiz.'
stop nudge 'Gemerkt habe ich den Stand, damit die nächste Sitzung nicht wieder sucht.'
stop nudge 'Dafür schlage ich eine frische Sitzung vor, diese ist schon lang.'
stop nudge 'Als Nächstes #12 in einer frischen Session.'
stop nudge 'Du kannst die Mail abschicken und dann `/clear` machen.'
stop nudge $'Also: `/clear`, dann:\n> Weiter laut Notiz.'
stop nudge 'Die letzte Frage kannst du auch in der neuen Session beantworten.'
stop nudge 'Danke dir, schönen Abend!'
# English offers
stop nudge 'Everything is merged. You can now run /clear.'
stop nudge 'It is safe to /clear now.'
stop nudge 'This session is done; the notes are saved.'
stop nudge 'Nothing else is open in this session.'
stop nudge 'Shall I write a handover for the next session?'
stop nudge 'You can close this session.'
# A list was shown: the offer stands
stop pass $'## Closing check\n1. Questions to the owner\n- [done] all answered: see above\n...\nDu kannst jetzt /clear machen.'
stop pass $'Erledigt.\r\n\r\n## Closing check\r\n1. Questions to the owner\r\nDu kannst jetzt /clear machen.'
# The second stop after a nudge lets the session stop: a false alarm costs one short turn
stop pass 'Du kannst jetzt /clear machen.' cfg-on true
# Not installed: no nudge
stop pass 'Du kannst jetzt /clear machen.' cfg-off
# Measured false alarms: another object closed, a commit question, a conditional mention of /clear
stop pass 'Der Pull Request ist abgeschlossen und gemergt.'
stop pass 'Issue #12 ist damit abgeschlossen; weiter mit #13.'
stop pass 'Hier ist nichts mehr offen. Darf ich committen?'
stop pass 'Falls du danach `/clear` machst, bleibt die Notiz erhalten.'
stop pass 'Wenn du später /clear machst, lies vorher die Notiz.'
# A clear after something still pending is a future offer, not this one
stop pass 'Wenn du beides so bestätigst, mache ich die Übergabe fertig, und du kannst `/clear` machen.'
stop pass $'Offen sind zwei Fragen.\n\nDanach kannst du `/clear` machen.'
stop pass '**Danach** kannst du `/clear` machen. Die nächste Sitzung startet mit der Notiz.'
stop pass 'Sagen Sie „merge“, dann merge ich #107. Danach können Sie `/clear` machen.'
stop pass 'Der Test schließt die Datei, bevor er sie löscht.'
stop pass 'Ich habe den Parser umgebaut; die Tests laufen grün.'
stop pass ''

# Batch mode for scripts/measure-closing-nudge.py: NUL-separated messages in, one 1 (nudged) or
# 0 per message out, by the same rules
out=$(printf 'Du kannst jetzt /clear machen.\0Die Tests laufen grün.\0## Closing check\nDu kannst jetzt /clear machen.\0' | CLOSING_NUDGE_SELFTEST=batch bash "$hook")
run=$((run + 1))
[[ $out == $'1\n0\n0' ]] || { fail=$((fail + 1)); echo "FAIL batch mode printed: ${out//$'\n'/ }"; }

# A Stop hook runs at the end of every turn: a long message stays fast. It takes 1 to 2 s on a busy
# machine (measured 2026-11-15); the limit leaves room for load and still catches a blow-up.
long=$(printf 'Ich habe den Parser umgebaut, die Tests laufen grün und die Doku ist nachgezogen. %.0s' $(seq 1 700))
start=$(date +%s%N)
stop pass "$long"
ms=$((($(date +%s%N) - start) / 1000000))
echo "timing: message of ${#long} bytes: $ms ms"
((ms < 5000)) || { fail=$((fail + 1)); echo "FAIL a message of ${#long} bytes took $ms ms"; }

echo "$run cases, $fail failed"
((fail == 0))
