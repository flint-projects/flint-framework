/// Direct D bindings to AppKit and WKWebView through the Objective-C runtime C ABI, owned by the
/// process main thread (ADR-020, ADR-024).
module flint.engine.desktop.ffi.wkwebview;

import core.stdc.stdlib : calloc, free, getenv;
import flint.arena : Error, Status;
import flint.engine.desktop.ipc : appOrigin, assetPath, bridgeScript, frameLimit, mediaType,
    originOf, parseFrame, rejectScript, startsWith;
import flint.engine.desktop.types : Asset, WindowOptions;

@safe:
nothrow @nogc:

version (FlintNativeWkwebview)  : private alias id = void*;
private alias SEL = void*;
private alias Class = void*;

private struct CGSize
{
    double width;
    double height;
}

private struct CGRect
{
    double x;
    double y;
    double width;
    double height;
}

// The leading fields every Objective-C block shares; `invoke` takes the block itself first.
private struct BlockHeader
{
    void* isa;
    int flags;
    int reserved;
    void* invoke;
}

extern (C) private @system
{
    Class objc_getClass(const(char)*);
    SEL sel_registerName(const(char)*);
    void objc_msgSend();
    Class objc_allocateClassPair(Class, const(char)*, size_t);
    void objc_registerClassPair(Class);
    bool class_addMethod(Class, SEL, const(void)*, const(char)*);
    bool class_addProtocol(Class, void*);
    void* objc_getProtocol(const(char)*);
    void* objc_autoreleasePoolPush();
    void objc_autoreleasePoolPop(void*);
}

private enum ringCapacity = 64;
private enum originLimit = 255;
private enum liveCapacity = 16;
private enum utf8 = 4; // NSUTF8StringEncoding
private enum policyCancel = 0; // WKNavigationActionPolicyCancel and WKNavigationResponsePolicyCancel
private enum policyAllow = 1;
private enum permissionDeny = 2; // WKPermissionDecisionDeny
private enum appPrefix = appOrigin ~ "/";
private enum contentSecurity = "default-src 'self'; script-src 'self' 'unsafe-inline'; "
    ~ "style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self'; "
    ~ "frame-src 'none'; child-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; "
    ~ "frame-ancestors 'none'";

private struct Message
{
    size_t length;
    size_t originLength;
    char[originLimit] origin;
    ubyte[frameLimit] bytes;
}

/// Native state pinned in C memory so AppKit and WebKit delegate calls can borrow it until teardown.
package(flint.engine.desktop) struct Webview
{
    private id window;
    private id view;
    private id delegate_;
    // Borrowed from the owner slot's retained WindowOptions until close.
    private immutable(Asset)[] assets;
    private string entry;
    private string html;
    private string external;
    private Message[ringCapacity] ring;
    private size_t first;
    private size_t count;
    private int width;
    private int height;
    private bool resized;
    private bool closeRequested;
    private bool crashed;
    /// Navigations refused by the origin policy.
    ulong deniedNavigations;
    /// Frames refused because the window's frame ring was full.
    ulong droppedFrames;
}

/// Native event codes returned by `webviewEvent`.
package(flint.engine.desktop) enum WebviewEvent
{
    none,
    close,
    resize,
    crashed
}

private Webview*[liveCapacity] live;
private int initialized;

/// Send `selector` to `receiver` through `objc_msgSend` cast to the exact C prototype, as arm64 requires.
private R send(R = id, Args...)(const(void)* receiver, const(char)* selector, Args args) @system
{
    alias Fn = extern (C) R function(const(void)*, SEL, Args) nothrow @nogc;
    return (cast(Fn)&objc_msgSend)(receiver, sel_registerName(selector), args);
}

private id cls(const(char)* name) @system
{
    return objc_getClass(name);
}

/// An autoreleased NSString copied from sized UTF-8 bytes.
private id string_(scope const(char)[] value) @system
{
    auto made = send(send(cls("NSString"), "alloc"), "initWithBytes:length:encoding:", value.ptr,
            value.length, cast(size_t) utf8);
    return made is null ? null : send(made, "autorelease");
}

