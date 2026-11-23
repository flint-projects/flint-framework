/// Direct D bindings to GTK 3 and WebKitGTK 4.1, owned by the process UI thread.
module flint.engine.desktop.ffi.webkit;

import core.stdc.config : c_ulong;
import core.stdc.stdlib : calloc, free, getenv;

import flint.arena : Error, Status;
import flint.engine.desktop.ipc : appOrigin, assetPath, bridgeScript, frameLimit, mediaType,
    originOf, parseFrame, rejectScript, startsWith;
import flint.engine.desktop.types : Asset, WindowOptions;

@safe:
nothrow @nogc:

// WebKitGTK is a Linux backend; Windows has no POSIX environment or access calls (ADR-026).
version (Posix)
{
    import core.sys.posix.stdlib : setenv;
    import core.sys.posix.unistd : F_OK, access;
}

version (FlintNativeWebkitgtk)  : private struct GtkWidget;
private struct GObject;
private struct GError;
private struct GBytes;
private struct GInputStream;
private struct SoupMessageHeaders;
private struct WebKitWebView;
private struct WebKitWebContext;
private struct WebKitUserContentManager;
private struct WebKitUserScript;
private struct WebKitURISchemeRequest;
private struct WebKitURISchemeResponse;
private struct WebKitPolicyDecision;
private struct WebKitJavascriptResult;
private struct JSCValue;

private struct GdkRectangle
{
    int x;
    int y;
    int width;
    int height;
}

extern (C) private @system
{
    int gtk_init_check(int*, char***);
    GtkWidget* gtk_window_new(int);
    void gtk_window_set_title(GtkWidget*, const(char)*);
    void gtk_window_set_default_size(GtkWidget*, int, int);
    void gtk_window_set_resizable(GtkWidget*, int);
    void gtk_window_resize(GtkWidget*, int, int);
    void gtk_window_close(GtkWidget*);
    void gtk_container_add(GtkWidget*, GtkWidget*);
    void gtk_widget_show_all(GtkWidget*);
    void gtk_widget_destroy(GtkWidget*);
    void* gdk_display_get_default();
    const(char)* g_type_name_from_instance(void*);

    int g_main_context_iteration(void*, int);
    c_ulong g_signal_connect_data(void*, const(char)*, void*, void*, void*, int);
    void g_signal_handler_disconnect(void*, c_ulong);
    void g_object_unref(void*);
    void g_free(void*);
    uint g_quark_from_static_string(const(char)*);
    GError* g_error_new_literal(uint, int, const(char)*);
    void g_error_free(GError*);
    GBytes* g_bytes_new(const(void)*, size_t);
    void g_bytes_unref(GBytes*);
    GInputStream* g_memory_input_stream_new_from_bytes(GBytes*);

    SoupMessageHeaders* soup_message_headers_new(int);
    void soup_message_headers_append(SoupMessageHeaders*, const(char)*, const(char)*);

    WebKitWebContext* webkit_web_context_get_default();
    void webkit_web_context_register_uri_scheme(WebKitWebContext*, const(char)*, void*, void*, void*);
    void* webkit_web_context_get_security_manager(WebKitWebContext*);
    void webkit_security_manager_register_uri_scheme_as_secure(void*, const(char)*);
    void webkit_security_manager_register_uri_scheme_as_cors_enabled(void*, const(char)*);
    void webkit_download_cancel(void*);

    WebKitUserContentManager* webkit_user_content_manager_new();
    int webkit_user_content_manager_register_script_message_handler(WebKitUserContentManager*, const(char)*);
    void webkit_user_content_manager_unregister_script_message_handler(WebKitUserContentManager*, const(char)*);
    void webkit_user_content_manager_add_script(WebKitUserContentManager*, WebKitUserScript*);
    WebKitUserScript* webkit_user_script_new(const(char)*, int, int, const(char*)*, const(char*)*);
    void webkit_user_script_unref(WebKitUserScript*);
    JSCValue* webkit_javascript_result_get_js_value(WebKitJavascriptResult*);
    char* jsc_value_to_string(JSCValue*);

    GtkWidget* webkit_web_view_new_with_user_content_manager(WebKitUserContentManager*);
    void* webkit_web_view_get_settings(WebKitWebView*);
    void webkit_settings_set_enable_write_console_messages_to_stdout(void*, int);
    void webkit_settings_set_enable_developer_extras(void*, int);
    void webkit_web_view_load_uri(WebKitWebView*, const(char)*);
    const(char)* webkit_web_view_get_uri(WebKitWebView*);
    void webkit_web_view_evaluate_javascript(WebKitWebView*, const(char)*, ptrdiff_t,
            const(char)*, const(char)*, void*, void*, void*);

    const(char)* webkit_uri_scheme_request_get_uri(WebKitURISchemeRequest*);
    WebKitWebView* webkit_uri_scheme_request_get_web_view(WebKitURISchemeRequest*);
    void webkit_uri_scheme_request_finish_error(WebKitURISchemeRequest*, GError*);
    void webkit_uri_scheme_request_finish_with_response(WebKitURISchemeRequest*, WebKitURISchemeResponse*);
    WebKitURISchemeResponse* webkit_uri_scheme_response_new(GInputStream*, long);
    void webkit_uri_scheme_response_set_status(WebKitURISchemeResponse*, uint, const(char)*);
    void webkit_uri_scheme_response_set_content_type(WebKitURISchemeResponse*, const(char)*);
    void webkit_uri_scheme_response_set_http_headers(WebKitURISchemeResponse*, SoupMessageHeaders*);

    void* webkit_navigation_policy_decision_get_navigation_action(WebKitPolicyDecision*);
    void* webkit_navigation_action_get_request(void*);
    const(char)* webkit_uri_request_get_uri(void*);
    int webkit_response_policy_decision_is_mime_type_supported(WebKitPolicyDecision*);
    void webkit_policy_decision_use(WebKitPolicyDecision*);
    void webkit_policy_decision_ignore(WebKitPolicyDecision*);
    void webkit_permission_request_deny(void*);
}

