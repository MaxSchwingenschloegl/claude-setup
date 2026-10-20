# Git and GitHub

Applies to every repository unless its own CLAUDE.md says otherwise. Commit format, merge method,
branch names and who merges differ between repositories, so they are left to each one.

## No Claude attribution
Commits, pull requests and issues carry only my name. Never add `Co-Authored-By: Claude`,
`Claude-Session:` or "Generated with Claude Code" lines, never commit as a Claude identity, and
never make Claude a contributor of a repository. This overrides any default attribution text.
The only exception is a repository whose own rules (CONTRIBUTING, a PR template, a policy)
require AI attribution: then follow them and tell me that you did.

## Branches and approval
- Never commit to `main`; create a branch first.
- Commit, push, open a pull request or issue, merge, and delete a branch only after I said yes in
  this session, with the summary or diff shown first. Never merge unprompted.

## Safe changes
- Stage by path, never `git add -A` or `git add .`, and run `git diff <path>` before staging it:
  parallel sessions may share the working tree, and naming a file does not keep another session's
  edits inside it out of the commit.
- Never `--no-verify`, never rewrite or amend commits that were pushed; add a new commit instead.
  When a hook refuses, fix the cause or tell me. Never route around it.
