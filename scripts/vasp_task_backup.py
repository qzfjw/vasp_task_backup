#!/usr/bin/env python3
"""CLI for the VASP task backup workflow."""
from __future__ import annotations
import argparse
import base64
import json
import os
import sys
from pathlib import Path
from vasp_backup_common import BackupError, atomic_write_json
from vasp_backup_scan import check_targets, discover_tasks, find_record, load_index, log_records, save_index, summarize_inventory
from vasp_backup_store import apply_archive, create_archive, ensure_backup_root, run_local
from vasp_xlsx_log import update_workbook

def request_from_args(args) -> dict:
    try:
        raw = base64.b64decode(args.request_b64).decode("utf-8")
        request = json.loads(raw)
    except Exception as exc:
        raise BackupError(f"Invalid request payload: {exc}") from exc
    required = ("server", "paths", "backup_root", "index_path", "log_path")
    missing = [name for name in required if name not in request]
    if missing:
        raise BackupError("Request is missing: " + ", ".join(missing))
    return request

def read_inventory(path: str) -> dict:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise BackupError(f"Cannot read inventory {path}: {exc}") from exc

def command_run(args) -> dict:
    request = request_from_args(args)
    report = run_local(request)
    records = report.pop("log_records", [])
    if request.get("execute") and not report.get("errors"):
        report["excel"] = update_workbook(Path(request["log_path"]), records)
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return report

def command_inventory(args) -> dict:
    request = request_from_args(args)
    index = load_index(request["index_path"])
    inventory = discover_tasks(request, index["tasks"])
    atomic_write_json(Path(args.output), inventory)
    summary = summarize_inventory(inventory)
    if args.summary:
        atomic_write_json(Path(args.summary), summary)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return summary

def command_export_index(args) -> dict:
    request = request_from_args(args)
    index = load_index(request["index_path"])
    atomic_write_json(Path(args.output), index)
    summary = {"tasks": len(index.get("tasks", {})), "output": args.output}
    print(json.dumps(summary, ensure_ascii=False))
    return summary

def command_compact_index(args) -> dict:
    request = request_from_args(args)
    index = load_index(request["index_path"])
    save_index(request["index_path"], index)
    summary = {"tasks": len(index.get("tasks", {})), "index_path": request["index_path"]}
    print(json.dumps(summary, ensure_ascii=False))
    return summary

def command_check_targets(args) -> dict:
    request = request_from_args(args)
    try:
        with open(args.summary, "r", encoding="utf-8") as handle:
            summary = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise BackupError(f"Cannot read inventory summary {args.summary}: {exc}") from exc
    result = check_targets(request, summary)
    atomic_write_json(Path(args.output), result)
    print(json.dumps({"actions": len(result["actions"]), "repairs": len(result["repairs"])}, ensure_ascii=False))
    return result

def command_log_records(args) -> dict:
    inventory = read_inventory(args.inventory)
    records = log_records(inventory)
    atomic_write_json(Path(args.output), records)
    summary = {"records": len(records), "output": args.output}
    print(json.dumps(summary, ensure_ascii=False))
    return summary

def command_pack(args) -> dict:
    request = request_from_args(args)
    inventory = read_inventory(args.inventory)
    record = find_record(inventory, args.task)
    if os.path.abspath(os.path.normpath(record["destination"])) != os.path.abspath(os.path.normpath(args.destination)):
        raise BackupError("Packed task destination does not match the inventory destination")
    manifest = create_archive(request, record, args.archive, args.manifest)
    summary = {
        "path": manifest["path"], "destination": manifest["destination"],
        "archive": args.archive, "archive_sha256": manifest["archive_sha256"],
        "archive_size": manifest["archive_size"], "manifest": args.manifest,
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return summary

def command_apply(args) -> dict:
    request = request_from_args(args)
    ensure_backup_root(request)
    result = apply_archive(request, args.archive, args.manifest)
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return result

def command_update_log(args) -> dict:
    request = request_from_args(args)
    try:
        with open(args.records, "r", encoding="utf-8") as handle:
            records = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise BackupError(f"Cannot read log records {args.records}: {exc}") from exc
    result = update_workbook(Path(request["log_path"]), records)
    result["log_path"] = request["log_path"]
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return result

def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    run = subparsers.add_parser("run")
    run.add_argument("--request-b64", required=True)
    run.set_defaults(func=command_run)
    inventory = subparsers.add_parser("inventory")
    inventory.add_argument("--request-b64", required=True)
    inventory.add_argument("--output", required=True)
    inventory.add_argument("--summary", default="")
    inventory.set_defaults(func=command_inventory)
    export_index = subparsers.add_parser("export-index")
    export_index.add_argument("--request-b64", required=True)
    export_index.add_argument("--output", required=True)
    export_index.set_defaults(func=command_export_index)
    compact = subparsers.add_parser("compact-index")
    compact.add_argument("--request-b64", required=True)
    compact.set_defaults(func=command_compact_index)
    check = subparsers.add_parser("check-targets")
    check.add_argument("--request-b64", required=True)
    check.add_argument("--summary", required=True)
    check.add_argument("--output", required=True)
    check.set_defaults(func=command_check_targets)
    records = subparsers.add_parser("log-records")
    records.add_argument("--inventory", required=True)
    records.add_argument("--output", required=True)
    records.set_defaults(func=command_log_records)
    pack = subparsers.add_parser("pack")
    pack.add_argument("--request-b64", required=True)
    pack.add_argument("--inventory", required=True)
    pack.add_argument("--task", required=True)
    pack.add_argument("--destination", required=True)
    pack.add_argument("--archive", required=True)
    pack.add_argument("--manifest", required=True)
    pack.set_defaults(func=command_pack)
    apply = subparsers.add_parser("apply")
    apply.add_argument("--request-b64", required=True)
    apply.add_argument("--archive", required=True)
    apply.add_argument("--manifest", required=True)
    apply.set_defaults(func=command_apply)
    log = subparsers.add_parser("update-log")
    log.add_argument("--request-b64", required=True)
    log.add_argument("--records", required=True)
    log.set_defaults(func=command_update_log)
    return parser

def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
        return 0
    except BackupError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    except Exception as exc:
        print(f"ERROR: unexpected {type(exc).__name__}: {exc}", file=sys.stderr)
        return 3

if __name__ == "__main__":
    raise SystemExit(main())
