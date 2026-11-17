/*
 * ======================================================================
 *  COPG-VD  ::  identity engine
 *  Spoof your device fingerprint and build: Zygisk, KernelSU/APatch/Magisk.
 *
 *  Copyright (C) 2026  AlirezaParsi & VD171
 *  SPDX-License-Identifier: Apache-2.0
 *  Fork by VD171.  Identity module by Ilham311.
 *
 *  Licensed under the Apache License, Version 2.0; you may obtain a copy at
 *  http://www.apache.org/licenses/LICENSE-2.0
 * ======================================================================
 *
 *  Framework helper for the identifiers that cannot be read from a file.
 *
 *  SSAID (Settings.Secure.ANDROID_ID) is not a stored per-package value on
 *  Android 8+: SettingsProvider derives it as
 *
 *      HMAC-SHA256(ssaid_user_key, Σ len32be(sig) || sig)[0:16 hex]
 *
 *  with the package's signing certificates, and caches the result. The
 *  certificates live only in PackageManager. A shell script that parses
 *  `dumpsys package` gets a hex signature block, not the DER the algorithm
 *  consumes, and `dumpsys` needs the DUMP permission. So this helper talks to
 *  IPackageManager directly, the same way Scope.java does, and hands the raw
 *  DER to the MAC.
 *
 *  Run as root via app_process (no installed app):
 *      LD_LIBRARY_PATH= app_process -Djava.class.path=copgvd_identity.dex \
 *          /system/bin com.vd171.copgvd.Identity ssaid <userId> <package>
 *
 *  Verbs:
 *      ssaid <userId> <pkg>          derive the value the OS would return
 *      ssaid-file <userId> <pkg>     same, but read the user key from disk
 *      userkey <userId>              print (or create) the per-user key
 *      verify <userId> <pkg>         compare derived vs the stored value
 *      signers <pkg>                 list the signing cert sha256 per signer
 *
 *  Every verb prints one JSON object on stdout, like Scope.java, so the shell
 *  never has to parse prose.
 * ======================================================================
 */
package com.vd171.copgvd;

import android.content.pm.PackageInfo;
import android.os.IBinder;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.ByteArrayOutputStream;
import java.lang.reflect.Method;
import java.security.MessageDigest;
import java.util.Arrays;
import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

public final class Identity {

    /* The text form of settings_ssaid.xml is a plain key/value table. On
     * releases that store it as Android Binary XML the literal is still in
     * the string pool, so a byte scan finds it either way. */
    private static final int MAX_XML_BYTES = 4 * 1024 * 1024;

    // ------------------------------------------------------------ packages
    private static Object packageManager() throws Exception {
        Class<?> sm = Class.forName("android.os.ServiceManager");
        IBinder binder = (IBinder) sm.getMethod("getService", String.class).invoke(null, "package");
        if (binder == null) throw new IllegalStateException("package service unavailable");
        Class<?> stub = Class.forName("android.content.pm.IPackageManager$Stub");
        return stub.getMethod("asInterface", IBinder.class).invoke(null, binder);
    }

    /* getPackageInfo across SDK generations: the flags arg is int on older
     * APIs and long on newer ones, so the overload is picked by its type. */
    private static PackageInfo packageInfo(Object ipm, String pkg, int userId) throws Exception {
        Method best = null;
        for (Method m : ipm.getClass().getMethods()) {
            if (!"getPackageInfo".equals(m.getName())) continue;
            Class<?>[] pt = m.getParameterTypes();
            if (pt.length == 3 && pt[0] == String.class) { best = m; break; }
        }
        if (best == null) throw new NoSuchMethodException("getPackageInfo");
        Class<?>[] pt = best.getParameterTypes();
        Object flags = (pt[1] == long.class) ? (Object) 0L : (Object) 0;
        Object pi = best.invoke(ipm, pkg, flags, userId);
        if (pi == null) throw new IllegalStateException("no PackageInfo for " + pkg);
        return (PackageInfo) pi;
    }

