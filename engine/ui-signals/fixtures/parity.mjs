import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {decodeBatch, initialState} from "../../../benchmarks/bench-wasm/driver.mjs";

const [path, native] = process.argv.slice(2);
const module = await WebAssembly.compile(await readFile(path));
assert.deepEqual(WebAssembly.Module.imports(module), []);
const {exports:guest} = await WebAssembly.instantiate(module);
const size = guest.signal_trace();
const offset = guest.signal_trace_ptr();
const actual = Buffer.from(new Uint8Array(guest.memory.buffer, offset, size));
assert.deepEqual(actual, await readFile(native));
assert.deepEqual([...actual.subarray(0, 4)], [1, 6, 0, 5]);
const firstSize = actual.readUInt32LE(12);
const one = decodeBatch(guest.memory, offset + 4, firstSize, initialState(47));
const two = decodeBatch(guest.memory, offset + 4 + firstSize, size - 4 - firstSize, one.state);
assert.deepEqual([one.operations[0].text, two.operations[0].text], ["6", "-22"]);
console.log(`Verified ${size} identical native and wasm32 status and FLNT bytes`);