private const(char)[] text(const(char)* value) @system pure
{
    if (value is null)
        return null;
    size_t length;
    while (value[length])
        ++length;
    return value[0 .. length];
}

/// UTF-8 text borrowed from an NSString for the current autorelease pool.
private const(char)[] utf8Text(id value) @system
{
    return value is null ? null : text(send!(const(char)*)(value, "UTF8String"));
}

private const(char)[] urlText(id url) @system
{
    return url is null ? null : utf8Text(send(url, "absoluteString"));
}

private bool navigable(scope const Webview* state, scope const(char)[] uri) pure
{
    if (assetPath(uri) !is null)
        return true;
    const origin = originOf(uri);
    return state.external.length && startsWith(origin, "https://") && origin == state.external;
}

private Webview* find(id delegate_) @system
{
    foreach (state; live)
    {
        if (state !is null && state.delegate_ is delegate_)
            return state;
    }
    return null;
}

private alias Decide = extern (C) void function(void*, long) nothrow @nogc;

private void decideWith(id handler, long decision) @system
{
    auto block = cast(BlockHeader*) handler;
    (cast(Decide) block.invoke)(block, decision);
}

// SAFETY: WebKit calls the scheme handler on the main thread with a task live until it is
// finished. Asset bytes are copied into NSData before return; the task is finished exactly once.
extern (C) private @trusted void startTask(id self, SEL, id, id task)
{
    auto state = find(self);
    const path = assetPath(urlText(send(send(task, "request"), "URL")));
    const(char)[] bytes;
    string media;
    if (state !is null && path !is null)
    {
        const wanted = path.length ? path : state.entry;
        foreach (ref asset; state.assets)
        {
            if (asset.path == wanted)
            {
                bytes = asset.content;
                media = asset.mime.length ? asset.mime : mediaType(asset.path);
            }
        }
        if (media is null && state.html.length && wanted == state.entry)
        {
            bytes = state.html;
            media = mediaType(".html");
        }
    }
    if (media is null)
    {
        auto failure = send(cls("NSError"), "errorWithDomain:code:userInfo:", string_("flint-desktop"), 404L, null);
        send!void(task, "didFailWithError:", failure);
        return;
    }
    respond(task, bytes, media);
}

// SAFETY: The task is live until didFinish. Header names and values are autoreleased NSStrings
// and the bytes are copied into NSData; nothing borrowed outlives this call.
private @trusted void respond(id task, scope const(char)[] bytes, scope const(char)[] media)
{
    id[4] keys = [
        string_("Content-Type"), string_("Content-Security-Policy"),
        string_("X-Content-Type-Options"), string_("Cache-Control")
    ];
    id[4] values = [
        string_(media), string_(contentSecurity), string_("nosniff"), string_("no-store")
    ];
    auto headers = send(cls("NSDictionary"), "dictionaryWithObjects:forKeys:count:", values.ptr,
            keys.ptr, cast(size_t) keys.length);
    auto url = send(send(task, "request"), "URL");
    auto allocated = send(cls("NSHTTPURLResponse"), "alloc");
    auto response = send(send(allocated, "initWithURL:statusCode:HTTPVersion:headerFields:", url,
            200L, string_("HTTP/1.1"), headers), "autorelease");
    auto data = send(cls("NSData"), "dataWithBytes:length:", bytes.ptr, bytes.length);
    send!void(task, "didReceiveResponse:", response);
    send!void(task, "didReceiveData:", data);
    send!void(task, "didFinish");
}

// SAFETY: Every task is finished synchronously in startTask, so there is nothing to stop.
extern (C) private @trusted void stopTask(id, SEL, id, id)
{
}

