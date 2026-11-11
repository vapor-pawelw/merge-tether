#!/usr/bin/env bash
# Promote CHANGELOG Unreleased notes into a dated version section, create and
# push an annotated tag, then (when configured) watch the Release workflow and
# verify the GitHub release + Homebrew tap.
#
# Env vars:
#   GITLABTODOS_RELEASE_REPO        — override release repo (default below).
#   GITLABTODOS_HOMEBREW_TAP_REPO   — when set, verifies the Homebrew cask
#                                     at Casks/gitlab-todos.rb in that repo.
#                                     When unset, Homebrew verification is
#                                     skipped gracefully.
#
# Args:
#   --version X.Y.Z  Skip the interactive prompt.
#   --yes, -y        Non-interactive; assume yes to confirmations.
#   --platform all|macos  Required release inventory (default: all).

set -euo pipefail

RELEASE_WORKFLOW_NAME="Release"
DEFAULT_RELEASE_REPO="vapor-pawelw/merge-tether"
CHANGELOG_FILE="CHANGELOG.md"
CHANGELOG_UNRELEASED_PLACEHOLDER="- _No notable changes yet._"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

infer_owner_repo() {
  local remote_url
  remote_url="$(git config --get remote.origin.url || true)"
  if [[ -z "$remote_url" ]]; then
    return 1
  fi

  if [[ "$remote_url" =~ ^git@github\.com:([^/]+/[^/]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$remote_url" =~ ^https://github\.com/([^/]+/[^/]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  if [[ "$remote_url" =~ ^ssh://git@github\.com/([^/]+/[^/]+)(\.git)?$ ]]; then
    echo "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

normalize_owner_repo() {
  local owner_repo="$1"
  owner_repo="${owner_repo%.git}"
  printf '%s\n' "$owner_repo"
}

# Exit codes:
#   0 — Release workflow exists and is queryable.
#   2 — GitHub API query failed or returned unexpected output.
#   3 — Repo has no GitHub Actions workflows at all.
#   4 — Repo has workflows, but none named "$RELEASE_WORKFLOW_NAME".
release_workflow_status() {
  local owner_repo="$1"
  local total_count release_count

  total_count="$(gh api "repos/${owner_repo}/actions/workflows" --jq '.total_count' 2>/dev/null || true)"
  if [[ -z "$total_count" ]]; then
    return 2
  fi
  if [[ ! "$total_count" =~ ^[0-9]+$ ]]; then
    return 2
  fi

  if [[ "$total_count" -eq 0 ]]; then
    return 3
  fi

  release_count="$(gh api "repos/${owner_repo}/actions/workflows" --jq ".workflows | map(select(.name == \"${RELEASE_WORKFLOW_NAME}\")) | length" 2>/dev/null || true)"
  if [[ -z "$release_count" ]]; then
    return 2
  fi
  if [[ ! "$release_count" =~ ^[0-9]+$ ]]; then
    return 2
  fi
  if [[ "$release_count" -eq 0 ]]; then
    return 4
  fi

  return 0
}

default_next_patch() {
  local latest_tag="$1"
  local clean
  clean="${latest_tag#v}"
  if [[ "$clean" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    local major minor patch
    major="${BASH_REMATCH[1]}"
    minor="${BASH_REMATCH[2]}"
    patch="${BASH_REMATCH[3]}"
    echo "${major}.${minor}.$((patch + 1))"
    return 0
  fi
  return 1
}

extract_unreleased_notes() {
  local file="$1"
  awk '
    BEGIN { in_unreleased = 0; found = 0 }
    /^## Unreleased[[:space:]]*$/ {
      in_unreleased = 1
      found = 1
      next
    }
    /^## / {
      if (in_unreleased == 1) {
        exit
      }
    }
    in_unreleased == 1 {
      print
    }
    END {
      if (found == 0) {
        exit 2
      }
    }
  ' "$file"
}

extract_version_notes() {
  local file="$1"
  local version="$2"
  awk -v version="$version" '
    BEGIN { in_version = 0; found = 0 }
    $0 ~ ("^## " version " - ") {
      in_version = 1
      found = 1
      print
      next
    }
    /^## / {
      if (in_version == 1) {
        exit
      }
    }
    in_version == 1 {
      print
    }
    END {
      if (found == 0) {
        exit 2
      }
    }
  ' "$file"
}

has_meaningful_changelog_notes() {
  local notes_file="$1"
  local count
  count="$(sed '/^[[:space:]]*$/d' "$notes_file" \
    | grep -Fvx -- "$CHANGELOG_UNRELEASED_PLACEHOLDER" \
    | grep -c '[^[:space:]]' || true)"
  [[ "${count:-0}" -gt 0 ]]
}

promote_unreleased_changelog() {
  local changelog_file="$1"
  local version="$2"
  local release_date="$3"
  local notes_file="$4"
  local tmp_file
  tmp_file="$(mktemp)"

  if ! awk -v version="$version" \
    -v release_date="$release_date" \
    -v placeholder="$CHANGELOG_UNRELEASED_PLACEHOLDER" \
    -v notes_file="$notes_file" '
      BEGIN { in_unreleased = 0; inserted = 0 }
      /^## Unreleased[[:space:]]*$/ && inserted == 0 {
        print
        print ""
        print placeholder
        print ""
        printf "## %s - %s\n\n", version, release_date
        while ((getline line < notes_file) > 0) {
          print line
        }
        close(notes_file)
        print ""
        in_unreleased = 1
        inserted = 1
        next
      }
      /^## / {
        if (in_unreleased == 1) {
          in_unreleased = 0
        }
      }
      {
        if (in_unreleased == 1) {
          next
        }
        print
      }
      END {
        if (inserted == 0) {
          exit 2
        }
      }
    ' "$changelog_file" >"$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$changelog_file"
}

NON_INTERACTIVE=0

confirm() {
  local prompt="$1"
  if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
    echo "$prompt [y/N]: y (non-interactive)"
    return 0
  fi
  local response
  read -r -p "$prompt [y/N]: " response
  case "$response" in
    [Yy]|[Yy][Ee][Ss]) return 0 ;;
    *) return 1 ;;
  esac
}

