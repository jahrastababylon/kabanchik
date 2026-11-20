package com.tropami.app;

import android.content.ActivityNotFoundException;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;

import androidx.core.content.FileProvider;

import com.getcapacitor.JSObject;
import com.getcapacitor.Plugin;
import com.getcapacitor.PluginCall;
import com.getcapacitor.PluginMethod;
import com.getcapacitor.annotation.CapacitorPlugin;

import java.io.File;

/**
 * Udostępnianie prosto do wybranej aplikacji (Instagram, Facebook, X, WhatsApp) — bez systemowej listy.
 * JS: Capacitor.Plugins.ShareTo.share({ package, path, text }) — path to file:// z Filesystem (katalog CACHE).
 * Gdy aplikacji nie ma w telefonie, zwraca błąd "not_installed" (strona wtedy używa innej drogi).
 */
@CapacitorPlugin(name = "ShareTo")
public class ShareToPlugin extends Plugin {

    private boolean installed(String pkg) {
        try {
            getContext().getPackageManager().getPackageInfo(pkg, 0);
            return true;
        } catch (PackageManager.NameNotFoundException e) {
            return false;
        }
    }

    @PluginMethod
    public void installed(PluginCall call) {
        JSObject r = new JSObject();
        for (String p : new String[] { "com.instagram.android", "com.facebook.katana", "com.twitter.android", "com.whatsapp" }) {
            r.put(p, installed(p));
        }
        call.resolve(r);
    }

    @PluginMethod
    public void share(PluginCall call) {
        String pkg = call.getString("package");
        String path = call.getString("path");
        String text = call.getString("text");
        if (pkg == null || !installed(pkg)) {
            call.reject("not_installed");
            return;
        }
        Intent intent = new Intent(Intent.ACTION_SEND);
        intent.setPackage(pkg);
        if (path != null && !path.isEmpty()) {
            try {
                String p = path.startsWith("file:") ? Uri.parse(path).getPath() : path;
                Uri uri = FileProvider.getUriForFile(getContext(), getContext().getPackageName() + ".fileprovider", new File(p));
                intent.setType("image/png");
                intent.putExtra(Intent.EXTRA_STREAM, uri);
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                getContext().grantUriPermission(pkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
            } catch (Exception e) {
                call.reject("file_error", e);
                return;
            }
        } else {
            intent.setType("text/plain");
        }
        if (text != null) intent.putExtra(Intent.EXTRA_TEXT, text);
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        try {
            getActivity().startActivity(intent);
            call.resolve();
        } catch (ActivityNotFoundException e) {
            call.reject("not_installed");
        }
    }
}
