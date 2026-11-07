"""Read-only remote verification for author follow-ups; never pushes or publishes."""
import argparse
import contextlib
import fcntl
import base64
import hashlib
import json
from pathlib import Path
import re
import tempfile
import os
import uuid
from urllib.parse import quote


def digest(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            json.dump(value, file)
            file.close()
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def load(path):
    if path.stat().st_size > 1000000:
        raise ValueError("Verification record is too large")
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("Invalid verification record")
    return value


class AuthorFollowUpVerifier:
    def __init__(self, root, reader):
        self.root, self.read = Path(root), reader

    @contextlib.contextmanager
    def local_lock(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        locks = self.root / "follow-up-locks"
        locks.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (locks / "state.lock").open("a+") as file:
            fcntl.flock(file.fileno(), fcntl.LOCK_EX)
            try: yield
            finally: fcntl.flock(file.fileno(), fcntl.LOCK_UN)

    def context(self, host, projectID, iid, runID=None):
        if not isinstance(host, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}(?::[0-9]{1,5})?", host) or ".." in host:
            raise ValueError("Invalid host")
        if not all(isinstance(x, str) and re.fullmatch(r"[1-9][0-9]{0,11}", x) for x in (projectID, iid)):
            raise ValueError("Invalid merge request")
        user = self.read(host, "/user")
        username = user.get("username")
        if not isinstance(username, str) or not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,254}", username) or ".." in username:
            raise ValueError("Invalid authenticated username")
        key = f"{projectID}-{iid}-{username}.json"
        run = load(self.root / "follow-up-runs" / host / key)
        if (run.get("version") != 1 or run.get("kind") != "author_follow_up" or run.get("pushAllowed") is not True or
                run.get("host") != host or run.get("projectID") != int(projectID) or run.get("iid") != int(iid) or
                run.get("username") != username or (runID is not None and run.get("runID", "").lower() != str(uuid.UUID(runID)))):
            raise ValueError("This author follow-up run is not authorized to push")
        mr = self.read(host, f"/projects/{projectID}/merge_requests/{iid}")
        if (mr.get("project_id") != int(projectID) or mr.get("iid") != int(iid) or mr.get("state") != "opened" or
                mr.get("author", {}).get("id") != user.get("id") or type(user.get("id")) is not int or
                type(mr.get("source_project_id")) is not int or not mr.get("source_branch")):
            raise ValueError("The open MR must belong to the authenticated user")
        return user, run, mr, key

    def drafts(self, host, projectID, iid, userID):
        result = []
        for page in range(1, 101):
            batch = self.read(host, f"/projects/{projectID}/merge_requests/{iid}/draft_notes?per_page=100&page={page}")
            if not isinstance(batch, list): raise ValueError("Invalid draft response")
            result.extend(d for d in batch if d.get("author_id") == userID)
            if len(batch) < 100: return result
        raise ValueError("Too many draft pages to verify safely")

    def status(self, host, projectID, iid, runID):
        _, run, mr, _ = self.context(host, projectID, iid, runID)
        return {"pushAllowed": True, "runID": run["runID"], "headSHA": mr["sha"],
                "discussionFingerprint": self.discussion_fingerprint(host, projectID, iid),
                "sourceProjectID": mr["source_project_id"], "sourceBranch": mr["source_branch"]}

    def discussion_fingerprint(self, host, projectID, iid):
        # Match ReviewVerdict.fingerprint: resolution flags and system events are irrelevant.
        notes = []
        for page in range(1, 101):
            batch = self.read(host, f"/projects/{projectID}/merge_requests/{iid}/discussions?per_page=100&page={page}")
            if not isinstance(batch, list): raise ValueError("Invalid discussion response")
            for discussion in batch:
                if not isinstance(discussion, dict) or not isinstance(discussion.get("notes"), list):
                    raise ValueError("Incomplete discussion data")
                for note in discussion["notes"]:
                    if not isinstance(note, dict): raise ValueError("Incomplete comment data")
                    if note.get("system") is True: continue
                    author = note.get("author")
                    if (type(note.get("id")) is not int or note["id"] <= 0 or not isinstance(author, dict) or
                            type(author.get("id")) is not int or author["id"] <= 0 or not isinstance(note.get("body"), str)):
                        raise ValueError("Incomplete comment identity or text")
                    notes.append((note["id"], author["id"], digest(note["body"])))
            if len(batch) < 100:
                return digest("".join(f"{note}:{author}:{body}\n" for note, author, body in sorted(notes)))
        raise ValueError("Too many discussions to verify safely")

    def verify(self, host, projectID, iid, runID, headSHA, filesJSON):
        if not isinstance(headSHA, str) or not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", headSHA):
            raise ValueError("Expected the exact tested commit SHA")
        if not isinstance(filesJSON, str) or len(filesJSON) > 50000: raise ValueError("Invalid file evidence")
        evidence = json.loads(filesJSON)
        if (not isinstance(evidence, dict) or not isinstance(evidence.get("discussionFingerprint"), str) or
                not re.fullmatch(r"[0-9a-f]{64}", evidence["discussionFingerprint"])):
            raise ValueError("Supply the discussionFingerprint you assessed and a files array")
        files = evidence.get("files")
        if not isinstance(files, list) or not 1 <= len(files) <= 20: raise ValueError("Supply 1–20 verified source/test files")
        user, run, mr, key = self.context(host, projectID, iid, runID)
        if mr.get("sha") != headSHA: raise ValueError("The tested local commit is not the remote MR HEAD")
        source = mr["source_project_id"]
        branch = self.read(host, f"/projects/{source}/repository/branches/{quote(mr['source_branch'], safe='')}")
        if branch.get("commit", {}).get("id") != headSHA: raise ValueError("Source branch HEAD changed")
        paths = set()
        for file in files:
            if not isinstance(file, dict): raise ValueError("Invalid file evidence")
            path, checksum = file.get("path"), file.get("sha256")
            if (not isinstance(path, str) or not path or len(path) > 2048 or path.startswith("/") or
                    any(part in ("", ".", "..") for part in path.split("/")) or any(ord(c) < 32 for c in path) or
                    not isinstance(checksum, str) or not re.fullmatch(r"[0-9a-f]{64}", checksum) or path in paths):
                raise ValueError("Invalid source file evidence")
            paths.add(path)
            remote = self.read(host, f"/projects/{source}/repository/files/{quote(path, safe='')}?ref={headSHA}")
            if remote.get("encoding") != "base64" or remote.get("file_path") != path:
                raise ValueError("GitLab returned a different source file")
            content = base64.b64decode(re.sub(r"\s", "", remote["content"]), validate=True)
            if hashlib.sha256(content).hexdigest() != checksum:
                raise ValueError("The claimed fix is absent from the remote source file")
        before = self.drafts(host, projectID, iid, user["id"])
        fingerprint = self.discussion_fingerprint(host, projectID, iid)
        if fingerprint != evidence["discussionFingerprint"]:
            raise ValueError("Discussion content changed since your assessment; re-read all feedback before verifying")
        _, current_run, current_mr, _ = self.context(host, projectID, iid, runID)
        if current_run != run or current_mr.get("sha") != headSHA or current_mr.get("source_project_id") != source or current_mr.get("source_branch") != mr["source_branch"]:
            raise ValueError("Follow-up context changed during verification")
        # Re-verification may retain exact drafts already sealed by this same run/account.
        try:
            prior = load(self.root / "follow-up-verifications" / host / key)
        except (OSError, ValueError):
            prior = {}
        same_run = (prior.get("sealed") is True and prior.get("runID") == run["runID"] and
                    prior.get("host") == host and prior.get("projectID") == int(projectID) and prior.get("iid") == int(iid) and
                    prior.get("username") == user["username"] and prior.get("userID") == user["id"])
        previously_sealed = {d["id"]: d["bodySHA256"] for d in prior.get("drafts", [])} if same_run else {}
        proof = {"version": 1, "sealed": False, "verificationID": str(uuid.uuid4()), "runID": run["runID"],
                 "host": host, "projectID": int(projectID), "iid": int(iid), "username": user["username"], "userID": user["id"],
                 "headSHA": headSHA, "sourceProjectID": source, "sourceBranch": mr["source_branch"], "files": files,
                 "discussionFingerprint": fingerprint,
                 "baselineDrafts": [{"id": d["id"], "bodySHA256": digest(d["note"])} for d in before
                                    if previously_sealed.get(d["id"]) != digest(d["note"])]}
        with self.local_lock():
            save(self.root / "follow-up-preflight" / host / key, proof)
        return {"verificationID": proof["verificationID"], "headSHA": headSHA, "verified": True}

    def archive_receipt(self, receipt, host, key):
        identity = str(uuid.UUID(receipt["verificationID"]))
        path = self.root / "follow-up-verifications-archive" / host / Path(key).stem / (identity + ".json")
        if path.exists() and load(path) != receipt:
            raise ValueError("A different sealed proof already uses this verification identity")
        save(path, receipt)

    def seal(self, host, projectID, iid, verificationID, draftIDsJSON):
        verificationID = str(uuid.UUID(verificationID))
        user, run, mr, key = self.context(host, projectID, iid)
        proof = load(self.root / "follow-up-preflight" / host / key)
        if (proof.get("verificationID") != verificationID or proof.get("runID") != run["runID"] or
                proof.get("userID") != user["id"] or proof.get("username") != user["username"] or proof.get("host") != host or
                proof.get("projectID") != int(projectID) or proof.get("iid") != int(iid) or proof.get("headSHA") != mr.get("sha") or
                proof.get("sourceProjectID") != mr.get("source_project_id") or proof.get("sourceBranch") != mr.get("source_branch")):
            raise ValueError("Remote head or follow-up run changed; verify again before drafting")
        ids = json.loads(draftIDsJSON)
        if not isinstance(ids, list) or not 1 <= len(ids) <= 100 or any(type(i) is not int or i <= 0 for i in ids) or len(set(ids)) != len(ids):
            raise ValueError("Supply the exact new or refreshed draft IDs")
        drafts = {d["id"]: d for d in self.drafts(host, projectID, iid, user["id"])}
        baseline = {d["id"]: d["bodySHA256"] for d in proof["baselineDrafts"]}
        sealed = []
        for draftID in ids:
            if draftID not in drafts: raise ValueError("A draft is missing or belongs to another account")
            checksum = digest(drafts[draftID]["note"])
            if baseline.get(draftID) == checksum:
                raise ValueError("Legacy or user-created drafts cannot be automatically adopted; verify and refresh claims after remote proof")
            sealed.append({"id": draftID, "bodySHA256": checksum})
        if self.discussion_fingerprint(host, projectID, iid) != proof.get("discussionFingerprint"):
            raise ValueError("Discussion content changed; re-read all feedback, retain the new status fingerprint, verify again, then edit or recreate every unsealed draft from this attempt before sealing")
        _, live_run, live_mr, _ = self.context(host, projectID, iid, run["runID"])
        if live_run != run or live_mr.get("sha") != proof["headSHA"]:
            raise ValueError("Context changed while sealing drafts")
        receipt = {k: v for k, v in proof.items() if k != "baselineDrafts"}
        receipt.update(sealed=True, drafts=sealed)
        with self.local_lock():
            pending = self.root / "follow-up-preflight" / host / key
            if load(pending).get("verificationID") != verificationID:
                raise ValueError("Remote verification was superseded")
            latest = self.root / "follow-up-verifications" / host / key
            try:
                prior = load(latest)
                uuid.UUID(prior.get("verificationID", ""))
                uuid.UUID(prior.get("runID", ""))
            except (OSError, ValueError, TypeError, AttributeError):
                prior = {}
            if (prior.get("version") == 1 and prior.get("sealed") is True and
                    prior.get("host") == host and prior.get("projectID") == int(projectID) and
                    prior.get("iid") == int(iid) and prior.get("username") == user["username"] and
                    prior.get("userID") == user["id"]):
                self.archive_receipt(prior, host, key)
            # Preserve each proof's own run, files and discussion binding before advancing latest.
            self.archive_receipt(receipt, host, key)
            save(latest, receipt)
            pending.unlink()
        return receipt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "verify", "seal"))
    parser.add_argument("--host", required=True)
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--iid", required=True)
    parser.add_argument("--run-id")
    parser.add_argument("--head-sha")
    parser.add_argument("--evidence-file", type=Path,
                        help="JSON object {discussionFingerprint,files:[{path,sha256}]} for the discussion snapshot you assessed")
    parser.add_argument("--verification-id")
    parser.add_argument("--draft-ids", help="JSON array, e.g. [12,13]")
    args = parser.parse_args()
    from evidence import ROOT, gitlab_get
    verifier = AuthorFollowUpVerifier(ROOT, gitlab_get)
    try:
        if args.action == "status":
            if not args.run_id: parser.error("status requires --run-id")
            result = verifier.status(args.host, args.project_id, args.iid, args.run_id)
        elif args.action == "verify":
            if not args.run_id or not args.head_sha or not args.evidence_file: parser.error("verify requires --run-id, --head-sha and --evidence-file")
            if args.evidence_file.stat().st_size > 50000: raise ValueError("Evidence file is too large")
            result = verifier.verify(args.host, args.project_id, args.iid, args.run_id, args.head_sha, args.evidence_file.read_text())
        else:
            if not args.verification_id or not args.draft_ids: parser.error("seal requires --verification-id and --draft-ids")
            result = verifier.seal(args.host, args.project_id, args.iid, args.verification_id, args.draft_ids)
        print(json.dumps(result))
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f"Remote follow-up verification failed: {error}\nNo publication is authorized.\n")


if __name__ == "__main__": main()