// SAFETY: WebKit owns the message for this main-thread call. Its string body is copied into the
// pinned ring of the registered state; no D handler runs here.
extern (C) private @trusted void receive(id self, SEL, id, id message)
{
    auto state = find(self);
    auto payload = send(message, "body");
    if (state is null || payload is null || !send!bool(payload, "isKindOfClass:", cls("NSString")))
        return;
    const frame = utf8Text(payload);
    if (frame.length > frameLimit || state.count == ringCapacity)
    {
        ++state.droppedFrames;
        refuse(state, frame);
        return;
    }
    ref Message slot = state.ring[(state.first + state.count) % ringCapacity];
    const origin = originOf(urlText(send(state.view, "URL")));
    slot.originLength = origin.length <= originLimit ? origin.length : 0;
    slot.origin[0 .. slot.originLength] = origin[0 .. slot.originLength];
    slot.length = frame.length;
    slot.bytes[0 .. frame.length] = cast(const(ubyte)[]) frame[];
    ++state.count;
}

// SAFETY: Called with the live view of a registered state; WebKit copies the script string.
private @trusted void refuse(Webview* state, scope const(char)[] frame)
{
    Error malformed;
    const parsed = parseFrame(cast(const(ubyte)[]) frame[0 .. frame.length < frameLimit ? frame.length
        : frameLimit], malformed);
    if (malformed.code != Status.ok || !parsed.id)
        return;
    char[256] storage;
    const script = rejectScript(storage[], parsed.id, Error(Status.resourceExhausted, "desktop frame queue is full"));
    evaluate(state, script);
}

// SAFETY: The navigation action and decision block are live for this main-thread call, and the
// block is invoked exactly once. Only borrowed URL text is inspected.
extern (C) private @trusted void decideAction(id self, SEL, id, id action, id handler)
{
    auto state = find(self);
    const download = send!bool(action, "respondsToSelector:", sel_registerName("shouldPerformDownload"))
        && send!bool(action, "shouldPerformDownload");
    if (state !is null && !download && navigable(state, urlText(send(send(action, "request"), "URL"))))
        return decideWith(handler, policyAllow);
    if (state !is null)
        ++state.deniedNavigations;
    decideWith(handler, policyCancel);
}

// SAFETY: As decideAction. Responses WebKit cannot show would become downloads and are refused.
extern (C) private @trusted void decideResponse(id, SEL, id, id response, id handler)
{
    decideWith(handler, send!bool(response, "canShowMIMEType") ? policyAllow : policyCancel);
}

// SAFETY: Returning nil refuses every new window; the state is only counted.
extern (C) private @trusted id createView(id self, SEL, id, id, id, id)
{
    if (auto state = find(self))
        ++state.deniedNavigations;
    return null;
}

// SAFETY: The decision block is live for this call and is invoked exactly once.
extern (C) private @trusted void refuseCapture(id, SEL, id, id, id, long, id handler)
{
    decideWith(handler, permissionDeny);
}

// SAFETY: WebKit passes the delegate registered for a live state on the main thread.
extern (C) private @trusted void terminated(id self, SEL, id)
{
    if (auto state = find(self))
        state.crashed = true;
}

// SAFETY: AppKit asks on the main thread. Returning NO keeps the window; the owner loop closes it.
extern (C) private @trusted bool shouldClose(id self, SEL, id)
{
    if (auto state = find(self))
        state.closeRequested = true;
    return false;
}

// SAFETY: AppKit notifies on the main thread while the window and its content view are live.
extern (C) private @trusted void didResize(id self, SEL, id)
{
    auto state = find(self);
    if (state is null || state.window is null)
        return;
    const frame = send!CGRect(send(state.window, "contentView"), "frame");
    const width = cast(int) frame.width;
    const height = cast(int) frame.height;
    if (width == state.width && height == state.height)
        return;
    state.width = width;
    state.height = height;
    state.resized = true;
}

private struct Method
{
    string selector;
    immutable(void)* implementation;
    string types;
}

