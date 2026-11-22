"use strict";
const $ = (id) => document.getElementById(id);
const log = (text) => { const item = document.createElement("li"); item.textContent = text; $("log").prepend(item); };
let ticks = 0;

flint.listen("count-changed", (payload) => {
  ticks += 1;
  $("count").value = String(payload.value);
});

async function greet(event) {
  if (event) event.preventDefault();
  const reply = await flint.invoke("greet", { name: $("name").value });
  $("greeting").textContent = reply.message;
  return reply.message;
}

async function step(by) {
  try {
    return (await flint.invoke("increment", { by })).value;
  } catch (error) {
    log(error.code + ": " + error.message);
    throw error;
  }
}

$("greet").addEventListener("submit", greet);
$("increment").addEventListener("click", () => step(1));
$("decrement").addEventListener("click", () => step(-1));
$("reset").addEventListener("click", () => flint.invoke("reset").then(() => log("reset")));
flint.emit("ui-ready", { revision: 1 });

/* Drives the real controls, then reports what the frontend observed. */
async function selfTest() {
  const greeting = await greet();
  for (const id of ["increment", "increment", "increment", "decrement"]) $(id).click();
  const count = await step(0);
  let denied = false;
  try { await flint.invoke("shell", { command: "id" }); } catch (error) { denied = error.code === "permissionDenied"; }
  let rejected = false;
  try { await flint.invoke("increment", { by: "lots" }); } catch (error) { rejected = error.code === "invalidArgument"; }
  await flint.invoke("report", { count, greeting, ticks, shown: Number($("count").value), denied, rejected });
}
