# Claude Code setup

Claude Code on Windows with one or more accounts on one shared configuration. Each account keeps
only its own login; rules, settings, plugins, history and memory are shared. A fresh machine is
set up with two clones and one script.

**What lives here:** the tools: the installer (`install.ps1`), the PowerShell functions that
switch accounts (`shell/`, `scripts/`), a plugin scan (`scripts/vet-plugins.ps1`), a secret
guard (`hooks/`), a status line (`statusline/`), skill groups as plugins you enable per project
(`plugins/`) and two templates for your own configuration (`templates/`).
**What never lives here:** your configuration. Accounts, settings, rules and global skills live
in a folder of your own, ideally a private git repository, which `install.ps1` links into every
account. Logins, tokens, transcripts and memory stay on each machine.

## How it works

```
your configuration                    ~/.claude (hub, no login)         ~/.claude-<account>
  CLAUDE.md         <-symlink--------  CLAUDE.md                         CLAUDE.md     --symlink--> config
  settings.json     <-symlink--------  settings.json                     settings.json --symlink--> config
  rules/            <-junction-------  rules/            <-junction-     rules/
  commands/         <-junction-------  commands/         <-junction-     commands/
  skills/<name>     <-junction-----------------------------------------  skills/<name>
this repo
  hooks/            <-junction-------  hooks/            <-junction-     hooks/
  statusline/       <-junction-------  statusline/
                                       history.jsonl     <-symlink--     history.jsonl
                                       plugins/          <-junction-     plugins/
                                       projects/         <-junction-     projects/  (incl. memory)
                                       paste-cache/      <-junction-     paste-cache/
                                                                         .credentials.json (own login)
```

- Claude Code reads its configuration from `CLAUDE_CONFIG_DIR`. Each account is a folder
  `~/.claude-<account>`; only its login and per-account state are real files there.
- `CLAUDE.md` and `settings.json` link straight into your configuration. Claude Code saves
  `settings.json` (for `/config`, plugin switches, "always allow") by replacing the file at the
  end of one link, so a direct link survives that and the change shows up in your `git diff`.
- The user environment variable `CLAUDE_CONFIG_DIR` points to the default account, so plain
  `claude` and the VS Code extension use it. `claude-<account>` starts Claude Code with any
  account; `code-<account>`, defined for every account but the default one, opens VS Code with
  its own profile for that account.
- Every new shell checks the default account's links, and `claude-<account>` checks that
  account's, with a warning when one has turned into a plain file.

## Requirements

