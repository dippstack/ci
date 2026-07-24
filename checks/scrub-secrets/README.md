# checks/scrub-secrets

One canonical secret-scan engine for the whole fleet. Replaces the hand-copied
`scrub_secrets.py` in the vaults and the inline `git grep` in `ci-python.yml`.

- **Commit gate** (composite action) — used as a step inside a reusable workflow
  (`ci-python.yml` at `core+dsn-creds`, `ci-vault.yml` at `full`). Fail-closed.
- **Pipeline CLI** (pip) — `scrub-secrets --in-place` for the ingest/render bus.

## Public / private boundary (this repo is PUBLIC)

Patterns are DATA, not code. `patterns-public.json` ships only **generic,
vendor-neutral** patterns. Anything project- or vendor-specific (a SaaS token
format, an integration domain, non-English labels) lives in a **private overlay
JSON in the project's Vault** and is passed with `--patterns`. Private patterns
never touch this repo. A self-check gate (`.github/workflows/self-check.yml`)
mechanically forbids private-pattern filenames and scans for vendor tells.

## Tiers

Patterns carry a `class`; `--tier` selects which classes apply (cumulative):

| tier | classes | for |
|------|---------|-----|
| `core` | unambiguous token shapes (PEM, AKIA, ghp_, JWT, …) | anything, ~0 false positives |
| `core+dsn-creds` | + DSN with `user:pass@` | **code monorepos** (commit gate) |
| `full` | + `password=`/`secret=`/`shared key` | **prose vaults**, ingest/render redact |

`password=`-style patterns are `full`-only on purpose: they are noisy on code
(source, fixtures), so code repos stay on `core+dsn-creds`. Any consumer can
narrow to `core` if it still sees noise. A bad `--tier` fails loudly, never
silently degrades.

## CLI

```
scrub-secrets --tier core+dsn-creds --check <path...>          # gate: exit 2 if found
scrub-secrets --tier full --in-place <path...>                # redact in place
scrub-secrets --tier full --patterns .config/scrub-extra.json --check <path...>
scrub-secrets --list-tiers ; scrub-secrets --version
```

Only counts and file paths are printed — never secret values.

## Install as a pipeline CLI

```
pip install "git+https://github.com/dippstack/ci@ci-v0.1.0#subdirectory=checks/scrub-secrets"
```

## Not-a-secret handling (no growing allow-list)

Two general layers keep false positives out without a per-finding list:

- **Default/dummy credentials auto-skip.** A DSN whose password is a well-known
  default (`postgres`, `root`, `changeme`, …) or equals the username
  (`user:user@`) is not a real secret and is skipped fleet-wide. Curated now; an
  entropy layer can be added on top later without touching callers.
- **Inline `scrub:allow` marker.** A deliberate fixture or canary (a fake secret
  that exists to test the scrubber) opts its own line out with a trailing
  `scrub:allow` comment. It lives with the code, shows up in the diff, and is
  review-gated — no central list to grow, scales per line.

```bash
printf "canary sk-ABCDEF...\n"   # scrub:allow  — deliberate test key
```

## Maintenance

Any pattern change ships with a positive test and a counter-example
(`tests/test_patterns.py`); the self-check gate validates `patterns-public.json`
is parseable before a tag is cut.
```
python -m pytest tests/
```
