# Contributing

## Setup

```bash
pip install pre-commit
pre-commit install --install-hooks -t pre-commit -t commit-msg
```

You also need `shellcheck`, `shfmt`, and (for tests) `bats`. On Debian/Ubuntu:
`apt-get install shellcheck shfmt bats`.

## Workflow

1. Pick a `ready` ticket from [tickets/README.md](tickets/README.md).
2. Branch from `develop`: `git checkout -b <type>/<ticket-slug>`.
3. Implement only that ticket's scope. Keep modules idempotent and `DRY_RUN`-aware.
4. `make lint` and `pre-commit run --all-files` must pass.
5. Open a PR to `develop`. One ticket per PR.

## Hard rules

- **Conventional Commits** — enforced at commit time. Type + scope, e.g.
  `feat(ssh): keys-only sshd drop-in`.
- **Writing style** — [docs/STYLE.md](docs/STYLE.md). No AI attribution in commits, docs,
  or comments; no AI-tell vocabulary. The language linter blocks violations.
- **No secrets** — gitleaks runs in pre-commit. Generated credentials never get committed
  or echoed to a terminal.

## Definition of done

Every ticket lists its own. The universal floor: acceptance criteria pass, lint clean,
idempotent, `DRY_RUN=1` supported, STYLE.md clean, rationale in
[docs/HARDENING.md](docs/HARDENING.md) if behavior changed.
