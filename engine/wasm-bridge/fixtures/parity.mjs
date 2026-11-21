import assert from "node:assert/strict";
import {readFile} from "node:fs/promises";
import {decodeBatch, initialState, Status} from "../../../benchmarks/bench-wasm/driver.mjs";

const [binary, native] = process.argv.slice(2);
const {instance} = await WebAssembly.instantiate(await readFile(binary), {});
const guest = instance.exports;
const count = guest.fixture_write();
assert(count > 0);
const pointer = guest.fixture_ptr();
const firstMemory = guest.memory.buffer;
const frame = Buffer.from(new Uint8Array(firstMemory, pointer, count));
assert.deepEqual(frame, await readFile(native));
const initial = decodeBatch(guest.memory, pointer, count, initialState(19), {canvas:true});
assert.equal(initial.operations.length, 7);
assert.equal(initial.operations[1].text, "<script id='fixture'>ignored</script> 🦊");
assert.deepEqual([initial.operations[5].x, initial.operations[5].y], [299, 149]);
guest.memory.grow(1);
assert.equal(firstMemory.byteLength, 0);
assert.deepEqual(decodeBatch(guest.memory, pointer, count, initialState(19), {canvas:true}), initial);

function fields(...words) {
    const buffer = Buffer.alloc(words.length * 4);
    words.forEach((value, index) => buffer.writeUInt32LE(value >>> 0, index * 4));
    return buffer;
}

function record(opcode, index, generation, value = Buffer.alloc(0), extra = 0) {
    const size = (16 + value.length + 7) & ~7;
    const frame = Buffer.alloc(size + extra);
    frame.writeUInt16LE(opcode, 0);
    fields(size + extra, index, generation).copy(frame, 4);
    value.copy(frame, 16);
    return frame;
}

function batch(epoch, sequence, ...commands) {
    const payload = Buffer.concat(commands);
    return Buffer.concat([fields(0x544e4c46, 1, payload.length + 32, commands.length, sequence, epoch, 0, 0), payload]);
}

function decode(batch, state = initialState(19), capabilities = {canvas:true, webgpu:true}) {
    const memory = new WebAssembly.Memory({initial:Math.ceil(batch.length / 65536)});
    new Uint8Array(memory.buffer).set(batch);
    return decodeBatch(memory, 0, batch.length, state, capabilities);
}

const text = (value, index = 0, generation = 1) =>
    record(2, index, generation, Buffer.concat([fields(value.length), Buffer.from(value)]));
const build = (index, tag = 1, generation = 1) => record(1, index, generation, fields(tag));
const attach = (parent, child) => record(4, parent, 1, fields(child, 1));
const root = initialState(19);
const next = decode(batch(19, 0xffffffff, text(Buffer.from("0"))));
const wrapped = decode(batch(19, 0), next.state);
assert.equal(wrapped.sequence, 0);
for (const sequence of [0, 0xffffffff, 0x80000000]) {
    assert.throws(() => decode(batch(19, sequence), wrapped.state), /replayed/);
}
for (const epoch of [0, 18, 20]) {
    assert.throws(() => decode(batch(epoch, 1, build(1)), wrapped.state), /epoch/);
}

const removed = decode(batch(19, 0, build(1), build(2), attach(1, 2), attach(0, 1), record(5, 1, 1)));
assert.equal(removed.state.nodes.size, 1);
assert.throws(() => decode(batch(19, 1, build(2)), removed.state), /retired/);
assert.equal(decode(batch(19, 1, build(2, 1, 2)), removed.state).state.nodes.get(2).generation, 2);
assert.throws(() => decode(batch(19, 0, build(1), build(1))), /duplicate/);
assert.throws(() => decode(batch(19, 0, build(65536))), /handle/);
assert.throws(() => decode(batch(19, 0, build(1), attach(1, 9))), /stale/);
assert.throws(() => decode(batch(19, 0, build(1), build(2), attach(0, 1), attach(2, 1))), /leaves mount/);

const tree = Array.from({length:66}, (_, i) => build(i + 1));
for (let leaf = 2; leaf <= 65; ++leaf) tree.push(attach(leaf - 1, leaf));
const detached = decode(batch(19, 0, ...tree));
assert.equal(detached.state.nodes.get(65).parent, 64);
assert.throws(() => decode(batch(19, 1, attach(66, 1)), detached.state), /depth/);
assert.equal(detached.state.nodes.get(1).parent, null);

const canvas = build(1, 5);
const rectangle = (x, y, width, height) => record(6, 1, 1, fields(1, x, y, width, height, 0xff0000ff));
assert.equal(decode(batch(19, 0, canvas, rectangle(300, 150, 0, 0))).operations.length, 2);
assert.throws(() => decode(batch(19, 0, canvas, rectangle(300, 150, 1, 0))), /bounds/);
const gpu = record(7, 1, 1, fields(1, 0x3f800000, 0, 0, 0x3f800000));
assert.equal(decode(batch(19, 0, canvas, gpu)).operations.length, 2);
assert.throws(() => decode(batch(19, 0, canvas, gpu), root, {}), {status:Status.unsupported});
const nan = record(7, 1, 1, fields(1, 0x7fc00000, 0, 0, 0));
assert.throws(() => decode(batch(19, 0, canvas, nan)), /color/);

assert.throws(() => decode(batch(19, 0, text([0xed, 0xa0, 0x80]))), {status:Status.invalidArgument});
assert.equal(decode(batch(19, 0, text(Buffer.alloc(65536, 97)))).operations[0].text.length, 65536);
assert.throws(() => decode(batch(19, 0, text(Buffer.alloc(65537, 97)))), /length/);
const one = text(Buffer.from("x"));
assert.equal(decode(batch(19, 0, ...Array(4096).fill(one))).operations.length, 4096);
assert.throws(() => decode(batch(19, 0, ...Array(4097).fill(one))), /command limit/);
assert.throws(() => decode(batch(19, 0, record(65535, 0, 1))), /unknown opcode/);
assert.throws(() => decode(batch(19, 0, record(2, 0, 1, fields(0), 8))), /padding size/);

for (let length = 0; length < frame.length; ++length) {
    assert.throws(() => decode(frame.subarray(0, length)));
}
for (const length of [0, 1, 15, 17, 0x80000000, 0xffffffff]) {
    const broken = Buffer.from(frame);
    broken.writeUInt32LE(length, 36);
    assert.throws(() => decode(broken));
}
console.log(`FLNT parity: ${count} identical bytes, 7 operations, fresh views after memory.grow`);
console.log("epoch, serial arithmetic, UTF-8, geometry, malformed lengths and shadow-registry checks passed");

for (const commands of [1, 100, 4096]) {
    let rounds = 0;
    let checksum = 0;
    const start = performance.now();
    do {
        const result = guest.fixture_bench(commands);
        assert.equal(result, commands + 102);
        checksum += result;
        ++rounds;
    } while (performance.now() - start < 150);
    const elapsed = performance.now() - start;
    console.log(`wasm_commands=${commands} rounds=${rounds} elapsed_ms=${elapsed.toFixed(3)} checksum=${checksum}`);
}
