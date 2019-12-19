# Nulogy Integrate GitHub Action

Fork of the `cirrus-actions/rebase` repo for integrating a PR

# Example Usage

Add the following setup code to `.github/workflows/integrate.yml`.

```yml
name: Integrate

on:
  issue_comment:
    types: [created]

jobs:
  integrate:
    name: Integrate
    if: github.event.issue.pull_request != '' && contains(github.event.comment.body, '/integrate')
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

> NOTE: The `GITHUB_MERGING_TOKEN` must allow merging the PR into the BASE branch of the PR which is typically `master`.

Then on a PR, type `/integrate` into the comments section.

This will fail if the HEAD branch is not rebaseable on top of the BASE branch of the PR and the HEAD branch needs to be rebased.