    /* The signing certificates, in the order PackageManager reports them.
     * Order matters: AOSP feeds them into the MAC in array order, so a
     * reordered list produces a different (wrong) SSAID. */
    private static byte[][] signatures(PackageInfo pi) throws Exception {
        Object si = null;
        try { si = pi.getClass().getField("signingInfo").get(pi); } catch (Throwable ignore) {}
        if (si != null) {
            try {
                Object signers = si.getClass().getMethod("getApkContentsSigners").invoke(si);
                if (signers != null) {
                    Object[] arr = (Object[]) signers;
                    byte[][] out = new byte[arr.length][];
                    for (int i = 0; i < arr.length; i++) {
                        out[i] = (byte[]) arr[i].getClass().getMethod("toByteArray").invoke(arr[i]);
                    }
                    if (out.length > 0) return out;
                }
            } catch (Throwable ignore) {}
        }
        /* Pre-P legacy field: Signature[] */
        java.lang.reflect.Field f = pi.getClass().getField("signatures");
        Object[] arr = (Object[]) f.get(pi);
        if (arr == null || arr.length == 0) return new byte[0][];
        byte[][] out = new byte[arr.length][];
        for (int i = 0; i < arr.length; i++) {
            out[i] = (byte[]) arr[i].getClass().getMethod("toByteArray").invoke(arr[i]);
        }
        return out;
    }

    // ------------------------------------------------------------- SSAID
    /* generateSsaidLocked(), ported from
     * AOSP packages/SettingsProvider/.../SettingsProvider.java */
    private static String ssaid(String userKeyHex, byte[][] sigs) throws Exception {
        if (userKeyHex == null || userKeyHex.isEmpty()) throw new IllegalArgumentException("no user key");
        byte[] key = hexToBytes(userKeyHex);
        /* AOSP accepts 16-byte keys from the O preview and the current 32. */
        if (key.length != 16 && key.length != 32) {
            throw new IllegalArgumentException("user key must be 16 or 32 bytes, got " + key.length);
        }
        if (sigs == null || sigs.length == 0) throw new IllegalStateException("package has no signers");

        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        for (byte[] sig : sigs) {
            if (sig == null || sig.length == 0) throw new IllegalStateException("empty signature");
            int n = sig.length;
            mac.update(new byte[]{(byte) (n >>> 24), (byte) (n >>> 16), (byte) (n >>> 8), (byte) n});
            mac.update(sig);
        }
        /* "Only want first 64 bits", lower-case hex. */
        byte[] out = mac.doFinal();
        return toHex(out, 8, false);
    }

    private static final String SSAID_FILE = "/data/system/users/%d/settings_ssaid.xml";
    private static final String USER_KEY_ENTRY = "ssaid_user_key";

    /* settings_ssaid.xml holds the key as a 32-byte (or legacy 16-byte)
     * upper-case hex string. Read as bytes and scan, so it works for both
     * plain XML and Android Binary XML. */
    private static String readUserKey(int userId) throws Exception {
        String path = String.format(SSAID_FILE, userId);
        File f = new File(path);
        if (!f.canRead()) throw new IllegalStateException("cannot read " + path);
        byte[] data = readFile(f);
        String text = new String(data, "UTF-8");
        int at = text.indexOf(USER_KEY_ENTRY);
        if (at < 0) return null;
        /* Look ahead for the first run of 32 or 64 hex digits. */
        int i = at + USER_KEY_ENTRY.length();
        int end = Math.min(text.length(), i + 400);
        StringBuilder run = new StringBuilder();
        java.util.List<String> runs = new java.util.ArrayList<String>();
        for (; i < end; i++) {
            char c = text.charAt(i);
            boolean hex = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F');
            if (hex) run.append(c);
            else {
                if (run.length() == 32 || run.length() == 64) runs.add(run.toString());
                run.setLength(0);
            }
        }
        if (run.length() == 32 || run.length() == 64) runs.add(run.toString());
        return runs.isEmpty() ? null : runs.get(0);
    }

