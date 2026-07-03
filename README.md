# Nulogy Integrate GitHub Action

Fork of the `cirrus-actions/rebase` repo for integrating a PR.

Supports two commands:

- `/integrate` -- Rebases, waits for CI, and merges the PR. "CI" spans a commit's
  GitHub Actions check-runs **and** legacy status contexts (e.g. Buildkite),
  read together via GitHub's GraphQL `statusCheckRollup`. The merge proceeds only
  when every check present on the commit has completed with a `success`,
  `neutral`, or `skipped` conclusion. See [Configuration](#configuration) for
  `REQUIRED_CHECKS`, which additionally waits for named checks to *appear* so a PR
  can't merge in the window before its checks have registered.
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
              # Strongly recommended (see Configuration): require your CI checks to be
              # present and pass. Without it, the action gates only on whatever checks
              # happen to exist when it polls.
              REQUIRED_CHECKS: '[{"checks":["your-ci-check"]}]'
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
| `REQUIRED_CHECKS` | _(empty)_ | JSON array of rules pairing path prefixes with check names that must be **present** (and pass) before merging — matching GitHub Actions check-runs *and* legacy status contexts (e.g. `buildkite/packmanager`). A rule with no `paths` always applies; with `paths` it applies only when the PR changes a file under one of those prefixes. The action *always* requires every check present on the commit to pass; these rules additionally require the named checks to have appeared, closing the window where a check hasn't registered yet and an empty/partial set looks "green". You do **not** list every check — a new check is caught by the always-on "all present must pass" rule — but name at least one reliably-running check per product as an anchor. Example: `[{"checks":["buildkite/packmanager"]},{"paths":["some/dir/"],"checks":["test","e2e"]}]` |

Example (a monorepo: Buildkite gates one product, GitHub Actions gates another):

```yml
      - uses: nulogy/integrate-action@v2.0.0
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_MERGING_TOKEN }}
          REQUIRED_CHECKS: '[{"checks":["buildkite/packmanager"]},{"paths":["SensrTrxMES/"],"checks":["test","client_test","e2e"]}]'
```

Notes:

- Check state is read from GitHub's GraphQL `statusCheckRollup`, so Actions check-runs and legacy status contexts are gated the same way — the action works for Actions-only, status-only, or mixed repos, and needs no branch-protection required checks.
- Without `REQUIRED_CHECKS` the action still won't merge on an *empty* check set (it waits for at least one check to appear), but it can only gate on whatever has appeared by then; set `REQUIRED_CHECKS` to guarantee specific checks ran.
- Each anchor should be a check that registers no later than the checks it stands in for (prefer a fast-registering check-run over a slow external status), so the "all present" rule can't finish before a sibling has appeared.
- Check names and path prefixes must not contain commas.
- If a commit has more than 100 checks, the action refuses to merge (it cannot see them all) rather than merging on a partial view.

# Versioning

This action is released as git tags. Reference a tag for stable behavior, e.g. `nulogy/integrate-action@v2.0.0`.

- `v2.0.0` -- waits for GitHub Actions check-runs in addition to legacy commit statuses before merging. Use this in repos whose CI runs (partly) on GitHub Actions, e.g. monorepos.
- `v1.1.1` -- legacy behavior: waits only on the combined commit-status API (check-runs are ignored). Pin this if you rely on the old behavior.

`@master` tracks the latest release.

