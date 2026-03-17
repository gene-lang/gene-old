## GeneClaw

cd example-projects/geneclaw
source .env
GENE_AI_DEBUG=1 gene run --no-gir-cache src/main.gene

curl -s 'http://localhost:4090/api/config?path=llm/openai' | gene format

## LLM App
nimble buildllmamacpp # Build LLM runtime dependencies
nimble buildwithllm # Build Gene with LLM support
cd example-projects/llm_app/backend
CONCURRENT_MODE=true GENE_LLM_MODEL=models/Qwen3-14B-Q4_K_M.gguf gene run src/main.gene
GENE_LLM_MODEL=$HOME/gene-workspace/gene-old/tmp/models/Qwen3-14B-Q4_K_M.gguf gene run src/main.gene
GENE_LLM_MODEL=$HOME/gene-workspace/gene-old/tmp/models/Qwen3.5-27B-Q4_K_M.gguf gene run src/main.gene

cd example-projects/llm_app/frontend
npm install
npm run dev

### Anthropic OAuth
ANTHROPIC_AUTH_TOKEN='sk-ant-oat01-REPLACE_ME'

curl -N -sS \
  -D /tmp/anthropic.headers \
  -o /tmp/anthropic.body \
  -w '\nHTTP %{http_code}\n' \
  https://api.anthropic.com/v1/messages \
  -H 'content-type: application/json' \
  -H 'accept: application/json' \
  -H 'anthropic-version: 2023-06-01' \
  -H 'anthropic-dangerous-direct-browser-access: true' \
  -H 'anthropic-beta: claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14,interleaved-thinking-2025-05-14' \
  -H 'user-agent: claude-cli/2.1.75' \
  -H 'x-app: cli' \
  -H "authorization: Bearer $ANTHROPIC_AUTH_TOKEN" \
  --data-binary @- <<'JSON'
{
  "model": "claude-sonnet-4-6",
  "max_tokens": 32,
  "stream": true,
  "system": [
    {
      "type": "text",
      "text": "You are Claude Code, Anthropic's official CLI for Claude."
    }
  ],
  "messages": [
    {
      "role": "user",
      "content": "Reply with OK."
    }
  ]
}
JSON

cat /tmp/anthropic.body

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

