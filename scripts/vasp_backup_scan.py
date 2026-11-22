#!/usr/bin/env python3
"""Task discovery and incremental state for VASP backups."""
from __future__ import annotations
import json
import os
from pathlib import Path
from vasp_backup_common import (
    INDEX_VERSION, BackupError, atomic_write_json, collect_metadata, copy_identity,
    destination_for, fingerprint, incomplete_reason, load_json, normalize_source,
    scan_task_tree, task_key,
)

def discover_tasks(request: dict, index_tasks: dict):
    paths = [normalize_source(item) for item in request.get("paths", [])]
    complete = []
    incomplete = []
    incomplete_total = 0
    seen = set()
    for root in paths:
        for current, dirnames, filenames in os.walk(root, topdown=True, followlinks=False):
            dirnames.sort()
            dirnames[:] = [name for name in dirnames if not (Path(current) / name).is_symlink()]
            if not {"INCAR", "POSCAR"}.issubset(filenames) or current in seen:
                continue
            seen.add(current)
            reason = incomplete_reason(current)
            if reason:
                incomplete_total += 1
                if len(incomplete) < 200:
                    incomplete.append({"path": current, "reason": reason})
                continue
            key = task_key(request["server"], current)
            previous = index_tasks.get(key, {})
            metadata = collect_metadata(current)
            try:
                files = scan_task_tree(current, request.get("deep_check", False), previous.get("files", []))
            except OSError as exc:
                incomplete_total += 1
                if len(incomplete) < 200:
                    incomplete.append({"path": current, "reason": f"scan-failed:{exc}"})
                continue
            current_fingerprint = fingerprint(files, request.get("deep_check", False))
            if not previous:
                status = "new"
            elif previous.get("fingerprint") != current_fingerprint:
                status = "changed"
            else:
                status = "unchanged"
            complete.append({
                "key": key,
                "server": request["server"],
                "path": current,
                "destination": destination_for(current, request["backup_root"]),
                "status": status,
                "fingerprint": current_fingerprint,
                "files": files,
                **metadata,
            })
    complete.sort(key=lambda item: item["path"])
    counts = {name: sum(item["status"] == name for item in complete) for name in ("new", "changed", "unchanged")}
    return {
        "version": INDEX_VERSION,
        "server": request["server"],
        "paths": paths,
        "complete": complete,
        "incomplete_count": incomplete_total,
        "incomplete_samples": incomplete,
        "counts": counts,
    }

def summarize_inventory(inventory: dict) -> dict:
    return {
        "server": inventory["server"],
        "paths": inventory["paths"],
        "complete_count": len(inventory["complete"]),
        "incomplete_count": inventory["incomplete_count"],
        "counts": inventory["counts"],
        "incomplete_samples": inventory["incomplete_samples"],
        "entries": [
            {"path": item["path"], "status": item["status"], "destination": item["destination"]}
            for item in inventory["complete"]
        ],
        "actions": [
            {"path": item["path"], "status": item["status"], "destination": item["destination"]}
            for item in inventory["complete"] if item["status"] != "unchanged"
        ],
    }

def check_targets(request: dict, summary: dict) -> dict:
    index = load_index(request["index_path"])
    entries = summary.get("entries") or summary.get("actions") or []
    actions = []
    repairs = []
    for entry in entries:
        path = entry["path"]
        destination = entry["destination"]
        status = entry.get("status", "new")
        identical = False
        stored = index.get("tasks", {}).get(task_key(request["server"], path))
        if stored and os.path.isdir(destination) and not os.path.islink(destination):
            try:
                identical = copy_identity(scan_task_tree(destination, False, [])) == copy_identity(stored.get("files", []))
            except OSError:
                identical = False
        if status != "unchanged":
            actions.append({"path": path, "status": status, "destination": destination})
        elif not identical:
            repairs.append(path)
            actions.append({"path": path, "status": "repair", "destination": destination})
    return {"actions": actions, "repairs": repairs}

def log_records(inventory: dict):
    rows = []
    for item in inventory["complete"]:
        rows.append({
            "server": item["server"],
            "path": item["path"],
            "operator": item["operator"],
            "time": item["time"],
            "description": item["description"],
            "usage": item["usage"],
        })
    return rows

def load_index(index_path: str):
    path = Path(index_path)
    value = load_json(path, {"version": INDEX_VERSION, "tasks": {}}) or {}
    if value.get("version") != INDEX_VERSION:
        raise BackupError(f"Unsupported backup index version in {index_path}: {value.get('version')}")
    tasks = value.setdefault("tasks", {})
    journal = Path(index_path + ".journal")
    if journal.exists():
        with journal.open("r", encoding="utf-8") as handle:
            for line in handle:
                try:
                    item = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise BackupError(f"Corrupt backup index journal {journal}: {exc}") from exc
                tasks[item["key"]] = item
    return value

def save_index(index_path: str, index: dict) -> None:
    atomic_write_json(Path(index_path), index)
    journal = Path(index_path + ".journal")
    try:
        journal.unlink()
    except FileNotFoundError:
        pass

def append_index_journal(index_path: str, record: dict) -> None:
    path = Path(index_path + ".journal")
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, separators=(",", ":")) + "\n")
        handle.flush()
        os.fsync(handle.fileno())

def find_record(inventory: dict, task_path: str) -> dict:
    normalized = os.path.abspath(os.path.normpath(task_path))
    for item in inventory["complete"]:
        if item["path"] == normalized:
            return item
    raise BackupError(f"Task is not a backup-eligible task in the inventory: {task_path}")
