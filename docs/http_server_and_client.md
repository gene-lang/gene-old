# HTTP Server and Client Documentation

## Overview

Gene provides built-in HTTP client and server capabilities through the `genex/http` module. This includes support for making HTTP requests, handling responses, and creating HTTP servers with request handlers.

## HTTP Client

### Working Features ✅

#### 1. Simple HTTP Requests
```gene
# GET request
(var response (await (http_get "http://example.com/api")))
(println "Status:" response/status)
(println "Body:" response/body)

# POST request with data
(var data {^name "Gene" ^version "1.0"})
(var response (await (http_post "http://example.com/api" data)))
```

#### 2. Request/Response Classes
```gene
# Create Request object
(var req (new gene/Request "http://example.com" "GET"))

# Create Response object  
(var resp (new gene/Response 200 "OK"))
(println resp/status resp/body)
```

#### 3. Async/Await Support
All HTTP requests return Futures that can be awaited:
```gene
(var f1 (http_get "http://api1.com"))
(var f2 (http_get "http://api2.com"))
(var r1 (await f1))
(var r2 (await f2))
```

#### 4. JSON Support (Partial)
```gene
# Parse JSON response
(var data (response .json))  # Note: Method dispatch needs work
```

### Client Limitations ❌

1. **Custom Headers**: Setting custom headers needs better API
2. **Request Configuration**: Timeouts, redirects, etc.
3. **File Uploads**: Multipart form data not implemented
4. **Streaming**: Large file downloads/uploads

## HTTP Server

### Working Features ✅

#### 1. Starting a Server
```gene
# Start server on port 8080
(start_server 8080 handler)

# Run event loop
(run_forever)
```

#### 2. Creating Responses
```gene
# Simple text response (200 OK)
(respond "Hello World")

# Status code only
(respond 404)

# Status and body
(respond 200 "Success")

# With headers (planned)
(respond 200 "OK" {^content-type "application/json"})
```

#### 3. Request Object
Server requests have these properties:
- `method` - HTTP method (GET, POST, etc.)
- `path` - Request path
- `url` - Full URL path
- `params` - Query parameters as map
- `headers` - Request headers as map
- `body` - Request body as string

#### 4. Basic Handler (Native Functions Only)
Currently only native functions registered in Gene can work as handlers:
```nim
# In genex/http.nim
proc my_handler(vm: ptr VirtualMachine, args: Value): Value {.gcsafe.} =
  let req = args.gene.children[0]
  # Process request...
  return vm_respond(vm, response_args)
```

### Server Limitations ❌

#### 1. Gene Function Handlers
**Problem**: Can't execute Gene functions from async native context
```gene
# This doesn't work yet:
(fn my_handler [req]
  (respond "Hello"))
(start_server 8080 my_handler)  # ❌ Can't call Gene function
```

#### 2. Instance Method Dispatch
**Problem**: Can't call instance methods properly
```gene
(class Router
  (method call req
    (respond "Hello")))
(var router (new Router))
(start_server 8080 router)  # ❌ Can't dispatch to router.call
```

#### 3. Middleware/Function Composition
**Problem**: Can't create and chain function wrappers
```gene
(fn auth [handler]
  (fn [req]
    (if authenticated
      (handler req)
      (respond 401))))
```

#### 4. Missing Helper Functions
- `gene/base64_encode` / `gene/base64_decode`
- Cookie handling
- Session management
- Static file serving

#### 5. String Interpolation
```gene
#"Hello #{name}!"  # Not implemented
```

## Implementation Plan

### Phase 1: VM Execution Bridge 🚧 PARTIALLY COMPLETE
Create ability to call Gene functions from native async context:

**Status**: Infrastructure added but Gene functions still can't execute properly from async context.

**Implemented**:
- Queue-based handler system with HandlerRequest type
- Global handler and VM storage
- Process queue function that polls for requests  
- Execute_gene_function for native functions, classes, instances
- Updated start_server to detect handler type
- Modified run_forever to poll queue periodically

**Still Needed**:
- Proper VM frame creation and execution for Gene functions
- Context switching between async and VM execution
- State preservation during async/VM transitions

**Current Limitation**: Gene functions return NIL when called as handlers due to complexity of VM frame execution from async context.

### Phase 2: Base64 Support ✅ COMPLETED
Add base64 encoding/decoding functions:
```gene
(gene/base64_encode "Hello")  # → "SGVsbG8="
(gene/base64_decode "SGVsbG8=")  # → "Hello"
```

**Status**: ✅ Implemented and tested
- Functions added to `gene` namespace
- Available as `gene/base64_encode` and `gene/base64_decode`
- Works with authentication example

