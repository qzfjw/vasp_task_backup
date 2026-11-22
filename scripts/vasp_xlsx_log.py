#!/usr/bin/env python3
"""Dependency-free atomic updater for /home/bak/VaspLog.xlsx."""
from __future__ import annotations
import copy
import contextlib
import fcntl
import os
import re
import shutil
import tempfile
import zipfile
from datetime import datetime
from pathlib import Path
import xml.etree.ElementTree as ET
from vasp_backup_common import BackupError

HEADERS = ("编号", "关联任务编号", "操作人", "时间", "计算说明", "使用记录", "任务所在文件夹")
NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
RELNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKGREL = "http://schemas.openxmlformats.org/package/2006/relationships"
XMLNS = "http://www.w3.org/XML/1998/namespace"
ET.register_namespace("", NS)
ET.register_namespace("r", RELNS)

def q(name: str) -> str:
    return f"{{{NS}}}{name}"

def rel_q(name: str) -> str:
    return f"{{{RELNS}}}{name}"

def cell_text(cell) -> str:
    kind = cell.get("t", "n")
    if kind == "inlineStr":
        node = cell.find(q("is"))
        if node is None:
            return ""
        values = [item.text or "" for item in node.iter(q("t"))]
        return "".join(values)
    value = cell.find(q("v"))
    if value is not None:
        return value.text or ""
    return ""

def set_cell_text(cell, value: str) -> None:
    style = cell.get("s")
    for key in list(cell.attrib):
        if key not in {"r", "s"}:
            del cell.attrib[key]
    for child in list(cell):
        cell.remove(child)
    cell.set("t", "inlineStr")
    if style is not None:
        cell.set("s", style)
    if value == "":
        return
    inline = ET.SubElement(cell, q("is"))
    node = ET.SubElement(inline, q("t"))
    if value[:1].isspace() or value[-1:].isspace():
        node.set(f"{{{XMLNS}}}space", "preserve")
    node.text = value

def set_cell_number(cell, value: int) -> None:
    style = cell.get("s")
    for key in list(cell.attrib):
        if key not in {"r", "s"}:
            del cell.attrib[key]
    for child in list(cell):
        cell.remove(child)
    cell.set("t", "n")
    if style is not None:
        cell.set("s", style)
    ET.SubElement(cell, q("v")).text = str(value)

def row_cells(row):
    return {re.match(r"[A-Z]+", cell.get("r", "")).group(0): cell for cell in row.findall(q("c")) if re.match(r"[A-Z]+", cell.get("r", ""))}

def row_number(row) -> int:
    return int(row.get("r", "0"))

def make_cell(row_number_value: int, column: str, style: str, text: str = "") -> object:
    cell = ET.Element(q("c"), {"r": f"{column}{row_number_value}", "s": style, "t": "inlineStr"})
    set_cell_text(cell, text)
    return cell

def resolve_sheet_path(archive: zipfile.ZipFile) -> str:
    workbook = ET.fromstring(archive.read("xl/workbook.xml"))
    sheet = next((item for item in workbook.iter(q("sheet")) if item.get("name") == "VaspLog"), None)
    if sheet is None:
        raise BackupError("VaspLog.xlsx does not contain a worksheet named VaspLog")
    relation_id = sheet.get(rel_q("id"))
    relationships = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
    for item in relationships:
        if item.get("Id") == relation_id:
            target = item.get("Target", "")
            return target.lstrip("/") if target.startswith("/") else os.path.normpath(os.path.join("xl", target)).replace("\\", "/")
    raise BackupError("Cannot resolve the VaspLog worksheet relationship")

def resolve_table_path(archive: zipfile.ZipFile, sheet_path: str):
    rel_path = os.path.join(os.path.dirname(sheet_path), "_rels", os.path.basename(sheet_path) + ".rels").replace("\\", "/")
    if rel_path not in archive.namelist():
        return ""
    relationships = ET.fromstring(archive.read(rel_path))
    for item in relationships:
        if item.get("Type", "").endswith("/table"):
            target = item.get("Target", "")
            return target.lstrip("/") if target.startswith("/") else os.path.normpath(os.path.join(os.path.dirname(sheet_path), target)).replace("\\", "/")
    return ""

@contextlib.contextmanager
def log_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