private enum ringCapacity = 64;
private enum originLimit = 255;
private enum signalCapacity = 8;
private enum liveCapacity = 16;
private enum navigationAction = 0;
private enum responseAction = 2;
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

/// Native state pinned in C memory so GTK callbacks can borrow it until teardown.
package(flint.engine.desktop) struct Webview
{
    private GtkWidget* window;
    private WebKitWebView* view;
    private WebKitUserContentManager* manager;
    private void*[signalCapacity] instances;
    private c_ulong[signalCapacity] signals;
    private size_t signalCount;
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

private const(char)[] text(const(char)* value) @system pure
{
    if (value is null)
        return null;
    size_t length;
    while (value[length])
        ++length;
    return value[0 .. length];
}

private bool navigable(scope const Webview* state, scope const(char)[] uri) pure
{
    if (assetPath(uri) !is null)
        return true;
    const origin = originOf(uri);
    return state.external.length && startsWith(origin, "https://") && origin == state.external;
}

private Webview* find(WebKitWebView* view) @system
{
    foreach (state; live)
    {
        if (state !is null && state.view is view)
            return state;
    }
    return null;
}

// SAFETY: UI-thread request live until finished; only registered webviews match. Asset bytes are
// copied into GBytes before return, and every reference created here is released here.
extern (C) private @trusted void serveAsset(WebKitURISchemeRequest* request, void*)
{
    auto state = find(webkit_uri_scheme_request_get_web_view(request));
    const path = assetPath(text(webkit_uri_scheme_request_get_uri(request)));
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
        auto failure = g_error_new_literal(g_quark_from_static_string("flint-desktop"), 404,
                "desktop asset unavailable");
        webkit_uri_scheme_request_finish_error(request, failure);
        g_error_free(failure);
        return;
    }
    respond(request, bytes, media);
}

