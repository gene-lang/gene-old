# begin Nimble config (version 2)
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

let geneProfile = getEnv("GENE_PROFILE", "native")

case geneProfile
of "native", "":
  switch("define", "gene_native")
of "wasm-wasi":
  switch("define", "gene_wasm")
  switch("define", "gene_wasm_wasi")
  switch("threads", "off")
of "wasm-emscripten":
  switch("define", "gene_wasm")
  switch("define", "gene_wasm_emscripten")
  switch("threads", "off")
else:
  echo "Unknown GENE_PROFILE='" & geneProfile & "', falling back to native profile"
  switch("define", "gene_native")
