module flint.engine.desktop.ipc_wire_tests;

import flint.arena : Error, Status;
import flint.engine.desktop.ipc : IpcKind, appOrigin, assetPath, mediaType, dispatchScript,
    originOf, parseFrame, permitted, rejectScript, resolveScript, validName;
import flint.engine.desktop.types : Capability;

@safe:

@("Bridge frames decode kind, id, name and body and reject every malformed prefix")
unittest
{
    immutable frame = cast(immutable(ubyte)[]) "F1\ni\n42\nmath.add\n{\"a\":2}";
    Error failure;
    const decoded = parseFrame(frame, failure);
    assert(failure.code == Status.ok && decoded.kind == IpcKind.invoke && decoded.id == 42);
    assert(decoded.name == "math.add" && decoded.body == cast(const(ubyte)[]) "{\"a\":2}");

    enum header = "F1\ni\n42\nmath.add\n".length;
    foreach (length; 0 .. header)
    {
        parseFrame(frame[0 .. length], failure);
        assert(failure.code == Status.invalidArgument);
    }
    static immutable string[] broken = [
        "F2\ni\n1\nx\nnull", "F1\nq\n1\nx\nnull", "F1\ni\n\nx\nnull", "F1\ni\n1a\nx\nnull",
        "F1\ni\n1\n\nnull", "F1\ni\n1\nbad name\nnull", "F1\ni\n9007199254740992\nx\nnull",
        "F1\ni\n12345678901234567\nx\nnull", "F1\ni\n1\nx",
    ];
    foreach (text; broken)
    {
        parseFrame(cast(const(ubyte)[]) text, failure);
        assert(failure.code == Status.invalidArgument, text);
    }
    auto huge = new ubyte[16_385];
    parseFrame(huge, failure);
    assert(failure.code == Status.resourceExhausted);

    const emitted = parseFrame(cast(const(ubyte)[]) "F1\ne\n0\nclicked\n", failure);
    assert(failure.code == Status.ok && emitted.kind == IpcKind.emit && !emitted.body.length);
}

@("Names, origins and asset paths accept only their exact grammar")
unittest
{
    assert(validName("a") && validName("plugin:fs.read-text_2"));
    assert(!validName("") && !validName("a b") && !validName("é") && !validName("x/y"));
    char[65] long_ = 'a';
    assert(!validName(long_[]) && validName(long_[0 .. 64]));

    assert(originOf("flint://localhost/index.html?x#y") == appOrigin);
    assert(originOf("https://example.com:8443/a") == "https://example.com:8443");
    assert(originOf("https://user@example.com/") is null);
    assert(originOf("about:blank") is null && originOf("https:///x") is null);

    assert(assetPath("flint://localhost/") == "" && assetPath("flint://localhost/a/b.js?v=1") == "a/b.js");
    assert(assetPath("flint://localhost.evil/x") is null && assetPath("https://localhost/x") is null);
    assert(mediaType("app.mjs") == "text/javascript; charset=utf-8");
    assert(mediaType("x.bin") == "application/octet-stream");
}

@("Capabilities are deny-by-default per window, origin, kind and name")
unittest
{
    static immutable Capability[] grants = [
        Capability("main", ["main"], ["add"], ["clicked"]), Capability("tools", ["*"],
                ["version"]),
        Capability("remote", ["main"], ["status"], null, ["https://example.com"]),
    ];
    assert(permitted(grants, "main", appOrigin, IpcKind.invoke, "add"));
    assert(!permitted(grants, "other", appOrigin, IpcKind.invoke, "add"));
    assert(permitted(grants, "other", appOrigin, IpcKind.invoke, "version"));
    assert(!permitted(grants, "main", appOrigin, IpcKind.emit, "add"));
    assert(permitted(grants, "main", appOrigin, IpcKind.emit, "clicked"));
    assert(!permitted(grants, "main", appOrigin, IpcKind.invoke, "secret"));
    assert(!permitted(grants, "main", "https://example.com", IpcKind.invoke, "add"));
    assert(permitted(grants, "main", "https://example.com", IpcKind.invoke, "status"));
    assert(!permitted(grants, "main", "https://example.com:444", IpcKind.invoke, "status"));
    assert(!permitted(grants, "main", "", IpcKind.invoke, "status"));
    assert(!permitted(null, "main", appOrigin, IpcKind.invoke, "add"));
}

@("Reply and event scripts are exact and report overflow instead of truncating")
unittest
{
    char[128] storage;
    assert(resolveScript(storage[], 7,
            cast(const(ubyte)[]) "{\"value\":42}") == `window.__FLINT__.resolve(7,true,{"value":42})`);
    assert(resolveScript(storage[], 8, null) == `window.__FLINT__.resolve(8,true,null)`);
    enum rejected = `window.__FLINT__.resolve(9,false,{"code":"permissionDenied","message":"no \"grant\" "})`;
    assert(rejectScript(storage[], 9, Error(Status.permissionDenied, "no \"grant\"\n")) == rejected);
    assert(dispatchScript(storage[], "tick", cast(const(ubyte)[]) "1") == `window.__FLINT__.dispatch("tick",1)`);
    char[16] small;
    assert(resolveScript(small[], 1, cast(const(ubyte)[]) "{}") is null);
}
