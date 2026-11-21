#include "flint_desktop.h"

#include <gtk/gtk.h>
#include <webkit2/webkit2.h>
#include <stdlib.h>
#include <string.h>

enum { CLOSE = 0, RESIZE = 1, IPC_VERSION = 1, IPC_HEADER = 4, IPC_MAX = 4096 };

typedef struct app_page {
    gchar *uri;
    GBytes *html;
} app_page;

struct flint_webkit_window {
    GtkWidget *widget;
    WebKitWebView *view;
    WebKitWebContext *context;
    WebKitUserContentManager *content;
    gchar *uri;
    GUri *approved;
    uint64_t generation;
    uint32_t slot;
    flint_window_event resized;
    int resize_pending;
    int closing;
    int overload;
    int local_committed;
};

static const char app_scheme[] = "flint-app";
static const char bridge_name[] = "flint";
static const char csp[] =
    "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; "
    "img-src data:; connect-src 'none'; frame-src 'none'; child-src 'none'; "
    "frame-ancestors 'none'; object-src 'none'; base-uri 'none'; form-action 'none'";

static gboolean exact(const char *a, const char *b) {
    return a && b && strcmp(a, b) == 0;
}

static void release_page(gpointer context) {
    app_page *page = context;
    g_bytes_unref(page->html);
    g_free(page->uri);
    g_free(page);
}

static void serve_page(WebKitURISchemeRequest *request, gpointer context) {
    const app_page *page = context;
    if (!exact(webkit_uri_scheme_request_get_uri(request), page->uri)) {
        GError *failure = g_error_new_literal(G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED, "desktop asset unavailable");
        webkit_uri_scheme_request_finish_error(request, failure);
        g_error_free(failure);
        return;
    }
    GInputStream *stream = g_memory_input_stream_new_from_bytes(page->html);
    WebKitURISchemeResponse *response =
        webkit_uri_scheme_response_new(stream, (gint64)g_bytes_get_size(page->html));
    SoupMessageHeaders *headers = soup_message_headers_new(SOUP_MESSAGE_HEADERS_RESPONSE);
    soup_message_headers_append(headers, "Content-Security-Policy", csp);
    soup_message_headers_append(headers, "X-Content-Type-Options", "nosniff");
    soup_message_headers_append(headers, "Cache-Control", "no-store");
    webkit_uri_scheme_response_set_http_headers(response, headers);
    webkit_uri_scheme_response_set_content_type(response, "text/html; charset=utf-8");
    webkit_uri_scheme_response_set_status(response, 200, "OK");
    webkit_uri_scheme_request_finish_with_response(request, response);
    g_object_unref(response);
    g_object_unref(stream);
}

static gboolean valid_origin(GUri *uri) {
    return uri && exact(g_uri_get_scheme(uri), "https") && g_uri_get_host(uri) && *g_uri_get_host(uri) &&
           !g_uri_get_userinfo(uri);
}

static GUri *approved_origin(const char *text) {
    GUri *uri = g_uri_parse(text, G_URI_FLAGS_NONE, NULL);
    if (valid_origin(uri) && (exact(g_uri_get_path(uri), "") || exact(g_uri_get_path(uri), "/")) &&
        !g_uri_get_query(uri) && !g_uri_get_fragment(uri)) return uri;
    if (uri) g_uri_unref(uri);
    return NULL;
}

static int origin_port(GUri *uri) {
    const int configured = g_uri_get_port(uri);
    return configured < 0 ? 443 : configured;
}

static gboolean allows_external(const flint_webkit_window *window, const char *text) {
    if (!window->approved || !text) return FALSE;
    GUri *uri = g_uri_parse(text, G_URI_FLAGS_NONE, NULL);
    const gboolean allowed = valid_origin(uri) &&
        g_ascii_strcasecmp(g_uri_get_host(uri), g_uri_get_host(window->approved)) == 0 &&
        origin_port(uri) == origin_port(window->approved);
    if (uri) g_uri_unref(uri);
    return allowed;
}

static gboolean policy(WebKitWebView *view, WebKitPolicyDecision *decision,
                       WebKitPolicyDecisionType type, gpointer data) {
    (void)view;
    flint_webkit_window *window = data;
    if (type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION) {
        WebKitNavigationAction *navigation =
            webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
        WebKitURIRequest *request = webkit_navigation_action_get_request(navigation);
        const char *uri = request ? webkit_uri_request_get_uri(request) : NULL;
        if (exact(uri, window->uri) || allows_external(window, uri)) {
            window->local_committed = 0;
            webkit_policy_decision_use(decision);
            return TRUE;
        }
    } else if (type == WEBKIT_POLICY_DECISION_TYPE_RESPONSE) {
        WebKitResponsePolicyDecision *response = WEBKIT_RESPONSE_POLICY_DECISION(decision);
        WebKitURIRequest *request = webkit_response_policy_decision_get_request(response);
        const char *uri = request ? webkit_uri_request_get_uri(request) : NULL;
        if ((exact(uri, window->uri) || allows_external(window, uri)) &&
            webkit_response_policy_decision_is_mime_type_supported(response)) {
            webkit_policy_decision_use(decision);
            return TRUE;
        }
    }
    webkit_policy_decision_ignore(decision);
    return TRUE;
}

