"""Local MCP bridge for MergeTether's durable Codex Desktop queue."""

import base64
import contextlib
import fcntl
import hashlib
from itertools import chain
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from urllib.parse import quote, urlsplit

ROOT = Path.home() / "Library/Application Support/com.vaporpw.GitLabTodos/Codex Desktop Relay"
GLAB_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
VERDICTS = ("no_objections", "objections")
CLAUDE_SESSION = re.compile(r"local_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
HOST_PATTERN = re.compile(r"[A-Za-z0-9.-]{1,253}(:[0-9]{1,5})?")
MR_RESOURCES = ("details", "diffs", "discussions", "notes", "draft_notes", "approval_state", "pipelines")


def mr_status_markdown(report, pending, claimed, language):
    def text(en, pl):
        return pl if language == "pl" else en

    def escape(value):
        value = str(value).replace("\\", "\\\\").replace("\n", " ").replace("\r", " ")
        for char in "|`*_[]":
            value = value.replace(char, "\\" + char)
        return value.replace("<", "&lt;").replace(">", "&gt;")

    statuses = {
        "discussions_not_resolved": text("Open discussions", "Otwarte dyskusje"),
        "blocked": text("Blocked (reason not supplied)", "Zablokowana (brak przyczyny)"),
        "merge_request_blocked": text("Blocked (GitLab)", "Zablokowana (GitLab)"),
        "unchecked": text("Merge checks pending", "Oczekuje na kontrole merge"),
        "checking": text("Merge checks pending", "Oczekuje na kontrole merge"),
        "not_approved": text("Approvals needed", "Brakuje approvali"),
        "need_rebase": text("Rebase needed", "Wymaga rebase"),
        "conflict": text("Merge conflict", "Konflikt merge"),
        "mergeable": text("GitLab merge checks passed", "Kontrole merge GitLaba przeszły"),
        "ci_must_pass": text("CI must pass", "CI musi przejść"),
        "ci_still_running": text("CI running", "CI w toku"),
        "requested_changes": text("Changes requested", "Zażądano zmian"),
    }
    pipelines = {"success": text("Passed", "Przeszedł"), "failed": text("Failed", "Błąd"),
                 "running": text("Running", "W toku"), "pending": text("Pending", "Oczekuje"),
                 "canceled": text("Canceled", "Anulowany"), "skipped": text("Skipped", "Pominięty"),
                 "manual": text("Manual action", "Akcja ręczna")}

    def row_data(entry):
        url = str(entry.get("url", ""))
        try:
            parsed = urlsplit(url)
            parts = parsed.path.split("/")
            repo = parts[parts.index("-") - 1] if "-" in parts else "—"
            valid_url = parsed.scheme in ("http", "https") and bool(parsed.netloc)
        except ValueError:
            repo, valid_url = "—", False
        iid = entry.get("iid")
        label = "!" + (str(iid) if type(iid) is int and iid > 0 else "?")
        link = "[" + label + "](<" + quote(url, safe=":/?#@!$&'+,;=%") + ">)" if valid_url else label
        merge_status = entry.get("mergeStatus") if isinstance(entry.get("mergeStatus"), str) else None
        draft = entry.get("draft") is True or merge_status == "draft_status"
        status = "**DRAFT**" if draft else escape(statuses.get(merge_status, text("Unknown", "Nieznany")))
        if entry.get("openDiscussions") is True or merge_status == "discussions_not_resolved":
            discussion = "**" + text("Open discussions", "Otwarte dyskusje") + "**"
            status = discussion if merge_status == "discussions_not_resolved" and not draft else status + "; " + discussion
        if entry.get("reReviewUnconfirmed") is True:
            status += "; **" + text("Re-review unconfirmed", "Re-review niepotwierdzone") + "**"
        pipeline = entry.get("pipeline") if isinstance(entry.get("pipeline"), str) else None
        ci = escape(pipelines.get(pipeline, pipeline or "—"))
        if pipeline == "failed":
            ci = "**" + ci + "**"
        count = entry.get("unpublishedComments")
        comments = ("**" + str(count) + "**" if count > 0 else "0") if type(count) is int and count >= 0 else "—"
        return repo, draft, iid if type(iid) is int else 0, "| " + " | ".join((escape(repo), link, status, ci, comments)) + " |"

    entries = [entry for entry in report["mergeRequests"] if isinstance(entry, dict)]
    timestamp = escape(report["checkedAt"].replace("T", " ").replace("Z", " UTC"))
    completeness = text("Complete", "Kompletny") if report.get("complete") is True else text("Partial", "Częściowy")
    lines = ["## " + text("MR report", "Raport MR"), "",
             text("Snapshot: ", "Stan na: ") + timestamp + " · " + completeness + " · MR: " + str(len(entries))]
    for role, heading in (("author", text("Own MRs", "Własne MR-y")), ("reviewer", text("For review", "Do review")),
                          ("other", text("Role unknown", "Nieznana rola"))):
        rows = [row_data(entry) for entry in entries
                if (entry.get("role") if entry.get("role") in ("author", "reviewer") else "other") == role]
        if not rows:
            continue
        lines += ["", "### " + heading, "", text("| Repository | MR | Status / blockers | CI | To publish |",
                    "| Repozytorium | MR | Status / blokery | CI | Do publikacji |"), "|---|---|---|---|---|"]
        lines.extend(row[3] for row in sorted(rows, key=lambda row: (row[0].casefold(), row[1], row[2])))
    if not entries:
        lines += ["", text("No open MRs in the snapshot.", "Brak otwartych MR-ów w zestawieniu.")]
    lines += ["", text("**Queue:** ", "**Kolejka:** ") + str(pending) + text(" pending · ", " oczekujących · ")
              + str(claimed) + text(" claimed", " zajętych")]
    return "\n".join(lines)


def gitlab_get(host, endpoint):
    executable = shutil.which("glab", path=GLAB_PATH)
    if not executable:
        raise ValueError("MergeTether could not find glab in a standard installation directory")
    try:
        result = subprocess.run(
            [executable, "api", endpoint, "--hostname", host, "--method", "GET"],
            cwd=Path.home(), env={"PATH": GLAB_PATH, "HOME": str(Path.home()), "GLAB_NO_PROMPT": "true"},
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=25, check=True,
        )
        if len(result.stdout) > 1_000_000:
            raise ValueError("GitLab response is too large for the automatic reader")
        return json.loads(result.stdout)
    except (subprocess.SubprocessError, OSError, json.JSONDecodeError) as error:
        raise ValueError("Could not read from GitLab using the local glab session") from error


def identifier(value):
    try:
        return str(uuid.UUID(value))
    except (ValueError, TypeError, AttributeError):
        raise ValueError("Expected a UUID") from None


def read_object(path):
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def conversation_identity(key):
    # Legacy preparation and current read jobs use the same chat. Keep the
    # original key on claims and receipts to enforce GitLab read permissions.
    try:
        scope = json.loads(base64.b64decode(key, validate=True))
    except (TypeError, ValueError, UnicodeError):
        return ("exact", key)
    if isinstance(scope, dict) and scope.get("assistant") == "codex" and scope.get("access") in ("preparation", "gitLabRead"):
        work = scope.get("work")
        if isinstance(work, dict) and all(field in work for field in ("host", "projectID", "iid")) and "username" in scope:
            return ("codex-mr", work["host"], work["projectID"], work["iid"], scope["username"])
    return ("exact", key)


def repository_section(payload):
    slug = payload.get("repository")
    if isinstance(slug, str) and re.fullmatch(r"[\w][\w.-]{0,254}", slug):
        return f"[MT] {slug}"
    first_line = payload["prompt"].splitlines()[0]
    old_link = re.fullmatch(r"\[Open MR in GitLab\]\(<([^>]+)>\)", first_line)
    try:
        url = urlsplit(old_link[1] if old_link else first_line)
        identity = conversation_identity(payload["conversationKey"])
        if (url.scheme not in ("https", "http") or url.username or url.password or
                identity[0] != "codex-mr" or url.netloc.casefold() != identity[1].casefold()):
            return None
        match = re.search(r"/([\w][\w.-]{0,254})/-/merge_requests/([1-9][0-9]*)$", url.path)
        if match and int(match[2]) == identity[3] and re.search(rf"(?<!\S)!{match[2]}(?!\S)", payload["title"]):
            return f"[MT] {match[1]}"
    except (AttributeError, IndexError, ValueError):
        return None
    return None


def write_object(path, data):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            json.dump(data, file)
            file.close()
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def live_merge_request_state(key):
    identity = conversation_identity(key)
    if len(identity) != 5 or identity[0] != "codex-mr":
        raise ValueError("This job has no verifiable GitLab merge request identity; leave it pending")
    _, host, project_id, iid, username = identity
    if (not isinstance(host, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}(?::[0-9]{1,5})?", host)
            or not isinstance(username, str) or not username
            or not all(type(value) is int and 0 < value <= 9_999_999_999 for value in (project_id, iid))):
        raise ValueError("Invalid GitLab merge request identity; leave the job pending")
    account = gitlab_get(host, "/user")
    if not isinstance(account, dict) or account.get("username") != username:
        raise ValueError("The GitLab login does not match the queued job; leave it pending")
    request = gitlab_get(host, f"/projects/{project_id}/merge_requests/{iid}")
    if (not isinstance(request, dict) or request.get("project_id") != project_id or request.get("iid") != iid
            or request.get("state") not in ("opened", "merged", "closed")):
        raise ValueError("Could not verify the queued MR's current state; leave it pending")
    return request["state"]


class Queue:
    def __init__(self, root):
        self.root = root
        self.jobs = root / "jobs"
        self.claims = root / "claims"
        self.receipts = root / "receipts"
        # Claude jobs are opened by MergeTether itself, so the Codex listener never sees them.
        self.claude_jobs = root / "claude-jobs"
        self.claude_receipts = root / "claude-receipts"

    @contextlib.contextmanager
    def exclusive(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.root / ".plugin.lock").open("a") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            yield

    def receipt(self, job_id):
        return self.receipts / (job_id + ".json")

    def is_skipped(self, job_id, key):
        record = read_object(self.root / "skipped" / (job_id + ".json"))
        return (record.get("version") == 1 and record.get("jobID") == job_id
                and isinstance(key, str) and record.get("conversationKey") == key
                and record.get("state") in ("merged", "closed"))

    def dispatch_template(self):
        record = read_object(self.root / "template.json")
        if type(record.get("version")) is not int or record["version"] != 1:
            return None
        try:
            return identifier(record.get("threadID"))
        except ValueError:
            return None

    def record_dispatch_template(self, thread_id):
        thread_id = identifier(thread_id)
        with self.exclusive():
            path = self.root / "template.json"
            if os.path.lexists(path):
                if self.dispatch_template() == thread_id:
                    return
                raise ValueError("To change or repair template routing, reset template in MergeTether settings first")
            write_object(path, {"version": 1, "threadID": thread_id})

    def status(self):
        pending = claimed = 0
        for job in self.jobs.glob("*.json"):
            if self.receipt(job.stem).exists():
                continue
            if (self.claims / job.stem).is_dir():
                claimed += 1
            elif not self.is_skipped(job.stem, read_object(job).get("conversationKey")):
                pending += 1
        result = {"pending": pending, "claimed": claimed, "validatesOpenMR": True}
        if template := self.dispatch_template():
            result["templateThreadID"] = template
        return result

    def poll(self, report_language="en"):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        write_object(self.root / "heartbeat.json", {"version": 1})
        result = self.status()
        report = read_object(self.root / "mr-status.json")
        if isinstance(report.get("mergeRequests"), list) and isinstance(report.get("checkedAt"), str):
            result["mrStatus"] = report
            result["mrStatusMarkdown"] = mr_status_markdown(report, result["pending"], result["claimed"], report_language)
        return result

    def claim_next(self, allow_merged=False, allow_work_item=False, state_reader=None):
        with self.exclusive():
            candidates = []
            for job in self.jobs.glob("*.json"):
                try:
                    candidates.append((job.stat().st_mtime_ns, job))
                except FileNotFoundError:
                    continue
            for _, job in sorted(candidates):
                payload = read_object(job)
                key = payload.get("conversationKey")
                title = payload.get("title")
                prompt = payload.get("prompt")
                try:
                    job_id = identifier(payload.get("id"))
                except ValueError:
                    continue
                if (job_id != job.stem or payload.get("version") != 1 or
                        not isinstance(key, str) or not key or self.receipt(job_id).exists() or self.is_skipped(job_id, key)):
                    continue
                operation = payload.get("operation")
                target_thread = None
                if operation in ("mark_merged", "mark_merged_with_work_item", "set_stack_position"):
                    if not allow_merged or prompt is not None:
                        continue
                    try:
                        target_thread = identifier(payload.get("threadID"))
                    except ValueError:
                        continue
                    if operation != "set_stack_position" and (target_thread != job_id or key != f"merged:{job_id}"):
                        continue
                    follow_up = payload.get("followUpPrompt")
                    if operation == "mark_merged_with_work_item" and (
                            not allow_work_item or not isinstance(follow_up, str) or not 0 < len(follow_up) <= 6000):
                        continue
                    if operation == "set_stack_position" and (key != f"stack:{target_thread}" or
                            type(payload.get("iid")) is not int or payload["iid"] <= 0 or
                            not valid_stack_position(payload.get("position"))):
                        continue
                    if not self.is_delivered_chat(target_thread, payload.get("iid") if operation == "set_stack_position" else None):
                        continue
                elif (operation is not None or not isinstance(title, str) or not title.startswith("[MT] ") or
                        not isinstance(prompt, str) or not prompt.strip()):
                    continue
                # An ambiguous dispatch blocks more work for this conversation.
                active = False
                identity = conversation_identity(key)
                for claim in self.claims.iterdir():
                    if not claim.is_dir() or self.receipt(claim.name).exists():
                        continue
                    metadata = read_object(claim / "job.json") or read_object(self.jobs / (claim.name + ".json"))
                    if claim.name == job_id or conversation_identity(metadata.get("conversationKey")) == identity:
                        active = True
                        break
                if active:
                    continue
                if state_reader is not None and target_thread is None:
                    state = state_reader(key)
                    if state in ("merged", "closed"):
                        skipped = self.root / "skipped"
                        skipped.mkdir(exist_ok=True, mode=0o700)
                        write_object(skipped / (job_id + ".json"), {
                            "version": 1, "jobID": job_id, "conversationKey": key, "state": state,
                        })
                        continue
                thread = self.find_thread(payload) if payload.get("reuse") is True else None
                claim = self.claims / job_id
                try:
                    claim.mkdir(mode=0o700)
                except FileExistsError:
                    continue
                if not job.exists():
                    claim.rmdir()
                    continue
                metadata = {"conversationKey": key}
                if target_thread:
                    metadata["expectedThreadID"] = target_thread
                    write_object(claim / "job.json", metadata)
                    result = {"id": job_id, "operation": operation, "threadID": target_thread}
                    if operation == "set_stack_position":
                        result.update(iid=payload["iid"], position=payload.get("position"))
                    elif operation == "mark_merged_with_work_item":
                        result["followUpPrompt"] = follow_up
                    return result
                write_object(claim / "job.json", metadata)
                digest = hashlib.sha256(prompt.encode()).hexdigest()
                instructions = claim / "instructions.json"
                workspace = claim / "workspace"
                workspace.mkdir(mode=0o700)
                write_object(instructions, {"version": 1, "jobID": job_id, "title": title,
                                            "prompt": prompt, "promptSHA256": digest,
                                            "workingDirectory": str(workspace)})
                first_line = prompt.splitlines()[0]
                link = first_line if len(first_line) <= 1000 and re.fullmatch(r"https?://[^\s<>]+", first_line) else title
                bootstrap = (
                    f"{link}\n\n{title}\n\n"
                    "Continue this MergeTether task using its complete local instruction snapshot. "
                    f"Read the JSON file {json.dumps(str(instructions), ensure_ascii=False)}. "
                    f"Use workingDirectory {json.dumps(str(workspace), ensure_ascii=False)} for all scratch files and command cwd. "
                    "Leave the template folder untouched. Source edits and their commands must use the isolated worktree required by the full prompt. "
                    f"Verify SHA-256 of the exact UTF-8 prompt field equals {digest}, then follow that full prompt "
                    "with the applicable installed skills and repository instructions. "
                    "Do not substitute a summary or omit its permission, verification or publication rules. "
                    "If the file is missing or the hash differs, stop and report the blocker. "
                    "This task does not authorize changing Codex permission settings."
                )
                result = {"id": job_id, "title": title, "deliveryPrompt": bootstrap, "threadID": thread}
                if thread is None and payload.get("useTemplate") is not False and (template := self.dispatch_template()):
                    result["templateThreadID"] = template
                if thread is None and (section := repository_section(payload)):
                    result["sectionName"] = section
                for field in ("model", "thinking"):
                    if isinstance(payload.get(field), str) and payload[field]:
                        result[field] = payload[field]
                return result
            return None

    def read_merge_request(self, host, projectID, iid, resource, page="1"):
        if (not isinstance(host, str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}(?::[0-9]{1,5})?", host)
                or not all(isinstance(n, str) and re.fullmatch(r"[1-9][0-9]{0,9}", n) for n in (projectID, iid, page))
                or resource not in MR_RESOURCES):
            raise ValueError("Invalid GitLab merge request or resource")
        work = {"host": host, "projectID": int(projectID), "iid": int(iid)}
        paths = (list(self.receipts.glob("*.json")) + list(self.claims.glob("*/job.json"))
                 + list(self.claude_receipts.glob("*.json")) + list(self.claude_jobs.glob("*.json")))
        usernames = set()
        for path in paths:
            key = read_object(path).get("conversationKey")
            if not isinstance(key, str):
                continue
            try:
                scope = json.loads(base64.b64decode(key, validate=True))
            except (ValueError, UnicodeError):
                continue
            if (isinstance(scope, dict) and scope.get("assistant") in ("codex", "claude") and scope.get("access") == "gitLabRead"
                    and scope.get("work") == work and isinstance(scope.get("username"), str)):
                usernames.add(scope["username"])
        if not usernames:
            raise ValueError("This merge request was not dispatched with GitLab read access")
        user = gitlab_get(host, "/user")
        if not isinstance(user, dict) or user.get("username") not in usernames:
            raise ValueError("The GitLab login does not match the dispatched request")
        endpoint = f"/projects/{projectID}/merge_requests/{iid}"
        paged = resource not in ("details", "approval_state")
        if resource != "details":
            endpoint += "/" + resource
        if paged:
            endpoint += f"?per_page=20&page={page}"
        data = gitlab_get(host, endpoint)
        result = {"data": data, "nextPage": str(int(page) + 1) if paged and isinstance(data, list) and len(data) == 20 else None}
        if resource in ("notes", "discussions"):
            notes = data if resource == "notes" else list(chain.from_iterable(d.get("notes", []) for d in data if isinstance(d, dict)))
            result["sourceCommentHashes"] = {}
            for note in notes:
                if not isinstance(note, dict) or type(note.get("id")) is not int or not isinstance(note.get("body"), str):
                    continue
                try:
                    digest = hashlib.sha256(note["body"].encode("utf-8")).hexdigest()
                except UnicodeEncodeError:
                    continue  # Preserve readable data but never authorize publication from a lossy hash.
                result["sourceCommentHashes"][str(note["id"])] = digest
        return result

    def find_thread(self, payload):
        try:
            return identifier(payload.get("threadID"))
        except ValueError:
            pass
        identity = conversation_identity(payload["conversationKey"])
        latest = None
        for path in self.receipts.glob("*.json"):
            receipt = read_object(path)
            if conversation_identity(receipt.get("conversationKey")) != identity:
                continue
            try:
                candidate = (path.stat().st_mtime_ns, identifier(receipt.get("threadID")))
            except (FileNotFoundError, ValueError):
                continue
            latest = candidate if latest is None else max(latest, candidate)
        return latest[1] if latest else None

    def is_delivered_chat(self, thread_id, iid=None):
        links = self.root / "linked-chats"
        for path in chain(self.receipts.glob("*.json"), (links / (thread_id + ".json"),)):
            receipt = read_object(path)
            if receipt.get("version") != 1 or receipt.get("threadID") != thread_id:
                continue
            key = receipt.get("conversationKey")
            try:
                scope = json.loads(base64.b64decode(key, validate=True))
            except (TypeError, ValueError, UnicodeError):
                continue
            if (isinstance(scope, dict) and scope.get("assistant") == "codex" and isinstance(scope.get("work"), dict)
                    and (iid is None or scope["work"].get("iid") == iid)):
                return True
        return False

    def record_claude_session(self, job_id, session_id):
        job_id = identifier(job_id)
        if not (isinstance(session_id, str) and CLAUDE_SESSION.fullmatch(session_id)):
            raise ValueError("Expected this Claude session's local_ ID")
        with self.exclusive():
            payload = read_object(self.claude_jobs / (job_id + ".json"))
            key = payload.get("conversationKey")
            try:
                scope = json.loads(base64.b64decode(key, validate=True))
            except (TypeError, ValueError, UnicodeError):
                scope = None
            if payload.get("version") != 1 or str(payload.get("id", "")).lower() != job_id or \
                    not isinstance(scope, dict) or scope.get("assistant") != "claude":
                raise ValueError("Unknown MergeTether Claude job")
            receipt = self.claude_receipts / (job_id + ".json")
            existing = read_object(receipt)
            if existing and existing.get("threadID") != session_id:
                raise ValueError("This job is already linked to another session")
            self.claude_receipts.mkdir(parents=True, exist_ok=True, mode=0o700)
            write_object(receipt, {"version": 1, "jobID": job_id, "threadID": session_id, "conversationKey": key})

    def record_ai_assessment(self, host, projectID, iid, noteID, bodySHA256, confidence, evidence):
        number = re.compile(r"[1-9][0-9]{0,11}")
        if not isinstance(host, str) or not HOST_PATTERN.fullmatch(host) or ".." in host:
            raise ValueError("Invalid host")
        if not all(isinstance(v, str) and number.fullmatch(v) for v in (projectID, iid, noteID)):
            raise ValueError("Invalid comment")
        if confidence != "very_high" or not isinstance(bodySHA256, str) or not re.fullmatch(r"[0-9a-f]{64}", bodySHA256):
            raise ValueError("Only very-high-confidence assessments with exact comment text can be recorded")
        if not isinstance(evidence, str) or not evidence.strip() or len(evidence) > 2000:
            raise ValueError("Concrete evidence is required")
        with self.exclusive():
            folder = self.root / "ai-assessments" / host
            folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            write_object(folder / f"{projectID}-{iid}-{noteID}.json", {
                "version": 1, "host": host, "projectID": int(projectID), "iid": int(iid), "noteID": int(noteID),
                "bodySHA256": bodySHA256,
                "confidence": confidence, "evidence": evidence,
            })

    def author_follow_up_status(self, host, projectID, iid, runID):
        try:
            from author_follow_up import AuthorFollowUpVerifier
            return AuthorFollowUpVerifier(self.root, gitlab_get).status(host, projectID, iid, runID)
        except (ImportError, KeyError, TypeError, AttributeError, UnicodeError) as error:
            raise ValueError("Could not confirm current follow-up permission") from error

    def verify_author_follow_up(self, host, projectID, iid, runID, headSHA, filesJSON):
        try:
            from author_follow_up import AuthorFollowUpVerifier
            return AuthorFollowUpVerifier(self.root, gitlab_get).verify(host, projectID, iid, runID, headSHA, filesJSON)
        except (ImportError, KeyError, TypeError, AttributeError, UnicodeError) as error:
            raise ValueError("Could not verify the author follow-up; check the plugin installation and GitLab response") from error

    def record_author_follow_up_drafts(self, host, projectID, iid, verificationID, draftIDsJSON):
        try:
            from author_follow_up import AuthorFollowUpVerifier
            return AuthorFollowUpVerifier(self.root, gitlab_get).seal(host, projectID, iid, verificationID, draftIDsJSON)
        except (ImportError, KeyError, TypeError, AttributeError, UnicodeError) as error:
            raise ValueError("Could not seal author replies; no publication is authorized") from error

    def record_verdict(self, host, projectID, iid, headSHA, verdict):
        number = re.compile(r"[1-9][0-9]{0,11}")
        if not (isinstance(host, str) and HOST_PATTERN.fullmatch(host) and ".." not in host):
            raise ValueError("Invalid host")
        if not (isinstance(projectID, str) and number.fullmatch(projectID) and isinstance(iid, str) and number.fullmatch(iid)):
            raise ValueError("Invalid merge request")
        if not (isinstance(headSHA, str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", headSHA)) or verdict not in VERDICTS:
            raise ValueError("Invalid verdict")
        endpoint = f"/projects/{projectID}/merge_requests/{iid}"
        if gitlab_get(host, endpoint).get("sha") != headSHA:
            raise ValueError("The reviewed MR head has changed")
        notes = []
        for page in range(1, 101):
            discussions = gitlab_get(host, f"{endpoint}/discussions?per_page=100&page={page}")
            if not isinstance(discussions, list):
                raise ValueError("Could not verify current discussions")
            for discussion in discussions:
                if not isinstance(discussion, dict) or not isinstance(discussion.get("notes"), list):
                    raise ValueError("Incomplete discussion data")
                for note in discussion["notes"]:
                    if not isinstance(note, dict):
                        raise ValueError("Incomplete comment data")
                    if note.get("system") is True:
                        continue
                    author = note.get("author")
                    if not isinstance(note.get("id"), int) or note["id"] <= 0 or not isinstance(author, dict) \
                            or not isinstance(author.get("id"), int) or author["id"] <= 0 or not isinstance(note.get("body"), str):
                        raise ValueError("Incomplete comment identity or text")
                    notes.append((note["id"], author["id"], hashlib.sha256(note["body"].encode()).hexdigest()))
            if len(discussions) < 100:
                break
        else:
            raise ValueError("Too many discussions to bind a review safely")
        fingerprint = hashlib.sha256("".join(f"{note}:{author}:{body}\n" for note, author, body in sorted(notes)).encode()).hexdigest()
        if gitlab_get(host, endpoint).get("sha") != headSHA:
            raise ValueError("The reviewed MR head has changed")
        with self.exclusive():
            folder = self.root / "verdicts" / host
            folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            write_object(folder / f"{projectID}-{iid}.json", {
                "version": 1, "host": host, "projectID": int(projectID), "iid": int(iid),
                "headSHA": headSHA, "verdict": verdict, "discussionFingerprint": fingerprint,
            })
        return {"recorded": True, "discussionFingerprint": fingerprint}

    def record(self, job_id, thread_id):
        job_id, thread_id = identifier(job_id), identifier(thread_id)
        with self.exclusive():
            path = self.receipt(job_id)
            if path.exists():
                if identifier(read_object(path).get("threadID")) != thread_id:
                    raise ValueError("This job already has a different receipt")
                return
            metadata = read_object(self.claims / job_id / "job.json")
            if not metadata.get("conversationKey"):
                raise ValueError("This job was not claimed by the plugin")
            if metadata.get("expectedThreadID", thread_id) != thread_id:
                raise ValueError("This title update belongs to a different chat")
            write_object(path, {
                "version": 1, "jobID": job_id, "threadID": thread_id,
                "conversationKey": metadata["conversationKey"],
            })


def valid_stack_position(position):
    if position is None:
        return True
    if not isinstance(position, str) or not re.fullmatch(r"[1-9][0-9]{0,5}/[1-9][0-9]{0,5}", position):
        return False
    index, total = map(int, position.split("/"))
    return 1 <= index <= total and total > 1


def tool(name, description, fields=()):
    return {"name": name, "description": description,
            "inputSchema": {"type": "object", "properties": {f: {"type": "string"} for f in fields},
                            "required": list(fields), "additionalProperties": False}}


TOOLS = [
    tool("queue_status", "Count pending and claimed MergeTether jobs without reading their prompts."),
    tool("poll", "Check the queue, record a listener heartbeat, and return the latest open MR status report. Only use in the scheduled dispatch."),
    tool("claim_next", "Claim at most one queued job after live account/MR GET checks. Skip merged/closed MR work without delivery; errors leave it pending. Existing-chat title jobs remain supported."),
    tool("record_dispatch", "Record confirmed native delivery. Never call after an uncertain result.",
         ("jobID", "threadID")),
    tool("record_dispatch_template", "Record the UUID of an explicitly configured native Codex template chat for new-chat routing. "
         "Registration is write-once; changing or repairing it requires resetting the template in MergeTether settings first. "
         "This stores a routing preference only and does not change or verify Codex permissions.", ("threadID",)),
    tool("record_claude_session",
         "Link this Claude Code session to the MergeTether job named in its first message, so later events for the "
         "same merge request continue here. Pass this session's local_ ID.",
         ("jobID", "sessionID")),
    tool("record_ai_comment_assessment",
         "Record very-high-confidence AI authorship of a source comment, including comments posted by humans. "
         "Supply bodySHA256 from read_merge_request sourceCommentHashes (or hash the exact glab JSON body), and concrete evidence; style alone is insufficient. This tool does not publish anything.",
         ("host", "projectID", "iid", "noteID", "bodySHA256", "confidence", "evidence")),
    tool("author_follow_up_status",
         "Author worker only: check current run permission and source branch before editing and immediately before a push. If disabled or superseded, stop with a chat-only report. Reads only.",
         ("host", "projectID", "iid", "runID")),
    tool("verify_author_follow_up",
         "Author worker only, not the dispatcher. Before saving fix replies, verify the tested/pushed MR HEAD and SHA256 of its remote source/test files. Reads GitLab only. Returns a one-use verificationID; fails when follow-up push is off or code is absent remotely.",
         ("host", "projectID", "iid", "runID", "headSHA", "filesJSON")),
    tool("record_author_follow_up_drafts",
         "Author worker only. After remote verification and saving/re-reading new or refreshed private drafts, bind their exact IDs/bodies to the verified run and head. Unchanged legacy/user-created drafts cannot be adopted. Never publishes anything.",
         ("host", "projectID", "iid", "verificationID", "draftIDsJSON")),
    tool("record_review_verdict",
         "Record your finished review verdict for one MR head: no_objections when you have no open findings, "
         "otherwise objections. MergeTether approves only after no_objections for the current head once every "
         "discussion is resolved.",
         ("host", "projectID", "iid", "headSHA", "verdict")),
]
claim_tool = next(item for item in TOOLS if item["name"] == "claim_next")
poll_tool = next(item for item in TOOLS if item["name"] == "poll")
poll_tool["inputSchema"]["properties"]["reportLanguage"] = {"type": "string", "enum": ["en", "pl"]}
claim_tool["inputSchema"]["properties"]["allowMerged"] = {
    "type": "boolean",
    "description": "Allow title-only updates if the current chat has native read_thread and set_thread_title tools.",
}
claim_tool["inputSchema"]["properties"]["allowWorkItem"] = {
    "type": "boolean",
    "description": "Allow merged-title jobs that send a read-only work item proposal request to the confirmed chat.",
}
read_tool = tool("read_merge_request",
                 "Read a dispatched GitLab MR using glab. Resources: " + ", ".join(MR_RESOURCES)
                 + ". Use nextPage to continue list results. This tool only performs GET requests.",
                 ("host", "projectID", "iid", "resource", "page"))
read_tool["inputSchema"]["required"].remove("page")
TOOLS.append(read_tool)


def handle(request, queue):
    method, params = request.get("method"), request.get("params") or {}
    if method == "initialize":
        version = params.get("protocolVersion")
        supported = {"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"}
        return {"protocolVersion": version if version in supported else "2025-06-18",
                "capabilities": {"tools": {}}, "serverInfo": {"name": "merge-tether", "version": "0.1.0"}}
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": TOOLS}
    if method != "tools/call":
        raise LookupError
    name, args = params.get("name"), params.get("arguments") or {}
    is_error = False
    try:
        if name == "queue_status" and not args:
            output = queue.status()
        elif name == "poll" and set(args) <= {"reportLanguage"} and args.get("reportLanguage", "en") in ("en", "pl"):
            output = queue.poll(report_language=args.get("reportLanguage", "en"))
        elif name == "claim_next" and set(args) <= {"allowMerged", "allowWorkItem"} and all(type(v) is bool for v in args.values()):
            output = {"job": queue.claim_next(allow_merged=args.get("allowMerged", False),
                                              allow_work_item=args.get("allowWorkItem", False), state_reader=live_merge_request_state)}
        elif name == "record_claude_session" and set(args) == {"jobID", "sessionID"}:
            queue.record_claude_session(args["jobID"], args["sessionID"])
            output = {"recorded": True}
        elif name == "record_ai_comment_assessment" and set(args) == {"host", "projectID", "iid", "noteID", "bodySHA256", "confidence", "evidence"}:
            queue.record_ai_assessment(**args)
            output = {"recorded": True}
        elif name == "author_follow_up_status" and set(args) == {"host", "projectID", "iid", "runID"}:
            output = queue.author_follow_up_status(**args)
        elif name == "verify_author_follow_up" and set(args) == {"host", "projectID", "iid", "runID", "headSHA", "filesJSON"}:
            output = queue.verify_author_follow_up(**args)
        elif name == "record_author_follow_up_drafts" and set(args) == {"host", "projectID", "iid", "verificationID", "draftIDsJSON"}:
            output = queue.record_author_follow_up_drafts(**args)
        elif name == "record_review_verdict" and set(args) == {"host", "projectID", "iid", "headSHA", "verdict"}:
            output = queue.record_verdict(**args)
        elif name == "record_dispatch" and set(args) == {"jobID", "threadID"}:
            queue.record(args["jobID"], args["threadID"])
            output = {"recorded": True}
        elif name == "record_dispatch_template" and set(args) == {"threadID"}:
            queue.record_dispatch_template(args["threadID"])
            output = {"recorded": True}
        elif name == "read_merge_request" and set(args) in (
            {"host", "projectID", "iid", "resource"}, {"host", "projectID", "iid", "resource", "page"}
        ):
            output = queue.read_merge_request(**args)
        else:
            raise ValueError("Unknown tool or invalid arguments")
    except ValueError as error:
        is_error, output = True, {"error": str(error)}
    except OSError:
        is_error, output = True, {"error": "Could not access the local MergeTether queue"}
    return {"content": [{"type": "text", "text": json.dumps(output)}], "isError": is_error}


def serve():
    queue = Queue(ROOT)
    for line in sys.stdin:
        try:
            request = json.loads(line)
        except ValueError:
            continue
        if not isinstance(request, dict) or "id" not in request:
            continue
        reply = {"jsonrpc": "2.0", "id": request["id"]}
        try:
            reply["result"] = handle(request, queue)
        except LookupError:
            reply["error"] = {"code": -32601, "message": "Method not found"}
        except (AttributeError, TypeError):
            reply["error"] = {"code": -32602, "message": "Invalid parameters"}
        print(json.dumps(reply), flush=True)


if __name__ == "__main__":
    if len(sys.argv) == 7 and sys.argv[1] == "record-verdict":
        try:
            Queue(ROOT).record_verdict(*sys.argv[2:])
            print(json.dumps({"recorded": True}))
        except (ValueError, OSError) as error:
            print(json.dumps({"recorded": False, "error": str(error)}))
            sys.exit(1)
    elif len(sys.argv) == 1:
        serve()
    else:
        sys.exit("Usage: relay.py [record-verdict HOST PROJECT_ID IID HEAD_SHA no_objections|objections]")
