import assert from "node:assert/strict";
import {spawn} from "node:child_process";
import {readFile, mkdtemp, rm} from "node:fs/promises";
import {createServer} from "node:http";
import {tmpdir} from "node:os";
import {join} from "node:path";
import {setTimeout as pause} from "node:timers/promises";
import {fileURLToPath} from "node:url";

const [fixtureWasm, appWasm, chromium = "chromium"] = process.argv.slice(2);
const base = fileURLToPath(new URL("../../../", import.meta.url));
const routes = new Map([
    ["/packages/engine-wasm-bridge/fixtures/browser.html", ["text/html", join(base, "packages/engine-wasm-bridge/fixtures/browser.html")]],
    ["/benchmarks/bench-wasm/index.html", ["text/html", join(base, "benchmarks/bench-wasm/index.html")]],
    ["/benchmarks/bench-wasm/driver.mjs", ["text/javascript", join(base, "benchmarks/bench-wasm/driver.mjs")]],
    ["/fixture.wasm", ["application/wasm", fixtureWasm]],
    ["/benchmarks/bench-wasm/build/app.wasm", ["application/wasm", appWasm]],
]);

async function until(get, accepts) {
    const deadline = performance.now() + 10_000;
    let observation;
    while (performance.now() < deadline) {
        observation = await get();
        if (accepts(observation)) return observation;
        await pause(20);
    }
    throw new Error(`timed out waiting for Chromium, last value was ${JSON.stringify(observation)}`);
}

function connected(socket) {
    return new Promise((resolve, reject) => {
        socket.addEventListener("open", resolve, {once:true});
        socket.addEventListener("error", reject, {once:true});
    });
}

function devtools(socket) {
    let id = 0;
    const pending = new Map();
    socket.addEventListener("message", event => {
        const reply = JSON.parse(event.data);
        const respond = pending.get(reply.id);
        if (!respond) return;
        pending.delete(reply.id);
        if (reply.error) respond.reject(new Error(reply.error.message));
        else respond.resolve(reply.result);
    });
    socket.addEventListener("close", () => {
        for (const respond of pending.values()) respond.reject(new Error("Chromium disconnected"));
        pending.clear();
    });
    return (method, params = {}) => new Promise((resolve, reject) => {
        const sequence = ++id;
        pending.set(sequence, {resolve, reject});
        socket.send(JSON.stringify({id:sequence, method, params}));
    });
}

const server = createServer(async (request, response) => {
    const route = routes.get(new URL(request.url, "http://127.0.0.1").pathname);
    if (!route) {
        response.writeHead(404).end();
        return;
    }
    try {
        const bytes = await readFile(route[1]);
        response.writeHead(200, {"Content-Type":route[0]}).end(bytes);
    } catch {
        response.writeHead(500).end();
    }
});
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
const origin = `http://127.0.0.1:${server.address().port}`;
const profile = await mkdtemp(join(tmpdir(), "flint-chromium-"));
const browser = spawn(chromium, ["--headless", "--no-sandbox", "--disable-dev-shm-usage",
    "--disable-background-networking", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "about:blank"],
    {stdio:["ignore", "ignore", "ignore"]});
let socket;
try {
    const port = await until(async () => {
        assert.equal(browser.exitCode, null, "Chromium exited while starting");
        try {
            return (await readFile(join(profile, "DevToolsActivePort"), "utf8")).split("\n")[0];
        } catch (error) {
            if (error.code !== "ENOENT") throw error;
        }
    }, Boolean);
    const pages = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    socket = new WebSocket(pages.find(page => page.type === "page").webSocketDebuggerUrl);
    await connected(socket);
    const command = devtools(socket);
    const evaluate = async expression => {
        const answer = await command("Runtime.evaluate", {expression, returnByValue:true});
        return answer.result.value;
    };
    await command("Page.navigate", {url:`${origin}/packages/engine-wasm-bridge/fixtures/browser.html?wasm=/fixture.wasm`});
    const text = await until(() => evaluate("document.querySelector('#result')?.textContent"),
        value => value?.startsWith("PASS:") || value?.startsWith("FAIL:"));
    assert.equal(text, "PASS: FLNT DOM, canvas, memory growth, and reset");

    await command("Page.navigate", {url:`${origin}/benchmarks/bench-wasm/index.html`});
    await until(() => evaluate("document.querySelector('#status')?.textContent"), value => value === "Ready");
    await evaluate("for (let i = 0; i < 15; ++i) document.querySelector('#add').click()");
    await until(() => evaluate("document.querySelector('#counter')?.textContent"), value => value === "15");
    console.log(text);
    console.log("PASS: golden counter rendered 15 clicks through the compiled WASM signal graph");
} finally {
    socket?.close();
    if (browser.exitCode === null && browser.signalCode === null) {
        const stopped = new Promise(resolve => browser.once("exit", resolve));
        browser.kill();
        await stopped;
    }
    server.close();
    await rm(profile, {recursive:true, force:true});
}
