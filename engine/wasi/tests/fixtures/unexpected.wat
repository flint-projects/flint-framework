(module
  (import "unknown" "answer" (func $host (result i32)))
  (func (export "answer") (result i32) call $host))