// SAFETY: The request is live until finished here. The media type is copied into bounded
// NUL-terminated buffers and the bytes into GBytes; every reference created is released.
private @trusted void respond(WebKitURISchemeRequest* request, scope const(char)[] bytes, scope const(char)[] media)
{
    enum limit = 127;
    char[limit + 1] header = 0;
    char[limit + 1] essence = 0;
    const length = media.length < limit ? media.length : limit;
    header[0 .. length] = media[0 .. length];
    size_t bare;
    while (bare < length && media[bare] != ';')
        ++bare;
    essence[0 .. bare] = media[0 .. bare];
    auto data = g_bytes_new(bytes.ptr, bytes.length);
    auto stream = g_memory_input_stream_new_from_bytes(data);
    g_bytes_unref(data);
    auto response = webkit_uri_scheme_response_new(stream, cast(long) bytes.length);
    auto headers = soup_message_headers_new(1);
    soup_message_headers_append(headers, "Content-Type", header.ptr);
    soup_message_headers_append(headers, "Content-Security-Policy", contentSecurity);
    soup_message_headers_append(headers, "X-Content-Type-Options", "nosniff");
    soup_message_headers_append(headers, "Cache-Control", "no-store");
    webkit_uri_scheme_response_set_status(response, 200, "OK");
    webkit_uri_scheme_response_set_http_headers(response, headers);
    webkit_uri_scheme_response_set_content_type(response, essence.ptr);
    webkit_uri_scheme_request_finish_with_response(request, response);
    g_object_unref(response);
    g_object_unref(stream);
}

// SAFETY: The download object is live for this UI-thread signal emission. Cancelling it
// retains no pointer and calls no D code.
extern (C) private @trusted void refuseDownload(void*, void* download, void*)
{
    webkit_download_cancel(download);
}

// SAFETY: WebKit owns the result for this UI-thread emission. The returned string is copied
// into the pinned ring of the registered state and freed here. No D handler runs here.
extern (C) private @trusted void receive(WebKitUserContentManager*, WebKitJavascriptResult* result, void* data)
{
    auto state = cast(Webview*) data;
    auto value = jsc_value_to_string(webkit_javascript_result_get_js_value(result));
    if (value is null)
        return;
    const frame = text(value);
    if (frame.length > frameLimit || state.count == ringCapacity)
    {
        ++state.droppedFrames;
        refuse(state, frame);
        g_free(value);
        return;
    }
    ref Message slot = state.ring[(state.first + state.count) % ringCapacity];
    const origin = originOf(text(webkit_web_view_get_uri(state.view)));
    slot.originLength = origin.length <= originLimit ? origin.length : 0;
    slot.origin[0 .. slot.originLength] = origin[0 .. slot.originLength];
    slot.length = frame.length;
    slot.bytes[0 .. frame.length] = cast(const(ubyte)[]) frame[];
    ++state.count;
    g_free(value);
}

// SAFETY: Called with the live view of a registered state; WebKit copies the sized script.
private @trusted void refuse(Webview* state, scope const(char)[] frame)
{
    Error malformed;
    const parsed = parseFrame(cast(const(ubyte)[]) frame[0 .. frame.length < frameLimit ? frame.length
        : frameLimit], malformed);
    if (malformed.code != Status.ok || !parsed.id)
        return;
    char[256] storage;
    const script = rejectScript(storage[], parsed.id, Error(Status.resourceExhausted, "desktop frame queue is full"));
    webkit_web_view_evaluate_javascript(state.view, script.ptr, script.length, null, null, null, null, null);
}

// SAFETY: The decision and its navigation request are live for this UI-thread emission. Only
// borrowed URI text is inspected; WebKit receives exactly one decision for handled types.
extern (C) private @trusted int decide(WebKitWebView*, WebKitPolicyDecision* decision, int type, void* data)
{
    auto state = cast(Webview*) data;
    if (type == responseAction)
    {
        if (webkit_response_policy_decision_is_mime_type_supported(decision))
            webkit_policy_decision_use(decision);
        else
            webkit_policy_decision_ignore(decision);
        return 1;
    }
    if (type == navigationAction)
    {
        auto action = webkit_navigation_policy_decision_get_navigation_action(decision);
        auto request = action is null ? null : webkit_navigation_action_get_request(action);
        if (request !is null && navigable(state, text(webkit_uri_request_get_uri(request))))
        {
            webkit_policy_decision_use(decision);
            return 1;
        }
    }
    ++state.deniedNavigations;
    webkit_policy_decision_ignore(decision);
    return 1;
}

// SAFETY: The permission request is live for this emission and is denied synchronously.
extern (C) private @trusted int refusePermission(WebKitWebView*, void* request, void*)
{
    webkit_permission_request_deny(request);
    return 1;
}

// SAFETY: GTK passes the pinned state registered with this handler on the UI thread.
// Returning true keeps GTK from destroying the window; the owner loop closes it.
extern (C) private @trusted int deleteRequested(GtkWidget*, void*, void* data)
{
    (cast(Webview*) data).closeRequested = true;
    return 1;
}

