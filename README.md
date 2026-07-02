# Nulogy Integrate GitHub Action

Fork of the `cirrus-actions/rebase` repo for integrating a PR.

Supports two commands:

- `/integrate` -- Rebases, waits for CI, and merges the PR. "CI" means the legacy
  commit statuses (e.g. Buildkite) **and** GitHub Actions check-runs on the
  rebased commit. By default the merge proceeds only when the legacy status is
  `success` and every check-run present has completed with a `success`,
  `neutral`, or `skipped` conclusion. See [Configuration](#configuration) to
  require a specific named set of checks instead.
- `/hotfix` -- Same as integrate, but appends `[skip tests]` to the merge commit message.

# Example Usage

1. Add the following setup code to `.github/workflows/integrate.yml`.

    ```yml
    name: Integrate

    on:
      issue_comment:
        types: [created]

    jobs:
      integrate:
        name: Integrate
        if: >-
          github.event.issue.pull_request != '' &&
          (contains(github.event.comment.body, '/integrate') || contains(github.event.comment.body, '/hotfix'))
        runs-on: ubuntu-latest
        steps:
          - uses: actions/checkout@v1.2.0
          - uses: nulogy/integrate-action@master
            env:
              GITHUB_TOKEN: ${{ secrets.GITHUB_MERGING_TOKEN }}
      always_job:
        name: Aways run job
        runs-on: ubuntu-latest
        steps:
          - name: Always run
            run: echo "This job is used to prevent the workflow to fail when all other jobs are skipped."
    ```

1. Add `GITHUB_MERGING_TOKEN` as a secret in "Settings" > "Secrets". NOTE: The `GITHUB_MERGING_TOKEN` must allow merging the PR into the BASE branch of the PR which is typically `master`.
1. Make sure "Allow merge commits" is checked under the "Merge button" section in your repo settings.

Then on a PR, type `/integrate` or `/hotfix` into the comments section. Using `/hotfix` will add `[skip tests]` to the merge commit message.

This will fail if the HEAD branch is not rebaseable on top of the BASE branch of the PR and the HEAD branch needs to be rebased.

# Configuration

All optional, passed via `env:` on the action step:

| Variable | Default | Purpose |
|---|---|---|
| `GITHUB_TOKEN` | — | **Required.** Token allowed to merge into the PR's base branch. |
| `ADD_CHANGE_LOGS` | `false` | Collect `Change log:` PR comments into the merge commit message. |
| `CI_WAIT_TIMEOUT_SECONDS` | `14400` (4h) | Give up waiting for CI after this many seconds (fail, don't merge). Keep it above your slowest check and below the job's own timeout (GitHub's default is 6h). |
| `REQUIRED_CHECK_RUNS` | _(empty)_ | Comma-separated check-run names that must be **present and pass** before merging. When empty, the action gates on every check-run present on the commit. Set this to avoid trusting an empty/partial check-run set and to ignore unrelated/advisory checks. |
| `REQUIRED_CHECK_RUNS_PATHS` | _(empty)_ | Comma-separated path **prefixes**. When set, `REQUIRED_CHECK_RUNS` is enforced only if the PR changes a file under one of them — so a PR that doesn't touch the relevant product isn't blocked waiting for checks that never run. When empty, `REQUIRED_CHECK_RUNS` always applies. |

Example (a monorepo whose SFac product's tests run as GitHub Actions):

```yml
      - uses: nulogy/integrate-action@v2.0.0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_MERGING_TOKEN }}
          REQUIRED_CHECK_RUNS: "test,client_test,e2e"
          REQUIRED_CHECK_RUNS_PATHS: "SensrTrxMES/"
```

**Requirement:** the action waits on the legacy combined-status API and merges only when it reports `success`, so a repo must have **at least one legacy commit status** (e.g. Buildkite) that stays `pending` through its build. A pure-GitHub-Actions repo with no legacy statuses is not yet supported — the combined status reads `pending` indefinitely and the action will wait until it times out.

# Versioning

This action is released as git tags. Reference a tag for stable behavior, e.g. `nulogy/integrate-action@v2.0.0`.

- `v2.0.0` -- waits for GitHub Actions check-runs in addition to legacy commit statuses before merging. Use this in repos whose CI runs (partly) on GitHub Actions, e.g. monorepos.
- `v1.1.1` -- legacy behavior: waits only on the combined commit-status API (check-runs are ignored). Pin this if you rely on the old behavior.

`@master` tracks the latest release.

