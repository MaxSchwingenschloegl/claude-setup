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