def relation_map(row_data):
    path_to_number = {item["path"]: item["number"] for item in row_data}
    related = {item["path"]: [] for item in row_data}
    for item in row_data:
        parent = os.path.dirname(item["path"])
        while parent and parent != os.path.dirname(parent):
            if parent in path_to_number:
                related[parent].append(item["number"])
                break
            parent = os.path.dirname(parent)
    return {path: ",".join(str(number) for number in sorted(numbers)) for path, numbers in related.items()}

def update_sheet(sheet_root, worksheet_path: str, table_path: str, archive: zipfile.ZipFile, records):
    sheet_data = sheet_root.find(q("sheetData"))
    if sheet_data is None:
        raise BackupError("VaspLog worksheet has no sheetData element")
    rows = {row_number(row): row for row in sheet_data.findall(q("row")) if row_number(row) > 0}
    if 1 not in rows:
        raise BackupError("VaspLog worksheet is missing the header row")
    header = row_cells(rows[1])
    actual_headers = tuple(cell_text(header.get(column, ET.Element("c"))) for column in "ABCDEFG")
    if actual_headers != HEADERS:
        raise BackupError(f"VaspLog header mismatch: expected {HEADERS}, found {actual_headers}")
    row_data = []
    path_rows = {}
    max_number = 0
    for number_value, row in sorted(rows.items()):
        if number_value == 1:
            continue
        cells = row_cells(row)
        raw_path = cell_text(cells["G"]) if "G" in cells else ""
        path = os.path.normpath(raw_path) if raw_path else ""
        if not path:
            continue
        if path in path_rows:
            raise BackupError(f"VaspLog contains duplicate task path: {path}")
        number_text = cell_text(cells["A"]) if "A" in cells else ""
        try:
            task_number = int(float(number_text))
        except ValueError:
            max_number += 1
            task_number = max_number
            if "A" not in cells:
                cells["A"] = make_cell(number_value, "A", "2")
                row.append(cells["A"])
            set_cell_number(cells["A"], task_number)
        max_number = max(max_number, task_number)
        path_rows[path] = {"row_number": number_value, "row": row, "cells": cells, "number": task_number}
        row_data.append({"path": path, "number": task_number})
    template = next((row for number_value, row in sorted(rows.items()) if number_value > 1 and row.findall(q("c"))), None)
    template_cells = row_cells(template) if template is not None else {}
    styles = {column: (template_cells.get(column).get("s", "5") if template_cells.get(column) is not None else "5") for column in "ABCDEFG"}
    styles["A"] = template_cells.get("A").get("s", "2") if template_cells.get("A") is not None else "2"
    styles["B"] = template_cells.get("B").get("s", "3") if template_cells.get("B") is not None else "3"
    styles["C"] = template_cells.get("C").get("s", "4") if template_cells.get("C") is not None else "4"
    added = 0
    updated = 0
    for record in sorted(records, key=lambda item: item["path"]):
        path = os.path.normpath(record["path"])
        values = {"C": record["operator"], "D": record["time"], "E": record["description"], "F": record["usage"], "G": path}
        if path in path_rows:
            target = path_rows[path]
            changed = False
            for column, value in values.items():
                current = cell_text(target["cells"].get(column, ET.Element("c")))
                if current != value:
                    if column not in target["cells"]:
                        target["cells"][column] = make_cell(target["row_number"], column, styles[column])
                        target["row"].append(target["cells"][column])
                    set_cell_text(target["cells"][column], value)
                    changed = True
            updated += int(changed)
            continue
        max_number += 1
        row_number_value = max(rows) + 1 if rows else 2
        row = ET.Element(q("row"), {"r": str(row_number_value)})
        cells = {}
        for column in "ABCDEFG":
            cells[column] = make_cell(row_number_value, column, styles[column])
            row.append(cells[column])
        set_cell_number(cells["A"], max_number)
        for column, value in values.items():
            set_cell_text(cells[column], value)
        sheet_data.append(row)
        rows[row_number_value] = row
        path_rows[path] = {"row_number": row_number_value, "row": row, "cells": cells, "number": max_number}
        row_data.append({"path": path, "number": max_number})
        added += 1
    related = relation_map(row_data)
    relation_updates = 0
    for path, target in path_rows.items():
        expected = related.get(path, "")
        current_cell = target["cells"].get("B")
        current = cell_text(current_cell) if current_cell is not None else ""
        if current != expected or current_cell is None or current_cell.get("t") != "inlineStr":
            if current_cell is None:
                current_cell = make_cell(target["row_number"], "B", styles["B"])
                target["row"].append(current_cell)
            set_cell_text(current_cell, expected)
            relation_updates += 1
    last_row = max(rows) if rows else 1
    dimension = sheet_root.find(q("dimension"))
    if dimension is None:
        dimension = ET.Element(q("dimension"))
        sheet_root.insert(0, dimension)
    dimension.set("ref", f"A1:G{last_row}")
    table_updates = update_table(archive, table_path, last_row)
    return {"added": added, "updated": updated, "relation_updates": relation_updates, "rows": last_row - 1, "table_updates": table_updates}

