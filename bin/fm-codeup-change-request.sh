#!/usr/bin/env bash
# Publish, verify, or merge one Codeup request for a registered-base push-only ship.
# Usage: fm-codeup-change-request.sh publish <worktree> <ship-branch> <base-branch>
#        fm-codeup-change-request.sh verify <worktree> <ship-branch> <base-branch> <local-id> <web-url>
#        fm-codeup-change-request.sh verify-merged <worktree> <ship-branch> <base-branch> <local-id> <web-url>
#        fm-codeup-change-request.sh merge <worktree> <ship-branch> <base-branch> <local-id> <web-url> <task-id>
# Merge routes through fm-pr-merge.sh; only that gate calls the sourced function
# with a receipt-bound head instead of a task ID. Sourcing has no side effects.
# The CLI commands and response fields follow the central-edition aliyun devops
# codeup-get-repository, codeup-list-change-requests, codeup-create-change-request,
# and codeup-get-change-request contracts. A retry lists open requests before
# creating, so an interrupted create cannot produce a second request for the
# same source and target. Publish/verify do not verify the head or CI. Merge
# requires the latest source patch and branch head to equal the acceptance head,
# allRequirementsPass=true, NO_CONFLICT, and the latest CI checklist to be PASS.
# Codeup has no expected-head merge parameter: the last branch read narrows but
# cannot close a concurrent-push race. Only a readback of MERGED proves landing.
# Merge uses no-fast-forward and preserves the source branch.
# Output is MR <local-id> <URL>, using detailUrl when present and webUrl otherwise.
fm_codeup_change_request() (
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }
mode=${1:-}
wt=${2:-}
branch=${3:-}
base=${4:-}
case "$mode" in publish) [ "$#" -eq 4 ] || die 'usage: publish <worktree> <ship-branch> <base-branch>' ;; merge) [ "$#" -eq 7 ] || die 'usage: merge <worktree> <ship-branch> <base-branch> <local-id> <web-url> <head>' ;; verify|verify-merged) [ "$#" -eq 6 ] || die 'usage: verify <worktree> <ship-branch> <base-branch> <local-id> <web-url>' ;; *) die 'usage: publish|verify|verify-merged|merge <worktree> <ship-branch> <base-branch> [<local-id> <web-url>]' ;; esac
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
  https://*@codeup.aliyun.com/*)
    rest=${origin#https://}
    authority=${rest%%/*}
    userinfo=${authority%@codeup.aliyun.com}
    userinfo=${userinfo%@}
    [ -n "$userinfo" ] || die 'origin is not a Codeup remote'
    path=${rest#"$authority"/}
    ;;
  *) die 'origin is not a Codeup remote' ;;
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

read_request() { # <local-id> [expected-web-url] [allowed-statuses]
  local local_id=$1 expected_url=${2:-} allowed=${3:-'["UNDER_DEV","UNDER_REVIEW","TO_BE_MERGED"]'} url
  response=$(codeup codeup-get-change-request --repository-id "$repo_id" --local-id "$local_id") \
    || die "Codeup merge request $local_id cannot be read"
  url=$(printf '%s' "$response" | jq -er --argjson repo "$repo_id" --argjson id "$local_id" --argjson allowed "$allowed" \
    --arg source "$branch" --arg target "$base" --arg expected "$expected_url" '
    select(.localId == $id and .projectId == $repo and .sourceProjectId == $repo and .targetProjectId == $repo)
    | select(.sourceBranch == $source and .targetBranch == $target)
    | select((.status // .state) as $state | $allowed | index($state) != null)
    | (.detailUrl // .webUrl) | select(type == "string" and startswith("https://") and ($expected == "" or . == $expected))') \
    || die "Codeup merge request $local_id does not match repository $repo_id, $branch -> $base, its required state, or the reported URL"
  printf 'MR %s %s\n' "$local_id" "$url"
}

if [ "$mode" = verify ] || [ "$mode" = verify-merged ] || [ "$mode" = merge ]; then
  case "$5" in ''|*[!0-9]*) die 'merge request number must be a positive integer' ;; esac
  [ "$5" -gt 0 ] || die 'merge request number must be a positive integer'
  if [ "$mode" = merge ]; then
    head=$7
    [[ "$head" =~ ^[0-9a-f]{40}$|^[0-9a-f]{64}$ ]] || die 'invalid acceptance head'
    read_request "$5" "$6" '["TO_BE_MERGED","MERGED"]' >/dev/null
    patches=$(codeup codeup-list-change-request-patch-sets --repository-id "$repo_id" --local-id "$5") \
      || die 'Codeup source patch sets cannot be read'
    patch=$(printf '%s' "$patches" | jq -er --arg head "$head" '
      select(type == "array") | map(select(.relatedMergeItemType == "MERGE_SOURCE"))
      | select(length > 0 and all(.[]; (.versionNo | type) == "number"))
      | sort_by(.versionNo) | .[-1] | select(.commitId == $head)
      | .patchSetBizId | select(type == "string" and length > 0)') \
      || die 'latest Codeup source patch does not hold the acceptance head'
    if [ "$(printf '%s' "$response" | jq -r '.status // .state')" = MERGED ]; then
      read_request "$5" "$6" '["MERGED"]'
      exit 0
    fi
    printf '%s' "$response" | jq -e '.allRequirementsPass == true and .conflictCheckStatus == "NO_CONFLICT"' >/dev/null \
      || die 'Codeup merge requires passed requirements and no conflicts'
    checks=$(codeup codeup-list-change-request-ci-check-list --repository-id "$repo_id" --local-id "$5" --patch-set-biz-id "$patch") \
      || die 'Codeup CI checklist cannot be read'
    printf '%s' "$checks" | jq -e --arg head "$head" '
      type == "object" and .latest == true and .status == "PASS"
      and ((.commitStatuses // []) | all(.[]; .sha == $head and .state == "success"))' >/dev/null \
      || die 'Codeup latest head CI checks are not green'
    # GetBranch has .name and .commit.id; encode slashes in contrib/foo.
    branch_name=$(jq -nr --arg branch "$branch" '$branch | @uri')
    source=$(codeup codeup-get-branch --repository-id "$repo_id" --branch-name "$branch_name") \
      || die 'Codeup source branch cannot be read'
    printf '%s' "$source" | jq -e --arg branch "$branch" --arg head "$head" '.name == $branch and .commit.id == $head' >/dev/null \
      || die 'Codeup source branch does not hold the acceptance head'
    [ "$(git -C "$wt" rev-parse HEAD)" = "$head" ] || die 'local HEAD changed since acceptance'
    merge_output=$(codeup codeup-merge-change-request --repository-id "$repo_id" --local-id "$5" \
      --merge-type no-fast-forward --remove-source-branch false 2>&1) || true
    # Do not trust even a zero CLI exit: a definite unmerged read refuses.
    if ! (read_request "$5" "$6" '["MERGED"]'); then
      [ -z "$merge_output" ] || printf 'error: > %s\n' "$merge_output" >&2
      die "Codeup did not confirm $6 as MERGED"
    fi
  elif [ "$mode" = verify-merged ]; then
    read_request "$5" "$6" '["MERGED"]'
  else
    read_request "$5" "$6"
  fi
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
  title=$(git -C "$wt" log -1 --format=%s "refs/heads/$branch" 2>/dev/null) || die "local ship branch $branch cannot supply a merge request title"
  [ -n "$title" ] || die "local ship branch $branch has no commit subject for a merge request title"
  title=${title:0:256}
  created=$(codeup codeup-create-change-request --repository-id "$repo_id" --source-project-id "$repo_id" --source-branch "$branch" --target-project-id "$repo_id" --target-branch "$base" --title "$title") \
    || die 'Codeup merge request creation failed; retry publication to check for an existing request before creating'
  local_id=$(printf '%s' "$created" | jq -er '.localId | select(type == "number" and . > 0 and . == floor)') || die 'created Codeup response lacks a local ID; retry publication to check before creating'
fi
read_request "$local_id"

)

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = merge ]; then
    [ "$#" -eq 7 ] || { echo 'error: usage: merge <worktree> <ship-branch> <base-branch> <local-id> <web-url> <task-id>' >&2; exit 1; }
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    # Supplied worktree/branches must agree with the task that owns the gate.
    exec "$script_dir/fm-pr-merge.sh" "$7" "$6" --codeup-worktree "$2" --codeup-branch "$3" --codeup-base "$4" --codeup-id "$5"
  fi
  fm_codeup_change_request "$@"
fi
