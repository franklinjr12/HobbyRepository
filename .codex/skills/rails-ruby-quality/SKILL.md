---
name: rails-ruby-quality
description: Run Ruby on Rails quality checks after editing Ruby, Rails, Gemfile, routes, initializers, migrations, jobs, models, controllers, views, tests, or RuboCop/CI configuration. Use when Codex changes Ruby code or Rails structure and should verify syntax, autoloading, linting, performance cops, and static security analysis before finishing.
---

# Rails Ruby Quality

## Workflow

After editing Ruby or Rails-related files, run the repository's Docker-based checks
from the project root. Prefer Compose commands so the result matches the Windows
development environment.

Run these checks after Ruby/Rails edits:

```powershell
docker compose run --rm web ./bin/rubocop
docker compose run --rm web ./bin/rails zeitwerk:check
docker compose run --rm web ./bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error
```

When `Gemfile` or `Gemfile.lock` changes, refresh the lockfile first:

```powershell
docker compose run --rm web bundle lock
```

When database migrations or schema-affecting changes are made, also run:

```powershell
docker compose run --rm web ./bin/rails db:prepare
```

## Fix Loop

If a check fails, fix the reported issue and rerun the failed check. For RuboCop
format-only offenses, use autocorrect when it is low risk:

```powershell
docker compose run --rm web ./bin/rubocop -A
```

Review autocorrected changes before finishing. Do not use autocorrect as a
substitute for understanding semantic warnings.

## Reporting

In the final response, mention which checks were run and whether they passed. If
a check could not run, state the reason and the remaining risk.
