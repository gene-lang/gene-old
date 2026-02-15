#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_DIR="$ROOT_DIR/tools/llama.cpp"
BUILD_DIR="$ROOT_DIR/build/llama"
SHIM_SRC="$ROOT_DIR/src/genex/llm/shim/gene_llm.cpp"
SERVER_DEFAULT_PARALLEL="${GENE_LLAMA_SERVER_PARALLEL:-4}"
BUILD_SERVER="${GENE_LLAMA_BUILD_SERVER:-1}"

# Auto-detect Apple Silicon and enable Metal support
ARCH="$(uname -m)"
if [ "$ARCH" = "arm64" ]; then
  echo "🍎 Detected Apple Silicon ($ARCH), enabling Metal acceleration"
  export GENE_LLAMA_METAL=1
  # For Apple Silicon, ensure we're using the right architecture
  CMAKE_ARCH_FLAGS="-DCMAKE_OSX_ARCHITECTURES=arm64"
else
  echo "💻 Detected Intel/Other architecture ($ARCH)"
  CMAKE_ARCH_FLAGS=""
fi

# Initialize submodule if missing
if [ ! -d "$LLAMA_DIR" ] || [ -z "$(ls -A "$LLAMA_DIR" 2>/dev/null)" ]; then
  echo "📦 Initializing llama.cpp submodule..."
  cd "$ROOT_DIR"
  git submodule update --init --recursive tools/llama.cpp
  cd "$ROOT_DIR/tools"
fi

mkdir -p "$BUILD_DIR"

declare -a EXTRA_CMAKE_FLAGS=()
if [ "${GENE_LLAMA_METAL:-0}" = "1" ]; then
  EXTRA_CMAKE_FLAGS+=("-DGGML_METAL=ON")
  echo "⚡ Metal acceleration enabled"
fi
if [ "${GENE_LLAMA_CUDA:-0}" = "1" ]; then
  EXTRA_CMAKE_FLAGS+=("-DGGML_CUDA=ON")
  echo "🚀 CUDA acceleration enabled"
fi

if [ "$BUILD_SERVER" = "1" ]; then
  echo "🌐 llama-server build enabled (parallel slots default: $SERVER_DEFAULT_PARALLEL)"
else
  echo "📚 Building runtime libraries only (set GENE_LLAMA_BUILD_SERVER=1 to also build llama-server)"
fi

cmake_args=(
  -S "$LLAMA_DIR"
  -B "$BUILD_DIR"
  -DCMAKE_BUILD_TYPE=Release
  -DBUILD_SHARED_LIBS=OFF
  -DLLAMA_BUILD_COMMON=ON
  -DLLAMA_BUILD_TESTS=OFF
  -DLLAMA_BUILD_TOOLS="$BUILD_SERVER"
  -DLLAMA_BUILD_EXAMPLES=OFF
  -DLLAMA_BUILD_SERVER="$BUILD_SERVER"
  -DLLAMA_CURL=OFF
  -DLLAMA_BUILD_STANDALONE=OFF
  -DLLAMA_ALL_WARNINGS=OFF
)
if [ ${#EXTRA_CMAKE_FLAGS[@]} -gt 0 ]; then
  cmake_args+=("${EXTRA_CMAKE_FLAGS[@]}")
fi
if [ -n "$CMAKE_ARCH_FLAGS" ]; then
  cmake_args+=($CMAKE_ARCH_FLAGS)
fi

echo "🔧 Configuring llama.cpp with: ${cmake_args[*]}"
cmake "${cmake_args[@]}"

echo "🏗️  Building llama.cpp library..."
JOBS="$(sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
cmake --build "$BUILD_DIR" --target llama --config Release -j"$JOBS"

if [ "$BUILD_SERVER" = "1" ]; then
  echo "🌐 Building llama-server..."
  cmake --build "$BUILD_DIR" --target llama-server --config Release -j"$JOBS"
fi

# Find the built library location
if [ -f "$BUILD_DIR/src/libllama.a" ]; then
  cp "$BUILD_DIR/src/libllama.a" "$BUILD_DIR/libllama.a"
  echo "✅ Found libllama.a in src/"
elif [ -f "$BUILD_DIR/libllama.a" ]; then
  echo "✅ Found libllama.a in build root"
else
  echo "❌ Could not find libllama.a after build"
  ls -la "$BUILD_DIR"
  find "$BUILD_DIR" -name "*.a" -type f
  exit 1
fi

echo "🔗 Building Gene LLM shim..."
clang++ -std=c++17 -O3 -fPIC \
  -I"$LLAMA_DIR/include" \
  -I"$LLAMA_DIR/ggml/include" \
  -I"$LLAMA_DIR" \
  -c "$SHIM_SRC" -o "$BUILD_DIR/gene_llm.o"

ar rcs "$BUILD_DIR/libgene_llm.a" "$BUILD_DIR/gene_llm.o"

echo "✅ Llama runtime built successfully at $BUILD_DIR"
echo "📁 Libraries: libllama.a $(ls -la "$BUILD_DIR/libllama.a" | awk '{print $5}' | numfmt --to=iec)"
echo "📁 Shim: libgene_llm.a $(ls -la "$BUILD_DIR/libgene_llm.a" | awk '{print $5}' | numfmt --to=iec)"

if [ "$BUILD_SERVER" = "1" ]; then
  SERVER_BIN="$BUILD_DIR/bin/llama-server"
  if [ ! -x "$SERVER_BIN" ] && [ -x "$BUILD_DIR/bin/Release/llama-server" ]; then
    SERVER_BIN="$BUILD_DIR/bin/Release/llama-server"
  fi

  if [ -x "$SERVER_BIN" ]; then
    LAUNCHER="$BUILD_DIR/run_llama_server.sh"
    cat > "$LAUNCHER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SERVER_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/llama-server"
if [ ! -x "$SERVER_BIN" ] && [ -x "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/Release/llama-server" ]; then
  SERVER_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/bin/Release/llama-server"
fi

MODEL_PATH="${1:-${GENE_LLM_MODEL:-}}"
if [ -z "$MODEL_PATH" ]; then
  echo "Usage: $0 <model.gguf> [extra llama-server args...]"
  echo "Or set GENE_LLM_MODEL and run without positional args."
  exit 1
fi

PARALLEL="${GENE_LLAMA_SERVER_PARALLEL:-4}"
PORT="${GENE_LLAMA_SERVER_PORT:-8080}"
CTX="${GENE_LLAMA_SERVER_CTX:-8192}"
shift || true

exec "$SERVER_BIN" \
  -m "$MODEL_PATH" \
  -c "$CTX" \
  --parallel "$PARALLEL" \
  --cont-batching \
  --port "$PORT" \
  "$@"
EOF
    chmod +x "$LAUNCHER"
    echo "📁 Server: $SERVER_BIN"
    echo "🚦 Launcher: $LAUNCHER (defaults: --parallel ${SERVER_DEFAULT_PARALLEL} --cont-batching)"
  else
    echo "⚠️  llama-server target built, but binary was not found under $BUILD_DIR/bin"
  fi
fi