// Each implementation is an extern(C) function above whose C signature matches its type encoding.
// The literals are NUL-terminated, as the runtime reads them.
private immutable Method[] methods = [
    Method("userContentController:didReceiveScriptMessage:", cast(immutable(void)*)&receive,
            "v@:@@"),
    Method("webView:startURLSchemeTask:", cast(immutable(void)*)&startTask, "v@:@@"),
    Method("webView:stopURLSchemeTask:", cast(immutable(void)*)&stopTask, "v@:@@"),
    Method("webView:decidePolicyForNavigationAction:decisionHandler:",
            cast(immutable(void)*)&decideAction, "v@:@@@?"),
    Method("webView:decidePolicyForNavigationResponse:decisionHandler:",
            cast(immutable(void)*)&decideResponse, "v@:@@@?"),
    Method("webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
            cast(immutable(void)*)&createView, "@@:@@@@"),
    Method("webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
            cast(immutable(void)*)&refuseCapture,
            "v@:@@@q@?"),
    Method("webViewWebContentProcessDidTerminate:", cast(immutable(void)*)&terminated, "v@:@"),
    Method("windowShouldClose:", cast(immutable(void)*)&shouldClose, "c@:@"),
    Method("windowDidResize:", cast(immutable(void)*)&didResize, "v@:@"),
];

// SAFETY: Registers one NSObject subclass on the main thread; every method is a static extern(C)
// function above whose C signature matches the type encoding given for it.
private @trusted bool register()
{
    // The runtime owns the class for the life of the process and finds it by name.
    if (cls("FlintWebviewDelegate") !is null)
        return true;
    auto made = objc_allocateClassPair(cls("NSObject"), "FlintWebviewDelegate", 0);
    if (made is null)
        return false;
    static immutable string[] protocols = [
        "WKScriptMessageHandler", "WKURLSchemeHandler", "WKNavigationDelegate", "WKUIDelegate",
        "NSWindowDelegate"
    ];
    foreach (name; protocols)
    {
        char[32] terminated = 0;
        terminated[0 .. name.length] = name[];
        auto protocol = objc_getProtocol(terminated.ptr);
        if (protocol !is null && !class_addProtocol(made, protocol))
            return false;
    }
    foreach (ref method; methods)
    {
        if (!class_addMethod(made, sel_registerName(method.selector.ptr), method.implementation, method.types.ptr))
            return false;
    }
    objc_registerClassPair(made);
    return true;
}

// SAFETY: Runs once on the main thread. NSApplication is created before any window, and the
// delegate class is registered for the life of the process.
private @trusted bool initialize()
{
    if (initialized)
        return initialized > 0;
    initialized = -1;
    auto application = send(cls("NSApplication"), "sharedApplication");
    if (application is null || cls("WKWebView") is null || !register())
        return false;
    cast(void) send!bool(application, "setActivationPolicy:", 0L); // NSApplicationActivationPolicyRegular
    send!void(application, "finishLaunching");
    initialized = 1;
    return true;
}

// SAFETY: The view is live. FLINT_DESKTOP_DEVTOOLS=1 makes it inspectable (macOS 13.3 and later);
// WKWebView has no console-to-stdout setting, so FLINT_DESKTOP_CONSOLE has no effect here.
private @trusted void developerSettings(id view)
{
    const devtools = getenv("FLINT_DESKTOP_DEVTOOLS");
    if (devtools !is null && devtools[0] == '1' && send!bool(view, "respondsToSelector:",
            sel_registerName("setInspectable:")))
        send!void(view, "setInspectable:", true);
}

// SAFETY: The configuration, script and view are created and released here or owned by the
// returned state; the delegate is retained by the state and unhooked in webviewClose.
private @trusted id makeView(Webview* state, ref const WindowOptions options)
{
    auto configuration = send(send(send(cls("WKWebViewConfiguration"), "alloc"), "init"), "autorelease");
    auto content = send(configuration, "userContentController");
    auto script = send(send(send(cls("WKUserScript"), "alloc"),
            "initWithSource:injectionTime:forMainFrameOnly:", string_(bridgeScript), 0L, true), "autorelease");
    send!void(content, "addUserScript:", script);
    send!void(content, "addScriptMessageHandler:name:", state.delegate_, string_("flint"));
    send!void(configuration, "setURLSchemeHandler:forURLScheme:", state.delegate_, string_("flint"));
    const frame = CGRect(0, 0, options.width, options.height);
    auto view = send(send(cls("WKWebView"), "alloc"), "initWithFrame:configuration:", frame, configuration);
    if (view is null)
        return null;
    send!void(view, "setNavigationDelegate:", state.delegate_);
    send!void(view, "setUIDelegate:", state.delegate_);
    developerSettings(view);
    return view;
}

