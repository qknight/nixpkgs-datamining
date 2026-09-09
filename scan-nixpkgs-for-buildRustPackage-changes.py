#!/usr/bin/env python3

import fcntl
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path


NIXPKGS = Path("/home/nixos/nixpkgs")
START_REV = "095901e7684f435e6a87c27db84f5c56091d6f39"
END_REV = "7624768955f7736c9c10469b11ac181297020746"

SCRIPT_DIR = Path(__file__).resolve().parent
PROBE = SCRIPT_DIR / "rustPlatform.buildRustPackage-probe.nix"
RESULTS = SCRIPT_DIR / "rustPlatform.buildRustPackage-probe-results.txt"

COMMIT_RE = re.compile(r"[0-9a-f]{40}")


class ScanError(RuntimeError):
    pass


@dataclass(frozen=True)
class Commit:
    revision: str
    timestamp: str


@dataclass(frozen=True)
class CheckoutState:
    branch: str | None
    revision: str


def run(command: list[str], cwd: Path, check: bool = True) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        command,
        cwd=cwd,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        rendered = " ".join(command)
        details = result.stderr.strip() or result.stdout.strip() or "no error output"
        raise ScanError(f"command failed ({result.returncode}): {rendered}\n{details}")
    return result


def verify_commit(revision: str) -> str:
    result = run(
        ["git", "rev-parse", "--verify", f"{revision}^{{commit}}"],
        NIXPKGS,
    )
    resolved = result.stdout.strip()
    if not COMMIT_RE.fullmatch(resolved):
        raise ScanError(f"Git returned an invalid commit for {revision!r}: {resolved!r}")
    return resolved


def load_commits(start: str, end: str) -> list[Commit]:
    revision_range = f"{start}^..{end}"
    result = run(
        [
            "git",
            "log",
            "--first-parent",
            "--reverse",
            "--format=%H%x09%cI",
            revision_range,
        ],
        NIXPKGS,
    )

    commits = []
    for line in result.stdout.splitlines():
        try:
            revision, timestamp = line.split("\t", 1)
        except ValueError as error:
            raise ScanError(f"could not parse Git history line: {line!r}") from error
        if not COMMIT_RE.fullmatch(revision):
            raise ScanError(f"invalid commit in Git history: {revision!r}")
        try:
            parsed_timestamp = datetime.fromisoformat(timestamp)
        except ValueError as error:
            raise ScanError(f"invalid commit timestamp for {revision}: {timestamp!r}") from error
        if not (
            parsed_timestamp.year == 2026
        ):
            raise ScanError(
                f"commit {revision} is outside the allowed period (2026): {timestamp}; refusing to scan"
            )
        commits.append(Commit(revision, timestamp))

    if not commits or commits[0].revision != start or commits[-1].revision != end:
        raise ScanError(
            "the start revision is not on the end revision's first-parent history"
        )
    return commits


def get_checkout_state() -> CheckoutState:
    revision = run(["git", "rev-parse", "HEAD"], NIXPKGS).stdout.strip()
    branch_result = run(
        ["git", "symbolic-ref", "--quiet", "--short", "HEAD"],
        NIXPKGS,
        check=False,
    )
    branch = branch_result.stdout.strip() if branch_result.returncode == 0 else None
    return CheckoutState(branch=branch, revision=revision)


def restore_checkout(state: CheckoutState) -> None:
    if state.branch is not None:
        run(["git", "checkout", "--quiet", state.branch], NIXPKGS)
    else:
        run(["git", "checkout", "--quiet", "--detach", state.revision], NIXPKGS)


def validate_environment() -> CheckoutState:
    if not NIXPKGS.is_dir():
        raise ScanError(f"nixpkgs directory does not exist: {NIXPKGS}")
    if not (NIXPKGS / ".git").exists():
        raise ScanError(f"not a Git repository: {NIXPKGS}")
    if not PROBE.is_file():
        raise ScanError(f"probe file does not exist: {PROBE}")
    if shutil.which("git") is None:
        raise ScanError("git is not available in PATH")
    if shutil.which("nix-instantiate") is None:
        raise ScanError("nix-instantiate is not available in PATH")

    status = run(
        ["git", "status", "--porcelain", "--untracked-files=all"],
        NIXPKGS,
    ).stdout
    if status.strip():
        raise ScanError(
            f"nixpkgs worktree is not clean; commit or remove these changes first:\n{status.rstrip()}"
        )
    return get_checkout_state()


