#!/usr/bin/env python3
"""Mirror-copy and archive application for VASP task backups."""
from __future__ import annotations
import os
import shutil
import subprocess
import tarfile
import tempfile
import warnings
from datetime import datetime
from pathlib import Path
from vasp_backup_common import (
    BackupError, atomic_write_json, copy_identity, fingerprint, load_json, now_text,
    scan_task_tree, sha256_file,
)
from vasp_backup_scan import append_index_journal, discover_tasks, load_index, save_index

def internal_root(request: dict) -> Path:
    return Path(request["backup_root"]) / ".vasp_task_backup"

def check_backup_root(request: dict) -> None:
    root = Path(request["backup_root"])
    if not root.is_dir():
        raise BackupError(f"Backup root does not exist: {root}")
    if not os.access(root, os.W_OK | os.X_OK):
        raise BackupError(f"Backup root is not writable by the current user: {root}")

def ensure_backup_root(request: dict) -> None:
    check_backup_root(request)
    root = Path(request["backup_root"])
    for name in ("staging", "versions", "tmp"):
        (internal_root(request) / name).mkdir(parents=True, exist_ok=True)

def looks_like_vasp_task(path: str) -> bool:
    return os.path.isdir(path) and not os.path.islink(path) and all(
        os.path.isfile(os.path.join(path, name)) for name in ("INCAR", "POSCAR")
    )

def assert_destination_owner(request: dict, record: dict, index=None) -> None:
    state = index if index is not None else load_index(request["index_path"])
    for other in state.get("tasks", {}).values():
        if other.get("destination") == record.get("destination") and other.get("server") != record.get("server"):
            raise BackupError(
                f"Destination collision between {other.get('server')}:{other.get('path')} and "
                f"{record.get('server')}:{record.get('path')}: {record.get('destination')}"
            )

def commit_staging(request: dict, record: dict, staging: str) -> str:
    destination = record["destination"]
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    version_path = ""
    if os.path.lexists(destination):
        version_base = internal_root(request) / "versions" / request["server"] / record["key"]
        version_base.mkdir(parents=True, exist_ok=True)
        version_path = str(version_base / datetime.now().strftime("%Y%m%d_%H%M%S_%f"))
        os.replace(destination, version_path)
    try:
        os.replace(staging, destination)
    except Exception:
        if version_path and not os.path.lexists(destination):
            os.replace(version_path, destination)
        raise
    return version_path

def copy_source_to_staging(request: dict, record: dict) -> str:
    staging = tempfile.mkdtemp(prefix=record["key"][:12] + "-", dir=str(internal_root(request) / "staging"))
    try:
        command = ["rsync", "-rlpt", "--delete", record["path"].rstrip("/") + "/", staging.rstrip("/") + "/"]
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode != 0:
            raise BackupError(f"rsync failed for {record['path']}: {result.stderr.strip()}")
        return staging
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise

def verify_staged_copy(record: dict, staging: str) -> None:
    copied_files = scan_task_tree(staging, False, [])
    if copy_identity(record["files"]) != copy_identity(copied_files):
        raise BackupError(f"Staged copy does not match source metadata: {record['path']}")

def current_source_fingerprint(record: dict, deep: bool) -> str:
    files = scan_task_tree(record["path"], deep, record.get("files", []))
    return fingerprint(files, deep)

def create_archive(request: dict, record: dict, archive_path: str, manifest_path: str) -> dict:
    before = current_source_fingerprint(record, request.get("deep_check", False))
    if before != record["fingerprint"]:
        raise BackupError(f"Task changed while preparing backup: {record['path']}")
    archive = Path(archive_path)
    archive.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["tar", "-cf", str(archive), "-C", record["path"], "."],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
    )
    if result.returncode != 0:
        try:
            archive.unlink()
        except FileNotFoundError:
            pass
        raise BackupError(f"tar failed for {record['path']}: {result.stderr.strip()}")
    after = current_source_fingerprint(record, request.get("deep_check", False))
    if after != before:
        archive.unlink(missing_ok=True)
        raise BackupError(f"Task changed while archiving; backup aborted: {record['path']}")
    manifest = dict(record)
    manifest["archive_sha256"] = sha256_file(archive)
    manifest["archive_size"] = archive.stat().st_size
    atomic_write_json(Path(manifest_path), manifest)
    return manifest