// SAFETY: GTK passes a live allocation rectangle for this emission and the pinned state.
extern (C) private @trusted void allocated(GtkWidget*, GdkRectangle* allocation, void* data)
{
    auto state = cast(Webview*) data;
    if (allocation.width == state.width && allocation.height == state.height)
        return;
    state.width = allocation.width;
    state.height = allocation.height;
    state.resized = true;
}

// SAFETY: WebKit passes the pinned state registered with this handler on the UI thread.
extern (C) private @trusted void terminated(WebKitWebView*, int, void* data)
{
    (cast(Webview*) data).crashed = true;
}

// SAFETY: The callback pointers name extern(C) functions in this module with the signal's C
// signature. Handler identities are recorded and disconnected before the state is freed.
private @trusted void connect(Webview* state, void* instance, const(char)* signal, void* callback)
{
    assert(state.signalCount < signalCapacity);
    state.instances[state.signalCount] = instance;
    state.signals[state.signalCount++] = g_signal_connect_data(instance, signal, callback, state, null, 0);
}

// SAFETY: The view is live and owned by the caller; the settings object belongs to the view.
// FLINT_DESKTOP_CONSOLE=1 copies page console output to stdout; FLINT_DESKTOP_DEVTOOLS=1 enables the inspector.
private @trusted void developerSettings(WebKitWebView* view)
{
    auto settings = webkit_web_view_get_settings(view);
    const console = getenv("FLINT_DESKTOP_CONSOLE");
    const devtools = getenv("FLINT_DESKTOP_DEVTOOLS");
    webkit_settings_set_enable_write_console_messages_to_stdout(settings, console !is null && console[0] == '1');
    webkit_settings_set_enable_developer_extras(settings, devtools !is null && devtools[0] == '1');
}

// SAFETY: Runs once on the UI thread before GTK creates any EGL display or other thread.
// The literals are NUL-terminated and setenv copies them; an existing user value is kept.
private @trusted void mitigateDriver()
{
    // NVIDIA's EGL explicit-sync path fails Wayland compositors' syncobj checks for GTK/WebKit
    // surfaces ("Missing acquire timeline", protocol error 71). Tauri applies the same opt-out.
    if (getenv("WAYLAND_DISPLAY") !is null && access("/proc/driver/nvidia/version", F_OK) == 0)
        setenv("__NV_DISABLE_EXPLICIT_SYNC", "1", 0);
}

// SAFETY: Runs once on the UI thread. The scheme handler and download handler are static
// functions with no user data, valid for the life of the default WebKit context.
private @trusted bool initialize()
{
    if (initialized)
        return initialized > 0;
    mitigateDriver();
    initialized = gtk_init_check(null, null) ? 1 : -1;
    if (initialized < 0)
        return false;
    auto context = webkit_web_context_get_default();
    webkit_web_context_register_uri_scheme(context, "flint", cast(void*)&serveAsset, null, null);
    auto security = webkit_web_context_get_security_manager(context);
    webkit_security_manager_register_uri_scheme_as_secure(security, "flint");
    webkit_security_manager_register_uri_scheme_as_cors_enabled(security, "flint");
    g_signal_connect_data(context, "download-started", cast(void*)&refuseDownload, null, null, 0);
    return true;
}