    /* A stable key for a user who has none yet. Derived from the build
     * fingerprint so it survives a reboot but changes when the profile does. */
    private static String makeUserKey() {
        try {
            String seed = android.os.Build.FINGERPRINT + "|" + android.os.Build.ID + "|copgvd";
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            return toHex(md.digest(seed.getBytes("UTF-8")), 32, true);
        } catch (Exception e) {
            throw new IllegalStateException("cannot derive a user key: " + e);
        }
    }

    // -------------------------------------------------------------- verbs
    private static void verbSsaid(int userId, String pkg) throws Exception {
        Object ipm = packageManager();
        PackageInfo pi = packageInfo(ipm, pkg, userId);
        byte[][] sigs = signatures(pi);
        String key = readUserKey(userId);
        String source = "file";
        if (key == null) { key = makeUserKey(); source = "derived"; }
        String value = ssaid(key, sigs);
        out("{\"ok\":true,\"verb\":\"ssaid\",\"package\":\"" + esc(pkg) + "\",\"userId\":" + userId
            + ",\"signers\":" + sigs.length + ",\"userKeySource\":\"" + source + "\""
            + ",\"ssaid\":\"" + value + "\"}");
    }

    private static void verbUserkey(int userId) throws Exception {
        String key = readUserKey(userId);
        boolean created = false;
        if (key == null) { key = makeUserKey(); created = true; }
        out("{\"ok\":true,\"verb\":\"userkey\",\"userId\":" + userId
            + ",\"present\":" + (!created) + ",\"userKey\":\"" + esc(key) + "\"}");
        if (created) {
            out("{\"warn\":\"no ssaid_user_key on disk; this value is derived, not stored. "
                + "Writing it needs a SettingsProvider change (see module docs).\"}");
        }
    }

    private static void verbVerify(int userId, String pkg) throws Exception {
        Object ipm = packageManager();
        PackageInfo pi = packageInfo(ipm, pkg, userId);
        byte[][] sigs = signatures(pi);
        String key = readUserKey(userId);
        String derived = (key == null) ? null : ssaid(key, sigs);
        /* The stored value is the one the provider cached for this uid. */
        String stored = storedSsaid(userId, pi.applicationInfo.uid);
        boolean match = derived != null && stored != null && derived.equals(stored);
        out("{\"ok\":true,\"verb\":\"verify\",\"package\":\"" + esc(pkg) + "\""
            + ",\"derived\":" + (derived == null ? "null" : "\"" + derived + "\"")
            + ",\"stored\":" + (stored == null ? "null" : "\"" + stored + "\"")
            + ",\"match\":" + match + "}");
    }

    private static String storedSsaid(int userId, int uid) {
        try {
            String path = String.format(SSAID_FILE, userId);
            String text = new String(readFile(new File(path)), "UTF-8");
            String needle = "name=\"" + uid + "\"";
            int at = text.indexOf(needle);
            if (at < 0) return null;
            int end = Math.min(text.length(), at + 200);
            String win = text.substring(at, end);
            java.util.regex.Matcher m =
                java.util.regex.Pattern.compile("value=\"([0-9a-f]{16})\"").matcher(win);
            return m.find() ? m.group(1) : null;
        } catch (Throwable t) {
            return null;
        }
    }

    private static void verbSigners(String pkg) throws Exception {
        Object ipm = packageManager();
        PackageInfo pi = packageInfo(ipm, pkg, 0);
        byte[][] sigs = signatures(pi);
        StringBuilder sb = new StringBuilder("{\"ok\":true,\"verb\":\"signers\",\"package\":\"");
        sb.append(esc(pkg)).append("\",\"certificates\":[");
        for (int i = 0; i < sigs.length; i++) {
            if (i > 0) sb.append(',');
            MessageDigest md = MessageDigest.getInstance("SHA-256");
            sb.append("\"").append(toHex(md.digest(sigs[i]), 32, false)).append("\"");
        }
        sb.append("]}");
        out(sb.toString());
    }

