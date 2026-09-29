# shellcheck shell=bash
# Resolve a project's base branch. Registry format is owned by fm-project-mode.sh.
# A registered base must name a branch on origin; the absence of that branch is
# an error, never a reason to fall back to origin/HEAD or a local branch.
# Without a registered base, preserve the legacy origin/HEAD, main, master order.
fm_project_base_branch() { # <project-dir> [registered-project-name]
  local dir=$1 name=${2:-$(basename "$1")} registered ref branch script_dir remote_refs
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  registered=$("$script_dir/fm-project-mode.sh" --base-branch "$name" 2>/dev/null) || {
    "$script_dir/fm-project-mode.sh" --base-branch "$name" >/dev/null || true
    return 1
  }
  if [ -n "$registered" ]; then
    . "$script_dir/fm-timeout-lib.sh"
    remote_refs=$(fm_run_timed 10 git -C "$dir" ls-remote --exit-code --heads origin "refs/heads/$registered" 2>/dev/null) || remote_refs=
    if ! printf '%s\n' "$remote_refs" | awk -v ref="refs/heads/$registered" '$2 == ref { found=1 } END { exit !found }'; then
      echo "error: registered base branch '$registered' for $name does not exist on origin or origin cannot be read" >&2
      return 1
    fi
    printf '%s\n' "$registered"
    return 0
  fi
  ref=$(git -C "$dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    printf '%s\n' "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf '%s\n' "$branch"
      return 0
    fi
  done
  return 1
}
