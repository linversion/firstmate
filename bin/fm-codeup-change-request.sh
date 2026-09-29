#!/usr/bin/env bash
# Publish or verify one Codeup merge request for a registered-base push-only ship.
# Usage: fm-codeup-change-request.sh publish <worktree> <ship-branch> <base-branch>
#        fm-codeup-change-request.sh verify <worktree> <ship-branch> <base-branch> <local-id> <web-url>
# The CLI commands and response fields follow the central-edition aliyun devops
# codeup-get-repository, codeup-list-change-requests, codeup-create-change-request,
# and codeup-get-change-request contracts. A retry lists open requests before
# creating, so an interrupted create cannot produce a second request for the
# same source and target. This does not verify the MR's head commit or its CI.
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
mode=${1:-}
wt=${2:-}
branch=${3:-}
base=${4:-}
case "$mode" in publish) [ "$#" -eq 4 ] || die 'usage: publish <worktree> <ship-branch> <base-branch>' ;; verify) [ "$#" -eq 6 ] || die 'usage: verify <worktree> <ship-branch> <base-branch> <local-id> <web-url>' ;; *) die 'usage: publish|verify <worktree> <ship-branch> <base-branch> [<local-id> <web-url>]' ;; esac
if [ ! -d "$wt" ] || ! git -C "$wt" rev-parse --git-dir >/dev/null 2>&1; then
  die "not a git worktree: $wt"
fi
git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "invalid ship branch: $branch"
git check-ref-format --branch "$base" >/dev/null 2>&1 || die "invalid base branch: $base"
[ -n "${ALIBABA_CLOUD_YUNXIAO_ORGANIZATION_ID:-}" ] || die 'ALIBABA_CLOUD_YUNXIAO_ORGANIZATION_ID is missing; obtain it from Organization Management > Basic Information in Yunxiao'
[ -n "${ALIBABA_CLOUD_YUNXIAO_ACCESS_TOKEN:-}" ] || die 'ALIBABA_CLOUD_YUNXIAO_ACCESS_TOKEN is missing; obtain a personal access token with Codeup merge request access in Yunxiao'
command -v aliyun >/dev/null 2>&1 || die 'aliyun CLI is missing'
command -v jq >/dev/null 2>&1 || die 'jq is missing'

origin=$(git -C "$wt" config --get remote.origin.url) || die 'origin URL cannot be read'
case "$origin" in
  git@codeup.aliyun.com:*) path=${origin#git@codeup.aliyun.com:} ;;
  ssh://git@codeup.aliyun.com/*) path=${origin#ssh://git@codeup.aliyun.com/} ;;
  https://codeup.aliyun.com/*) path=${origin#https://codeup.aliyun.com/} ;;
  *) die "origin is not a Codeup remote: $origin" ;;
esac
path=${path%.git}
case "$path" in */*) ;; *) die 'Codeup origin has no namespace/repository path' ;; esac
repo_path=$(jq -nr --arg path "$path" '$path | @uri')

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# A bounded read prevents a stalled CLI from accepting partial JSON. A failed
# create may have succeeded remotely; the next publish lists before creating.
# shellcheck source=bin/fm-timeout-lib.sh
. "$script_dir/fm-timeout-lib.sh"
codeup() { fm_run_timed 30 aliyun devops "$@"; }
repository=$(codeup codeup-get-repository --repository-id "$repo_path") || die 'Codeup repository lookup failed'
repo_id=$(printf '%s' "$repository" | jq -er --arg path "$path" 'select(.pathWithNamespace == $path) | .id | select(type == "number" and . > 0 and . == floor)') \
  || die "Codeup repository response does not identify $path"

read_request() { # <local-id> [expected-web-url]
  local local_id=$1 expected_url=${2:-} response url
  response=$(codeup codeup-get-change-request --repository-id "$repo_id" --local-id "$local_id") \
    || die "Codeup merge request $local_id cannot be read"
  url=$(printf '%s' "$response" | jq -er --argjson repo "$repo_id" --argjson id "$local_id" \
    --arg source "$branch" --arg target "$base" --arg expected "$expected_url" '
    select(.localId == $id and .projectId == $repo and .sourceProjectId == $repo and .targetProjectId == $repo)
    | select(.sourceBranch == $source and .targetBranch == $target)
    | select((.status // .state) as $state | ["UNDER_DEV", "UNDER_REVIEW", "TO_BE_MERGED"] | index($state) != null)
    | (.webUrl // .detailUrl) | select(type == "string" and startswith("https://") and ($expected == "" or . == $expected))') \
    || die "Codeup merge request $local_id does not match repository $repo_id, $branch -> $base, its open state, or the reported URL"
  printf 'MR %s %s\n' "$local_id" "$url"
}

if [ "$mode" = verify ]; then
  case "$5" in ''|*[!0-9]*) die 'merge request number must be a positive integer' ;; esac
  [ "$5" -gt 0 ] || die 'merge request number must be a positive integer'
  read_request "$5" "$6"
  exit 0
fi

page=1
matches='[]'
while [ "$page" -le 100 ]; do
  listed=$(codeup codeup-list-change-requests --project-ids "$repo_id" --state opened --page "$page" --per-page 100) \
    || die 'Codeup open merge requests cannot be listed'
  printf '%s' "$listed" | jq -e 'type == "array"' >/dev/null || die 'Codeup list response is not an array'
  found=$(printf '%s' "$listed" | jq --argjson repo "$repo_id" --arg source "$branch" --arg target "$base" '
    map(select(.projectId == $repo and .sourceProjectId == $repo and .targetProjectId == $repo and .sourceBranch == $source and .targetBranch == $target))') \
    || die 'Codeup list response cannot be parsed'
  matches=$(jq -cn --argjson before "$matches" --argjson found "$found" '$before + $found')
  count=$(printf '%s' "$listed" | jq 'length')
  [ "$count" -eq 100 ] || break
  page=$((page + 1))
done
[ "$page" -le 100 ] || die 'Codeup open merge request listing exceeded 100 pages'
count=$(printf '%s' "$matches" | jq 'length')
if [ "$count" -gt 1 ]; then die "multiple open Codeup merge requests match $branch -> $base"; fi
if [ "$count" -eq 1 ]; then
  local_id=$(printf '%s' "$matches" | jq -er '.[0].localId | select(type == "number" and . > 0 and . == floor)') || die 'matching Codeup merge request lacks a local ID'
else
  title=$(git -C "$wt" log -1 --format=%s "$branch" 2>/dev/null || true)
  [ -n "$title" ] || title="Merge $branch into $base"
  title=${title:0:256}
  created=$(codeup codeup-create-change-request --repository-id "$repo_id" --source-project-id "$repo_id" --source-branch "$branch" --target-project-id "$repo_id" --target-branch "$base" --title "$title") \
    || die 'Codeup merge request creation failed; retry publication to check for an existing request before creating'
  local_id=$(printf '%s' "$created" | jq -er '.localId | select(type == "number" and . > 0 and . == floor)') || die 'created Codeup response lacks a local ID; retry publication to check before creating'
fi
read_request "$local_id"
