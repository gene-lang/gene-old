## Main module for genex/ai provider wrappers
## Exports OpenAI/Anthropic functionality to Gene

import ../../gene/logging_core
import bindings, openai_client, anthropic_client, streaming
import documents, vectordb, conversation, tools, rag, utils, control_slack, agent_runtime, scheduler, provider_router, slack_ingress, slack_socket_mode, memory_store, workspace_policy

const GenexAiLogger = "genex/ai"

template genex_ai_log(level: LogLevel, message: untyped) =
  if log_enabled(level, GenexAiLogger):
    log_message(level, GenexAiLogger, message)

# Export the native functions that will be registered with the VM
export vm_openai_new_client
export vm_openai_chat
export vm_openai_embeddings
export vm_openai_respond
export vm_openai_stream
export vm_anthropic_new_client
export vm_anthropic_messages

# Export types and utilities
export OpenAIConfig, OpenAIError, StreamingChunk, StreamEvent
export AnthropicConfig, AnthropicError
export buildOpenAIConfig, geneValueToJson, jsonToGeneValue
export buildChatPayload, buildEmbeddingsPayload, buildResponsesPayload
export buildAnthropicConfig, buildAnthropicMessagesPayload, isAnthropicOAuthToken
export redactSecret, getEnvVar
export documents
export vectordb, conversation, tools, rag, utils, control_slack, agent_runtime, scheduler, provider_router, slack_ingress, slack_socket_mode, memory_store, workspace_policy

# Module initialization function
proc init_ai_module*() =
  # This will be called from the VM initialization
  # Register all native functions here
  discard

when isMainModule:
  # Test the module directly if run as a script
  genex_ai_log(LlDebug, "OpenAI API module loaded successfully")
