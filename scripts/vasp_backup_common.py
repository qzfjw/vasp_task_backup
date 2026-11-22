#!/usr/bin/env python3
"""Shared primitives for the VASP task backup skill."""
from __future__ import annotations
import hashlib
import json
import os
import pwd
import re
import stat
import tempfile
from datetime import datetime
from pathlib import Path

INDEX_VERSION = 1
REQUIRED_FILES = ("INCAR", "POSCAR")
KEY_FILES = {
    "INCAR", "POSCAR", "POTCAR", "KPOINTS", "CONTCAR", "OUTCAR", "OSZICAR",
    "vasprun.xml", "EIGENVAL", "DOSCAR", "CHGCAR", "LOCPOT",
}
DOCUMENT_SUFFIXES = {".pdf", ".doc", ".docx", ".ppt", ".pptx", ".tex", ".md"}
DOCUMENT_KEYWORDS = (
    "report", "paper", "article", "manuscript", "thesis", "draft",
    "报告", "论文", "文章", "手稿", "汇报", "成果",
)
PROPERTY_HINTS = (
    ("能带", "能带结构/带隙"),
    ("态密度", "电子态密度"),
    ("电荷", "电荷转移/静电势"),
    ("弹性", "弹性常数/力学性质"),
    ("声子", "声子谱/晶格稳定性"),
    ("光学", "光学吸收/介电性质"),
    ("磁序", "磁序/磁性质"),
    ("过渡态", "反应路径/能垒"),
    ("截断能", "截断能收敛性"),
    ("结构弛豫", "平衡结构/结构参数"),
    ("自洽静态", "总能量/电子结构"),
)
FORMULA_TOKEN = re.compile(r"^(?:[A-Z][a-z]?\d*){2,}$")
POTCAR_TITLE = re.compile(
    r"TITEL\s*=.*?\s([A-Z][a-z]?)(?:_[^\s]+)?\s+\d{2}[A-Za-z]{3}\d{4}"
)
FATAL_PATTERNS = (
    b"zbrent: fatal error",
    b"very bad news! internal error",
    b"error edddav",
    b"segmentation fault",
    b"signal 11",
)
COMPLETION_MARKERS = (
    b"general timing and accounting informations for this job",
)

class BackupError(RuntimeError):
    pass

def atomic_write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=f".{path.name}.", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(name, 0o664)
        os.replace(name, path)
    except Exception:
        try:
            os.unlink(name)
        except FileNotFoundError:
            pass
        raise

def load_json(path: Path, default: object = None) -> object:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)

def sha256_file(path: Path, chunk_size: int = 4 * 1024 * 1024) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            block = handle.read(chunk_size)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()

def normalize_source(raw_path: str) -> str:
    path = os.path.abspath(os.path.normpath(raw_path))
    if not path.startswith("/") or path in {"/", "/home", "/home/bak"}:
        raise BackupError(f"Source must be a safe absolute task path, not the filesystem root or backup root: {raw_path}")
    if path.startswith("/home/bak/"):
        raise BackupError(f"Source cannot be the backup root: {path}")
    if "\n" in path or "\r" in path:
        raise BackupError("Source paths containing newlines are unsupported")
    if not os.path.isdir(path) or os.path.islink(path):
        raise BackupError(f"Source is missing, not a directory, or a symlink: {path}")
    return path

def destination_for(source_path: str, backup_root: str) -> str:
    root = os.path.abspath(os.path.normpath(backup_root))
    if not root.startswith("/home/") or root == "/home":
        raise BackupError(f"Backup root must be below /home: {backup_root}")
    relative = source_path[len("/home/"):] if source_path.startswith("/home/") else source_path.lstrip("/")
    destination = os.path.join(root, relative)
    normalized = os.path.normpath(destination)
    if not normalized.startswith(root + os.sep):
        raise BackupError(f"Unsafe destination path: {normalized}")
    return normalized

def task_key(server: str, source_path: str) -> str:
    raw = f"{server}\0{source_path}".encode("utf-8", "surrogateescape")
    return hashlib.sha256(raw).hexdigest()

def now_text() -> str:
    return datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S")

def owner_name(uid: int) -> str:
    try:
        return pwd.getpwuid(uid).pw_name
    except KeyError:
        return str(uid)

def read_tail(path: Path, size: int = 256 * 1024) -> bytes:
    with path.open("rb") as handle:
        handle.seek(0, os.SEEK_END)
        length = handle.tell()
        handle.seek(max(0, length - size))
        return handle.read().lower()

def incomplete_reason(task_path: str) -> str:
    missing = [name for name in REQUIRED_FILES if not os.path.isfile(os.path.join(task_path, name))]
    if missing:
        return "missing:" + ",".join(missing)
    outcar = Path(task_path) / "OUTCAR"
    if not outcar.is_file():
        # OUTCAR may be removed after a completed run; the remaining inputs still identify a backup task.
        return ""
    try:
        tail = read_tail(outcar)
    except FileNotFoundError:
        return ""
    except OSError as exc:
        return f"outcar-unreadable:{exc}"
    if not any(marker in tail for marker in COMPLETION_MARKERS):
        return "outcar-without-normal-completion-marker"
    fatal = next((item.decode("ascii", "replace") for item in FATAL_PATTERNS if item in tail), None)
    if fatal:
        return f"outcar-fatal-marker:{fatal}"
    return ""