def safe_extract(archive_path: str, target: str) -> None:
    target_real = os.path.realpath(target)
    with tarfile.open(archive_path, "r:") as archive:
        for member in archive.getmembers():
            name = member.name.replace("\\", "/")
            normalized = os.path.normpath(name)
            if os.path.isabs(name) or normalized == ".." or normalized.startswith("../"):
                raise BackupError(f"Unsafe tar member: {member.name}")
            if member.isdev() or member.isfifo():
                raise BackupError(f"Unsupported special file in archive: {member.name}")
            if member.islnk():
                link = os.path.normpath(member.linkname.replace("\\", "/"))
                if os.path.isabs(member.linkname) or link == ".." or link.startswith("../"):
                    raise BackupError(f"Unsafe hard link in archive: {member.name}")
            destination = os.path.realpath(os.path.join(target, name))
            if os.path.commonpath([target_real, destination]) != target_real:
                raise BackupError(f"Archive member escapes the staging directory: {member.name}")
            with warnings.catch_warnings():
                warnings.filterwarnings("ignore", message="The default behavior of tarfile extraction", category=RuntimeWarning)
                archive.extract(member, target)

def apply_archive(request: dict, archive_path: str, manifest_path: str) -> dict:
    manifest = load_json(Path(manifest_path), None)
    if not manifest:
        raise BackupError(f"Archive manifest is missing: {manifest_path}")
    if manifest.get("server") != request.get("server"):
        raise BackupError("Archive server does not match backup request")
    assert_destination_owner(request, manifest)
    if sha256_file(Path(archive_path)) != manifest.get("archive_sha256"):
        raise BackupError(f"Archive SHA256 mismatch: {archive_path}")
    staging = tempfile.mkdtemp(prefix=manifest["key"][:12] + "-", dir=str(internal_root(request) / "staging"))
    try:
        safe_extract(str(archive_path), staging)
        verify_staged_copy(manifest, staging)
        version = commit_staging(request, manifest, staging)
        stored = dict(manifest)
        stored.pop("status", None)
        stored["backed_up_at"] = now_text()
        stored["last_version"] = version
        append_index_journal(request["index_path"], stored)
        return {"key": stored["key"], "path": stored["path"], "destination": stored["destination"], "version": version}
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise

def run_local(request: dict) -> dict:
    if request.get("execute"):
        ensure_backup_root(request)
    else:
        check_backup_root(request)
    index = load_index(request["index_path"])
    inventory = discover_tasks(request, index["tasks"])
    report = {
        "status": "PLAN_ONLY" if not request.get("execute") else "COMPLETED",
        "server": request["server"],
        "paths": inventory["paths"],
        "complete_count": len(inventory["complete"]),
        "incomplete_count": inventory["incomplete_count"],
        "counts": inventory["counts"],
        "backed_up": [],
        "adopted": [],
        "repaired": [],
        "errors": [],
        "log_records": [],
        "incomplete_samples": inventory["incomplete_samples"],
    }
    if not request.get("execute"):
        report["actions"] = [
            {"path": item["path"], "status": item["status"], "destination": item["destination"]}
            for item in inventory["complete"] if item["status"] != "unchanged"
        ]
        return report
    successful_paths = []
    for record in inventory["complete"]:
        assert_destination_owner(request, record, index)
        destination = record["destination"]
        destination_identical = False
        if looks_like_vasp_task(destination):
            try:
                destination_files = scan_task_tree(destination, False, [])
                destination_identical = copy_identity(destination_files) == copy_identity(record["files"])
            except OSError:
                destination_identical = False
        if record["status"] == "unchanged" and not destination_identical:
            record["status"] = "changed"
            report["repaired"].append(record["path"])
        untracked_identical = record["status"] == "new" and destination_identical
        if record["status"] == "unchanged" or untracked_identical:
            stored = dict(record)
            stored.pop("status", None)
            stored["backed_up_at"] = now_text()
            index["tasks"][record["key"]] = stored
            append_index_journal(request["index_path"], stored)
            successful_paths.append(record["path"])
            if untracked_identical:
                report["adopted"].append(record["path"])
            continue
        staging = ""
        try:
            staging = copy_source_to_staging(request, record)
            if current_source_fingerprint(record, request.get("deep_check", False)) != record["fingerprint"]:
                raise BackupError(f"Task changed during backup: {record['path']}")
            verify_staged_copy(record, staging)
            version = commit_staging(request, record, staging)
            staging = ""
            stored = dict(record)
            stored.pop("status", None)
            stored["backed_up_at"] = now_text()
            stored["last_version"] = version
            index["tasks"][record["key"]] = stored
            append_index_journal(request["index_path"], stored)
            successful_paths.append(record["path"])
            report["backed_up"].append({"path": record["path"], "destination": destination, "version": version})
        except Exception as exc:
            if staging:
                shutil.rmtree(staging, ignore_errors=True)
            report["errors"].append({"path": record["path"], "error": str(exc)})
            break
    save_index(request["index_path"], index)
    successful = set(successful_paths)
    report["log_records"] = [item for item in inventory["complete"] if item["path"] in successful]
    if report["errors"]:
        report["status"] = "PARTIAL_FAILURE"
    return report
