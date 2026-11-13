// External scanners for tree-sitter grammars whose SwiftPM manifests omit them; this target exposes no API.
// The grammar packages' parser.c files reference these scanner symbols, which resolve at link time.