def parse_incar(path: Path) -> dict:
    params = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return params
    for raw_line in lines:
        line = raw_line.split("#", 1)[0].split("!", 1)[0].strip()
        if not line or "=" not in line:
            continue
        key, value = line.split(";", 1)[0].split("=", 1)
        key = key.strip().upper()
        value = value.strip().strip("\"'").split()[0] if value.strip() else ""
        if key:
            params[key] = value
    return params

def compose_formula(symbols, counts=None):
    if counts and len(counts) == len(symbols):
        return "".join(symbol + (str(count) if count != 1 else "") for symbol, count in zip(symbols, counts))
    return "".join(symbols)

def parse_poscar(path: Path):
    try:
        lines = [line.rstrip("\r\n") for line in path.read_text(encoding="utf-8", errors="replace").splitlines()]
    except OSError:
        return None, []
    if len(lines) < 7:
        return None, []
    title = lines[0].strip()
    if FORMULA_TOKEN.fullmatch(title) and any(char.isdigit() for char in title):
        return title, []
    symbols = lines[5].split()
    counts = lines[6].split()
    if symbols and all(re.fullmatch(r"[A-Z][a-z]?", item) for item in symbols):
        try:
            counts_int = [int(item) for item in counts]
        except ValueError:
            counts_int = []
        if counts_int and len(counts_int) == len(symbols):
            return compose_formula(symbols, counts_int), counts_int
    return None, []

def symbols_from_potcar(path: Path, expected_count=None):
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return []
    symbols = POTCAR_TITLE.findall(text)
    if expected_count is not None and len(symbols) != expected_count:
        return []
    return symbols

def symbols_from_outcar(path: Path, expected_count=None):
    symbols = []
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = re.search(r"POTCAR:\s+.*?\s([A-Z][a-z]?)(?:_[^\s]+)?\s+\d{2}[A-Za-z]{3}\d{4}", line)
                if match:
                    symbols.append(match.group(1))
    except OSError:
        return []
    if expected_count is not None and len(symbols) != expected_count:
        return []
    return symbols

def extract_formula(task_path: str):
    directory = Path(task_path)
    formula, counts = parse_poscar(directory / "POSCAR")
    if formula:
        return formula
    formula, _ = parse_poscar(directory / "CONTCAR")
    if formula:
        return formula
    expected_count = len(counts) if counts else None
    symbols = symbols_from_potcar(directory / "POTCAR", expected_count)
    if not symbols:
        symbols = symbols_from_outcar(directory / "OUTCAR", expected_count)
    if symbols:
        return compose_formula(symbols, counts if counts else None)
    return "未识别"

def identifying_items(task_path: str, params: dict):
    path_text = task_path.lower()
    basename = os.path.basename(task_path).lower()
    items = []
    if re.search(r"(?:^|[_-])rf\d+_static", basename):
        items.append("静态参数/截断能对比验证")
    elif any(token in path_text for token in ("/charge", "charge_density", "差分电荷", "1-charge")):
        items.append("电荷密度/差分电荷分析")
    elif "elastic" in path_text:
        items.append("弹性常数计算")
    elif "phonon" in path_text:
        items.append("声子/晶格动力学计算")
    elif "band" in path_text:
        items.append("能带计算")
    elif "dos" in path_text:
        items.append("态密度计算")
    elif any(token in path_text for token in ("optics", "optical", "光学")):
        items.append("光学性质计算")
    elif any(token in path_text for token in ("hubbard", "ldau")):
        items.append("DFT+U 参数计算")
    elif re.search(r"(?:^|[/_-])(?:afm|fm)(?:$|[/_-])", path_text):
        items.append("磁序（AFM/FM）对比计算")
    else:
        items.append("结构弛豫" if params.get("IBRION", "").strip() not in {"", "-1"} else "自洽静态计算")
    if (params.get("ICHARG", "").strip() == "11" or params.get("NSW", "").strip() == "0") and items[0] not in {"自洽静态计算", "能带计算", "态密度计算"}:
        items.append("自洽静态计算")
    if params.get("ISPIN", "").strip() == "2":
        items.append("自旋极化")
    if params.get("LDAU", "").strip().upper().startswith((".T", "T", "1")):
        items.append("DFT+U")
    if params.get("LUSE_VDW", "").strip().upper().startswith((".T", "T", "1")) or params.get("IVDW", "").strip() not in {"", "0"}:
        items.append("vdW 修正")
    return items

def build_description(formula: str, items) -> str:
    prefix = f"化学式：{formula}；任务："
    selected = []
    for item in items:
        candidate = prefix + "；".join(selected + [item]) + "。"
        if len(candidate) > 100:
            break
        selected.append(item)
    if not selected:
        selected = [items[0]]
    description = prefix + "；".join(selected) + "。"
    return description if len(description) <= 100 else description[:99] + "。"