// SAFETY: Bounded title and URI buffers; the owner slot retains option slices until webviewClose.
// Every AppKit and WebKit object created here is owned by the returned pinned state.
package(flint.engine.desktop) @trusted Webview* webviewOpen(scope const(char)[] title,
        scope ref const WindowOptions options)
{
    if (!initialize() || !title.length || title[$ - 1] != 0)
        return null;
    size_t index;
    while (index < live.length && live[index]!is null)
        ++index;
    if (index == live.length)
        return null;
    auto state = cast(Webview*) calloc(1, Webview.sizeof);
    if (state is null)
        return null;
    auto pool = objc_autoreleasePoolPush();
    scope (exit)
        objc_autoreleasePoolPop(pool);
    state.assets = options.assets;
    state.entry = options.entryAsset;
    state.html = options.html;
    state.external = options.httpsOrigin;
    state.delegate_ = send(send(cls("FlintWebviewDelegate"), "alloc"), "init");
    state.view = makeView(state, options);
    if (state.view is null)
    {
        send!void(state.delegate_, "release");
        free(state);
        return null;
    }
    // Titled, closable, miniaturizable and, when asked, resizable; buffered backing.
    const style = 1UL | 2UL | 4UL | (options.resizable ? 8UL : 0UL);
    const frame = CGRect(0, 0, options.width, options.height);
    state.window = send(send(cls("NSWindow"), "alloc"),
            "initWithContentRect:styleMask:backing:defer:", frame, style, 2UL, false);
    send!void(state.window, "setReleasedWhenClosed:", false);
    send!void(state.window, "setTitle:", string_(title[0 .. $ - 1]));
    send!void(state.window, "setContentView:", state.view);
    send!void(state.window, "setDelegate:", state.delegate_);
    send!void(state.window, "center");
    live[index] = state;
    state.width = options.width;
    state.height = options.height;
    char[256] uri = 0;
    uri[0 .. appPrefix.length] = appPrefix;
    uri[appPrefix.length .. appPrefix.length + options.entryAsset.length] = options.entryAsset[];
    auto url = send(cls("NSURL"), "URLWithString:", string_(uri[0 .. appPrefix.length + options.entryAsset.length]));
    send(state.view, "loadRequest:", send(cls("NSURLRequest"), "requestWithURL:", url));
    send!void(state.window, "makeKeyAndOrderFront:", null);
    return state;
}

// SAFETY: Only the main thread destroys the state. Every delegate and the message handler are
// unhooked before the view, window and delegate are released, so no call can borrow freed memory.
package(flint.engine.desktop) @trusted void webviewClose(Webview* state)
{
    if (state is null)
        return;
    foreach (ref entry; live)
    {
        if (entry is state)
            entry = null;
    }
    auto pool = objc_autoreleasePoolPush();
    auto content = send(send(state.view, "configuration"), "userContentController");
    send!void(content, "removeScriptMessageHandlerForName:", string_("flint"));
    send!void(state.view, "stopLoading");
    send!void(state.view, "setNavigationDelegate:", null);
    send!void(state.view, "setUIDelegate:", null);
    send!void(state.window, "setDelegate:", null);
    send!void(state.window, "orderOut:", null);
    send!void(state.window, "close");
    send!void(state.window, "setContentView:", null);
    send!void(state.view, "release");
    send!void(state.window, "release");
    send!void(state.delegate_, "release");
    objc_autoreleasePoolPop(pool);
    free(state);
    webviewPump();
}