wait_for_release_run_id() {
  local owner_repo="$1"
  local tag="$2"
  local run_id=""
  local attempt

  for attempt in $(seq 1 36); do
    run_id="$(gh run list \
      --repo "$owner_repo" \
      --workflow "$RELEASE_WORKFLOW_NAME" \
      --limit 40 \
      --json databaseId,event,headBranch,createdAt \
      --jq ".[] | select(.event == \"push\" and .headBranch == \"$tag\") | .databaseId" | head -n1 || true)"

    if [[ -n "$run_id" ]]; then
      echo "$run_id"
      return 0
    fi

    sleep 5
  done

  return 1
}

# Verify the release record itself, then the required per-platform inventory.
verify_release_asset() {
  local owner_repo="$1" tag="$2" version="$3" platform="$4" expected_build="$5" evidence
  evidence="$(mktemp -d)"
  if ! gh release view "$tag" --repo "$owner_repo" --json tagName,isDraft,url,assets >"$evidence/release.json"; then
    rm -rf "$evidence"
    echo "Could not read the published release record." >&2
    return 1
  fi
  if ! gh release download "$tag" --repo "$owner_repo" --pattern release-manifest.json --dir "$evidence" >/dev/null; then
    rm -rf "$evidence"
    echo "Could not read release-manifest.json; version/build evidence is required." >&2
    return 1
  fi
  local result=0
  python3 - "$evidence" "$owner_repo" "$tag" "$version" "$platform" "$expected_build" <<'PYTHON' || result=$?
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
with (root / 'release.json').open() as source:
    release = json.load(source)
with (root / 'release-manifest.json').open() as source:
    manifest = json.load(source)
repo, tag, version, platform, expected_build = sys.argv[2:]
expected_url = 'https://github.com/' + repo + '/releases/tag/' + tag
if release.get('tagName') != tag or release.get('isDraft') is not False or release.get('url') != expected_url:
    sys.exit('Release is missing, still a draft, or does not match the requested repository/tag URL.')
if manifest.get('version') != version or manifest.get('distributable') is not True or manifest.get('build') != expected_build:
    sys.exit('Release manifest does not describe a distributable artifact set for the requested version/build.')
assets = release.get('assets', [])
required = [(['GitLabTodos-' + version + '.dmg', 'GitLabTodos.dmg']),
            (['GitLabTodos-' + version + '.zip', 'GitLabTodos.zip'])]
if platform == 'all':
    required.append(['MergeTetheriOS-' + version + '.ipa'])
selected = []
for alternatives in required:
    matches = [asset for asset in assets if asset.get('name') in alternatives]
    if len(matches) != 1 or not isinstance(matches[0].get('size'), int) or matches[0]['size'] <= 0:
        sys.exit('Expected exactly one nonempty release asset: ' + ' or '.join(alternatives))
    selected.append(matches[0]['name'])
entries = manifest.get('artifacts', [])
if len(entries) != len(selected) or {entry.get('name') for entry in entries} != set(selected):
    sys.exit('Release manifest artifact count/names do not match the required platform inventory.')
if any(not re.fullmatch(r'[a-f0-9]{64}', entry.get('sha256', '')) for entry in entries):
    sys.exit('Release manifest is missing artifact SHA-256 evidence.')
print(expected_url)
PYTHON
  rm -rf "$evidence"
  return "$result"
}

