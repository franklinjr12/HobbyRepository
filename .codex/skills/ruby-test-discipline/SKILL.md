---
name: ruby-test-discipline
description: Require Ruby code changes to include matching test coverage. Use when Codex edits Ruby files, Rails app code, models, controllers, services, jobs, mailers, helpers, libraries, migrations with behavior, or Ruby configuration that changes runtime behavior, so each behavior change is added or updated with a focused test.
---

# Ruby Test Discipline

## Workflow

Treat tests as part of every Ruby change, not as a follow-up. Before editing,
identify the behavior that will change and the closest existing test file.

When changing Ruby behavior:

1. Add or update a focused test that would fail without the code change.
2. Prefer the repository's existing test style, helpers, factories, fixtures,
   and naming conventions.
3. Keep tests close to the changed behavior: model tests for model logic,
   request/controller tests for HTTP behavior, job tests for jobs, service or
   unit tests for plain Ruby objects, and system tests only for full user flows.
4. Cover bug fixes with a regression test that demonstrates the original
   failure.
5. Cover new branches, edge cases, validations, callbacks, authorization,
   serialization, side effects, and error handling introduced by the change.

## Exceptions

Skip test edits only when the Ruby change cannot affect behavior, such as a
comment-only edit, documentation-only change, generated metadata change, or
mechanical formatting change. In the final response, explicitly state why no
test file was needed.

If the repository has no suitable test framework or no nearby precedent, create
the smallest conventional test file for the project rather than leaving the
behavior untested. If that is not possible, explain the blocker and the residual
risk.

## Verification

Run the narrowest relevant test command for the files changed before broader
quality checks. Examples include a single test file, a specific line, or the
smallest affected suite supported by the repo.

In the final response, mention:

- Which test file was added or updated.
- Which test command was run and whether it passed.
- Any tests that could not run and why.
