/// Typed frontend commands, events, capability checks and the bridge wire format.
module flint.engine.desktop.ipc;

import flint.arena : Buffer, Error, RequestArena, Status;
import flint.conc : Context;
import flint.engine.desktop.ffi.platform : Identity;
import flint.engine.desktop.types : Capability;

@safe:

/// Type annotation marking a struct whose methods are frontend commands and listeners.
struct DesktopCommands
{
}

/// Expose a method to `flint.invoke(name, args)`.
struct Command
{
    /// Name used by the frontend and by capabilities.
    string name;
}

/// Receive `flint.emit(name, payload)` from the frontend.
struct Listen
{
    /// Event name used by the frontend and by capabilities.
    string name;
}

/// Per-invocation state. The arena and anything decoded into it expire when the method returns.
struct InvokeContext
{
    /// Region holding decoded arguments and the encoded result.
    RequestArena arena;
    /// Window cancellation and deadline.
    Context cancellation;
    /// Label of the window whose page sent the call.
    string window;
    /// Origin of the page that sent the call.
    const(char)[] origin;
    package(flint.engine.desktop) Identity identity;

    /// Send a typed event to the calling window's frontend listeners.
    Error emit(T)(scope const(char)[] event, scope auto ref const T payload) scope nothrow @nogc
    {
        import flint.engine.desktop.runtime : emitValue;

        return emitValue(identity, event, payload);
    }

    /// Close the calling window after this invocation returns.
    Error close() scope nothrow @nogc
    {
        import flint.engine.desktop.runtime : requestClose;

        return requestClose(identity);
    }
}

/// Frontend message categories.
package(flint.engine.desktop) enum IpcKind : ubyte
{
    invoke,
    emit
}

/// One decoded bridge frame borrowing the received bytes.
package(flint.engine.desktop) struct Frame
{
    IpcKind kind;
    ulong id;
    const(char)[] name;
    const(ubyte)[] body;
}

/// Origin of pages served from the embedded assets.
package(flint.engine.desktop) enum appOrigin = "flint://localhost";
/// Largest frame accepted from the frontend.
package(flint.engine.desktop) enum frameLimit = 16_384;
private enum nameLimit = 64;
private enum maximumId = (1UL << 53) - 1;

