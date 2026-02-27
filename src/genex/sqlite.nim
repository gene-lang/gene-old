{.push warning[ResultShadowed]: off.}
import db_connector/db_sqlite
import db_connector/sqlite3 as sqlite3mod
import std/locks
import ./db

# For static linking, don't include boilerplate to avoid duplicate set_globals
when defined(noExtensions):
  include ../gene/extension/boilerplate
else:
  # Statically linked - just import types directly
  import ../gene/types

# Global Connection class
var connection_class_global: Class

# Custom wrapper for SQLite connection
type
  SQLiteConnection* = ref object of DatabaseConnection
    conn*: DbConn
    lock*: Lock

# Global table to store connections by ID (shared across worker threads)
var connection_table: Table[system.int64, SQLiteConnection]
var next_conn_id: system.int64
var connection_lock: Lock
initLock(connection_lock)

# Convert Gene Value to SQLite parameter
proc bind_gene_param(stmt: SqlPrepared, idx: int, value: Value) =
  case value.kind
  of VkNil:
    stmt.bindNull(idx)
  of VkBool:
    stmt.bindParam(idx, if value.to_bool: 1 else: 0)
  of VkInt:
    stmt.bindParam(idx, value.int64)
  of VkFloat:
    stmt.bindParam(idx, value.float)
  of VkString:
    stmt.bindParam(idx, value.str)
  else:
    stmt.bindParam(idx, $value)

# Bind multiple parameters to a prepared statement
proc bind_gene_params(stmt: SqlPrepared, params: seq[Value]) =
  for i, param in params:
    bind_gene_param(stmt, i + 1, param)

# Finalize a prepared statement
proc finalize_stmt(stmt: SqlPrepared) =
  discard sqlite3mod.finalize(stmt.PStmt)