def update_table(archive: zipfile.ZipFile, table_path: str, last_row: int) -> list:
    if not table_path or table_path not in archive.namelist():
        return []
    root = ET.fromstring(archive.read(table_path))
    new_ref = f"A1:G{last_row}"
    changed = []
    if root.get("ref") != new_ref:
        root.set("ref", new_ref)
        changed.append(table_path)
    auto_filter = root.find(q("autoFilter"))
    if auto_filter is not None and auto_filter.get("ref") != new_ref:
        auto_filter.set("ref", new_ref)
        if table_path not in changed:
            changed.append(table_path)
    archive_replacements[table_path] = ET.tostring(root, encoding="utf-8", xml_declaration=True)
    return changed

def atomic_rewrite_workbook(log_path: Path, replacements: dict) -> None:
    backup_dir = log_path.parent / ".vasp_task_backup" / "log-backups"
    backup_dir.mkdir(parents=True, exist_ok=True)
    old_backups = sorted(backup_dir.glob(log_path.name + ".*.bak"))
    while len(old_backups) >= 5:
        old_backups.pop(0).unlink(missing_ok=True)
    if log_path.exists():
        shutil.copy2(log_path, backup_dir / f"{log_path.name}.{datetime.now().strftime('%Y%m%d_%H%M%S_%f')}.bak")
    fd, temp_name = tempfile.mkstemp(prefix=f".{log_path.name}.", dir=str(log_path.parent))
    os.close(fd)
    try:
        with zipfile.ZipFile(log_path, "r") as source, zipfile.ZipFile(temp_name, "w") as target:
            for info in source.infolist():
                data = replacements.get(info.filename, source.read(info.filename))
                target.writestr(info, data)
        os.chmod(temp_name, stat_mode(log_path))
        os.replace(temp_name, log_path)
    except Exception:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise

def stat_mode(path: Path) -> int:
    try:
        return os.stat(path).st_mode & 0o777
    except FileNotFoundError:
        return 0o664

def update_workbook(log_path: Path, records) -> dict:
    if not log_path.exists():
        create_workbook(log_path)
    with log_lock(Path(str(log_path) + ".lock")):
        with zipfile.ZipFile(log_path, "r") as archive:
            sheet_path = resolve_sheet_path(archive)
            table_path = resolve_table_path(archive, sheet_path)
            sheet_root = ET.fromstring(archive.read(sheet_path))
            global archive_replacements
            archive_replacements = {}
            result = update_sheet(sheet_root, sheet_path, table_path, archive, records)
            archive_replacements[sheet_path] = ET.tostring(sheet_root, encoding="utf-8", xml_declaration=True)
        changed = bool(result["added"] or result["updated"] or result["relation_updates"] or result["table_updates"])
        result["written"] = changed
        if changed:
            atomic_rewrite_workbook(log_path, archive_replacements)
    if result["written"]:
        verify_workbook(log_path, records)
    return result

def verify_workbook(log_path: Path, records) -> dict:
    with zipfile.ZipFile(log_path, "r") as archive:
        bad = archive.testzip()
        if bad:
            raise BackupError(f"VaspLog.xlsx zip verification failed at {bad}")
        sheet_path = resolve_sheet_path(archive)
        root = ET.fromstring(archive.read(sheet_path))
    sheet_data = root.find(q("sheetData"))
    paths = []
    numbers = []
    headers = tuple(cell_text(cell) for cell in row_cells(sheet_data.findall(q("row"))[0]).values())
    if set(HEADERS) - set(headers):
        raise BackupError("VaspLog.xlsx header verification failed")
    for row in sheet_data.findall(q("row"))[1:]:
        cells = row_cells(row)
        path = cell_text(cells["G"]) if "G" in cells else ""
        if path:
            paths.append(path)
            numbers.append(int(float(cell_text(cells["A"]))) if "A" in cells else 0)
    if len(paths) != len(set(paths)):
        raise BackupError("VaspLog.xlsx contains duplicate task paths after update")
    expected = {os.path.normpath(item["path"]) for item in records}
    missing = expected - set(paths)
    if missing:
        raise BackupError(f"VaspLog.xlsx verification is missing {len(missing)} registered task(s)")
    return {"rows": len(paths), "max_number": max(numbers) if numbers else 0}

