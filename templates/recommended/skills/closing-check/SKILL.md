---
name: closing-check
description: Walk the whole work once more for what was left out, and show the result as a fixed list. Use before offering a handover or a /clear, before opening a pull request, merging or releasing, before starting a run that costs much time or machine (full gates, benchmark, mutation run, review panel, live test, release build), and before calling a piece of work done that has an issue, a branch or a handover of its own. Run it before the expensive step, not after it.
---

# Closing check

Sessions drop things: a question never answered, a "later" never done, a line of the issue's
definition of done that was not met, a probe that only exists in a temporary folder. This check
walks the work against its artefacts, not against memory, and writes down every item with its
state. A small step inside a larger piece (a typo, one test) needs no list.

## The form

The output always starts with the line `## Closing check`, also inside German text, and holds the
eight parts in this order, each with at least one item:

```
## Closing check
1. Questions to the owner
- [done] <what>: <evidence>
2. Findings
3. Promises (later, follow-up, I will)
4. Issue and definition of done
5. Routine steps
6. Changed after the last proof
7. Leftovers
8. Other sessions
```

Every item is one line `- [<state>] <text>`, with one of these states:

- `[done]` with evidence that outlives the session: a commit, a link, a file in a repository, or
  the output quoted in the list. A log path in a temporary folder is no evidence.
- `[open with owner]`: the owner (the person the session works for) has to decide or act. In chat
  you may name them.
- `[issue #<n>]`: recorded in that issue.
- `[limitation]`: a known limit, with where it is written down.
- `[dropped]`: not done, with the reason. Dropping is a legal state; do not invent work to close
  an item.

A part with nothing in it gets one line `- [nothing] checked by <what you looked at>`, for example
`- [nothing] checked by git status of every touched worktree`. `done`, `limitation`, `dropped` and
`nothing` need a real text of at least ten characters. No placeholders: no `<...>`, `TODO`,
`TBD`, `FIXME`. An item nobody can place goes to the owner as `[open with owner]`, never silently
away.

## The eight parts

1. **Questions to the owner.** Every question put to the owner in the session: answered (with the
   answer), or still open.
2. **Findings.** Every finding met on the way (own measurements, reviews, live tests, messages
   from other sessions): repaired, recorded or dropped.
3. **Promises.** Every "later", "follow-up" and "I will" said in the session.
4. **Issue and definition of done.** Open the issue and quote its checklist and definition of done
   line by line, each with its state. Answering from memory does not count. Then every statement
   in the issue, its overview issue and the pages the change touches that the change has made
   false.
5. **Routine steps.** The steps of the repository's own routine from its `CLAUDE.md` (tests in the
   same change, doc sync, changelog, live verification, other runs it names), each with its state.
   "Not applicable" is a `[dropped]` whose reason names what the change touches. A step that was
   not run is `[open with owner]` until the owner has said to skip it; then it is `[dropped]` with
   their decision and its date. It is never `[limitation]` or `[nothing]`.
6. **Changed after the last proof.** What changed after the last full run, with a date or commit
   on both sides: the last full run on which state, the last edit when. Also text the owner
   approved that changed afterwards (a changelog entry reworded after a review finding): it goes
   back to them.
7. **Leftovers**, named one by one: probes and scratch files, files that exist only in a temporary
   folder, worktrees, the branch of every shared checkout, containers, ports, running processes,
   uncommitted and unpushed work.
8. **Other sessions.** What other sessions were told or are waiting for, and what the merge of
   this piece changes for them (shared files, a baseline that moves).

At a handover or a `/clear`, ask one more question and put the answers into the parts above: what
exists only in this conversation or in a temporary folder and would be gone afterwards?

## Build it against artefacts

Look, do not recall:

- the issue text (`gh issue view <n>`) and its overview issue;
- `git status`, `git worktree list` and the branch of every touched repository and worktree,
  including shared checkouts;
- the temporary folders the session used, and running processes, containers and ports it started;
- the line's standing record: its handover and memory notes and the open issues assigned to it.
  An item can come from an assignment made weeks ago that no conversation of today holds.

## Second reader

Before an expensive run, a pull request, a merge or a release, and at a handover or `/clear`, a
fresh reader checks the list. For a piece of work done without such a step, your own list is
enough.

1. Find your own transcript: `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/<project folder>/<session id>.jsonl`.
   The project folder is the session's start directory with every character other than a letter
   or digit replaced by `-`. Several sessions often share it, so the newest file there is not
   proof: take the session id from something certain (it is part of the scratchpad path the
   harness gives the session), or search the folder for a sentence only this conversation holds.
2. Extract what was said, since a transcript can be 50 MB:
   `python -I <this skill's folder>/transcript-extract.py <transcript> > <scratch>/said.txt`.
   It keeps every message of the owner (also those queued while the session was busy), their
   answers to question tools, every message other sessions sent in and this one sent out, the
   reports of its subagents, and every turn-final message of the session. Name the file you used and its first owner message
   in the list, so a wrong pick shows.
3. Start a fresh general-purpose subagent, not a fork (a fork inherits your view). Give it the
   draft list, the paths of the artefacts above and the extract, and ask it to report only what the
   list lacks or gets wrong, not a second list.
4. Work its findings into the list before you show it, and say that the second reader ran.

## The chat view

The owner reads what is left, not what is done. In the chat, show only this view, always in this
shape, in the chat's language (for a German chat the blocks are "Deine Entscheidung", "Im Auge
behalten" and "Bewusst weggelassen"):

```
## Closing check
Checked: 8 parts, 23 items done, second reader ran. Full list: <where it is>.

### Your decision
**1. <short title>**
What it is about: <the facts the owner needs, with numbers and links>.
My recommendation: <what you would do, and why, in one or two sentences>.

### Keep an eye on
**2. <short title>**
What it is about: ...
My recommendation: ...

### Dropped on purpose
**3. <short title>**
Reason: ...
```

- **Your decision**: every `[open with owner]` item, a decision or an action only the owner can
  take, and every item nobody could place.
- **Keep an eye on**: `[limitation]` and `[issue #<n>]` items that arose in this piece of work.
  A limit that was already written down before is not repeated.
- **Dropped on purpose**: `[dropped]` items the owner has not already agreed to, with the reason.
- Number the items across all blocks, so the owner can answer "1 yes, 2 later". Leave out a block
  with nothing in it. With nothing left at all, the view is the heading and one line:
  "Nothing open; all 8 parts checked, second reader ran." The header line names the number of
  done items and where the full list is, so the owner can look without reading it here.

## Where the list goes

- In the chat: the chat view above, never the full list.
- The full list, in the form above:
  - before a pull request, as the `## Closing check` section of its body. In the owner's own
    repositories a hook refuses `gh pr create` and `gh pr merge` without a filled section (also
    one whose part 5 holds a `[limitation]` or `[nothing]`), and the merge while an item is still
    `[open with owner]`. A pull request Dependabot opened and wrote every commit of needs no
    list; a commit authored by anyone else on its branch (a fix, a merge of main) brings the list
    back, so ask Dependabot to rebase (`@dependabot rebase`) rather than merging main in;
  - at a handover, into the handover note;
  - otherwise into a file in the session's scratchpad, which the chat view's header line names;
  - to the coordinating session, where one exists, before asking it for a slot for an
    expensive run.
