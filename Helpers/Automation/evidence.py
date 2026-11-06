"""Standalone GitLab evidence helper; reads GitLab and writes local proof only."""

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

# Preserve the existing evidence location so upgrades retain verified draft history.
ROOT = Path.home() / "Library/Application Support/com.vaporpw.GitLabTodos/Codex Desktop Relay"
GLAB_PATH = str(Path.home() / ".local/bin") + ":/opt/homebrew/bin:/usr/local/bin:/opt/local/bin:/usr/bin:/bin"
HOST_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]{0,252}(?::[0-9]{1,5})?")
VERDICTS = ("no_objections", "objections")


def gitlab_get(host, endpoint):
    if not isinstance(host, str) or not HOST_PATTERN.fullmatch(host) or ".." in host:
        raise ValueError("Invalid host")
    if not isinstance(endpoint, str) or not endpoint.startswith("/") or any(ord(c) < 32 for c in endpoint):
        raise ValueError("Invalid GitLab read endpoint")
    executable = shutil.which("glab", path=GLAB_PATH)
    if not executable:
        raise ValueError("MergeTether could not find glab in a standard installation directory")
    environment = {"PATH": GLAB_PATH, "HOME": str(Path.home()), "GLAB_NO_PROMPT": "true"}
    # Claude's sandbox routes network reads through its local proxy. Keep only
    # the explicit transport/config variables; never inherit provider credentials.
    for key in ("GLAB_CONFIG_DIR", "XDG_CONFIG_HOME", "HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "NO_PROXY",
                "https_proxy", "http_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR",
                "NODE_EXTRA_CA_CERTS"):
        if os.environ.get(key): environment[key] = os.environ[key]
    try:
        result = subprocess.run(
            [executable, "api", endpoint, "--hostname", host, "--method", "GET"],
            cwd=Path.home(), env=environment, stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL, timeout=25, check=True,
        )
        if len(result.stdout) > 1_000_000:
            raise ValueError("GitLab response is too large for the automatic reader")
        return json.loads(result.stdout)
    except (subprocess.SubprocessError, OSError, json.JSONDecodeError) as error:
        raise ValueError("Could not read from GitLab using the local glab session") from error


def write_object(path, data):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
        temporary = Path(file.name)
        try:
            json.dump(data, file)
            file.close()
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


class ReviewEvidenceRecorder:
    def __init__(self, root, reader=gitlab_get):
        self.root, self.read = Path(root), reader

    @contextlib.contextmanager
    def exclusive(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        locks = self.root / "follow-up-locks"
        locks.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (locks / "review-evidence.lock").open("a") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            try: yield
            finally: fcntl.flock(lock.fileno(), fcntl.LOCK_UN)

    def record_verdict(self, host, projectID, iid, headSHA, verdict):
        number = re.compile(r"[1-9][0-9]{0,11}")
        if not (isinstance(host, str) and HOST_PATTERN.fullmatch(host) and ".." not in host):
            raise ValueError("Invalid host")
        if not (isinstance(projectID, str) and number.fullmatch(projectID) and isinstance(iid, str) and number.fullmatch(iid)):
            raise ValueError("Invalid merge request")
        if not (isinstance(headSHA, str) and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", headSHA)) or verdict not in VERDICTS:
            raise ValueError("Invalid verdict")
        endpoint = f"/projects/{projectID}/merge_requests/{iid}"

        def check_head():
            request = self.read(host, endpoint)
            if (not isinstance(request, dict) or request.get("sha") != headSHA or request.get("state") != "opened"
                    or request.get("project_id") != int(projectID) or request.get("iid") != int(iid)):
                raise ValueError("The reviewed MR head, state or identity has changed")

        check_head()
        notes = []
        for page in range(1, 101):
            discussions = self.read(host, f"{endpoint}/discussions?per_page=100&page={page}")
            if not isinstance(discussions, list):
                raise ValueError("Could not verify current discussions")
            for discussion in discussions:
                if not isinstance(discussion, dict) or not isinstance(discussion.get("notes"), list):
                    raise ValueError("Incomplete discussion data")
                for note in discussion["notes"]:
                    if not isinstance(note, dict): raise ValueError("Incomplete comment data")
                    if note.get("system") is True: continue
                    author = note.get("author")
                    if (type(note.get("id")) is not int or note["id"] <= 0 or not isinstance(author, dict)
                            or type(author.get("id")) is not int or author["id"] <= 0 or not isinstance(note.get("body"), str)):
                        raise ValueError("Incomplete comment identity or text")
                    notes.append((note["id"], author["id"], hashlib.sha256(note["body"].encode()).hexdigest()))
            if len(discussions) < 100: break
        else:
            raise ValueError("Too many discussions to bind a review safely")
        fingerprint = hashlib.sha256("".join(f"{note}:{author}:{body}\n" for note, author, body in sorted(notes)).encode()).hexdigest()
        check_head()
        with self.exclusive():
            folder = self.root / "verdicts" / host
            folder.mkdir(parents=True, exist_ok=True, mode=0o700)
            write_object(folder / f"{projectID}-{iid}.json", {
                "version": 1, "host": host, "projectID": int(projectID), "iid": int(iid),
                "headSHA": headSHA, "verdict": verdict, "discussionFingerprint": fingerprint,
            })
        return {"recorded": True, "discussionFingerprint": fingerprint}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("record-verdict",))
    parser.add_argument("host")
    parser.add_argument("project_id")
    parser.add_argument("iid")
    parser.add_argument("head_sha")
    parser.add_argument("verdict", choices=VERDICTS)
    args = parser.parse_args()
    try:
        result = ReviewEvidenceRecorder(ROOT).record_verdict(args.host, args.project_id, args.iid, args.head_sha, args.verdict)
        print(json.dumps(result))
    except (ValueError, OSError, KeyError, TypeError) as error:
        parser.exit(1, f"Review evidence could not be recorded: {error}\nNo approval is authorized.\n")


if __name__ == "__main__": main()