### Phase 3: String Interpolation ✅ COMPLETED
Implement string interpolation syntax:
```gene
(var name "World")
#"Hello #{name}!"  # → "Hello World!"
```

**Status**: ✅ Fully implemented and tested
- Parser already supported #"..." syntax
- Added vm_str_interpolation function to handle #Str calls
- Registered #Str in global namespace
- Works with variables, expressions, and all basic types

### Phase 4: Method Dispatch Fix 🔧
Fix instance method calls:
```gene
(router .call req)  # Should work
(router req)        # Should call .call method if it exists
```

### Phase 5: Complete Examples 🎯
Get `http_server.gene` fully working with:
- Class-based app structure
- Middleware support
- Routing
- Authentication

## Testing

### Current Test Status

✅ **Working**:
- Basic server starts
- Responds with 404 for nil handler
- Response creation
- Client requests (GET, POST)

❌ **Not Working**:
- Gene function handlers
- Class-based routing
- Middleware chains
- Full http_server.gene example

## Usage Examples

### Simple Working Server (Native Handler)
```gene
# Currently requires native function handler
(start_server 8080 nil)  # All requests return 404
(run_forever)
```

### Client Example (Working)
```gene
(var response (await (http_get "http://httpbin.org/get")))
(println "Status:" response/status)
```

## Implementation Status Summary

### ✅ Completed Features:
1. **Base64 Support**: Fully implemented (`gene/base64_encode`, `gene/base64_decode`)
2. **String Interpolation**: Working with `#"...#{expr}..."` syntax
3. **Method Dispatch**: Instance `call` methods are invoked when instance is used as function
4. **HTTP Client**: All client functions working (GET, POST, PUT, DELETE)
5. **HTTP Server Infrastructure**: Server starts, handles requests, returns responses
6. **VM Coroutine Support**: VM refactored to use `self.pc` for re-entrant execution
7. **Gene Function Handlers**: Gene functions can now be used as HTTP handlers! ✅
8. **VkComplexSymbol Parsing**: Fixed parsing of `/property` syntax in matchers
9. **Constructor Scope**: Fixed scope initialization for class constructors
10. **Array Methods**: Implemented `add` and `size` methods for arrays
11. **Array Method Dispatch**: Added array method handling in VM's IkCallMethod1
12. **HTTP Server Startup**: The http_server.gene example now starts successfully!

### ✅ VM Refactoring Complete:
The VM has been successfully refactored to support coroutine-style execution:
1. **exec() loop**: Now uses `self.pc` instead of local `pc` variable
2. **exec_continue()**: Added for re-entrant execution
3. **exec_function()**: Updated to properly save/restore VM state
4. **Gene functions as handlers**: Working! Can execute Gene functions from async HTTP context

### ⚠️ Remaining Work:
1. **Method Argument Passing Bug**: Methods receive incorrect argument values
   - All method arguments after `self` become 0.0 (float) regardless of input
   - This affects all method calls like `(obj .method arg)`
   - Root cause: Method dispatch isn't correctly passing arguments to the function
   - **FIXED**: Function argument syntax was corrected from `(fn name a b)` to `(fn name [a b])`
2. **Full http_server.gene Example**: Server starts but crashes due to method argument bug
3. **Middleware chains**: Need testing once method calls work
4. **Authentication**: Requires working middleware support

### Technical Solution Path:
To enable Gene functions as HTTP handlers, the VM needs refactoring:
1. Change `exec()` to use `self.pc` instead of local `pc` variable
2. Make the execution loop re-entrant (can pause and resume)
3. Create `exec_continue()` method that continues from current PC
4. Then `exec_function()` can work by setting up state and calling `exec_continue()`

This is architecturally feasible - the VM already preserves all necessary state,
it just needs the execution loop to be refactored for re-entrancy.

## Next Steps

1. **Priority 1**: Fix VM execution context switching for Gene functions in async handlers
2. **Priority 2**: Complete middleware support once Gene functions work
3. **Priority 3**: Test and fix the complete http_server.gene example

## Technical Notes

### Architecture
- Client uses `httpclient` from Nim std lib
- Server uses `asynchttpserver` from Nim std lib
- Request/Response objects are Gene instances
- Futures are used for async operations

### Files
- `src/genex/http.nim` - Main implementation
- `examples/http_server.gene` - Server example (not fully working)
- `examples/http_examples.gene` - Client examples (working)

### Known Issues
1. Port number display issue (integer overflow in some cases)
2. Gene function execution context not available in async handlers
3. Method dispatch incomplete for instances
4. String interpolation not implemented
5. Base64 functions missing
