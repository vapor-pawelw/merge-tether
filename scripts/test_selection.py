"""Conservative, reviewed change-to-test mapping. Unmapped changes run everything."""

from fnmatch import fnmatchcase
from functools import lru_cache
from pathlib import Path
import os
import re
import subprocess


TASKS = ["tools", "helpers", "remote", "relay", "ios"]

# Top-level Swift type declarations; test suites follow the `...Tests` naming convention.
DECLARATION = re.compile(
    r"^(?:@\w+(?:\([^)\n]*\))?\s+)*(?:(?:public|internal|private|fileprivate|final|nonisolated|indirect)\s+)*"
    r"(?:struct|class|enum|actor|protocol)\s+([A-Z]\w*)", re.M)
RELAY_PREFIXES = ("Services/RemoteRelay/", "prototypes/remote-relay/")

# These groups include callers, not only the suite named after the edited type.
GROUPS = {
    "usage": ["AssistantUsageTests", "AssistantUsageStoreTests", "AssistantUsageRunnerTests",
              "AssistantJobSnapshotTests", "AssistantJobInvocationTests"],
    "presentation": ["MRBoardGroupingTests", "MRHumanActionTests", "MRProgressPresentationTests",
                     "MergeRequestBoardSnapshotTests", "InboxSnapshotTests", "RemoteBoardAdapterTests",
                     "ConfirmedAttentionSnapshotTests", "UserAttentionTests", "ReviewingContextTests",
                     "BoardRefreshStateTests", "BoardCardPinTests",
                     "MRActivityTimelineTests", "BoardApprovalProgressTests", "CommentReviewSnapshotTests",
                     "AuthorFeedbackCoordinatorTests", "BoardPresentationCacheTests", "CommandCenterDisplayFrameTests",
                     "ConfirmationQueueTests", "MRBoardManualOrderTests", "MRBoardProjectorTests",
                     "MREffectivePolicyPresentationTests", "MRWaitingStatusTests", "MergeSubmissionTests",
                     "RemoteHostDetailTests"],
    "feedback": ["AuthorFeedbackPolicyTests", "AuthorFeedbackCoordinatorTests", "AuthorFeedbackMergeTests",
                 "ReReviewAssessmentTests", "ReReviewVerifierTests", "VerifiedAuthorFeedbackTests",
                 "ConfirmationQueueTests", "MergeRequestTodoRoutingTests", "DraftProofRecoveryTests",
                 "FollowUpPushPermissionTests", "MRHumanActionTests", "RemoteBoardAdapterTests",
                 "MergeWorkflowExecutionTests", "TodoAutomationTests", "MRNoticeClassifierTests",
                 "FeedbackSuggestionDecisionsTests", "FeedbackSuggestionDecisionActionTests",
                 "CommentReviewSnapshotTests", "AuthoredMergeRequestStatusTests", "GlabMergeRequestAPITests",
                 # Verdict invalidation, readiness, discussion and routing consumers of the mapped types.
                 "AssistantJobExecutionTests", "AssistantJobInvocationTests", "AttentionAutomationTests",
                 "AuthorFeedbackPresentationTests", "AutoHandledEventBannerTests", "BoardAttentionPresenterTests",
                 "CommandCenterDisplayFrameTests", "MRCommentCitationTests", "MRDiscussionMarkdownCacheTests",
                 "MRDiscussionPresentationTests", "MRDiscussionSnapshotTests", "ManualDiscussionResolutionTests",
                 "MergeActionReadinessTests", "MergeRequestBoardSnapshotTests", "MergeSubmissionTests",
                 "ModelEvaluationTests", "PersonDirectoryTests", "ProposalMRContextTests", "ReReviewCoordinatorTests",
                 "RemoteMRControlsTests", "RemoteMRDetailLoaderTests", "ReviewingContextTests",
                 "StalePipelineJobTests", "TodoMonitorPersistenceGuardTests"],
}
GROUPS["usage"] += ["AssistantCLIHealthTests", "AssistantJobCoordinatorTests", "MRNoticeClassifierTests"]