    // ------------------------------------------------------------ helpers
    private static byte[] readFile(File f) throws Exception {
        FileInputStream in = new FileInputStream(f);
        try {
            ByteArrayOutputStream bos = new ByteArrayOutputStream();
            byte[] buf = new byte[8192];
            int n, total = 0;
            while ((n = in.read(buf)) != -1) {
                total += n;
                if (total > MAX_XML_BYTES) throw new IllegalStateException("file too large");
                bos.write(buf, 0, n);
            }
            return bos.toByteArray();
        } finally { in.close(); }
    }

    private static byte[] hexToBytes(String s) {
        int n = s.length() / 2;
        byte[] out = new byte[n];
        for (int i = 0; i < n; i++) {
            int hi = Character.digit(s.charAt(i * 2), 16);
            int lo = Character.digit(s.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) throw new IllegalArgumentException("not hex");
            out[i] = (byte) ((hi << 4) | lo);
        }
        return out;
    }

    private static String toHex(byte[] d, int len, boolean upper) {
        final char[] lo = "0123456789abcdef".toCharArray();
        final char[] up = "0123456789ABCDEF".toCharArray();
        char[] set = upper ? up : lo;
        StringBuilder sb = new StringBuilder(len * 2);
        for (int i = 0; i < len && i < d.length; i++) {
            sb.append(set[(d[i] >> 4) & 0xf]);
            sb.append(set[d[i] & 0xf]);
        }
        return sb.toString();
    }

    private static String esc(String s) {
        if (s == null) return "";
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"': b.append("\\\""); break;
                case '\\': b.append("\\\\"); break;
                case '\n': b.append("\\n"); break;
                case '\r': b.append("\\r"); break;
                case '\t': b.append("\\t"); break;
                default: if (c < 0x20) b.append(String.format("\\u%04x", (int) c)); else b.append(c);
            }
        }
        return b.toString();
    }

    private static void out(String s) { System.out.println(s); }

    // --------------------------------------------------------------- main
    public static void main(String[] args) {
        try {
            String verb = args.length > 0 ? args[0] : "";
            if ("ssaid".equals(verb) || "ssaid-file".equals(verb)) {
                int userId = args.length > 1 ? parseInt(args[1], 0) : 0;
                String pkg = args.length > 2 ? args[2] : "";
                if (pkg.isEmpty()) throw new IllegalArgumentException("ssaid needs <userId> <package>");
                verbSsaid(userId, pkg);
            } else if ("userkey".equals(verb)) {
                verbUserkey(args.length > 1 ? parseInt(args[1], 0) : 0);
            } else if ("verify".equals(verb)) {
                int userId = args.length > 1 ? parseInt(args[1], 0) : 0;
                String pkg = args.length > 2 ? args[2] : "";
                if (pkg.isEmpty()) throw new IllegalArgumentException("verify needs <userId> <package>");
                verbVerify(userId, pkg);
            } else if ("signers".equals(verb)) {
                if (args.length < 2) throw new IllegalArgumentException("signers needs <package>");
                verbSigners(args[1]);
            } else {
                out("{\"ok\":false,\"code\":\"ERR_VERB\",\"usage\":\"ssaid|userkey|verify|signers\"}");
            }
        } catch (Throwable t) {
            out("{\"ok\":false,\"code\":\"ERR_IDENTITY\",\"message\":\"" + esc(t.toString()) + "\"}");
        }
        System.out.flush();
        System.exit(0);
    }

    private static int parseInt(String s, int fallback) {
        try { return Integer.parseInt(s); } catch (NumberFormatException e) { return fallback; }
    }
}
