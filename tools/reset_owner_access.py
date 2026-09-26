"""Prepare an explicitly authorized owner handover, preserving business data.

This maintenance tool is not a password bypass exposed by the application.
The Windows user must be able to write the database and CAPC must be closed.
The next launch asks the owner to choose their own name, login and password.
"""

import argparse
from contextlib import contextmanager
import ctypes
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3
import sys
import uuid


APPLICATION_ID = 1128353859
MARKER = "owner_reconfiguration_user_id"


@contextmanager
def desktop_lock():
    if sys.platform != "win32":
        raise RuntimeError("Esta herramienta de mantenimiento requiere Windows.")
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateMutexW.argtypes = (ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p)
    kernel.CreateMutexW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = (ctypes.c_void_p,)
    handle = kernel.CreateMutexW(None, False, "Local\\CAPC_MULTISERVICIO_DESKTOP")
    if not handle:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        if ctypes.get_last_error() == 183:
            raise RuntimeError("Cierra CAPC antes de restablecer el acceso.")
        yield
    finally:
        kernel.CloseHandle(handle)


def connect(path, mode="ro"):
    conn = sqlite3.connect(path.as_uri() + "?mode=" + mode, uri=True, timeout=5)
    conn.execute("PRAGMA foreign_keys=ON")
    return conn


def validate(conn):
    if conn.execute("PRAGMA application_id").fetchone()[0] != APPLICATION_ID:
        raise ValueError("El archivo no es una base CAPC compatible.")
    if conn.execute("PRAGMA user_version").fetchone()[0] != 2:
        raise ValueError("El esquema requiere otra versión de la herramienta.")
    if conn.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
        raise ValueError("La base no pasó la comprobación de integridad.")
    if conn.execute("PRAGMA foreign_key_check").fetchall():
        raise ValueError("La base contiene referencias inconsistentes.")


def quote_identifier(value):
    return '"' + value.replace('"', '""') + '"'


def business_fingerprint(conn):
    """Every business table, including counters/outbox, must remain unchanged."""
    digest = hashlib.sha256()
    tables = conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' "
        "AND name NOT LIKE 'sqlite_%' ORDER BY name"
    ).fetchall()
    for (table,) in tables:
        if table in {"settings", "users", "audit"}:
            continue
        digest.update(table.encode("utf-8"))
        for row in conn.execute("SELECT * FROM " + quote_identifier(table) + " ORDER BY rowid"):
            digest.update(repr(row).encode("utf-8"))
            digest.update(b"\n")
    return digest.hexdigest()


def owner_record(conn, username):
    business = conn.execute("SELECT value FROM settings WHERE key='business_id'").fetchone()
    if not business:
        raise ValueError("No se encontró la empresa local.")
    users = conn.execute(
        "SELECT id,name,username FROM users WHERE business_id=? "
        "AND username=? COLLATE NOCASE AND active=1 AND role='owner'",
        (business[0], username),
    ).fetchall()
    if len(users) != 1:
        raise ValueError("El usuario indicado no es un propietario activo de esta empresa.")
    return users[0], business[0]


def prepare_owner_access(database, username):
    """Caller must hold desktop_lock; no password is read or generated here."""
    database = Path(database).resolve(strict=True)
    conn = connect(database, "rw")
    backup_path = None
    try:
        validate(conn)
        owner, business = owner_record(conn, username)
        if conn.execute("SELECT value FROM settings WHERE key=?", (MARKER,)).fetchone():
            raise ValueError("Ya está preparada la configuración del nuevo propietario. Abre CAPC.")
        source_version = conn.execute("PRAGMA data_version").fetchone()[0]
        backup_dir = database.parent / "respaldos_acceso"
        backup_dir.mkdir(exist_ok=True)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        backup_path = backup_dir / ("antes-nuevo-propietario-" + stamp + "-" + uuid.uuid4().hex[:8] + ".sqlite3")
        # Reserve a unique destination; never overwrite an existing backup.
        with backup_path.open("xb"):
            pass
        backup = connect(backup_path, "rw")
        try:
            conn.backup(backup)
            validate(backup)
            snapshot_fingerprint = business_fingerprint(backup)
            snapshot_owner, _ = owner_record(backup, username)
        finally:
            backup.close()

        conn.execute("BEGIN IMMEDIATE")
        owner, business = owner_record(conn, username)
        if (conn.execute("PRAGMA data_version").fetchone()[0] != source_version
                or owner != snapshot_owner or business_fingerprint(conn) != snapshot_fingerprint):
            raise RuntimeError("La base cambió durante el respaldo. Repite con CAPC cerrada.")
        if conn.execute("SELECT value FROM settings WHERE key=?", (MARKER,)).fetchone():
            raise RuntimeError("Otro proceso ya preparó el cambio de propietario.")
        device = conn.execute("SELECT value FROM settings WHERE key='device_id'").fetchone()[0]
        conn.execute("UPDATE users SET session_version=session_version+1 WHERE business_id=?", (business,))
        conn.execute(
            "DELETE FROM settings WHERE key IN (?,?)",
            ("password_recovery_hash:" + owner[0], "password_recovery_attempts:" + owner[0]),
        )
        conn.execute("INSERT INTO settings(key,value) VALUES(?,?)", (MARKER, owner[0]))
        now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        conn.execute(
            "INSERT INTO audit(id,business_id,device_id,created_at,actor_id,actor_name,action,entity_id,details) "
            "VALUES(?,?,?,?,?,?,?,?,?)",
            (str(uuid.uuid4()), business, device, now, "local-maintenance", "Mantenimiento local autorizado",
             "user.owner_reconfiguration_prepared", owner[0], json.dumps({"previousUsername": owner[2], "backup": backup_path.name})),
        )
        if business_fingerprint(conn) != snapshot_fingerprint:
            raise RuntimeError("La verificación detectó un cambio inesperado en los datos del negocio.")
        validate(conn)
        conn.commit()
        return {"prepared": True, "previousUsername": owner[2], "backup": str(backup_path),
                "businessFingerprint": snapshot_fingerprint, "businessDataPreserved": True}
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="Preparar nuevo acceso propietario conservando datos y respaldo.")
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--expected-owner", required=True)
    parser.add_argument("--prepare", action="store_true", help="Confirma la preparación del nuevo propietario.")
    args = parser.parse_args()
    if not args.prepare:
        parser.error("Se requiere --prepare para esta operación de mantenimiento autorizada.")
    with desktop_lock():
        result = prepare_owner_access(args.database, args.expected_owner)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("No se cambió el acceso: " + str(error), file=sys.stderr)
        sys.exit(1)
