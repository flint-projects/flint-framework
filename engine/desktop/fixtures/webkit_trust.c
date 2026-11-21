/* Test-only trust for the ephemeral loopback HTTPS fixture. */
#include <gtk/gtk.h>
#include <webkit2/webkit2.h>

int flint_test_trust_loopback(const char *pem) {
    GError *error = NULL;
    GTlsCertificate *certificate = g_tls_certificate_new_from_file(pem, &error);
    if (!certificate) {
        g_clear_error(&error);
        return 0;
    }
    int configured = 0;
    GList *windows = gtk_window_list_toplevels();
    for (GList *item = windows; item; item = item->next) {
        GtkWidget *child = gtk_bin_get_child(GTK_BIN(item->data));
        if (WEBKIT_IS_WEB_VIEW(child)) {
            WebKitWebContext *context = webkit_web_view_get_context(WEBKIT_WEB_VIEW(child));
            webkit_web_context_allow_tls_certificate_for_host(context, certificate, "127.0.0.1");
            configured++;
        }
    }
    g_list_free(windows);
    g_object_unref(certificate);
    return configured == 1;
}