// SAFETY: Non-blocking dispatch of queued AppKit events and run-loop sources on the main thread.
// Delegate methods run here only copy POD state into registered webviews.
package(flint.engine.desktop) @trusted void webviewPump()
{
    auto pool = objc_autoreleasePoolPush();
    scope (exit)
        objc_autoreleasePoolPop(pool);
    auto application = send(cls("NSApplication"), "sharedApplication");
    auto past = send(cls("NSDate"), "distantPast");
    auto mode = string_("kCFRunLoopDefaultMode");
    foreach (_; 0 .. 64)
    {
        auto event = send(application, "nextEventMatchingMask:untilDate:inMode:dequeue:", ulong.max, past, mode, true);
        if (event is null)
            break;
        send!void(application, "sendEvent:", event);
    }
    // One pass over the run loop's sources, which deliver WebKit's process messages.
    cast(void) send!bool(send(cls("NSRunLoop"), "currentRunLoop"), "runMode:beforeDate:", mode, past);
}

// SAFETY: Takes the next event recorded by delegate calls. The pinned state is owned by the
// calling main thread and is not freed during this call.
package(flint.engine.desktop) @trusted WebviewEvent webviewEvent(Webview* state, out int width, out int height)
{
    if (state.crashed)
        return WebviewEvent.crashed;
    if (state.closeRequested)
    {
        state.closeRequested = false;
        return WebviewEvent.close;
    }
    if (!state.resized)
        return WebviewEvent.none;
    state.resized = false;
    width = state.width;
    height = state.height;
    return WebviewEvent.resize;
}

// SAFETY: The ring belongs to the main thread that also runs the delegate filling it. Bytes are
// copied into the caller's spans only when both fit.
package(flint.engine.desktop) @trusted bool webviewTake(Webview* state, scope ubyte[] bytes,
        out size_t length, scope char[] origin, out size_t originLength)
{
    if (!state.count)
        return false;
    ref Message slot = state.ring[state.first];
    state.first = (state.first + 1) % ringCapacity;
    --state.count;
    if (slot.length > bytes.length || slot.originLength > origin.length)
        return false;
    bytes[0 .. slot.length] = slot.bytes[0 .. slot.length];
    origin[0 .. slot.originLength] = slot.origin[0 .. slot.originLength];
    length = slot.length;
    originLength = slot.originLength;
    return true;
}

// SAFETY: The NSString copies the sized script before WebKit sees it. No completion handler is given.
private @trusted void evaluate(Webview* state, scope const(char)[] script)
{
    auto pool = objc_autoreleasePoolPush();
    send!void(state.view, "evaluateJavaScript:completionHandler:", string_(script), null);
    objc_autoreleasePoolPop(pool);
}

/// Evaluate trusted Flint bridge source in the page.
package(flint.engine.desktop) void webviewEvaluate(Webview* state, scope const(char)[] script)
{
    evaluate(state, script);
}

// SAFETY: The window is live and owned by the main thread; AppKit notifies windowDidResize: here.
package(flint.engine.desktop) @trusted void webviewResize(Webview* state, int width, int height)
{
    send!void(state.window, "setContentSize:", CGSize(width, height));
}

// SAFETY: The window is live; AppKit asks the registered windowShouldClose: on this thread.
package(flint.engine.desktop) @trusted void webviewRequestClose(Webview* state)
{
    send!void(state.window, "performClose:", null);
}

/// The windowing system the backend drives.
package(flint.engine.desktop) const(char)[] displayBackend()
{
    return initialized > 0 ? "AppKit" : null;
}

// SAFETY: The view is live; the borrowed URL text is copied into the caller's span before the
// autorelease pool that holds it is popped.
package(flint.engine.desktop) @trusted const(char)[] webviewUri(Webview* state, return scope char[] storage)
{
    auto pool = objc_autoreleasePoolPush();
    scope (exit)
        objc_autoreleasePoolPop(pool);
    const uri = urlText(send(state.view, "URL"));
    const length = uri.length < storage.length ? uri.length : storage.length;
    storage[0 .. length] = uri[0 .. length];
    return storage[0 .. length];
}