- Windows 10 or 11, PowerShell 5.1 or 7
- [Git for Windows](https://git-scm.com/download/win). Its Git Bash runs the secret guard and the
  status line.
- [Claude Code](https://code.claude.com/docs/en/setup), signed in or not
- **Developer Mode** (Settings > System > For developers) or an elevated PowerShell, for file
  symlinks. The installer checks this before it changes anything.
- PowerShell allowed to run scripts: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`
- Recommended: [gitleaks](https://github.com/gitleaks/gitleaks) (`winget install Gitleaks.Gitleaks`)
  for the secret scan on every commit, and [skillspector](https://github.com/NVIDIA/skillspector)
  to scan plugins and skills before installing them (with uv; see *Vetting plugins*)

## Install

Keep both repositories outside OneDrive or another sync folder: links into a folder that a sync
client moves or replaces break. If Windows redirects your Documents folder to OneDrive, use
`C:\dev` or similar instead of `$HOME\Documents\GitHub` below.

```powershell
git clone https://github.com/MaxSchwingenschloegl/claude-setup.git $HOME\Documents\GitHub\claude-setup
cd $HOME\Documents\GitHub\claude-setup

# 1. Create your configuration from a template (the folder must not exist yet)
.\install.ps1 -ConfigDir $HOME\Documents\GitHub\claude-config -Template recommended
```

2. Edit the new folder (see the next two sections): your accounts in `accounts.json`, then read
   `CLAUDE.md`, `rules/` and `settings.json`. Make it a private git repository so it is versioned
   and travels to your next machine: `git init`, commit, and push it to a **private**
   repository of your own.
3. Install, after looking at what would change:

   ```powershell
   .\install.ps1 -DryRun
   .\install.ps1
   ```

4. Open a new PowerShell window. Accounts you were not signed in to yet: `claude-<account>`,
   then `/login`.

`install.ps1` remembers the configuration folder (user environment variable
`CLAUDE_SETUP_CONFIG`) from the moment it creates or installs one, is safe to run again at any time
and is also the repair tool when a link warning shows up. Plugins your `settings.json` enables but
this machine does not have yet are listed; scan them (*Vetting plugins*), then
`.\install.ps1 -InstallPlugins` installs the scanned ones.

### Accounts

`accounts.json` names your accounts and which one is the default:

```json
{
  "default": "work",
  "accounts": ["work", "private"],
  "marketplaces": ["../my-skills"]
}
```

- Each account is one claude.ai login (a Pro, Max, Team or Enterprise seat) with its own folder
  `~/.claude-<name>`. Names use `a-z`, `0-9` and `-`. One account is fine too.
- The **default** account is what plain `claude` and the VS Code extension use.
  `claude-<name>` starts any account, `code-<name>` opens VS Code with another one.
- Switching costs nothing: all accounts share the configuration, plugins, input history,
  transcripts and memory, so `/resume` and the memory work across them. That sharing is the
  point; if two accounts belong to clients who must not see each other's work, use two separate
  setups instead.
- `marketplaces` is optional: further plugin marketplaces of your own (see *Skill groups*).

### If you already used Claude Code on this machine

Run the dry run first and read it. The installer takes over what you had:

- your login in `~/.claude` moves to the default account, so you stay signed in there;
- `~/.claude.json` (MCP servers, trusted projects) is copied to the default account;
- your skills in `~/.claude/skills`, and the contents of `commands`, `rules`, `agents` and
  `output-styles`, move into your configuration; review them there with `git status`. When
  `~/.claude/skills` is a link (`npx skills` makes one to `~/.agents/skills`), its skills stay
  where they are and the installer names them: copy the ones you want into your configuration's
  `skills` folder after scanning them;
- transcripts, memory and input history stay in `~/.claude` and are shared from then on;
- a plain `settings.json` or `CLAUDE.md` is taken into your configuration only when it is a newer,
  changed copy of it. Your own old one is kept as `settings.json.backup-<time>` in `~/.claude`;
  copy what you want from it (permissions, model, theme) into your configuration's file.

### Things to know

- **Run the installer from a plain PowerShell window,** with every Claude Code session closed. A
  session that was already running keeps using `~/.claude`, because it started without
  `CLAUDE_CONFIG_DIR`, and a `/login` in it writes the login into the hub instead of an account
  (the next install run warns about it). Open a new window before you sign in.
- **Start Claude Code in a project folder, not in your home folder.** There
  `~/.claude/settings.json` is also read as the folder's project settings, so every enabled
  plugin is installed a second time with project scope for `C:\Users\<name>` (listed in
  `~/.claude/plugins/installed_plugins.json`). Do not remove those with
  `claude plugin uninstall --scope project` from the home folder: the project settings it edits
  are that same `settings.json`, so it would switch the plugin off everywhere.
- **`claude plugin install` and `uninstall` rewrite `settings.json`** with its keys in another
  order, so your configuration can show a long `git diff` although nothing changed but the order.
  If every removed line comes back elsewhere (give or take a trailing comma),
  `git checkout -- settings.json` restores the committed file; if a value changed (a plugin
  switched on or off), commit it.

## Choose your configuration

| | `recommended` | `minimal` |
|---|---|---|
| Secret guard, status line | yes | yes |
| Telemetry, error reports, `/bug`, feedback survey off | yes | yes |
| Transcripts kept 90 days (default 30) | yes | yes |
| Deny rules for secret files | yes | yes |
| `CLAUDE.md`: evidence before success claims, numbers from executed code, language, skill vetting | yes | a header only |
| `rules/git.md`: branch first, approval before outward actions, stage by path, no `--no-verify`, no Claude attribution | yes | – |
| No Claude attribution in commits and pull requests (`attribution`) | yes | – |
| Plugins: feature-dev, code-review, claude-md-management, frontend-design (skillspector 2 to 13, `plugins/VENDORED.md`) | yes | – |
| Global skills `grilling` and `grill-me` (an interview that stress-tests a plan) | yes | – |
| Spinner tips off, unused claude.ai skills off | yes | – |
| Bash timeouts raised to 5 minutes (default) and 20 minutes (maximum) | yes | yes |

Neither template turns on auto mode (`permissions.defaultMode: "auto"`); Claude asks before acting
until you decide otherwise. Language, theme, model and effort are left to you: set them with
`/config` and they land in your `settings.json`.

### Plugins worth a deliberate decision

Two well-known official plugins are not in the template, because skillspector scores both 100 and
what they do goes beyond reading text. Enable them yourself if you want what they bring:

- **superpowers**: process skills for brainstorming, plans, test-driven development and
  debugging. Its session-start hook adds about 3.2 KB of instructions to every session that make
  Claude check for a matching skill before any answer. Very effective, and very insistent.
- **security-guidance**: a background security review of your edits, commits and pushes, sent to
  a model as a diff. At session start it installs the `claude-agent-sdk` package from PyPI,
  unpinned, into `~/.claude/security/` when it is missing. Best enabled per project where the
  review pays off: `claude plugin install security-guidance@claude-plugins-official --scope local`.

## Vetting plugins

A plugin runs with your permissions: its skills steer Claude, its hooks and MCP servers run code.
`scripts\vet-plugins.ps1` scans every plugin your `settings.json` enables, and every plugin
installed for all projects, with [skillspector](https://github.com/NVIDIA/skillspector) and
records the results in your configuration's `vetting.json`. Commit that file with the rest.

```powershell
.\scripts\vet-plugins.ps1                       # all of them; plugins scanned before and unchanged are skipped
.\scripts\vet-plugins.ps1 -Plugin superpowers   # only this one
.\scripts\vet-plugins.ps1 -Force                # scan again although nothing changed
```

- Each entry holds the version, a fingerprint of the plugin's files, the date, the score, the
  recommendation and the findings by severity. A plugin that is not installed yet is scanned in
  the local copy of its marketplace, before it ever runs, when the marketplace holds it as a
  folder (most official plugins); one from a remote repository is scanned after
  `claude plugin install`, which runs nothing yet, and before the next session.
- **Scan before the first session on a new machine:** `install.ps1`, then `vet-plugins.ps1`, then
  Claude Code. Claude Code can install what `settings.json` enables on its own when a session
  starts (seen in the home folder, see *Things to know*), without asking this tool; switch off
  in `settings.json` what you do not want before you start it.
- A score above 50, or a scan that did not cover every file, needs an exception: read every
  finding in the report the script names, and if each one is harmless, add `"approved"` (the
  date) and `"reasons"` to the plugin's entry. An approval holds only for the files it was given
  for; when they change, the next scan drops it.
- skillspector stops after 600 seconds. A large plugin (superpowers has over 200 files) needs
  more: set `$env:SKILLSPECTOR_MAX_WORKFLOW_SECONDS = 3600` before the scan. Every extra minute
  is more LLM calls against your plan.
- `install.ps1` warns about every enabled plugin without a scan, changed since its scan, or above
  50 or incomplete without an approval. `-InstallPlugins` installs only plugins whose scan
  matches what the marketplace would install.
- Some plugins, the language servers among them, declare their servers, hooks or commands in the
  marketplace entry instead of their folder (`"strict": false`). Those fields count toward the
  fingerprint, so a change is noticed, but skillspector scans only the folder: read the entry in
  the marketplace's `.claude-plugin/marketplace.json` yourself.
- Most official plugins have no version of their own and take the marketplace's commit as one,
  which changes with every marketplace update. The fingerprint does not, so an update that left a
  plugin alone needs no new scan.

skillspector itself, and how to get scans comparable with the scores in `vetting.json` and
`plugins/VENDORED.md`:

- Install it with [uv](https://docs.astral.sh/uv/): `winget install astral-sh.uv`, then
  `uv tool install git+https://github.com/NVIDIA/skillspector.git`.
- Its semantic analysis needs an LLM. `SKILLSPECTOR_PROVIDER=claude_cli` uses your local `claude`
  CLI, without an API key; every call counts against your plan. Without a provider the three
  semantic analyzers fail with `No LLM API key configured` and only the static score is reported,
  which for one plugin meant 100 without any review of its findings. `vet-plugins.ps1` uses
  `claude_cli` unless you set another provider; for scans by hand set it for your user,
  `[Environment]::SetEnvironmentVariable('SKILLSPECTOR_PROVIDER', 'claude_cli', 'User')`, and check
  that the report's semantic analysis says completed.
- Scan installed plugins through `~/.claude/plugins`, not through an account folder: `plugins`
  there is a junction to the hub, and skillspector refuses it with `Refusing to resolve input
  with a symlinked parent`. Pass absolute paths: `Cannot determine input type` means the path
  does not exist, often a relative one taken from the wrong folder.

## Skill groups

Skills that only some projects need are plugins in `plugins/`, never global: a global skill costs
context in every session of every project. This repo is a plugin marketplace named
`claude-setup`; the installer registers it.

| Plugin   | For |
|----------|-----|
| `dev`    | codebase architecture: deepening opportunities, module design, domain model and ADRs |
| `web`    | websites: SEO, AI search, structured data, analytics, copy, conversion |
| `growth` | marketing for clients: campaigns, ads, email, sales, pricing, social |

```powershell
claude plugin install web@claude-setup --scope local     # this project, only for you
claude plugin install web@claude-setup --scope project   # this project, for everyone (own repos)
```

Plugin skills are namespaced (`/web:copywriting`), so they never shadow a project skill of the
same name. They are vendored third-party skills (MIT); `plugins/VENDORED.md` lists sources,
commits and skillspector scores, including seven skills above 50 that the repository owner
accepted as false positives: decide for yourself before you enable `growth`.

Your own groups or other private marketplaces go into `accounts.json`:
`"marketplaces": ["../my-skills"]` (folders relative to the configuration, each with a
`.claude-plugin/marketplace.json`). Global skills for every session go into the configuration's
`skills/` folder, one folder per skill.

## Secret guard, status line, privacy

- `hooks/block-secrets.sh` is a PreToolUse hook that blocks Read, Grep, Bash and PowerShell calls
  reaching `.env` files (not `.env.example`), private keys and login files. Permission deny rules
  alone do not reach shell commands. It reads the whole command text, so a shell command that
  merely mentions such a file name (a commit message, a heredoc) is blocked too; write such text
  with the file tools. It is a guard against accidents, not against a determined attacker; its
  header lists what it does not cover. If its script cannot be found (this repo moved without
  running `install.ps1` again), Claude Code shows a hook error and the call goes through, so
  move the repo only together with a new install run. Tests: `bash hooks/block-secrets.test.sh`.
- `statusline/statusline.sh` shows the account, the model, the context fill and the five-hour and
  weekly limits, so you always see which account a session runs on.
- What still goes to Anthropic is the conversation itself, the host name before a WebFetch and,
  while Remote Control is connected, the synced session. How long it is kept depends on your
  plan and on "Help improve Claude" at claude.ai/settings/data-privacy-controls (consumer plans:
  30 days when off, 5 years when on).
- `DISABLE_TELEMETRY` also switches off feature flags, which can make Remote Control unavailable.
  Remove it from `env` if you need Remote Control.

## Updating

`git pull` in this repo, then `.\install.ps1`. Your configuration is untouched by updates; compare
it with `templates/` now and then for new defaults you may want.

## Uninstall

```powershell
.\install.ps1 -Uninstall -DryRun   # shows what would change
.\install.ps1 -Uninstall
```

Every link into your configuration or this repo becomes a plain copy, and the profile block, the
two environment variables, the marketplace registrations and the commit hook go. Plain `claude`
then uses `~/.claude` again; sign in there once. The account folders keep their logins; delete
the ones you no longer need. Files the installer kept as `*.backup-*` are yours to restore.

## Licence and contributions

MIT (`LICENSE`) for this repo's own code; the vendored skills keep their own MIT licences next to
them.

Issues are welcome, for bugs and ideas, and answered when time allows. Pull requests are not
accepted: fork the repository, adapt it, and keep your fork in sync with `git pull` from here if
you like. Security problems, a way around the secret guard included, go privately through
**Security > Report a vulnerability** (`SECURITY.md`).

## Secrets

Nothing secret goes into this repo or your configuration: logins (`.credentials.json`) are
created by `/login` per account and machine; tokens and API keys belong in environment variables,
the Windows Credential Manager or a file outside the repositories. With gitleaks installed, the
pre-commit hook scans every commit in this repo, your configuration and your own marketplaces (a
repository with git hooks of its own, such as husky, keeps them and gets a warning instead);
without gitleaks it only warns. It does not run for `--no-verify`, merges, rebases and
cherry-picks, and it is found through an absolute path, so after moving this repo run
`install.ps1` again. A finding you have reviewed and judged harmless goes into `.gitleaksignore`.
