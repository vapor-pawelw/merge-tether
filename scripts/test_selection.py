"""Conservative, reviewed change-to-test mapping. Unmapped changes run everything."""

from fnmatch import fnmatchcase
from pathlib import Path
import os
import subprocess


TASKS = ["tools", "helpers", "remote"]

# These groups include callers, not only the suite named after the edited type.
GROUPS = {
    "usage": ["AssistantUsageTests", "AssistantUsageStoreTests", "AssistantUsageRunnerTests",
              "AssistantJobSnapshotTests", "AssistantJobInvocationTests"],
    "presentation": ["MRBoardGroupingTests", "MRHumanActionTests", "MRProgressPresentationTests",
                     "MergeRequestBoardSnapshotTests", "InboxSnapshotTests", "RemoteBoardAdapterTests",
                     "ConfirmedAttentionSnapshotTests", "UserAttentionTests", "ReviewingContextTests",
                     "BoardRefreshStateTests", "BoardCardPinTests",
                     "MRActivityTimelineTests", "BoardApprovalProgressTests", "CommentReviewSnapshotTests"],
    "feedback": ["AuthorFeedbackPolicyTests", "AuthorFeedbackCoordinatorTests", "AuthorFeedbackMergeTests",
                 "ReReviewAssessmentTests", "ReReviewVerifierTests", "VerifiedAuthorFeedbackTests",
                 "ConfirmationQueueTests", "MergeRequestTodoRoutingTests", "DraftProofRecoveryTests",
                 "FollowUpPushPermissionTests", "MRHumanActionTests", "RemoteBoardAdapterTests",
                 "MergeWorkflowExecutionTests", "TodoAutomationTests", "MRNoticeClassifierTests",
                 "FeedbackSuggestionDecisionsTests", "FeedbackSuggestionDecisionActionTests",
                 "CommentReviewSnapshotTests", "AuthoredMergeRequestStatusTests", "GlabMergeRequestAPITests"],
}

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
        if path.endswith(".md") and (path in {"AGENTS.md", "README.md", "CHANGELOG.md"} or path.startswith("docs/")):
            reasons.append(f"{path}: documentation only")
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
            suites.add(Path(path).stem)
            reasons.append(f"{path}: changed suite")
        else:
            matches = [group for pattern, group in RULES if fnmatchcase(path, pattern)]
            if not matches:
                return full_plan(paths, f"{path}: shared or unmapped change; full suite required")
            for group in matches:
                suites.update(GROUPS[group])
            reasons.append(f"{path}: {', '.join(matches)} and their consumers")
    missing = [suite for suite in suites if not (repo / "Tests" / f"{suite}.swift").is_file()]
    if missing:
        return full_plan(paths, f"Selection references missing suites: {', '.join(sorted(missing))}")
    return dict(mode="targeted" if suites else "none", suites=[f"GitLabTodosTests/{suite}" for suite in sorted(suites)],
                tasks=[task for task in TASKS if task in tasks], paths=paths, reasons=reasons)


def plan_changes(repo, base=None):
    try:
        paths, comparison = changed_paths(repo, base)
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
        return full_plan([], f"Cannot determine change set ({error}); full suite required")
    plan = select_paths(repo, paths)
    plan["comparison"] = comparison
    return plan
