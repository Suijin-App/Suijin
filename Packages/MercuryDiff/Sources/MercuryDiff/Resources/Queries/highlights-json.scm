; Vendored from tree-sitter-json @ 0.24.8 (queries/highlights.scm). Upstream license: MIT. Do not edit; re-copy when the grammar pin changes.
(pair
  key: (_) @string.special.key)

(string) @string

(number) @number

[
  (null)
  (true)
  (false)
] @constant.builtin

(escape_sequence) @escape

(comment) @comment