static GtkWidget *refuse_window(WebKitWebView *view, WebKitNavigationAction *action, gpointer data) {
    (void)view;
    (void)action;
    (void)data;
    return NULL;
}

static void load_changed(WebKitWebView *view, WebKitLoadEvent event, gpointer data) {
    flint_webkit_window *window = data;
    if (event == WEBKIT_LOAD_STARTED)
        window->local_committed = 0;
    else if (event == WEBKIT_LOAD_COMMITTED)
        window->local_committed = exact(webkit_web_view_get_uri(view), window->uri);
}

static void cancel_download(WebKitWebContext *context, WebKitDownload *download, gpointer data) {
    (void)context;
    (void)data;
    webkit_download_cancel(download);
}

static gboolean refuse_permission(WebKitWebView *view, WebKitPermissionRequest *request, gpointer data) {
    (void)view;
    (void)data;
    webkit_permission_request_deny(request);
    return TRUE;
}

static int number(JSCValue *value, uint32_t upper, uint32_t *result) {
    if (!value || !jsc_value_is_number(value)) return 0;
    const double number = jsc_value_to_double(value);
    if (!(number >= 0 && number <= upper)) return 0;
    const uint32_t whole = (uint32_t)number;
    if (number != whole) return 0;
    *result = whole;
    return 1;
}

static size_t read_message(JSCValue *value, uint8_t *bytes, size_t capacity) {
    if (!jsc_value_is_array(value)) return 0;
    JSCValue *size = jsc_value_object_get_property(value, "length");
    uint32_t length;
    const int valid = number(size, (uint32_t)capacity, &length);
    g_clear_object(&size);
    if (!valid) return 0;
    for (uint32_t i = 0; i < length; ++i) {
        JSCValue *item = jsc_value_object_get_property_at_index(value, i);
        uint32_t byte;
        const int accepted = number(item, 255, &byte);
        g_clear_object(&item);
        if (!accepted) return 0;
        bytes[i] = (uint8_t)byte;
    }
    return length;
}

/* Compile the versioned method registry into its exact wire bounds. */
#define IPC_METHODS(entry) entry(1, IPC_MAX)

static int ipc_payload(const uint8_t *bytes, size_t length) {
    if (length < IPC_HEADER || bytes[0] != IPC_VERSION) return 0;
    const size_t declared = (size_t)bytes[2] | (size_t)bytes[3] << 8;
    if (declared != length - IPC_HEADER) return 0;
    switch (bytes[1]) {
#define IPC_CASE(method, max) case method: return declared <= max;
        IPC_METHODS(IPC_CASE)
#undef IPC_CASE
    default: return 0;
    }
}

static void on_message(WebKitUserContentManager *content, WebKitJavascriptResult *message, gpointer data) {
    (void)content;
    flint_webkit_window *window = data;
    if (window->closing || !window->local_committed || !exact(webkit_web_view_get_uri(window->view), window->uri))
        return;
    uint8_t bytes[IPC_HEADER + IPC_MAX];
    JSCValue *value = webkit_javascript_result_get_js_value(message);
    const size_t length = value ? read_message(value, bytes, sizeof(bytes)) : 0;
    if (!ipc_payload(bytes, length)) return;
    const int status = flint_desktop_queue_post(window->slot, window->generation, FLINT_DESKTOP_MESSAGE,
                                               bytes + IPC_HEADER, length - IPC_HEADER);
    if (status == FLINT_DESKTOP_LIMIT) window->overload = 1;
}

static gboolean close_requested(GtkWidget *widget, GdkEvent *event, gpointer data) {
    (void)widget;
    (void)event;
    flint_webkit_window *window = data;
    window->closing = 1;
    return TRUE;
}

static void resized(GtkWidget *widget, GtkAllocation *allocation, gpointer data) {
    (void)widget;
    flint_webkit_window *window = data;
    window->resized = (flint_window_event){RESIZE, allocation->width, allocation->height, 0};
    window->resize_pending = 1;
}

