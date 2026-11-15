#!/usr/bin/env bash
# Stop hook: when the session's last message offers a handover or a /clear, or says the session is
# done, and shows no closing check (a line `## Closing check`), it blocks the stop once with the
# reason "run the closing-check skill first, or say it was no such offer". The session then runs
# the check or answers in one line; with stop_hook_active set, the next stop passes, so a false
# alarm costs one short turn. On only when the closing-check skill is installed
# (${CLAUDE_CONFIG_DIR:-~/.claude}/skills/closing-check/SKILL.md). The Stop event fires for the
# main session only; subagents have their own.
# The phrases below are the single source: scripts/measure-closing-nudge.py runs this hook in its
# batch mode over local transcripts to measure precision and recall (2026-11-15: recall 0.650 and
# 0.675, precision 0.920 on two fresh samples; switched on by the owner below the bar of 0.80).
# Plain bash, no process on a normal call. A missing library lets every stop pass: a nudge is no
# guard.
# Not covered: an offer in words the list does not know (English is untested, the measured corpus
# held no English offers); a message that both offers a clear and asks for a commit, or mentions a
# /clear in a condition, passes (the exceptions below win).
# Tests: hooks/closing-check-nudge.test.sh

here=${BASH_SOURCE[0]%/*}
[[ $here == "${BASH_SOURCE[0]}" ]] && here=.
# shellcheck source=lib/command-segments.sh
source "$here/lib/command-segments.sh" 2> /dev/null || exit 0

# One bash extended regular expression per line, matched without case. No newline can appear in
# a pattern; [[:space:]] matches one. Letters outside ASCII are spelled in both cases ((ü|Ü)),
# as the hook may run in the C locale.
# nudge-patterns-begin
NUDGE_PATTERNS=(
'(du[[:space:]]+kannst|kannst[[:space:]]+du|können[[:space:]]+sie|darfst[[:space:]]+du)[[:space:]]+([^[:space:]]+[[:space:]]+){0,5}(`?/clear|clear(en)?([^[:alnum:]_]|$)|leeren([^[:alnum:]_]|$)|((die|diese)[[:space:]]+)?(session|sitzung)[[:space:]]+([^[:space:]]+[[:space:]]+){0,2}(schließen|zumachen)|schließen([^[:alnum:]_]|$)|zumachen|dich[[:space:]]+(jetzt[[:space:]]+)?ausklinken)'
'(jetzt|bitte|mach|also|empfehle([[:space:]]+ich)?|danach|ja,?[[:space:]]+gerne)[^[:alnum:]_]{0,6}(ein(en)?[[:space:]]+)?`/clear`'
'(^|[[:space:]])1\.[[:space:]]+\**`/clear`'
'(diese[rnm]?|f(ü|Ü)r[[:space:]]+mich[[:space:]]+ist[[:space:]]+diese)[[:space:]]+(session|sitzung)[[:space:]]+(ist[[:space:]]+)?((sonst|hier|damit)[[:space:]]+)?(nichts[[:space:]]+(weiter|mehr)[[:space:]]+offen|alles[[:space:]]+erledigt|durch([^[:alnum:]_]|$)|fertig([^[:alnum:]_]|$)|abgeschlossen)'
'f(ü|Ü)r[[:space:]]+heute[[:space:]]+ist[[:space:]]+((meine[[:space:]]+arbeit|alles)[[:space:]]+)?(erledigt|fertig|durch)'
'(in|f(ü|Ü)r|von)[[:space:]]+(dieser|der)[[:space:]]+(session|sitzung)[[:space:]]+(ist[[:space:]]+)?(sonst[[:space:]]+)?(nichts[[:space:]]+mehr[[:space:]]+offen|alles[[:space:]]+erledigt|abgeschlossen)'
'(hier|ich[[:space:]]+habe|von[[:space:]]+meiner[[:space:]]+seite|aus[[:space:]]+meiner[[:space:]]+sicht|sonst|damit)[[:space:]]+(ist[[:space:]]+)?([^[:space:]]+[[:space:]]+){0,2}nichts[[:space:]]+(mehr[[:space:]]+)?offen'
'offen[[:space:]]+ist[[:space:]]+nichts[[:space:]]+mehr'
'(hier|damit|sonst)[[:space:]]+ist[[:space:]]+(jetzt[[:space:]]+)?alles[[:space:]]+erledigt'
'mach[[:space:]]+zu[.!]'
'(start|einstieg)[[:alnum:]_]*[[:space:]]+(f(ü|Ü)r[[:space:]]+die[[:space:]]+(neue|nächste)[[:space:]]+(session|sitzung)|nach[[:space:]]+`?/clear)'
'satz[[:space:]]+f(ü|Ü)r[[:space:]]+die[[:space:]]+neue[[:space:]]+(session|sitzung)'
'in[[:space:]]+(der|einer)[[:space:]]+neuen[[:space:]]+(session|sitzung)'
'in[[:space:]]+einer[[:space:]]+frischen[[:space:]]+(session|sitzung)'
'(frische|neue)[[:space:]]+(session|sitzung)[[:space:]]+vor([^[:alnum:]_]|$)'
'(die|der)[[:space:]]+n(ä|Ä)chste[[:space:]]+(session|sitzung)[[:space:]]+(f(ä|Ä)ngt|beginnt|startet|setzt|liest|wei(ß|ss))'
'(findet|damit)[[:space:]]+die[[:space:]]+n(ä|Ä)chste[[:space:]]+(session|sitzung)'
'(schönen|guten)[[:space:]]+(abend|feierabend|wochenende)'
'f(ü|Ü)r[[:space:]]+den[[:space:]]+neustart'
'(ü|Ü)bergabe[[:alnum:]_]*[[:space:]]+zum[[:space:]]+einf(ü|Ü)gen'
'(starte|beginnt?)[[:space:]]+(die[[:space:]]+)?(neue|nächste)[[:space:]]+(session|sitzung)[[:space:]]+([^[:space:]]+[[:space:]]+){0,2}mit'
'nach[[:space:]]+(dem[[:space:]]+)?`?/?clear`?[[:space:]]+reicht'
'zum[[:space:]]+weitermachen[[:space:]]+reicht'
'beim[[:space:]]+`?/?clear`?[[:space:]]+(geht[[:space:]]+)?nichts[[:space:]]+verloren'
'setzt[[:space:]]+dort[[:space:]]+an([^[:alnum:]_]|$)'
'vorschlag[[:space:]]+(bleibt|ist)[^[:alnum:]_]{0,4}`?/clear'
'(soll|darf)[[:space:]]+ich[[:space:]]+([^[:space:]]+[[:space:]]+){0,3}(ü|Ü)bergabe'
'kontext[[:space:]]+(leeren|löschen)'
'you[[:space:]]+can[[:space:]]+(now[[:space:]]+)?(run[[:space:]]+)?`?/clear'
'safe[[:space:]]+to[[:space:]]+`?/?clear'
'ready[[:space:]]+(for|to)[[:space:]]+(a[[:space:]]+)?`?/?clear'
'(start|open)[[:space:]]+a[[:space:]]+(new|fresh)[[:space:]]+session'
'nothing[[:space:]]+(else[[:space:]]+|more[[:space:]]+)?(is[[:space:]]+)?(left[[:space:]]+)?open[[:space:]]+(in|for)[[:space:]]+this[[:space:]]+session'
'this[[:space:]]+session[[:space:]]+is[[:space:]]+(done|complete|finished)'
'you[[:space:]]+can[[:space:]]+close[[:space:]]+(this|the)[[:space:]]+session'
'(shall|should)[[:space:]]+i[[:space:]]+(write|prepare)[[:space:]]+(a[[:space:]]+)?hand-?over'
)
# nudge-patterns-end
# A match of one of these lets the message pass: it asks for something else (a commit, a push, a
# merge) or names the /clear in a condition or after something still pending ("danach")
# nudge-exceptions-begin
NUDGE_EXCEPTIONS=(
'(darf|soll)[[:space:]]+ich[[:space:]]+([^[:space:]?]+[[:space:]]+){0,4}(committen|commit|pushen|push|mergen|merge)[^?]{0,40}\?'
'(falls|wenn|sobald)[[:space:]]+([^[:space:].!?]+[[:space:]]+){0,4}`?/clear'
'(falls|wenn|sobald|nachdem)[[:space:]]+du[^.!?]{0,40}(best(ä|Ä)tigst|antwortest|beantwortest|entschieden|freigibst|ja[[:space:]]+sagst)[^.!?]{0,80}/clear'
'(^|[[:space:]])[*_]*danach[*_]*[[:space:]]+(kannst[[:space:]]+du|k(ö|Ö)nnen[[:space:]]+sie)[^.!?]{0,30}(/clear|kontext|schlie(ß|ss)en)'
'(sag|sagen[[:space:]]+sie|schreib)[[:space:]]+[^[:alnum:][:space:]]*merge'
)
# nudge-exceptions-end

# True when message $1 offers a handover or a clear without a closing check
nudge_wanted() {
    local p
    [[ -n $1 && ! $1 =~ (^|$nl)'## Closing check'[[:space:]] && ! $1 =~ (^|$nl)'## Closing check'$ ]] || return 1
    shopt -s nocasematch
    for p in "${NUDGE_EXCEPTIONS[@]}"; do
        [[ $1 =~ $p ]] && { shopt -u nocasematch; return 1; }
    done
    for p in "${NUDGE_PATTERNS[@]}"; do
        [[ $1 =~ $p ]] && { shopt -u nocasematch; return 0; }
    done
    shopt -u nocasematch
    return 1
}

# Batch mode for the measurement script: NUL-separated messages on stdin, 1 or 0 per message
if [[ $CLOSING_NUDGE_SELFTEST == batch ]]; then
    while IFS= read -r -d '' msg; do
        nudge_wanted "$msg" && echo 1 || echo 0
    done
    exit 0
fi

[[ -f ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/skills/closing-check/SKILL.md ]] || exit 0
read_input
[[ $input =~ \"stop_hook_active\"[[:space:]]*:[[:space:]]*true ]] && exit 0
field last_assistant_message
if nudge_wanted "$REPLY"; then
    printf '%s' '{"decision":"block","reason":"Run the closing-check skill first, or say it was no such offer; that ends it."}'
fi
exit 0