report_incomplete_release() {
  echo "Release incomplete: tag ${tag} was pushed, but release verification did not finish." >&2
  echo "Inspect https://github.com/${release_repo}/releases/tag/${tag}" >&2
  echo "Check with: gh release view ${tag} --repo ${release_repo}" >&2
  echo "Inspect the existing tag and workflow; do not push the tag again." >&2
}

read_homebrew_cask() {
  local tap_repo="$1"
  gh api -H "Accept: application/vnd.github.raw" "repos/${tap_repo}/contents/Casks/gitlab-todos.rb"
}

verify_homebrew_version() {
  local tap_repo="$1"
  local version="$2"
  local expected_url="${3:-}"
  local cask_content cask_version cask_sha cask_url

  cask_content="$(read_homebrew_cask "$tap_repo")"
  cask_version="$(printf '%s\n' "$cask_content" | sed -n 's/^[[:space:]]*version[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  cask_sha="$(printf '%s\n' "$cask_content" | sed -n 's/^[[:space:]]*sha256[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"
  cask_url="$(printf '%s\n' "$cask_content" | sed -n 's/^[[:space:]]*url[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)"

  if [[ "$cask_version" != "$version" ]]; then
    echo "Homebrew cask is at version '$cask_version', expected '$version'." >&2
    return 1
  fi

  if [[ -z "$cask_sha" ]]; then
    echo "Homebrew cask has an empty sha256 field." >&2
    return 1
  fi

  if [[ -n "$expected_url" && "$cask_url" != "$expected_url" ]]; then
    echo "Homebrew cask URL is '$cask_url', expected '$expected_url'." >&2
    return 1
  fi

  echo "$cask_sha"
}

wait_for_homebrew_update() {
  local tap_repo="$1"
  local version="$2"
  local expected_url="${3:-}"
  local sha=""
  local attempt

  for attempt in $(seq 1 30); do
    if sha="$(verify_homebrew_version "$tap_repo" "$version" "$expected_url" 2>/dev/null)"; then
      printf '%s\n' "$sha"
      return 0
    fi
    sleep 10
  done

  return 1
}

main() {
  local version_arg="" platform="all"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version|--platform)
        if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
          echo "Missing value for $1; use --help." >&2; exit 1
        fi
        if [[ "$1" == --version ]]; then version_arg="${2#v}"; else platform="$2"; fi
        shift 2 ;;
      --help|-h)
        echo "Usage: $0 --version X.Y.Z [--platform all|macos] [--yes]"
        echo "Publishes a changelog commit and tag; requires prior authorization. Default verifies macOS and iOS assets."
        return 0 ;;
      --yes|-y) NON_INTERACTIVE=1; shift ;;
      *) echo "Unknown argument: $1" >&2; echo "Usage: $0 [--version X.Y.Z] [--yes]" >&2; exit 1 ;;
    esac
  done

  if [[ "$platform" != all && "$platform" != macos ]]; then
    echo "--platform must be all or macos." >&2; exit 1
  fi
  if [[ -z "$version_arg" && ( "$NON_INTERACTIVE" -eq 1 || ! -t 0 ) ]]; then
    echo "--version X.Y.Z is required without an interactive terminal." >&2; exit 1
  fi
  if [[ "$NON_INTERACTIVE" -eq 0 && ! -t 0 ]]; then
    echo "Use --yes with --version for explicitly authorized non-interactive publication." >&2; exit 1
  fi
  require_cmd python3
  require_cmd git
  require_cmd gh
  require_cmd sed
  require_cmd grep
  require_cmd awk
  require_cmd date
  require_cmd mktemp

  if ! git rev-parse --git-dir >/dev/null 2>&1; then
    echo "Run this script from inside a git repository." >&2
    exit 1
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "GitHub CLI is not authenticated. Run: gh auth login" >&2
    exit 1
  fi

  local source_repo
  source_repo="$(infer_owner_repo || true)"
  if [[ -z "$source_repo" ]]; then
    echo "Could not infer GitHub owner/repo from origin remote." >&2
    exit 1
  fi
  source_repo="$(normalize_owner_repo "$source_repo")"

  local release_repo
  release_repo="${GITLABTODOS_RELEASE_REPO:-$DEFAULT_RELEASE_REPO}"

  local tap_repo
  tap_repo="${GITLABTODOS_HOMEBREW_TAP_REPO:-}"

  local branch latest_tag default_version version tag release_date
  branch="$(git branch --show-current)"
  if [[ -z "$branch" ]]; then
    echo "Detached HEAD is not supported for releases. Check out a branch first." >&2
    exit 1
  fi
  latest_tag="$(git tag --sort=-v:refname | head -n1 || true)"
  default_version=""
  if [[ -n "$latest_tag" ]]; then
    default_version="$(default_next_patch "$latest_tag" || true)"
  fi
  release_date="$(date +%Y-%m-%d)"

  echo "Source repository: $source_repo"
  echo "Release repository: $release_repo"
  echo "Current branch: ${branch:-detached}"
  if [[ -n "$latest_tag" ]]; then
    echo "Latest tag: $latest_tag"
  else
    echo "No tags found yet."
  fi
  if [[ -n "$tap_repo" ]]; then
    echo "Homebrew tap: $tap_repo"
  else
    echo "Homebrew tap: (not configured — skipping cask verification)"
  fi

  if [[ -n "$version_arg" ]]; then
    version="$version_arg"
    echo "Version: $version"
  elif [[ -n "$default_version" ]]; then
    read -r -p "Version to release (e.g. 1.2.3) [$default_version]: " version
    version="${version:-$default_version}"
  else
    read -r -p "Version to release (e.g. 1.2.3): " version
  fi

  version="${version#v}"
  if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Invalid version '$version'. Use semantic version format like 1.2.3." >&2
    exit 1
  fi

  tag="v${version}"

  if [[ "$branch" != "main" ]]; then
    echo "Warning: you are not on 'main' (current: ${branch:-detached})."
    if ! confirm "Continue anyway"; then
      echo "Aborted."
      exit 0
    fi
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Warning: working tree has uncommitted changes."
    if ! confirm "Continue anyway"; then
      echo "Aborted."
      exit 0
    fi
  fi

  if git rev-parse "$tag" >/dev/null 2>&1; then
    echo "Tag '$tag' already exists locally." >&2
    exit 1
  fi
  if git ls-remote --tags origin "refs/tags/${tag}" | grep -q .; then
    echo "Tag '$tag' already exists on origin." >&2
    exit 1
  fi

  if [[ ! -f "$CHANGELOG_FILE" ]]; then
    echo "Missing ${CHANGELOG_FILE}. Add it before creating a release." >&2
    exit 1
  fi

  local release_notes_file
  release_notes_file="$(mktemp)"
  local tag_notes_file
  tag_notes_file="$(mktemp)"
  trap 'rm -f "'"$release_notes_file"'" "'"$tag_notes_file"'"' EXIT

  if ! extract_unreleased_notes "$CHANGELOG_FILE" >"$release_notes_file"; then
    echo "Could not read '## Unreleased' from ${CHANGELOG_FILE}." >&2
    echo "Expected format:"
    echo "## Unreleased"
    echo
    echo "- Bullet describing a user-visible change"
    exit 1
  fi

  if ! has_meaningful_changelog_notes "$release_notes_file"; then
    echo "${CHANGELOG_FILE} has no release notes under '## Unreleased'." >&2
    echo "Add at least one bullet before releasing."
    exit 1
  fi

  local commit
  commit="$(git rev-parse --short HEAD)"
  echo
  echo "Release plan:"
  echo "- Promote ${CHANGELOG_FILE} '## Unreleased' notes into '## ${version} - ${release_date}'"
  echo "- Create and push changelog commit on branch '${branch}'"
  echo "- Create and push annotated tag: $tag"
  echo "- Current source commit: $commit"
  echo "- Watch workflow in ${source_repo}: $RELEASE_WORKFLOW_NAME"
  echo "- Verify published release in ${release_repo} contains macOS .dmg/.zip (platform: ${platform})"
  [[ "$platform" != all ]] || echo "- Verify separate MergeTetheriOS-${version}.ipa distribution artifact"
  if [[ -n "$tap_repo" ]]; then
    echo "- Verify Homebrew tap ${tap_repo} points to version ${version}"
  fi
  echo

  if ! confirm "Proceed with this release"; then
    echo "Aborted."
    exit 0
  fi

  if ! promote_unreleased_changelog "$CHANGELOG_FILE" "$version" "$release_date" "$release_notes_file"; then
    echo "Failed to update ${CHANGELOG_FILE} for ${version}." >&2
    exit 1
  fi

  git add "$CHANGELOG_FILE"
  if git diff --cached --quiet -- "$CHANGELOG_FILE"; then
    echo "No changelog changes were staged for release ${version}." >&2
    exit 1
  fi

  local changelog_commit
  git commit -m "Update changelog for ${tag}" -- "$CHANGELOG_FILE"
  changelog_commit="$(git rev-parse --short HEAD)"

  if ! git push origin "$branch"; then
    echo "Failed to push branch '${branch}'. Tag was not created." >&2
    exit 1
  fi

  if ! extract_version_notes "$CHANGELOG_FILE" "$version" >"$tag_notes_file"; then
    echo "Could not read '## ${version} - <date>' notes from ${CHANGELOG_FILE} after promotion." >&2
    exit 1
  fi
  git tag -a "$tag" -F "$tag_notes_file"
  if ! git push origin "$tag"; then
    echo "Failed to push tag. Cleaning up local tag '$tag'." >&2
    git tag -d "$tag" >/dev/null 2>&1 || true
    exit 1
  fi

  local workflow_status
  if release_workflow_status "$source_repo"; then
    :
  else
    workflow_status="$?"
    case "$workflow_status" in
      2)
        echo "Could not query GitHub Actions workflows for ${source_repo}." >&2
        ;;
      3)
        echo "No GitHub Actions workflows are configured in ${source_repo}." >&2
        ;;
      4)
        echo "Workflow '${RELEASE_WORKFLOW_NAME}' is not configured in ${source_repo}." >&2
        ;;
    esac
    report_incomplete_release
    echo "Check with: gh run list --workflow \"${RELEASE_WORKFLOW_NAME}\" --repo ${source_repo}" >&2
    echo "Check with: gh release view ${tag} --repo ${release_repo}" >&2
    exit 1
  fi

  echo "Changelog commit ${changelog_commit} pushed. Waiting for GitHub Actions run..."
  local run_id
  run_id="$(wait_for_release_run_id "$source_repo" "$tag" || true)"
  if [[ -z "$run_id" ]]; then
    echo "Could not find the '${RELEASE_WORKFLOW_NAME}' run for tag ${tag}." >&2
    echo "Check manually with: gh run list --workflow \"${RELEASE_WORKFLOW_NAME}\" --repo ${source_repo}" >&2
    report_incomplete_release
    exit 1
  fi

  echo "Watching workflow run $run_id..."
  if ! gh run watch "$run_id" --repo "$source_repo" --exit-status; then
    report_incomplete_release
    exit 1
  fi

  local expected_build
  expected_build="$(gh run view "$run_id" --repo "$source_repo" --json number --jq '.number')" || {
    report_incomplete_release
    exit 1
  }
  if [[ ! "$expected_build" =~ ^[1-9][0-9]*$ ]]; then
    echo "Could not read the successful workflow's build number." >&2
    report_incomplete_release
    exit 1
  fi
  echo "Verifying GitHub release assets in ${release_repo}..."
  local release_url
  if ! release_url="$(verify_release_asset "$release_repo" "$tag" "$version" "$platform" "$expected_build")"; then
    report_incomplete_release
    exit 1
  fi

  if [[ -z "$tap_repo" ]]; then
    echo
    echo "Release complete."
    echo "- Changelog commit: ${changelog_commit}"
    echo "- Tag: ${tag}"
    echo "- GitHub release: ${release_url}"
    echo "- Homebrew tap: (skipped — set GITLABTODOS_HOMEBREW_TAP_REPO to enable)"
    return 0
  fi

  local expected_cask_url
  expected_cask_url="https://github.com/${release_repo}/releases/download/${tag}/GitLabTodos.dmg"

  echo "Verifying Homebrew tap update in ${tap_repo}..."
  local cask_sha
  cask_sha="$(wait_for_homebrew_update "$tap_repo" "$version" "$expected_cask_url" || true)"
  if [[ -z "$cask_sha" ]]; then
    echo "Release completed, but Homebrew tap did not update to ${version} in time." >&2
    echo "Check manually: https://github.com/${tap_repo}/blob/main/Casks/gitlab-todos.rb" >&2
    exit 1
  fi

  echo
  echo "Release complete."
  echo "- Changelog commit: ${changelog_commit}"
  echo "- Tag: ${tag}"
  echo "- GitHub release: ${release_url}"
  echo "- Homebrew cask: https://github.com/${tap_repo}/blob/main/Casks/gitlab-todos.rb"
  echo "- Homebrew sha256: ${cask_sha}"
}

main "$@"
