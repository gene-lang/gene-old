import os
import db_connector/db_sqlite
import unittest

import ../helpers
import gene/types except Exception

const dbFile = "/tmp/gene-test.db"

proc recreate_db() =
  if fileExists(dbFile):
    removeFile(dbFile)
  let db = open(dbFile, "", "", "")
  db.exec(sql"DROP TABLE IF EXISTS table_a")
  db.exec(sql"""
    CREATE TABLE table_a (
      id   INTEGER,
      name VARCHAR(50) NOT NULL
    )
  """)
  db.exec(sql"""
    INSERT INTO table_a (id, name)
    VALUES (1, 'John'),
           (2, 'Mark')
  """)
  db.close()

suite "SQLite stdlib":
  recreate_db()
  init_all_with_extensions()

  test_vm """
    (var db (genex/sqlite/open "/tmp/gene-test.db"))
    (db .close)
  """

test_vm """
  (var db (genex/sqlite/open "/tmp/gene-test.db"))
  (var rows (db .query "select * from table_a order by id"))
  (db .close)
  rows
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 2
  let row1 = array_data(result)[0]
  let row2 = array_data(result)[1]
  check array_data(row1).len == 2
  check array_data(row1)[0].str == "1"
  check array_data(row1)[1].str == "John"
  check array_data(row2)[0].str == "2"
  check array_data(row2)[1].str == "Mark"

test_vm """
  (var db (genex/sqlite/open "/tmp/gene-test.db"))
  (db .exec "insert into table_a (id, name) values (?, ?)" 3 "Alice")
  (var rows (db .query "select name from table_a where id = ?" 3))
  (db .close)
  rows
""", proc(result: Value) =
  check result.kind == VkArray
  check array_data(result).len == 1
  let row1 = array_data(result)[0]
  check array_data(row1).len == 1
  check array_data(row1)[0].str == "Alice"
