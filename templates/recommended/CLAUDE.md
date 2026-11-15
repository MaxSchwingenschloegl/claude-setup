# Global rules

How to work with me, in every project. Git and GitHub rules are in `rules/git.md`; a
repository's own CLAUDE.md wins where it says something more specific.

## Evidence
- Say "done", "green", "fixed" or "works" only together with the command output that shows it.
  Name what was skipped or not verified.
- A number that reaches me or an artefact (count, percentage, size, timing, score) comes from code
  that was run and is quoted from its output, never from mental arithmetic or memory.
- Before reporting a negative result ("no difference", "nothing failed", "identical"), show that
  the check could have fired. A test nobody has seen fail for the right reason is unproven.
- Before offering a handover or a `/clear`, before a pull request, merge or release, before
  starting a run that costs much time or machine (full gates, benchmark, mutation run, review
  panel, live test, release build), and before calling a piece of work done that has an issue, a
  branch or a handover of its own, run the `closing-check` skill and show its list. Before the
  expensive step, not after it. A small step inside such a piece (a typo, one test) needs no list.
- Call a solution the best, cleanest or most uniform only after measuring or looking: name what
  was compared and what decided it.
- Bring in subagents whenever they raise quality: a second opinion not anchored on yours,
  independent checks in parallel, a fresh read of the session for the closing check. You need not
  ask first; say which ones ran and what they found.

## Heavy runs
- One heavy run on the machine at a time, announced with its expected length, reported at start
  and end: to the coordinating session where one exists, otherwise check the process list for
  another heavy run first and tell the owner. A short partial run that builds or uses every core
  counts as heavy too.
- A run that was stopped or killed is no evidence; it is repeated in a new slot.
- A run longer than the foreground limit is started detached with a log. Measured limits: a `!`
  command moves to the background after 300 s, an agent's foreground run after 20 minutes, and
  background runs are killed when memory runs low.
- A mutation run changes a copy of the code under test, never the source: a stopped run can leave
  child processes behind that keep changing files.

## Language
- Talk to me in the language I write in.
- Artefacts (code, comments, commits, pull requests, issues, docs) use the repository's language,
  English unless the repository says otherwise, whatever language the conversation is in.

## Skill & plugin vetting
Skills and plugins run with your permissions, and nobody verifies their content. Before any
skill or plugin is cloned, vendored, installed or enabled, marketplace plugins included, read
its SKILL.md files and any bundled scripts and tell me what they do. If `skillspector` is
installed, also run `skillspector scan <absolute-path-or-git-url>` and show me the result; a
score above 50 needs my explicit approval. Never install on trust alone.
