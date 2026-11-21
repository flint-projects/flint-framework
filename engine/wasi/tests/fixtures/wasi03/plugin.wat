(module
  (import "wasi:random/insecure@0.3.0" "get-insecure-random-u64" (func $random (result i64)))
  (func (export "answer") (result i32) call $random drop i32.const 42)
  (func (export "add") (param i32 i32) (result i32) local.get 0 local.get 1 i32.add))