/// Command, event and label names: `[A-Za-z0-9_.:-]{1,64}`.
package(flint.engine.desktop) bool validName(scope const(char)[] name) pure nothrow @nogc
{
    if (!name.length || name.length > nameLimit)
        return false;
    foreach (character; name)
    {
        if (!((character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z')
                || (character >= '0' && character <= '9') || character == '_' || character == '.'
                || character == ':' || character == '-'))
            return false;
    }
    return true;
}

/// Decode `F1\n<i|e>\n<id>\n<name>\n<json>`.
package(flint.engine.desktop) Frame parseFrame(return scope const(ubyte)[] input, out Error failure) pure nothrow @nogc
{
    enum malformed = Error(Status.invalidArgument, "malformed desktop bridge frame");
    if (input.length > frameLimit)
        return reject(failure, Error(Status.resourceExhausted, "desktop bridge frame exceeds 16 KiB"));
    if (input.length < 9 || input[0 .. 3] != cast(const(ubyte)[]) "F1\n" || input[4] != '\n'
            || (input[3] != 'i' && input[3] != 'e'))
        return reject(failure, malformed);
    const kind = input[3] == 'i' ? IpcKind.invoke : IpcKind.emit;
    size_t index = 5;
    const id = identifier(input, index);
    if (id < 0)
        return reject(failure, malformed);
    const start = index;
    while (index < input.length && input[index] != '\n')
        ++index;
    const name = cast(const(char)[]) input[start .. index];
    if (index == input.length || !validName(name))
        return reject(failure, malformed);
    return Frame(kind, cast(ulong) id, name, input[index + 1 .. $]);
}

/// Parse 1–16 decimal digits up to 2^53-1 terminated by a newline, advancing past it; -1 if malformed.
private long identifier(scope const(ubyte)[] input, ref size_t index) pure nothrow @nogc
{
    const start = index;
    long id;
    for (; index < input.length && input[index] != '\n'; ++index)
    {
        if (input[index] < '0' || input[index] > '9' || index - start == 16)
            return -1;
        id = id * 10 + (input[index] - '0');
    }
    if (index == start || index == input.length || id > maximumId)
        return -1;
    ++index;
    return id;
}

private Frame reject(out Error failure, Error reason) pure nothrow @nogc
{
    failure = reason;
    return Frame.init;
}

private enum appPrefix = appOrigin ~ "/";

package(flint.engine.desktop) bool startsWith(scope const(char)[] text, scope const(char)[] prefix) pure nothrow @nogc
{
    return text.length >= prefix.length && text[0 .. prefix.length] == prefix;
}

private bool endsWith(scope const(char)[] text, scope const(char)[] suffix) pure nothrow @nogc
{
    return text.length >= suffix.length && text[$ - suffix.length .. $] == suffix;
}

/// Media type for an embedded asset path.
package(flint.engine.desktop) string mediaType(scope const(char)[] path) pure nothrow @nogc
{
    static immutable string[2][] known = [
        [".html", "text/html; charset=utf-8"], [".htm", "text/html; charset=utf-8"],
        [".js", "text/javascript; charset=utf-8"], [".mjs", "text/javascript; charset=utf-8"],
        [".css", "text/css; charset=utf-8"], [".json", "application/json"], [
            ".svg", "image/svg+xml"
        ], [".png", "image/png"], [".jpg", "image/jpeg"], [".jpeg", "image/jpeg"],
        [".gif", "image/gif"], [".webp", "image/webp"], [".ico", "image/x-icon"],
        [".woff", "font/woff"], [".woff2", "font/woff2"], [".wasm", "application/wasm"],
        [".txt", "text/plain; charset=utf-8"],
    ];
    foreach (entry; known)
    {
        if (endsWith(path, entry[0]))
            return entry[1];
    }
    return "application/octet-stream";
}

/// Path below `flint://localhost/`, without query or fragment, or null for another origin.
package(flint.engine.desktop) const(char)[] assetPath(return scope const(char)[] uri) pure nothrow @nogc
{
    if (!startsWith(uri, appPrefix))
        return null;
    auto path = uri[appPrefix.length .. $];
    foreach (index, character; path)
    {
        if (character == '?' || character == '#')
            return path[0 .. index];
    }
    return path;
}

/// Exact `scheme://host[:port]` prefix of an absolute URI, or empty.
package(flint.engine.desktop) const(char)[] originOf(return scope const(char)[] uri) pure nothrow @nogc
{
    size_t index;
    while (index < uri.length && uri[index] != ':')
        ++index;
    if (index + 3 > uri.length || uri[index .. index + 3] != "://")
        return null;
    index += 3;
    const host = index;
    while (index < uri.length && uri[index] != '/' && uri[index] != '?' && uri[index] != '#')
    {
        if (uri[index] == '@')
            return null;
        ++index;
    }
    return index == host ? null : uri[0 .. index];
}

private bool contains(scope const(string)[] names, scope const(char)[] name) pure nothrow @nogc
{
    foreach (entry; names)
    {
        if (entry == name)
            return true;
    }
    return false;
}

/// True when some capability for this window and origin lists the command or event.
package bool permitted(scope const(Capability)[] grants, scope const(char)[] window,
        scope const(char)[] origin, IpcKind kind, scope const(char)[] name) pure nothrow @nogc
{
    foreach (ref grant; grants)
    {
        if (!contains(grant.windows, window) && !contains(grant.windows, "*"))
            continue;
        if (origin != appOrigin && !contains(grant.origins, origin))
            continue;
        if (contains(kind == IpcKind.invoke ? grant.commands : grant.events, name))
            return true;
    }
    return false;
}

private string statusName(Status code) pure nothrow @nogc
{
    static immutable string[] names = [
        "ok", "invalidArgument", "outOfMemory", "cancelled", "timedOut", "notFound", "conflict",
        "ioError", "unavailable", "unsupported", "permissionDenied", "resourceExhausted",
    ];
    static assert(names.length == Status.max + 1);
    return code >= Status.min && code <= Status.max ? names[code] : "ioError";
}

/// Bounded JavaScript source builder. A full builder reports overflow instead of truncating.
package(flint.engine.desktop) struct Script
{
    private char[] storage;
    private size_t used;
    private bool overflow;

    this(return scope char[] storage) pure nothrow @nogc
    {
        this.storage = storage;
    }

    void put(scope const(char)[] text) scope pure nothrow @nogc
    {
        if (overflow || text.length > storage.length - used)
        {
            overflow = true;
            return;
        }
        storage[used .. used + text.length] = text[];
        used += text.length;
    }

    void number(ulong value) scope pure nothrow @nogc
    {
        char[20] digits;
        size_t index = digits.length;
        do
        {
            digits[--index] = cast(char)('0' + value % 10);
            value /= 10;
        }
        while (value);
        put(digits[index .. $]);
    }

    /// Append a JSON string literal; non-printable bytes become spaces.
    void quoted(scope const(char)[] text) scope pure nothrow @nogc
    {
        put("\"");
        foreach (character; text)
        {
            if (character == '"' || character == '\\')
            {
                char[2] escaped = ['\\', character];
                put(escaped[]);
            }
            else
            {
                char[1] plain = [character < 0x20 || character == 0x7f ? ' ' : character];
                put(plain[]);
            }
        }
        put("\"");
    }

    const(char)[] text() const return scope pure nothrow @nogc
    {
        return overflow ? null : storage[0 .. used];
    }
}

package(flint.engine.desktop) pure nothrow @nogc
{
    /// `window.__FLINT__.resolve(id, true, json)`; empty JSON resolves to `null`.
    const(char)[] resolveScript(return scope char[] storage, ulong id, scope const(ubyte)[] json)
    {
        auto script = Script(storage);
        script.put("window.__FLINT__.resolve(");
        script.number(id);
        script.put(",true,");
        script.put(json.length ? cast(const(char)[]) json : "null");
        script.put(")");
        return script.text();
    }

    /// `window.__FLINT__.resolve(id, false, {code, message})`.
    const(char)[] rejectScript(return scope char[] storage, ulong id, Error failure)
    {
        auto script = Script(storage);
        script.put("window.__FLINT__.resolve(");
        script.number(id);
        script.put(",false,{\"code\":");
        script.quoted(statusName(failure.code));
        script.put(",\"message\":");
        script.quoted(failure.message.length ? failure.message : statusName(failure.code));
        script.put("})");
        return script.text();
    }

    /// `window.__FLINT__.dispatch(name, json)`.
    const(char)[] dispatchScript(return scope char[] storage, scope const(char)[] event, scope const(ubyte)[] json)
    {
        auto script = Script(storage);
        script.put("window.__FLINT__.dispatch(");
        script.quoted(event);
        script.put(",");
        script.put(json.length ? cast(const(char)[]) json : "null");
        script.put(")");
        return script.text();
    }
}

/// Router invoked by the owner loop for every permitted frame.
package(flint.engine.desktop) alias IpcRouter = Error delegate(IpcKind kind, scope const(char)[] name,
        scope const(ubyte)[] body, ref scope InvokeContext context, ref Buffer result) @safe nothrow @nogc;

/// Bridge installed in the top frame of every page before its scripts run.
package(flint.engine.desktop) enum bridgeScript = `(() => {
  "use strict";
  const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.flint;
  if (!handler || window.__FLINT__) return;
  const pending = new Map();
  const listeners = new Map();
  let next = 1;
  const limit = 16384;
  const name = (value) => {
    if (typeof value !== "string" || !/^[A-Za-z0-9_.:-]{1,64}$/.test(value)) throw new TypeError("invalid Flint name");
    return value;
  };
  const send = (kind, id, key, value) => {
    const body = JSON.stringify(value === undefined ? null : value);
    const frame = "F1\n" + kind + "\n" + id + "\n" + name(key) + "\n" + body;
    if (new TextEncoder().encode(frame).length > limit) throw new RangeError("Flint message exceeds 16 KiB");
    handler.postMessage(frame);
  };
  const api = Object.freeze({
    invoke(command, args) {
      return new Promise((resolve, reject) => {
        const id = next++;
        pending.set(id, { resolve, reject });
        try { send("i", id, command, args); } catch (error) { pending.delete(id); reject(error); }
      });
    },
    emit(event, payload) { send("e", 0, event, payload); },
    listen(event, callback) {
      name(event);
      if (typeof callback !== "function") throw new TypeError("listener must be a function");
      const set = listeners.get(event) || new Set();
      set.add(callback);
      listeners.set(event, set);
      return () => set.delete(callback);
    },
  });
  const internals = Object.freeze({
    resolve(id, ok, value) {
      const entry = pending.get(id);
      if (!entry) return;
      pending.delete(id);
      if (ok) entry.resolve(value);
      else entry.reject(Object.assign(new Error(value.message), { code: value.code }));
    },
    dispatch(event, payload) {
      const set = listeners.get(event);
      if (set) for (const callback of Array.from(set)) {
        try { callback(payload); } catch (error) { setTimeout(() => { throw error; }); }
      }
    },
  });
  Object.defineProperty(window, "__FLINT__", { value: internals });
  Object.defineProperty(window, "flint", { value: api, enumerable: true });
})();`;