# Open a database connection
proc vm_open(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 1:
    raise new_exception(types.Exception, "open requires a database path")

  let db_path_arg = get_positional_arg(args, 0, has_keyword_args)
  if db_path_arg.kind != VkString:
    raise new_exception(types.Exception, "database path must be a string")

  let db_path = db_path_arg.str

  # Open the database
  var conn: DbConn
  try:
    conn = open(db_path, "", "", "")
  except:
    raise new_exception(types.Exception, "Failed to open database: " & getCurrentExceptionMsg())

  # Create wrapper
  var wrapper = SQLiteConnection(conn: conn, closed: false)
  initLock(wrapper.lock)

  # Store in global table
  var conn_id: system.int64
  {.cast(gcsafe).}:
    withLock(connection_lock):
      conn_id = next_conn_id
      next_conn_id += 1
      connection_table[conn_id] = wrapper

  # Create Connection instance
  let conn_class = block:
    {.cast(gcsafe).}:
      (if connection_class_global != nil: connection_class_global else: new_class("Connection"))
  let instance = new_instance_value(conn_class)

  # Store the connection ID
  instance_props(instance)["__conn_id__".to_key()] = conn_id.to_value()

  return instance

# Execute a SQL query and return results (SELECT)
proc vm_query(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 2:
    raise new_exception(types.Exception, "query requires self and SQL statement")

  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkInstance:
    raise new_exception(types.Exception, "query must be called on a Connection instance")

  let conn_id_key = "__conn_id__".to_key()
  if not instance_props(self).hasKey(conn_id_key):
    raise new_exception(types.Exception, "Invalid Connection instance")

  let conn_id = instance_props(self)[conn_id_key].to_int()

  let sql_arg = get_positional_arg(args, 1, has_keyword_args)
  if sql_arg.kind != VkString:
    raise new_exception(types.Exception, "SQL statement must be a string")

  let stmt_text = sql_arg.str
  let params = collect_params(args, arg_count, has_keyword_args, 2)

  var wrapper: SQLiteConnection
  {.cast(gcsafe).}:
    withLock(connection_lock):
      if not connection_table.hasKey(conn_id):
        raise new_exception(types.Exception, "Connection not found")
      wrapper = connection_table[conn_id]

  var result = new_array_value(@[])
  {.cast(gcsafe).}:
    withLock(wrapper.lock):
      if wrapper.closed:
        raise new_exception(types.Exception, "Connection is closed")

      let prepared = wrapper.conn.prepare(stmt_text)
      try:
        bind_gene_params(prepared, params)
        for row in wrapper.conn.instantRows(prepared):
          let column_count = row.len.int
          var row_array = new_array_value(@[])
          for col in 0..<column_count:
            array_data(row_array).add(row[int32(col)].to_value())
          array_data(result).add(row_array)
      except DbError as e:
        raise new_exception(types.Exception, "SQL execution failed: " & e.msg)
      finally:
        finalize_stmt(prepared)

  return result

# Execute a SQL statement without returning results (INSERT, UPDATE, DELETE)
proc vm_exec(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 2:
    raise new_exception(types.Exception, "exec requires self and SQL statement")

  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkInstance:
    raise new_exception(types.Exception, "exec must be called on a Connection instance")

  let conn_id_key = "__conn_id__".to_key()
  if not instance_props(self).hasKey(conn_id_key):
    raise new_exception(types.Exception, "Invalid Connection instance")

  let conn_id = instance_props(self)[conn_id_key].to_int()

  let sql_arg = get_positional_arg(args, 1, has_keyword_args)
  if sql_arg.kind != VkString:
    raise new_exception(types.Exception, "SQL statement must be a string")

  let stmt_text = sql_arg.str
  let params = collect_params(args, arg_count, has_keyword_args, 2)

  var wrapper: SQLiteConnection
  {.cast(gcsafe).}:
    withLock(connection_lock):
      if not connection_table.hasKey(conn_id):
        raise new_exception(types.Exception, "Connection not found")
      wrapper = connection_table[conn_id]

    withLock(wrapper.lock):
      if wrapper.closed:
        raise new_exception(types.Exception, "Connection is closed")

      let prepared = wrapper.conn.prepare(stmt_text)
      bind_gene_params(prepared, params)

      try:
        var rc = sqlite3mod.step(prepared.PStmt)
        while rc == sqlite3mod.SQLITE_ROW:
          rc = sqlite3mod.step(prepared.PStmt)
        if rc != sqlite3mod.SQLITE_DONE:
          let err = $sqlite3mod.errmsg(wrapper.conn)
          raise new_exception(types.Exception, "SQL execution failed: " & err)
      except DbError as e:
        raise new_exception(types.Exception, "SQL execution failed: " & e.msg)
      finally:
        finalize_stmt(prepared)

  return NIL

# Close the database connection
proc vm_close(vm: ptr VirtualMachine, args: ptr UncheckedArray[Value], arg_count: int, has_keyword_args: bool): Value {.gcsafe.} =
  if arg_count < 1:
    raise new_exception(types.Exception, "close requires self")

  let self = get_positional_arg(args, 0, has_keyword_args)
  if self.kind != VkInstance:
    raise new_exception(types.Exception, "close must be called on a Connection instance")

  # Get the wrapper
  let conn_id_key = "__conn_id__".to_key()
  if not instance_props(self).hasKey(conn_id_key):
    raise new_exception(types.Exception, "Invalid Connection instance")

  let conn_id = instance_props(self)[conn_id_key].to_int()

  var wrapper: SQLiteConnection
  {.cast(gcsafe).}:
    withLock(connection_lock):
      if not connection_table.hasKey(conn_id):
        raise new_exception(types.Exception, "Connection not found")
      wrapper = connection_table[conn_id]

    withLock(wrapper.lock):
      if not wrapper.closed:
        try:
          db_sqlite.close(wrapper.conn)
          wrapper.closed = true
        except:
          raise new_exception(types.Exception, "Failed to close connection: " & getCurrentExceptionMsg())

  return NIL

# Initialize SQLite classes and functions
proc init_sqlite_classes*() =
  # Initialize connection table
  connection_table = initTable[system.int64, SQLiteConnection]()
  next_conn_id = 1

  VmCreatedCallbacks.add proc() =
    # Ensure App is initialized
    if App == NIL or App.kind != VkApplication:
      return

    # Create Connection class
    {.cast(gcsafe).}:
      connection_class_global = new_class("Connection")
      connection_class_global.def_native_method("query", vm_query)
      connection_class_global.def_native_method("exec", vm_exec)
      connection_class_global.def_native_method("close", vm_close)

    # Store class in gene namespace
    let connection_class_ref = new_ref(VkClass)
    {.cast(gcsafe).}:
      connection_class_ref.class = connection_class_global

    if App.app.genex_ns.kind == VkNamespace:
      # Create a sqlite namespace under genex
      let sqlite_ns = new_ref(VkNamespace)
      sqlite_ns.ns = new_namespace("sqlite")

      # Add open function
      let open_fn = new_ref(VkNativeFn)
      open_fn.native_fn = vm_open
      sqlite_ns.ns["open".to_key()] = open_fn.to_ref_value()

      # Add Connection class to sqlite namespace
      sqlite_ns.ns["Connection".to_key()] = connection_class_ref.to_ref_value()

      # Attach to genex namespace
      App.app.genex_ns.ref.ns["sqlite".to_key()] = sqlite_ns.to_ref_value()

# Call init function
init_sqlite_classes()

{.pop.}
