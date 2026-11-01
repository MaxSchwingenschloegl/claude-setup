#!/usr/bin/env bash
# Status line: the account this session runs on, the model, how full the context is and how much
# of the five-hour and the weekly limit is used, e.g.
# "work · Opus 5.5 · context 23% · 5h 41% · week 63%".
# Plain bash like the secret guard, so it needs nothing else. Parts that Claude Code has not
# reported yet (early in a session, or a plan without rate limits) are left out. Claude Code may
# still report a five-hour window for a plan that no longer has one; list such plans' rate-limit
# tiers (the account's .claude.json, oauthAccount, e.g. default_claude_max_20x) in
# STATUSLINE_NO_FIVE_HOUR, space-separated, e.g. in settings.json `env`.

input=$(cat)

account=${CLAUDE_CONFIG_DIR%[\\/]}
account=${account##*[\\/]}
account=${account#.claude-}
[[ -z $account || $account == .claude ]] && account=default

re='"display_name"[[:space:]]*:[[:space:]]*"([^"]*)"'
[[ $input =~ $re ]] && model=${BASH_REMATCH[1]}

# The first used_percentage after a key; null means not known yet
percent_after() {
    local rest=${input#*\"$1\"} re='"used_percentage"[[:space:]]*:[[:space:]]*([0-9.]+|null)'
    [[ $rest != "$input" && $rest =~ $re && ${BASH_REMATCH[1]} != null ]] && printf '%s' "${BASH_REMATCH[1]%%.*}"
}
context=$(percent_after context_window)
five_hour=$(percent_after five_hour)
# The plan's rate-limit tier, the user's own before the organisation's; an unknown tier keeps 5h
if [[ -n $STATUSLINE_NO_FIVE_HOUR && -n $five_hour ]]; then
    config= tier= file="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"
    [[ -r $file ]] && config=$(<"$file")
    [[ $config == *'"oauthAccount"'* ]] && config=${config#*\"oauthAccount\"} || config=
    for key in userRateLimitTier organizationRateLimitTier; do
        re="\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]+)\""
        [[ $config =~ $re ]] && tier=${BASH_REMATCH[1]} && break
    done
    [[ -n $tier && " $STATUSLINE_NO_FIVE_HOUR " == *" $tier "* ]] && five_hour=
fi
seven_day=$(percent_after seven_day)

line=$account
[[ -n $model ]] && line+=" · $model"
[[ -n $context ]] && line+=" · context $context%"
[[ -n $five_hour ]] && line+=" · 5h $five_hour%"
[[ -n $seven_day ]] && line+=" · week $seven_day%"
printf '%s' "$line"
