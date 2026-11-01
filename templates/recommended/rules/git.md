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
- Never commit on `main`; create a branch first. `main` moves only through a pull request or the
  fast-forward below.
- Commit, push, open a pull request or issue, merge, and delete a branch only after I said yes in
  this session, with the summary or diff shown first. Never merge unprompted. A yes to merge also
  covers deleting the merged branch, locally and on the remote.
- My own repositories are those whose `origin` is under my GitHub account (name it here, e.g.
  `github.com/<your-account>`). In anyone else's push a branch and open a pull request, both only
  after my yes. Follow that repository's rules for branch names and the pull request's form, but
  push to its `main` only when I ask for it in this session.
- In my own repositories the flow is the one their CLAUDE.md or CONTRIBUTING names. Where they
  name none, the repository uses pull requests if it has a PR template, a hook that refuses pushes
  to `main`, or merged pull requests (`gh pr list --state merged --limit 1`); otherwise merge by
  fast-forward. If those signs disagree, ask me.
- Fast-forward: `git push origin <branch>:main`, then delete the branch. If the push is rejected
  because `main` moved, stop and tell me: never force, never merge `main` into the branch, rebase
  only a branch that was never pushed, then show the new diff and ask again. Afterwards bring the
  local `main` up to date (`git merge --ff-only origin/main`) before the next branch.

## Safe changes
- Stage by path, never `git add -A` or `git add .`, and run `git diff <path>` before staging it:
  parallel sessions may share the working tree, and naming a file does not keep another session's
  edits inside it out of the commit.
- Never `--no-verify`, never rewrite or amend commits that were pushed; add a new commit instead.
  When a hook refuses, fix the cause or tell me. Never route around it.