def scan_documents_and_time(task_path: str):
    latest = os.stat(task_path).st_mtime
    documents = []
    with os.scandir(task_path) as entries:
        for entry in entries:
            lower = entry.name.lower()
            if lower.endswith(tuple(DOCUMENT_SUFFIXES)) and any(keyword in lower for keyword in DOCUMENT_KEYWORDS):
                try:
                    if entry.is_file(follow_symlinks=False):
                        documents.append(entry.name)
                except OSError:
                    pass
            if entry.name not in KEY_FILES and not entry.name.startswith("slurm-"):
                continue
            try:
                entry_stat = entry.stat(follow_symlinks=False)
            except OSError:
                continue
            if stat.S_ISREG(entry_stat.st_mode):
                latest = max(latest, entry_stat.st_mtime)
    return latest, sorted(documents)

def build_usage_record(items, documents) -> str:
    properties = []
    for needle, label in PROPERTY_HINTS:
        if any(needle in item for item in items) and label not in properties:
            properties.append(label)
    if not properties:
        properties.append("计算结果")
    document_text = "报告/论文文件：" + "、".join(documents[:3]) if documents else "报告/论文：未检索到"
    return f"{document_text}；可分析：{'、'.join(properties[:4])}。"[:200]

def file_record(root: Path, path: Path, deep: bool, known: dict) -> dict:
    rel = os.path.relpath(str(path), str(root))
    info = path.lstat()
    mode = stat.S_IMODE(info.st_mode)
    if stat.S_ISLNK(info.st_mode):
        return {"path": rel, "type": "symlink", "target": os.readlink(path), "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns, "mode": mode}
    if stat.S_ISDIR(info.st_mode):
        return {"path": rel, "type": "dir", "mode": mode, "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}
    if stat.S_ISREG(info.st_mode):
        record = {"path": rel, "type": "file", "size": info.st_size, "mode": mode, "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}
        if deep:
            reuse = known.get("type") == "file" and known.get("size") == info.st_size and known.get("mtime_ns") == info.st_mtime_ns and known.get("ctime_ns") == info.st_ctime_ns and known.get("sha256")
            record["sha256"] = known["sha256"] if reuse else sha256_file(path)
        return record
    return {"path": rel, "type": "other", "mode": mode, "mtime_ns": info.st_mtime_ns, "ctime_ns": info.st_ctime_ns}

def scan_task_tree(task_path: str, deep: bool = False, known_files=None):
    root = Path(task_path)
    known = {item.get("path"): item for item in (known_files or [])}
    records = []
    for current, dirnames, filenames in os.walk(task_path, topdown=True, followlinks=False):
        dirnames.sort()
        filenames.sort()
        keep_dirs = []
        for dirname in dirnames:
            child = Path(current) / dirname
            rel = os.path.relpath(str(child), task_path)
            record = file_record(root, child, deep, known.get(rel, {}))
            records.append(record)
            if record["type"] != "symlink":
                keep_dirs.append(dirname)
        dirnames[:] = keep_dirs
        for filename in filenames:
            child = Path(current) / filename
            rel = os.path.relpath(str(child), task_path)
            records.append(file_record(root, child, deep, known.get(rel, {})))
    records.sort(key=lambda item: (item["path"], item["type"]))
    return records

def fingerprint(records, deep: bool = False) -> str:
    digest = hashlib.sha256()
    for item in sorted(records, key=lambda value: (value.get("path", ""), value.get("type", ""))):
        fields = [item.get("path", ""), item.get("type", "")]
        if item.get("type") == "file":
            fields.extend([str(item.get("size", 0)), str(item.get("sha256", ""))])
        elif item.get("type") == "symlink":
            fields.append(str(item.get("target", "")))
        fields.extend([str(item.get("mtime_ns", 0)), str(item.get("ctime_ns", 0)), str(item.get("mode", 0))])
        digest.update(("\0".join(fields) + "\n").encode("utf-8", "surrogateescape"))
    return digest.hexdigest()

def copy_identity(records) -> str:
    digest = hashlib.sha256()
    for item in sorted(records, key=lambda value: (value.get("path", ""), value.get("type", ""))):
        fields = [item.get("path", ""), item.get("type", "")]
        if item.get("type") == "file":
            fields.extend([str(item.get("size", 0)), item.get("sha256", "")])
        elif item.get("type") == "symlink":
            fields.append(str(item.get("target", "")))
        digest.update(("\0".join(fields) + "\n").encode("utf-8", "surrogateescape"))
    return digest.hexdigest()

def collect_metadata(task_path: str):
    directory_stat = os.stat(task_path)
    params = parse_incar(Path(task_path) / "INCAR")
    latest_mtime, documents = scan_documents_and_time(task_path)
    items = identifying_items(task_path, params)
    return {
        "operator": owner_name(directory_stat.st_uid),
        "time": datetime.fromtimestamp(latest_mtime).astimezone().strftime("%Y-%m-%d %H:%M:%S"),
        "description": build_description(extract_formula(task_path), items),
        "usage": build_usage_record(items, documents),
    }
