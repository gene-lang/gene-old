import os
import unittest
import db_connector/db_postgres

import ../helpers
import gene/types except Exception
import ../src/genex/postgres

# PostgreSQL connection test
# Note: These tests require a running PostgreSQL server
# Set the GENE_TEST_POSTGRES_URL environment variable to run tests
# Example: export GENE_TEST_POSTGRES_URL="host=localhost port=5432 dbname=test user=postgres"

proc getTestConnUrl(): string =
  when defined(postgresTest):
    result = os.getEnv("GENE_TEST_POSTGRES_URL", "host=localhost port=5432 dbname=gene_test user=gene_user password=gene_password")
  else:
    result = os.getEnv("GENE_TEST_POSTGRES_URL", "")

proc setupTestDb(): bool =
  let url = getTestConnUrl()
  if url == "":
    return false

  try:
    let db = db_postgres.open("", "", "", url)
    # Create test table - use raw SQL without parameters
    db.exec(sql"DROP TABLE IF EXISTS test_users")
    db.exec(sql"""
      CREATE TABLE test_users (
        id SERIAL PRIMARY KEY,
        name VARCHAR(50),
        age INTEGER,
        active BOOLEAN
      )
    """)
    # Insert test data - use exec with prepare for parameters
    let stmt = db.prepare("test_insert1", sql"INSERT INTO test_users (name, age, active) VALUES ($1, $2, $3)", 3)
    db.exec(stmt, "John", "30", "t")
    db.exec(stmt, "Alice", "25", "t")
    db.exec(stmt, "Bob", "35", "f")
    db.close()
    return true
  except:
    echo "Warning: PostgreSQL not available or connection failed: ", getCurrentExceptionMsg()
    return false

suite "PostgreSQL stdlib":
  let dbAvailable = setupTestDb()

  init_all_with_extensions()

  if not dbAvailable:
    echo "Skipping PostgreSQL tests (set GENE_TEST_POSTGRES_URL to run)"
  else:
    test_vm """
      (var db (genex/postgres/open "host=localhost port=5432 dbname=gene_test user=gene_user password=gene_password"))
      (db .close)
    """

    test_vm """
      (var db (genex/postgres/open "host=localhost port=5432 dbname=gene_test user=gene_user password=gene_password"))
      (var rows (db .query "SELECT id, name, age, active FROM test_users ORDER BY id"))
      (db .close)
      rows
    """, proc(result: Value) =
      check result.kind == VkArray
      check array_data(result).len == 3
      let row1 = array_data(result)[0]
      check array_data(row1).len == 4
      # id, name, age, active
      check array_data(row1)[1].str == "John"

    test_vm """
      (var db (genex/postgres/open "host=localhost port=5432 dbname=gene_test user=gene_user password=gene_password"))
      (db .exec "INSERT INTO test_users (name, age, active) VALUES ($1, $2, $3)" "TestUser" 40 true)
      (var rows (db .query "SELECT name FROM test_users WHERE name = $1" "TestUser"))
      (db .exec "DELETE FROM test_users WHERE name = $1" "TestUser")
      (db .close)
      rows
    """, proc(result: Value) =
      check result.kind == VkArray
      check array_data(result).len == 1
      check array_data(result)[0].array_data[0].str == "TestUser"

    test_vm """
      (var db (genex/postgres/open "host=localhost port=5432 dbname=gene_test user=gene_user password=gene_password"))
      (db .begin)
      (db .exec "INSERT INTO test_users (name, age, active) VALUES ($1, $2, $3)" "TempUser" 99 true)
      (db .rollback)
      (var rows (db .query "SELECT COUNT(*) FROM test_users WHERE name = $1" "TempUser"))
      (db .close)
      rows
    """, proc(result: Value) =
      # Rollback should have discarded the insert
      check result.kind == VkArray
      check array_data(result).len == 1
      check array_data(result)[0].array_data[0].str == "0"

    test_vm """
      (var db (genex/postgres/open "host=localhost port=5432 dbname=gene_test user=gene_user password=gene_password"))
      (db .begin)
      (db .exec "INSERT INTO test_users (name, age, active) VALUES ($1, $2, $3)" "TempUser2" 88 true)
      (db .commit)
      (var rows (db .query "SELECT COUNT(*) FROM test_users WHERE name = $1" "TempUser2"))
      (db .exec "DELETE FROM test_users WHERE name = $1" "TempUser2")
      (db .close)
      rows
    """, proc(result: Value) =
      # Commit should have persisted the insert
      check result.kind == VkArray
      check array_data(result).len == 1
      check array_data(result)[0].array_data[0].str == "1"

    test_vm """
      (var db (genex/postgres/open "host=localhost port=5432 dbname=gene_test user=gene_user password=gene_password"))
      (db .exec "INSERT INTO test_users (name, age, active) VALUES ($1, $2, $3)" NIL NIL NIL)
      (var rows (db .query "SELECT name, age, active FROM test_users WHERE name IS NULL LIMIT 1"))
      (db .exec "DELETE FROM test_users WHERE name IS NULL")
      (db .close)
      rows
    """, proc(result: Value) =
      check result.kind == VkArray
      check array_data(result).len == 1
      # PostgreSQL db_connector returns NULL as empty string
      check array_data(result)[0].array_data[0].kind == VkString
      check array_data(result)[0].array_data[0].str == ""