def parse_results(
    results_file,
    commits: list[Commit],
) -> tuple[int, str | None]:
    results_file.seek(0)
    lines = results_file.read().splitlines()
    if not lines:
        return 0, None

    indexes = {commit.revision: index for index, commit in enumerate(commits)}
    timestamps = {commit.revision: commit.timestamp for commit in commits}
    previous_index = -1
    previous_drv = None

    for line_number, line in enumerate(lines, start=1):
        fields = line.split(maxsplit=2)
        if len(fields) != 3:
            raise ScanError(f"invalid results line {line_number}: {line!r}")
        timestamp, revision, drv_path = fields
        if not COMMIT_RE.fullmatch(revision) or revision not in indexes:
            raise ScanError(
                f"results line {line_number} contains a commit outside the scan: {revision!r}"
            )
        try:
            parsed_timestamp = datetime.fromisoformat(timestamp)
        except ValueError as error:
            raise ScanError(
                f"results line {line_number} has an invalid timestamp: {timestamp!r}"
            ) from error
        if parsed_timestamp.year != 2025 or timestamp != timestamps[revision]:
            raise ScanError(
                f"results line {line_number} timestamp does not match commit {revision}"
            )
        if not drv_path.startswith("/nix/store/") or not drv_path.endswith(".drv"):
            raise ScanError(
                f"results line {line_number} has an invalid derivation path: {drv_path!r}"
            )

        index = indexes[revision]
        if index <= previous_index:
            raise ScanError(f"results line {line_number} is not in chronological order")
        if line_number == 1 and index != 0:
            raise ScanError("the first results line must contain the configured start revision")
        previous_index = index
        previous_drv = drv_path

    return previous_index + 1, previous_drv


def evaluate_probe() -> str:
    result = run(
        ["nix-instantiate", "--eval", "--strict", str(PROBE)],
        SCRIPT_DIR,
    )
    output = result.stdout.strip()
    try:
        drv_path = json.loads(output)
    except json.JSONDecodeError as error:
        raise ScanError(f"could not parse probe output as a Nix string: {output!r}") from error
    if (
        not isinstance(drv_path, str)
        or not drv_path.startswith("/nix/store/")
        or not drv_path.endswith(".drv")
    ):
        raise ScanError(f"probe returned an invalid derivation path: {drv_path!r}")
    return drv_path


def append_result(results_file, commit: Commit, drv_path: str) -> None:
    results_file.seek(0, os.SEEK_END)
    results_file.write(f"{commit.timestamp} {commit.revision} {drv_path}\n")
    results_file.flush()
    os.fsync(results_file.fileno())


def scan(results_file, commits: list[Commit]) -> None:
    start_index, previous_drv = parse_results(results_file, commits)
    total = len(commits)
    if start_index >= total:
        print("Scan already reached the configured end revision.")
        return

    print(f"Scanning {total - start_index} of {total} first-parent commits")
    for index in range(start_index, total):
        commit = commits[index]
        print(f"[{index + 1}/{total}] {commit.revision}", flush=True)
        run(
            ["git", "checkout", "--quiet", "--detach", commit.revision],
            NIXPKGS,
        )
        drv_path = evaluate_probe()
        if previous_drv is None or drv_path != previous_drv:
            append_result(results_file, commit, drv_path)
            print(f"  buildRustPackage probe changed: {drv_path}", flush=True)
            previous_drv = drv_path


def main() -> int:
    checkout_state = None
    primary_error = None

    try:
        with RESULTS.open("a+", encoding="utf-8") as results_file:
            try:
                fcntl.flock(results_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ScanError(f"another scanner is using {RESULTS}") from error

            checkout_state = validate_environment()
            start = verify_commit(START_REV)
            end = verify_commit(END_REV)
            commits = load_commits(start, end)
            scan(results_file, commits)
    except KeyboardInterrupt:
        primary_error = "interrupted"
    except (OSError, ScanError) as error:
        primary_error = str(error)
    finally:
        if checkout_state is not None:
            try:
                restore_checkout(checkout_state)
            except (OSError, ScanError) as error:
                restoration_error = f"failed to restore nixpkgs checkout: {error}"
                if primary_error is None:
                    primary_error = restoration_error
                else:
                    print(f"ERROR: {restoration_error}", file=sys.stderr)

    if primary_error is not None:
        print(f"ERROR: {primary_error}", file=sys.stderr)
        return 130 if primary_error == "interrupted" else 1
    print(f"Scan complete. Results: {RESULTS}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