def create_workbook(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    sheet_rows = []
    for row_number_value in range(1, 2):
        rows = []
        for index, header in enumerate(HEADERS, start=1):
            column = chr(64 + index)
            rows.append(f'<c r="{column}{row_number_value}" s="1" t="inlineStr"><is><t>{header}</t></is></c>')
        sheet_rows.append(f'<row r="{row_number_value}">{"".join(rows)}</row>')
    sheet = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><worksheet xmlns="{NS}" xmlns:r="{RELNS}"><dimension ref="A1:G1"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/><cols><col min="1" max="1" width="11"/><col min="2" max="2" width="46"/><col min="3" max="3" width="12"/><col min="4" max="4" width="20"/><col min="5" max="5" width="72"/><col min="6" max="6" width="58"/><col min="7" max="7" width="92"/></cols><sheetData>{''.join(sheet_rows)}</sheetData><tableParts count="1"><tablePart r:id="rId1"/></tableParts></worksheet>'''
    table = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><table xmlns="{NS}" id="1" name="VaspLogTable" displayName="VaspLogTable" ref="A1:G1" headerRowCount="1"><autoFilter ref="A1:G1"/><tableColumns count="7">{''.join(f'<tableColumn id="{index}" name="{header}"/>' for index, header in enumerate(HEADERS, start=1))}</tableColumns><tableStyleInfo name="TableStyleMedium2" showFirstColumn="0" showLastColumn="0" showRowStripes="1" showColumnStripes="0"/></table>'''
    workbook = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><workbook xmlns="{NS}" xmlns:r="{RELNS}"><bookViews><workbookView/></bookViews><sheets><sheet name="VaspLog" sheetId="1" r:id="rId1"/></sheets></workbook>'''
    workbook_rels = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="{PKGREL}"><Relationship Id="rId1" Type="{RELNS}/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="{RELNS}/styles" Target="styles.xml"/></Relationships>'''
    sheet_rels = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="{PKGREL}"><Relationship Id="rId1" Type="{RELNS}/table" Target="../tables/table1.xml"/></Relationships>'''
    styles = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><styleSheet xmlns="{NS}"><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><color rgb="00FFFFFF"/><sz val="10"/><name val="Arial"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill><fill><patternFill patternType="solid"><fgColor rgb="001F4E78"/></patternFill></fill></fills><borders count="2"><border/><border><bottom style="thin"><color rgb="00D9E2F3"/></bottom></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="6"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="2" borderId="0" applyFont="1" applyFill="1" applyAlignment="1" xfId="0"><alignment horizontal="center"/></xf><xf numFmtId="1" fontId="0" fillId="0" borderId="1" applyBorder="1" xfId="0"/><xf numFmtId="49" fontId="0" fillId="0" borderId="1" applyBorder="1" xfId="0"/><xf numFmtId="49" fontId="0" fillId="0" borderId="1" applyBorder="1" xfId="0"/><xf numFmtId="49" fontId="0" fillId="0" borderId="1" applyBorder="1" xfId="0"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>'''
    content_types = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/tables/table1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.table+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>'''
    root_rels = f'''<?xml version="1.0" encoding="UTF-8" standalone="yes"?><Relationships xmlns="{PKGREL}"><Relationship Id="rId1" Type="{RELNS}/officeDocument" Target="xl/workbook.xml"/></Relationships>'''
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("[Content_Types].xml", content_types)
        archive.writestr("_rels/.rels", root_rels)
        archive.writestr("xl/workbook.xml", workbook)
        archive.writestr("xl/_rels/workbook.xml.rels", workbook_rels)
        archive.writestr("xl/worksheets/sheet1.xml", sheet)
        archive.writestr("xl/worksheets/_rels/sheet1.xml.rels", sheet_rels)
        archive.writestr("xl/tables/table1.xml", table)
        archive.writestr("xl/styles.xml", styles)
