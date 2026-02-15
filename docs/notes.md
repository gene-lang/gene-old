## LLM App
nimble buildllmamacpp # Build LLM runtime dependencies
nimble buildwithllm # Build Gene with LLM support
cd example-projects/llm_app/backend
CONCURRENT_MODE=true GENE_LLM_MODEL=models/Qwen3-14B-Q4_K_M.gguf gene run src/main.gene

cd example-projects/llm_app/frontend
npm install
npm run dev

open http://localhost:5173

## Major features to add:
* DONE repl on demand
* ^^repl_on_error in fn/method -> wrap function body in try/catch and call repl on error
* DONE exception handling: (throw $ex)
* DONE postgresql client
* redis client for fast caching
* DONE logging
* unit test framework
* hot-reload
* websocket
* DONE (a; b; c) = (((a) b) c)
* (class A (ctor [/p] ...)) (new A 1) => self/p is set to 1
* DONE #@a b = (a b), #@(a b) c = ((a b) c)
* AOP

