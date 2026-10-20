# Vendored skills

`web` and `growth` contain skills from [coreyhaines31/marketingskills](https://github.com/coreyhaines31/marketingskills),
MIT licensed (see `LICENSE` in each plugin), copied unchanged at commit `e85f3cb` (2026-10-19).

Not copied: the upstream `tools/` folder (optional CLI scripts and integration notes some skills
mention) and the skills `conversion-tracking` and `link-building`. Some "see also" links point to a
skill in the other group; with both groups enabled, Claude finds it by name.

## skillspector scan, 2026-10-20

skillspector 2.12.0 with the `claude_cli` provider; every report below completed its semantic
analysis. Scores above 50 were accepted only as an exception: every finding read, judged a false
positive with a reason, approved by the repository owner on 2026-10-20. If you use these groups,
the judgement is his; read the reasons below and decide for yourself.
None of these skills contains executable code, hidden or zero-width characters or encoded blobs,
and skillspector's own LLM review rejected the flagged findings.

| Exception | Score | Why the findings are false positives |
|---|---|---|
| ad-creative | 100 | Comment with usage notes in an HTML template; curl examples for public image and voice APIs with placeholders. |
| ads | 81 | "Memory poisoning" was the word *remember* in "social amnesia"; the injection hit is a rule that fetched pages are data, not instructions. |
| attribution | 63 | Code example that sends analytics events to your own PostHog with your own key; other hits are analysis limits, not findings. |
| lead-magnets | 57 | The "ignore previous instructions" lines are an eval case and a rule that defend against prompt injection. |
| marketing-loops | 85 | No obfuscated characters; the "anti-refusal" hits are guardrails (stage edits for review, never send without approval). |
| marketing-plan | 72 | "Don't refuse" is advice for founder conversations (frame when a move becomes affordable), not an instruction to the model. |
| prospecting | 64 | "Excessive agency" hits are warnings against scraping and legal notes on LinkedIn. |

### web

| Skill | Score |
|---|---|
| ai-seo | 19 |
| analytics | 9 |
| competitor-profiling | 7 |
| competitors | 0 |
| content-strategy | 17 |
| copy-editing | 0 |
| copywriting | 0 |
| cro | 7 |
| customer-research | 0 |
| image | 3 |
| marketing-psychology | 0 |
| product-marketing | 14 |
| programmatic-seo | 0 |
| schema | 16 |
| seo-audit | 0 |
| site-architecture | 0 |

### growth

| Skill | Score |
|---|---|
| ab-testing | 3 |
| ad-creative | 100 (exception) |
| ads | 81 (exception) |
| aso | 0 |
| attribution | 63 (exception) |
| churn-prevention | 7 |
| co-marketing | 0 |
| cold-email | 27 |
| community-marketing | 0 |
| directory-submissions | 25 |
| emails | 0 |
| events | 28 |
| free-tools | 0 |
| influencer-marketing | 0 |
| launch | 0 |
| lead-magnets | 57 (exception) |
| marketing-council | 3 |
| marketing-ideas | 3 |
| marketing-loops | 85 (exception) |
| marketing-plan | 72 (exception) |
| offers | 25 |
| onboarding | 0 |
| paywalls | 21 |
| popups | 0 |
| pricing | 0 |
| prospecting | 64 (exception) |
| public-relations | 27 |
| referrals | 0 |
| revops | 20 |
| sales-enablement | 7 |
| signup | 0 |
| sms | 0 |
| social | 4 |
| video | 26 |

## dev and the global skills

From [mattpocock/skills](https://github.com/mattpocock/skills), MIT licensed, copied unchanged at
commit `5beb35b` (2026-10-19), scanned with skillspector 2.12.0 on 2026-10-20, every report
complete:

| Skill | Where | Score |
|---|---|---|
| grilling | `templates/recommended/skills` (global) | 10 |
| grill-me | `templates/recommended/skills` (global) | 0 |
| improve-codebase-architecture | `dev` | 0 |
| codebase-design | `dev` | 0 |
| domain-modeling | `dev` | 0 |

`improve-codebase-architecture` calls `grilling` (global) and the two other `dev` skills by their
plain names; inside the plugin they are `dev:codebase-design` and `dev:domain-modeling`.
Not taken: `grill-with-docs` (its ADR and glossary files clash with each repo's own decision log),
`tdd` (superpowers has it), and `find-skills` from vercel-labs/skills (it installs skills without
the skillspector scan).

## Marketplace plugins in the `recommended` template

`templates/recommended/settings.json` enables four official plugins from `claude-plugins-official`.
They are not vendored here, so `scripts/vet-plugins.ps1` scans them on your machine and records
the result in your own `vetting.json`. For reference, the repository owner's scan with
skillspector 2.12.0 and the `claude_cli` provider on 2026-10-20, every report complete:

| Plugin | Version | Score | Recommendation | Findings |
|---|---|---|---|---|
| frontend-design | e68e375d2286 | 13 | SAFE | 1 high, a false positive: "Errors don't apologize" (`SKILL.md:69`) is advice for error messages in an interface, read as an anti-refusal statement |
| code-review | e68e375d2286 | 6 | SAFE | 1 medium: step 8 posts the review as a comment on the pull request (`gh pr comment`) without asking first |
| feature-dev | e68e375d2286 | 3 | SAFE | 2 low: the read-only agents `code-architect` and `code-explorer` are given `KillShell` and `BashOutput` |
| claude-md-management | 1.0.0 | 2 | SAFE | 1 low: the audit rubric says to run the commands a CLAUDE.md documents "mentally or actually", without asking first |

Scores of the same files vary by a few points between runs, as part of the analysis is done by a
model. `superpowers` (100) and `security-guidance` (100) are not in the template; the README
(*Plugins worth a deliberate decision*) says why and what they do.

## Updating

1. Clone upstream at the new commit into an empty scratch folder.
2. Run `skillspector scan <absolute path>` on every skill that changed. Check that the report
   finished its semantic analysis; parallel runs can fail it, so scan at most two at a time.
3. Copy the skills, review `git diff`, update this file (commit, date, scores, exceptions).