static int setup(flint_webkit_window *window, const char *title, uint32_t width, uint32_t height, uint32_t flags) {
    window->widget = gtk_window_new(GTK_WINDOW_TOPLEVEL);
    if (!window->widget) return 0;
    g_object_ref_sink(window->widget);
    window->view = g_object_new(WEBKIT_TYPE_WEB_VIEW, "web-context", window->context,
                               "user-content-manager", window->content, NULL);
    if (!window->view) return 0;
    g_object_ref_sink(window->view);
    GtkWidget *view = GTK_WIDGET(window->view);
    WebKitSettings *settings = webkit_web_view_get_settings(window->view);
    webkit_settings_set_allow_file_access_from_file_urls(settings, FALSE);
    webkit_settings_set_allow_universal_access_from_file_urls(settings, FALSE);
    webkit_settings_set_javascript_can_open_windows_automatically(settings, FALSE);
    webkit_settings_set_enable_developer_extras(settings, FALSE);
    webkit_settings_set_hardware_acceleration_policy(settings, WEBKIT_HARDWARE_ACCELERATION_POLICY_NEVER);

    g_signal_connect(window->content, "script-message-received::flint", G_CALLBACK(on_message), window);
    if (!webkit_user_content_manager_register_script_message_handler(window->content, bridge_name))
        return 0;
    g_signal_connect(window->view, "load-changed", G_CALLBACK(load_changed), window);
    g_signal_connect(window->view, "decide-policy", G_CALLBACK(policy), window);
    g_signal_connect(window->view, "create", G_CALLBACK(refuse_window), window);
    g_signal_connect(window->view, "permission-request", G_CALLBACK(refuse_permission), window);
    g_signal_connect(window->context, "download-started", G_CALLBACK(cancel_download), window);
    g_signal_connect(window->widget, "delete-event", G_CALLBACK(close_requested), window);
    g_signal_connect(window->widget, "size-allocate", G_CALLBACK(resized), window);

    GtkWindow *top = GTK_WINDOW(window->widget);
    gtk_window_set_title(top, title);
    gtk_window_set_default_size(top, (int)width, (int)height);
    gtk_window_set_resizable(top, flags != 0);
    gtk_container_add(GTK_CONTAINER(window->widget), view);
    gtk_widget_show_all(window->widget);
    webkit_web_view_load_uri(window->view, window->uri);
    return 1;
}

flint_webkit_window *flint_webkit_window_new(const char *title, uint32_t width,
    uint32_t height, uint32_t flags, uint32_t slot, uint64_t generation,
    const char *asset, const uint8_t *html, size_t html_length, const char *https_origin) {
    if (!flint_desktop_main_thread() || !title || !asset || !https_origin || !width || !height ||
        width > 16384 || height > 16384 || (flags & ~1u) || (html_length && !html) ||
        html_length > 1024 * 1024 || slot >= FLINT_DESKTOP_WINDOWS || !generation ||
        !gtk_init_check(NULL, NULL)) return NULL;

    flint_webkit_window *window = calloc(1, sizeof(*window));
    if (!window) return NULL;
    window->generation = generation;
    window->slot = slot;
    if (*https_origin) {
        window->approved = approved_origin(https_origin);
        if (!window->approved) {
            flint_webkit_window_free(window);
            return NULL;
        }
    }
    window->uri = g_strdup_printf("flint-app://g-%" G_GUINT64_FORMAT ".desktop.local/%s", generation, asset);
    window->context = webkit_web_context_new_ephemeral();
    window->content = webkit_user_content_manager_new();
    if (!window->context || !window->content) {
        flint_webkit_window_free(window);
        return NULL;
    }

    static const char fallback[] = "<!doctype html><meta charset=utf-8><title>Flint</title>";
    app_page *page = g_new0(app_page, 1);
    page->uri = g_strdup(window->uri);
    page->html = html_length ? g_bytes_new(html, html_length) : g_bytes_new_static(fallback, sizeof(fallback) - 1);
    webkit_web_context_register_uri_scheme(window->context, app_scheme, serve_page, page, release_page);
    WebKitSecurityManager *security = webkit_web_context_get_security_manager(window->context);
    webkit_security_manager_register_uri_scheme_as_secure(security, app_scheme);
    if (setup(window, title, width, height, flags)) return window;
    flint_webkit_window_free(window);
    return NULL;
}

int flint_webkit_window_poll(flint_webkit_window *window, flint_window_event *event) {
    if (!flint_desktop_main_thread()) return -FLINT_DESKTOP_DENIED;
    if (!window || !event) return -FLINT_DESKTOP_INVALID;
    for (size_t i = 0; i < FLINT_DESKTOP_EVENTS && g_main_context_pending(NULL); ++i)
        g_main_context_iteration(NULL, FALSE);
    if (window->closing) {
        *event = (flint_window_event){CLOSE, 0, 0, 0};
        return 1;
    }
    if (window->overload) {
        window->overload = 0;
        return -FLINT_DESKTOP_LIMIT;
    }
    if (!window->resize_pending) return 0;
    window->resize_pending = 0;
    *event = window->resized;
    return 1;
}

void flint_webkit_window_free(flint_webkit_window *window) {
    if (!window || !flint_desktop_main_thread()) return;
    window->closing = 1;
    if (window->content) {
        g_signal_handlers_disconnect_by_data(window->content, window);
        webkit_user_content_manager_unregister_script_message_handler(window->content, bridge_name);
    }
    if (window->view) {
        g_signal_handlers_disconnect_by_data(window->view, window);
        webkit_web_view_stop_loading(window->view);
    }
    if (window->context) g_signal_handlers_disconnect_by_data(window->context, window);
    if (window->widget) {
        g_signal_handlers_disconnect_by_data(window->widget, window);
        gtk_widget_destroy(window->widget);
    }
    g_clear_object(&window->view);
    g_clear_object(&window->widget);
    g_clear_object(&window->content);
    g_clear_object(&window->context);
    if (window->approved) g_uri_unref(window->approved);
    g_free(window->uri);
    free(window);
}