// SAFETY: NUL-terminated title and bounded URI buffers; the owner slot retains option slices until
// webviewClose. Every GTK/WebKit object created here is owned by the returned pinned state.
package(flint.engine.desktop) @trusted Webview* webviewOpen(scope const(char)[] title,
        scope ref const WindowOptions options)
{
    if (!initialize() || !title.length || title[$ - 1] != 0)
        return null;
    auto state = cast(Webview*) calloc(1, Webview.sizeof);
    if (state is null)
        return null;
    size_t index;
    while (index < live.length && live[index]!is null)
        ++index;
    if (index == live.length)
    {
        free(state);
        return null;
    }
    state.assets = options.assets;
    state.entry = options.entryAsset;
    state.html = options.html;
    state.external = options.httpsOrigin;
    state.manager = webkit_user_content_manager_new();
    auto bridge = webkit_user_script_new(bridgeScript, 1, 0, null, null);
    webkit_user_content_manager_add_script(state.manager, bridge);
    webkit_user_script_unref(bridge);
    if (!webkit_user_content_manager_register_script_message_handler(state.manager, "flint"))
    {
        g_object_unref(state.manager);
        free(state);
        return null;
    }
    state.window = gtk_window_new(0);
    state.view = cast(WebKitWebView*) webkit_web_view_new_with_user_content_manager(state.manager);
    developerSettings(state.view);
    gtk_window_set_title(state.window, title.ptr);
    gtk_window_set_default_size(state.window, options.width, options.height);
    gtk_window_set_resizable(state.window, options.resizable);
    gtk_container_add(state.window, cast(GtkWidget*) state.view);
    connect(state, state.manager, "script-message-received::flint", cast(void*)&receive);
    connect(state, state.view, "decide-policy", cast(void*)&decide);
    connect(state, state.view, "permission-request", cast(void*)&refusePermission);
    connect(state, state.view, "web-process-terminated", cast(void*)&terminated);
    connect(state, state.window, "delete-event", cast(void*)&deleteRequested);
    connect(state, state.window, "size-allocate", cast(void*)&allocated);
    live[index] = state;
    char[256] uri = 0;
    uri[0 .. appPrefix.length] = appPrefix;
    uri[appPrefix.length .. appPrefix.length + options.entryAsset.length] = options.entryAsset[];
    webkit_web_view_load_uri(state.view, uri.ptr);
    gtk_widget_show_all(state.window);
    return state;
}

// SAFETY: Only the UI thread destroys the state. Signal handlers and the message handler are
// disconnected before GTK destroys the window and view, so no callback can borrow freed memory.
package(flint.engine.desktop) @trusted void webviewClose(Webview* state)
{
    if (state is null)
        return;
    foreach (ref entry; live)
    {
        if (entry is state)
            entry = null;
    }
    foreach (index; 0 .. state.signalCount)
        g_signal_handler_disconnect(state.instances[index], state.signals[index]);
    webkit_user_content_manager_unregister_script_message_handler(state.manager, "flint");
    gtk_widget_destroy(state.window);
    g_object_unref(state.manager);
    free(state);
    foreach (_; 0 .. 64)
    {
        if (!g_main_context_iteration(null, 0))
            break;
    }
}

// SAFETY: Non-blocking iteration of the default main context on the UI thread. Handlers run
// here only copy POD state into registered webviews.
package(flint.engine.desktop) @trusted void webviewPump()
{
    foreach (_; 0 .. 64)
    {
        if (!g_main_context_iteration(null, 0))
            break;
    }
}

// SAFETY: Takes the next event recorded by GTK callbacks. The pinned state is owned by the
// calling UI thread and is not freed during this call.
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

// SAFETY: The ring belongs to the UI thread that also runs the callbacks filling it. Bytes are
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

// SAFETY: WebKit copies the sized script before returning. No completion callback is registered.
package(flint.engine.desktop) @trusted void webviewEvaluate(Webview* state, scope const(char)[] script)
{
    webkit_web_view_evaluate_javascript(state.view, script.ptr, script.length, null, null, null, null, null);
}

// SAFETY: The window is live and owned by the UI thread; GTK copies the request.
package(flint.engine.desktop) @trusted void webviewResize(Webview* state, int width, int height)
{
    gtk_window_resize(state.window, width, height);
}

// SAFETY: The window is live; GTK emits delete-event to the registered handler on this thread.
package(flint.engine.desktop) @trusted void webviewRequestClose(Webview* state)
{
    gtk_window_close(state.window);
}

// SAFETY: After GTK initialisation the default display and its static type name stay valid for
// the process; nothing is retained by GTK from this call.
package(flint.engine.desktop) @trusted const(char)[] displayBackend()
{
    if (initialized <= 0)
        return null;
    auto display = gdk_display_get_default();
    return display is null ? null : text(g_type_name_from_instance(display));
}

// SAFETY: The view is live; the borrowed URI is copied into the caller's span before return.
package(flint.engine.desktop) @trusted const(char)[] webviewUri(Webview* state, return scope char[] storage)
{
    const uri = text(webkit_web_view_get_uri(state.view));
    const length = uri.length < storage.length ? uri.length : storage.length;
    storage[0 .. length] = uri[0 .. length];
    return storage[0 .. length];
}
