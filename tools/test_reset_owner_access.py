"""Exercise maintenance only against disposable SQLite fixtures."""

import sqlite3
from contextlib import closing
import tempfile
from pathlib import Path
import unittest

from reset_owner_access import APPLICATION_ID, MARKER, business_fingerprint, prepare_owner_access


class OwnerMaintenanceTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="capc-access-test-")
        self.addCleanup(self.temporary.cleanup)
        self.path = Path(self.temporary.name) / "capc.sqlite3"
        conn = sqlite3.connect(self.path)
        conn.executescript(f"""
            PRAGMA application_id={APPLICATION_ID};
            PRAGMA user_version=2;
            CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
            INSERT INTO settings VALUES('business_id','business'),('device_id','device'),
                ('password_recovery_hash:owner','old-hash'),('password_recovery_attempts:owner','old-attempts');
            CREATE TABLE users(id TEXT PRIMARY KEY,name TEXT,username TEXT,role TEXT,active INTEGER,
                business_id TEXT,session_version INTEGER,password_hash TEXT);
            INSERT INTO users VALUES('owner','Carlos','capc','owner',1,'business',2,'original-password-hash');
            INSERT INTO users VALUES('cashier','Caja','caja','cashier',1,'business',4,'cashier-password-hash');
            CREATE TABLE sales(id TEXT PRIMARY KEY,actor_id TEXT REFERENCES users(id),total INTEGER);
            INSERT INTO sales VALUES('sale','owner',25000);
            CREATE TABLE products(id TEXT PRIMARY KEY,stock INTEGER);
            INSERT INTO products VALUES('product',9);
            CREATE TABLE audit(id TEXT PRIMARY KEY,business_id TEXT,device_id TEXT,created_at TEXT,
                actor_id TEXT,actor_name TEXT,action TEXT,entity_id TEXT,details TEXT);
        """)
        conn.close()

    def test_preserves_business_and_snapshot_then_rejects_replay(self):
        with closing(sqlite3.connect(self.path)) as conn:
            before = business_fingerprint(conn)
        result = prepare_owner_access(self.path, "CAPC")
        with closing(sqlite3.connect(self.path)) as conn:
            self.assertEqual(before, business_fingerprint(conn))
            self.assertEqual(conn.execute("SELECT value FROM settings WHERE key=?", (MARKER,)).fetchone(), ("owner",))
            self.assertEqual(conn.execute("SELECT session_version FROM users ORDER BY id").fetchall(), [(5,), (3,)])
            self.assertEqual(conn.execute("SELECT password_hash FROM users WHERE id='owner'").fetchone(), ("original-password-hash",))
            self.assertEqual(conn.execute("SELECT count(*) FROM settings WHERE key LIKE 'password_recovery_%'").fetchone()[0], 0)
        with closing(sqlite3.connect(result["backup"])) as backup:
            self.assertEqual(before, business_fingerprint(backup))
            self.assertIsNone(backup.execute("SELECT value FROM settings WHERE key=?", (MARKER,)).fetchone())
            self.assertEqual(backup.execute("SELECT session_version FROM users WHERE id='owner'").fetchone(), (2,))
        with self.assertRaises(ValueError):
            prepare_owner_access(self.path, "capc")
        self.assertEqual(len(list(self.path.parent.glob("respaldos_acceso/*.sqlite3"))), 1)

    def test_wrong_owner_and_audit_failure_never_activate_handover(self):
        with self.assertRaises(ValueError):
            prepare_owner_access(self.path, "caja")
        with closing(sqlite3.connect(self.path)) as conn:
            conn.execute("CREATE TRIGGER fail_audit BEFORE INSERT ON audit BEGIN SELECT RAISE(ABORT,'audit failed'); END")
        with self.assertRaises(sqlite3.IntegrityError):
            prepare_owner_access(self.path, "capc")
        with closing(sqlite3.connect(self.path)) as conn:
            self.assertIsNone(conn.execute("SELECT value FROM settings WHERE key=?", (MARKER,)).fetchone())
            self.assertEqual(conn.execute("SELECT session_version FROM users WHERE id='owner'").fetchone(), (2,))
            self.assertEqual(conn.execute("SELECT value FROM settings WHERE key='password_recovery_hash:owner'").fetchone(), ("old-hash",))


if __name__ == "__main__":
    unittest.main()