RULES = [
    ("Sources/Model/AssistantUsage*.swift", "usage"),
    ("Sources/Services/AssistantUsage*.swift", "usage"),
    ("Sources/Views/AssistantUsageMRDetailCost.swift", "usage"),
    ("Sources/Views/Settings/AssistantUsageSettingsTab.swift", "usage"),
    ("Sources/Model/MRCardPresentation.swift", "presentation"),
    ("Sources/Model/BoardCardPin.swift", "presentation"),
    ("Sources/Model/BoardRefreshState.swift", "presentation"),
    ("Sources/Views/BoardCardMetadata.swift", "presentation"),
    ("Sources/Views/MRRowLayout.swift", "presentation"),
    ("Sources/Views/MergeRequestTitle.swift", "presentation"),
    ("Sources/Views/AgentDiagnosticDetails.swift", "presentation"),
    ("Sources/Services/AuthorFeedbackCoordinator.swift", "feedback"),
    ("Sources/Services/MergeRequestTodoRouter.swift", "feedback"),
    ("Sources/Services/ReReviewVerifier.swift", "feedback"),
    ("Sources/Model/AuthorFeedbackPolicy.swift", "feedback"),
    ("Sources/Model/ReReviewAssessment.swift", "feedback"),
    ("Sources/Model/MergeRequestTodoRouting.swift", "feedback"),
]


def declared_types(text):
    return DECLARATION.findall(text)


@lru_cache(maxsize=None)
def _test_declarations(repo):
    """Top-level suites and helper types declared by each top-level Swift test file."""
    index = {}
    for path in sorted((repo / "Tests").glob("*.swift")):
        names = declared_types(path.read_text(errors="replace"))
        index[path.name] = ([name for name in names if name.endswith("Tests")],
                            [name for name in names if not name.endswith("Tests")])
    return index


def test_declarations(repo):
    return _test_declarations(Path(repo).resolve())


def declared_suites(repo):
    return {suite for suites, _ in test_declarations(repo).values() for suite in suites}


def changed_test_file_suites(repo, path):
    """Every suite in a changed file, plus suites in files using its shared top-level fixtures."""
    index = test_declarations(repo)
    suites, helpers = index.get(Path(path).name, ([], []))
    selected = set(suites) or {Path(path).stem}
    if helpers:
        pattern = re.compile(r"\b(?:" + "|".join(map(re.escape, helpers)) + r")\b")
        for name, (other_suites, _) in index.items():
            if name != Path(path).name and pattern.search((repo / "Tests" / name).read_text(errors="replace")):
                selected.update(other_suites)
    return selected


@lru_cache(maxsize=None)
def _ios_patterns(repo):
    """Sources and resources compiled into MergeTetheriOS, read from Project.swift."""
    try:
        source = (repo / "Project.swift").read_text()
    except OSError:
        return ()
    start = source.find('name: "MergeTetheriOS"')
    if start < 0:
        return ()
    end = source.find(".target(", start)
    block = source[start:end if end > 0 else len(source)]
    patterns = []
    for key in ("sources", "resources"):
        match = re.search(key + r":\s*\[(.*?)\]", block, re.S)
        if match:
            patterns += re.findall(r'"([^"]+)"', match.group(1))
    return tuple(patterns)


def ios_patterns(repo):
    return _ios_patterns(Path(repo).resolve())


def glob_matches(path, pattern):
    expression = re.escape(pattern).replace(r"\*\*/", "(?:.*/)?").replace(r"\*\*", ".*").replace(r"\*", "[^/]*")
    return re.fullmatch(expression, path) is not None


def affects_ios(repo, path):
    return (path.startswith(("iOS/", "Packages/MergeTetherRemote/Sources/")) or path == "Project.swift"
            or any(glob_matches(path, pattern) for pattern in ios_patterns(repo)))


