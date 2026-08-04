# dotfiles

Cross-platform environment, managed by [chezmoi](https://chezmoi.io), with
secrets in [Bitwarden](https://bitwarden.com) and secret *files* encrypted with
[age](https://age-encryption.org).

**Design principle:** Git holds reproducible *instructions*, Bitwarden holds
secret *values*, age bridges the two for secret *files*, and every machine keeps
its **own** SSH identity keys. One stolen laptop never equals total compromise.

Supported: macOS · Linux · WSL2 · Windows 10/11.

---

## Bootstrap a new machine

**macOS / Linux / WSL** — note the `bash -c "$(...)"` form; `curl | bash` breaks
the interactive vault prompts because it takes over stdin.

```bash
DOTFILES_REPO=git@github.com:<user>/dotfiles.git \
BW_EMAIL=you@example.com \
bash -c "$(curl -fsSL https://raw.githubusercontent.com/<user>/dotfiles/v1.0.0/bootstrap.sh)"
```

**Windows** — download, read it, then run:

```powershell
irm https://raw.githubusercontent.com/<user>/dotfiles/v1.0.0/bootstrap.ps1 -OutFile $env:TEMP\b.ps1
& $env:TEMP\b.ps1
```

---

## Daily workflow

```bash
cze ~/.zshrc      # chezmoi edit --apply : edit source and apply in one step
czd               # chezmoi diff         : ALWAYS run before a big apply
cza               # chezmoi apply -v
czu               # chezmoi update -v    : pull + apply on a secondary machine
czsync            # stage, show diff, then prompt before commit + push
```

`autoCommit` and `autoPush` are deliberately **off**. The human diff is the last
gate before a leaked credential becomes permanent git history.

---

## Secret tiers

| Tier | Examples | Mechanism |
|---|---|---|
| **Low** | read-only PATs, non-prod keys | rendered to `~/.config/env.sh` (0600) |
| **High** | cloud admin, prod DB, signing | on-demand `secret <item>` / `direnv` |
| **Files** | ssh config, kubeconfig, GPG | `chezmoi add --encrypt` (age) |

Never call the vault from `.zshrc` — it adds seconds to every new terminal.
Tier-Low is resolved once at apply time; Tier-High is fetched only when used.

Add a Tier-Low secret by putting it in Bitwarden, then referencing it via the
backend-agnostic helper (never call `rbw`/`bitwarden` directly in a template):

```gotemplate
export MY_TOKEN="{{ includeTemplate "secret" (dict "item" "my-item" "ctx" .) }}"
```

---

## Enabling secrets and encryption

Secrets are **off** by default so the repo works before the vault is populated.

```bash
# 1. create the age identity and store it in Bitwarden
age-keygen -o ~/.config/chezmoi/key.txt
grep 'public key' ~/.config/chezmoi/key.txt        # -> put in .chezmoi.toml.tmpl recipient
rbw add chezmoi-age-key                            # paste AGE-SECRET-KEY-... as the password

# 2. create the vault items referenced by templates
rbw add github-token

# 3. turn secrets on
chezmoi init --data=false && chezmoi init          # re-prompt; answer yes to enableSecrets

# 4. encrypt secret files
chezmoi add --encrypt ~/.kube/config
```

Replace `age1REPLACE_ME_WITH_YOUR_PUBLIC_KEY` in `.chezmoi.toml.tmpl` first.

---

## Adding packages

Edit `.chezmoidata/packages.yaml` — it is the single source of truth for all
platforms. The provisioning scripts hash that file, so every machine
re-provisions on its next `chezmoi apply`.

---

## This repo is public — how that stays safe

Secrets never live here. Values come from Bitwarden at apply time and secret
*files* are age-encrypted, so the repo holds only instructions. Three layers
keep it that way:

**1. A pre-commit guard** (`.githooks/pre-commit`), enabled automatically by
`run_once_after_40-git-hooks.sh`. Git hooks are not shared by `clone`, so this
must be re-enabled on every machine — the script does it for you. It blocks:

- private key material and env files that are not age-encrypted
- rendered secrets files (only the `.tmpl` belongs in git)
- literal AWS / GitHub / Slack tokens and `AGE-SECRET-KEY-` strings
- any real-looking email address, so the repo stays identity-free
- anything `gitleaks` flags in the staged diff

**2. CI** re-runs `gitleaks` on every push and renders all templates on
Ubuntu, macOS and Windows with `CHEZMOI_CI=1` (no vault access needed).

**3. GitHub push protection.** Enable it — it is free on public repos and is
the only layer that can stop a bad push server-side:

> Settings → Code security → **Secret scanning** + **Push protection**

Also enable, under your account → Emails:

> ☑️ Keep my email addresses private
> ☑️ Block command line pushes that expose my email

### Rules for a public dotfiles repo

- No name, email, hostname, employer or internal URL in any committed file.
  Identity is prompted and cached in `~/.config/chezmoi/chezmoi.toml`, which is
  **not** part of this repo.
- Use `<ID>+<user>@users.noreply.github.com` as your git email.
- `chezmoi add --encrypt` for any file with secret content. Plain
  `chezmoi add` on a secret is the one mistake that cannot be undone here:
  scrapers index public commits within minutes, and forks outlive any
  force-push.
- Verify before pushing:

  ```bash
  gitleaks detect --redact -c .gitleaks.toml   # full history
  git diff --cached                            # read it, every time
  ```

---

## Layout

| Path | Purpose |
|---|---|
| `.chezmoi.toml.tmpl` | prompts, platform detection, normalized path data |
| `.chezmoiignore` | per-OS exclusions (**also gates `.ps1` vs `.sh` scripts**) |
| `.chezmoitemplates/secret` | secret-backend abstraction (`rbw` ⇄ `bw`) |
| `.chezmoidata/packages.yaml` | package lists for every platform |
| `run_onchange_after_10-*` | provisioning, re-runs when packages change |
| `run_once_after_30-ps-*` | writes the OneDrive-proof PowerShell profile stub |
| `run_after_90-secure.*` | enforces permissions on **every** apply |

---

## Platform notes

- **`private_` is a silent no-op on Windows** (ACLs, not POSIX modes).
  `run_after_90-secure.ps1` enforces ACLs with `icacls` instead. This is not
  optional.
- **`rbw` is not viable on native Windows** (cargo-only, unix-socket agent), so
  Windows uses the official `bw` CLI. The `secret` template hides the difference.
- **`$PROFILE` lives under `Documents`**, which OneDrive relocates. A stub at the
  runtime-resolved `$PROFILE` dot-sources the managed profile.
- **`.gitattributes` pins `eol=lf`.** Without it a Windows checkout makes every
  script CRLF and Unix fails with `bad interpreter: ^M`.
- **SSH keys are per-machine** and never committed. `bootstrap.sh` generates one
  and prints the public key to add to GitHub.

---

## Machine-local overrides (never committed)

| File | Scope |
|---|---|
| `~/.zshrc.local` | shell |
| `~/.ssh/config.local` | ssh hosts |
| `~/.pwsh_profile.local.ps1` | PowerShell |

---

## Health checks

```bash
chezmoi doctor            # first thing to run when anything is weird
chezmoi diff              # pending changes
chezmoi verify            # target state matches
gitleaks detect --no-git  # secret scan before pushing
```

CI renders every template on Ubuntu, macOS and Windows using `CHEZMOI_CI=1`,
which substitutes placeholders so no vault access is needed.

**Test your disaster recovery in a clean VM at least twice a year.** An untested
bootstrap is a bootstrap that fails on the day you actually need it.
