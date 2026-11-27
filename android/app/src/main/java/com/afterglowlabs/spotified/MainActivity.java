package com.afterglowlabs.spotified;

import android.app.Activity;
import android.app.AlertDialog;
import android.app.DownloadManager;
import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.CookieManager;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebStorage;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;
import android.widget.Toolbar;
import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;

public final class MainActivity extends Activity {
    private static final String DEFAULT_SERVER = "https://nibiru-darklight-1.osiris-cosmological.ts.net:8443";
    private static final int BACKGROUND = Color.rgb(18, 8, 32);
    private WebView web;
    private LinearLayout offline;
    private TextView errorMessage;
    private String origin;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        origin = getPreferences(MODE_PRIVATE).getString("server", DEFAULT_SERVER);
        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(BACKGROUND);
        root.setOnApplyWindowInsetsListener((v, insets) -> {
            v.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            return insets.consumeSystemWindowInsets();
        });
        setContentView(root);
        Toolbar toolbar = new Toolbar(this);
        toolbar.setTitle("Spotified");
        toolbar.setTitleTextColor(Color.WHITE);
        toolbar.setBackgroundColor(BACKGROUND);
        toolbar.getMenu().add("Music server").setOnMenuItemClickListener(item -> { chooseServer(); return true; });
        toolbar.getMenu().add("Reload").setOnMenuItemClickListener(item -> { connect(); return true; });
        root.addView(toolbar, -1, dp(48));

        FrameLayout content = new FrameLayout(this);
        root.addView(content, new LinearLayout.LayoutParams(-1, 0, 1));
        web = new WebView(this);
        web.setBackgroundColor(BACKGROUND);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setAllowFileAccess(false);
        settings.setAllowContentAccess(false);
        settings.setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW);
        settings.setMediaPlaybackRequiresUserGesture(false);
        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(web, false);
        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient() {
            @Override public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri destination = request.getUrl();
                if (sameOrigin(destination)) return false;
                if (request.isForMainFrame() && request.hasGesture() && "https".equals(destination.getScheme())) {
                    Intent browser = new Intent(Intent.ACTION_VIEW, destination);
                    try { startActivity(browser); }
                    catch (ActivityNotFoundException e) { Toast.makeText(MainActivity.this, "No browser available", Toast.LENGTH_SHORT).show(); }
                }
                return true;
            }
            @Override public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame() && sameOrigin(request.getUrl())) showOffline(error.getDescription().toString());
            }
            @Override public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                CookieManager.getInstance().flush();
            }
        });
        web.setDownloadListener((url, agent, disposition, mime, size) -> download(Uri.parse(url), mime));
        content.addView(web);

        offline = new LinearLayout(this);
        offline.setOrientation(LinearLayout.VERTICAL);
        offline.setGravity(Gravity.CENTER);
        offline.setPadding(dp(24), dp(24), dp(24), dp(24));
        offline.setBackgroundColor(BACKGROUND);
        errorMessage = new TextView(this);
        errorMessage.setTextSize(16);
        errorMessage.setGravity(Gravity.CENTER);
        offline.addView(errorMessage);
        Button retry = new Button(this);
        retry.setText("Retry");
        retry.setOnClickListener(v -> connect());
        offline.addView(retry);
        Button change = new Button(this);
        change.setText("Change music server");
        change.setOnClickListener(v -> chooseServer());
        offline.addView(change);
        content.addView(offline);
        if (Build.VERSION.SDK_INT >= 33) getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT, this::goBack);
        connect();
    }

    private void connect() {
        offline.setVisibility(View.GONE);
        web.setVisibility(View.VISIBLE);
        web.loadUrl(origin + "/");
    }

    private void showOffline(String message) {
        web.setVisibility(View.GONE);
        offline.setVisibility(View.VISIBLE);
        errorMessage.setText("Couldn’t reach " + Uri.parse(origin).getHost() + "\n\n" + message);
    }

    static String serverOrigin(String text) {
        try {
            URI u = new URI(text.trim());
            String host = u.getHost();
            if (host == null || u.getUserInfo() != null || u.getQuery() != null || u.getFragment() != null
                    || !(u.getPath().isEmpty() || u.getPath().equals("/")) || u.getPort() == 0 || u.getPort() > 65535) return null;
            boolean https = "https".equalsIgnoreCase(u.getScheme());
            boolean local = "http".equalsIgnoreCase(u.getScheme()) && ("127.0.0.1".equals(host) || "localhost".equalsIgnoreCase(host));
            if (!https && !local) return null;
            int port = u.getPort() == (https ? 443 : 80) ? -1 : u.getPort();
            return new URI(https ? "https" : "http", null, host.toLowerCase(Locale.ROOT), port, null, null, null).toASCIIString();
        } catch (URISyntaxException e) { return null; }
    }

    private boolean sameOrigin(Uri uri) {
        if (uri.getScheme() == null || uri.getEncodedAuthority() == null) return false;
        return origin.equals(serverOrigin(uri.getScheme() + "://" + uri.getEncodedAuthority()));
    }

    private void chooseServer() {
        EditText address = new EditText(this);
        address.setSingleLine();
        address.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        address.setText(origin);
        address.selectAll();
        AlertDialog dialog = new AlertDialog.Builder(this).setTitle("Music server").setView(address)
                .setNegativeButton("Cancel", null).setPositiveButton("Connect", null).create();
        dialog.setOnShowListener(ignored -> dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v -> {
            String next = serverOrigin(address.getText().toString());
            if (next == null) { address.setError("Enter an HTTPS server address."); return; }
            dialog.dismiss();
            if (next.equals(origin)) { connect(); return; }
            web.stopLoading();
            web.loadUrl("about:blank");
            web.clearHistory();
            WebStorage.getInstance().deleteAllData();
            CookieManager.getInstance().removeAllCookies(removed -> {
                origin = next;
                getPreferences(MODE_PRIVATE).edit().putString("server", next).apply();
                connect();
            });
        }));
        dialog.show();
    }

    private void download(Uri uri, String mime) {
        if (!sameOrigin(uri)) return;
        DownloadManager.Request request = new DownloadManager.Request(uri);
        String cookie = CookieManager.getInstance().getCookie(uri.toString());
        if (cookie != null) request.addRequestHeader("Cookie", cookie);
        String path = uri.getQueryParameter("path");
        String name = path == null ? "Spotified music" : new java.io.File(path).getName();
        if (name.isEmpty() || name.equals(".") || name.equals("..")) name = "Spotified music";
        request.setTitle(name).setMimeType(mime).setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED);
        if (Build.VERSION.SDK_INT >= 29) request.setDestinationInExternalPublicDir(Environment.DIRECTORY_DOWNLOADS, name);
        try {
            ((DownloadManager)getSystemService(Context.DOWNLOAD_SERVICE)).enqueue(request);
            Toast.makeText(this, "Download started", Toast.LENGTH_SHORT).show();
        } catch (RuntimeException e) {
            Toast.makeText(this, "Couldn’t start the download", Toast.LENGTH_SHORT).show();
        }
    }

    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }

    private void goBack() {
        if (web.canGoBack()) web.goBack();
        else moveTaskToBack(true);
    }
    @Override public void onBackPressed() { goBack(); }

    @Override protected void onDestroy() {
        ((ViewGroup)web.getParent()).removeView(web);
        web.destroy();
        super.onDestroy();
    }
}