def git(repo, *arguments):
    return subprocess.check_output(["git", "-C", str(repo), *arguments], timeout=30, stderr=subprocess.PIPE)


def changed_paths(repo, base=None):
    """Include branch work, index/worktree changes and untracked files; retain deletions."""
    working = git(repo, "diff", "--name-only", "--no-renames", "--cached", "-z", "HEAD", "--")
    working += git(repo, "diff", "--name-only", "--no-renames", "-z", "--")
    working += git(repo, "ls-files", "--others", "--exclude-standard", "-z")
    if base is not None:
        comparison = git(repo, "merge-base", base, "HEAD").decode().strip()
    else:
        comparison = git(repo, "merge-base", "main", "HEAD").decode().strip()
        if comparison == git(repo, "rev-parse", "HEAD").decode().strip():
            # Local edits on main are the current change. In a clean checkout,
            # verify the latest commit rather than silently selecting nothing.
            if not working:
                comparison = git(repo, "rev-parse", "HEAD^").decode().strip()
    paths = git(repo, "diff", "--name-only", "--no-renames", "-z", comparison, "HEAD", "--")
    paths += working
    return sorted({os.fsdecode(path) for path in paths.split(b"\0") if path}), comparison


def full_plan(paths, reason):
    return dict(mode="full", suites=[], tasks=TASKS[:], paths=sorted(set(paths)), reasons=[reason])


def select_paths(repo, paths):
    paths = sorted(set(paths))
    if not paths:
        return full_plan(paths, "No change set established; run the full suite")
    suites, tasks, reasons = set(), set(), []
    for path in paths:
        if affects_ios(repo, path):
            tasks.add("ios")
        if path == "CHANGELOG.md":
            # Bundled What's New resource and release-workflow input, not only documentation.
            tasks.add("tools")
            reasons.append(f"{path}: changelog structure checks")
        elif path.endswith(".md") and (path in {"AGENTS.md", "README.md"} or path.startswith("docs/")):
            reasons.append(f"{path}: documentation only")
        elif path.startswith(RELAY_PREFIXES):
            tasks.add("relay")
            reasons.append(f"{path}: relay Worker tests")
        elif path.startswith("Tests/TestTools/") and path.endswith(".py"):
            tasks.add("tools")
            reasons.append(f"{path}: test tooling")
        elif path.startswith("Tests/AutomationHelpers/") and path.endswith(".py"):
            tasks.add("helpers")
            reasons.append(f"{path}: standalone automation helpers")
        elif path.startswith("Packages/MergeTetherRemote/Tests/") and path.endswith(".swift"):
            tasks.add("remote")
            reasons.append(f"{path}: remote package tests")
        elif path.startswith("Tests/") and path.count("/") == 1 and path.endswith("Tests.swift") and (repo / path).is_file():
            changed = changed_test_file_suites(repo, path)
            suites.update(changed)
            reasons.append(f"{path}: changed suite file ({', '.join(sorted(changed))})")
        else:
            matches = [group for pattern, group in RULES if fnmatchcase(path, pattern)]
            if not matches:
                return full_plan(paths, f"{path}: shared or unmapped change; full suite required")
            for group in matches:
                suites.update(GROUPS[group])
            reasons.append(f"{path}: {', '.join(matches)} and their consumers")
    available = declared_suites(repo)
    missing = [suite for suite in suites if suite not in available]
    if missing:
        return full_plan(paths, f"Selection references missing suites: {', '.join(sorted(missing))}")
    return dict(mode="targeted" if suites else "none", suites=[f"MergeTetherTests/{suite}" for suite in sorted(suites)],
                tasks=[task for task in TASKS if task in tasks], paths=paths, reasons=reasons)


def plan_changes(repo, base=None):
    try:
        paths, comparison = changed_paths(repo, base)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
        return full_plan([], f"Cannot determine change set ({error}); full suite required")
    plan = select_paths(repo, paths)
    plan["comparison"] = comparison
    return plan
