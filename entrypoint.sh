#!/bin/bash

set -e

# Workaround until new Actions support neutral strategy
# See how it was before: https://developer.github.com/actions/creating-github-actions/accessing-the-runtime-environment/#exit-codes-and-statuses
NEUTRAL_EXIT_CODE=0

# since https://github.blog/2022-04-12-git-security-vulnerability-announced/
git config --global --add safe.directory /github/workspace

# Skip if not a PR
echo "Checking if issue is a pull request..."
(jq -r ".issue.pull_request.url" "$GITHUB_EVENT_PATH") || exit $NEUTRAL_EXIT_CODE

if [[ "$(jq -r ".action" "$GITHUB_EVENT_PATH")" != "created" ]]; then
  echo "This is not a new comment event!"
  exit $NEUTRAL_EXIT_CODE
fi

PR_NUMBER=$(jq -r ".issue.number" "$GITHUB_EVENT_PATH")
echo "Collecting information about PR #$PR_NUMBER of $GITHUB_REPOSITORY..."

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Set the GITHUB_TOKEN env variable."
  exit 1
fi

URI=https://api.github.com
API_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token $GITHUB_TOKEN"

USER_URL=$(jq -r ".comment.user.url" "$GITHUB_EVENT_PATH")
user_resp=$(curl -X GET -s -H "${API_HEADER}" "${USER_URL}")
USER_FULL_NAME=$(echo "$user_resp" | jq -r ".name")

# add a Thumbs Up reaction to the comment
COMMENTS_URL=$(jq -r ".comment.url" "$GITHUB_EVENT_PATH")
PREVIEW_API_HEADER="Accept: application/vnd.github.squirrel-girl-preview+json"
curl -X POST -s -H "${AUTH_HEADER}" -H "${PREVIEW_API_HEADER}" -d '{ "content": "+1" }' "$COMMENTS_URL/reactions"

if [[ "$USER_FULL_NAME" == "null" ]]; then
  echo "USER_URL: $USER_URL"
  echo "You must have your full name set up on your GitHub user profile so that the integration can be attributed to you!"
  exit 1
fi

PR_URL="${URI}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER"

pr_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" "${PR_URL}")

BASE_REPO=$(echo "$pr_resp" | jq -r .base.repo.full_name)
BASE_BRANCH=$(echo "$pr_resp" | jq -r .base.ref)

if [[ "$(echo "$pr_resp" | jq -r .rebaseable)" != "true" ]]; then
  echo "GitHub doesn't think that the PR is rebaseable!"
  exit 1
fi

if [[ -z "$BASE_BRANCH" ]]; then
  echo "Cannot get base branch information for PR #$PR_NUMBER!"
  echo "API response: $pr_resp"
  exit 1
fi

HEAD_REPO=$(echo "$pr_resp" | jq -r .head.repo.full_name)
HEAD_BRANCH=$(echo "$pr_resp" | jq -r .head.ref)

echo "Base branch for PR #$PR_NUMBER is $BASE_BRANCH"

if [[ "$BASE_REPO" != "$HEAD_REPO" ]]; then
  echo "PRs from forks are not supported at the moment."
  exit 1
fi

git remote set-url origin https://x-access-token:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY.git
git config --global user.email "action@github.com"
git config --global user.name "GitHub Action"

# Make sure branches are up-to-date
git fetch origin $BASE_BRANCH
git fetch origin $HEAD_BRANCH

# Rebase
git checkout -b $HEAD_BRANCH origin/$HEAD_BRANCH
git rebase origin/$BASE_BRANCH
git push --force-with-lease
HEAD_BRANCH_HEAD=$(git rev-parse HEAD)
echo "(Potentially) Rebased commit hash of HEAD is: $HEAD_BRANCH_HEAD"

# Poll for CI status
while true; do
  sleep 10

  LAST_STATUS=$(curl -s -H "${AUTH_HEADER}" -H "${API_HEADER}" "${URI}/repos/$GITHUB_REPOSITORY/commits/$HEAD_BRANCH_HEAD/status" | jq -r ".state")

  if [[ $LAST_STATUS != "pending" ]]; then
    break
  fi
  echo "Polling for CI build completion..."
done

if [[ $LAST_STATUS != "success" ]]; then
  echo "CI did not pass for branch $HEAD_BRANCH and HEAD commit $HEAD_BRANCH_HEAD. Cancelling integration."
  exit 1
fi

# Rebase
git checkout $HEAD_BRANCH
git rebase origin/$BASE_BRANCH
git push --force-with-lease

# Hit the merge button
AUTH_HEADER_FOR_MERGING="Authorization: token $GITHUB_TOKEN"
MERGE_COMMIT_MESSAGE="Merge branch '$HEAD_BRANCH' on behalf of $USER_FULL_NAME"
merge_resp=$(curl -X PUT -s -H "${AUTH_HEADER_FOR_MERGING}" -H "${API_HEADER}" -d "{\"commit_title\":\"$MERGE_COMMIT_MESSAGE\"}" "${PR_URL}/merge")

if [[ $merge_resp != *"Pull Request successfully merged"* ]]; then
  echo "Could not merge PR. Error from GitHub: '$merge_resp'"
  exit 1
fi
