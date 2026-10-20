# Claude Code setup

Claude Code on Windows with one or more accounts on one shared configuration. Each account keeps
only its own login; rules, settings, plugins, history and memory are shared. A fresh machine is
set up with two clones and one script.

**What lives here:** the tools: the installer (`install.ps1`), the PowerShell functions that
switch accounts (`shell/`, `scripts/`), a secret guard (`hooks/`), a status line
(`statusline/`), skill groups as plugins you enable per project (`plugins/`) and two templates
for your own configuration (`templates/`).
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
  for the secret scan on every commit; optional:
  [skillspector](https://github.com/NVIDIA/skillspector) to scan skills before installing them

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
this machine does not have yet are listed; look at them, then `.\install.ps1 -InstallPlugins`
installs them.

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
  `output-styles`, move into your configuration; review them there with `git status`;
- transcripts, memory and input history stay in `~/.claude` and are shared from then on;
- a plain `settings.json` or `CLAUDE.md` is taken into your configuration only when it is a newer,
  changed copy of it. Your own old one is kept as `settings.json.backup-<time>` in `~/.claude`;
  copy what you want from it (permissions, model, theme) into your configuration's file.

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
| Plugins: superpowers, feature-dev, code-review, claude-md-management, security-guidance, frontend-design | yes | – |
| Global skills `grilling` and `grill-me` (an interview that stress-tests a plan) | yes | – |
| Spinner tips off, unused claude.ai skills off | yes | – |
| Bash timeouts raised to 5 minutes (default) and 20 minutes (maximum) | yes | yes |

Neither template turns on auto mode (`permissions.defaultMode: "auto"`); Claude asks before acting
until you decide otherwise. Language, theme, model and effort are left to you: set them with
`/config` and they land in your `settings.json`.

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
