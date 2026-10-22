"""Hold an uncommitted write on a store database until killed.

The killed-process recovery test runs this in a separate OS process (Python's
own SQLite, so no Dart toolchain lock is involved). It commits one preference,
then opens a transaction whose pages spill into the WAL, reports
"in-transaction" and waits to be killed with SIGKILL.
"""

import sqlite3
import sys
import time

connection = sqlite3.connect(sys.argv[1], isolation_level=None)
connection.execute("PRAGMA busy_timeout = 5000")
connection.execute("INSERT INTO preferences (key, value) VALUES ('committed', 'yes')")
# A one-page cache makes SQLite spill the open transaction into the WAL, so
# recovery has uncommitted frames to discard.
connection.execute("PRAGMA cache_size = 1")
connection.execute("BEGIN IMMEDIATE")
connection.execute("INSERT INTO preferences (key, value) VALUES ('uncommitted', 'no')")
for index in range(64):
    connection.execute(
        "INSERT INTO preferences (key, value) VALUES (?, ?)",
        (f"filler-{index}", "x" * 4000),
    )
print("in-transaction", flush=True)
time.sleep(300)
