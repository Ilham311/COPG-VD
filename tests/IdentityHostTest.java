/*
 * Host test for the shipping Identity.ssaid() implementation.
 *
 *   javac -d out tests/IdentityHostTest.java dex/src/com/vd171/copgvd/Identity.java
 *   java -cp out com.vd171.copgvd.IdentityHostTest
 *
 * The method under test is the real one from dex/src, reached by reflection
 * because it is private (it is not part of any public surface on the device).
 * The expected values come from tests/identity_reference.py, which implements
 * generateSsaidLocked() from the AOSP source with the Python standard library
 * and shares no code with the Java side.
 *
 * This cannot run device-only verbs (packageManager, readUserKey); those need
 * root and an Android runtime and are covered by tests/device.
 */
package com.vd171.copgvd;

import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;

public final class IdentityHostTest {

    private static int failed = 0;

    private static Method ssaidMethod;

    private static String derive(String keyHex, byte[]... sigs) throws Exception {
        return (String) ssaidMethod.invoke(null, keyHex, sigs);
    }

    private static byte[] b(String s) { return s.getBytes(StandardCharsets.UTF_8); }

    private static void check(String what, String got, String want) {
        if (want.equals(got)) {
            System.out.println("  ok   " + what);
        } else {
            System.out.println("  FAIL " + what + "\n       got  " + got + "\n       want " + want);
            failed++;
        }
    }

    private static void expectThrows(String what, Runnable r) {
        try {
            r.run();
            System.out.println("  FAIL " + what + " (no exception)");
            failed++;
        } catch (RuntimeException e) {
            System.out.println("  ok   " + what);
        } catch (Exception e) {
            System.out.println("  ok   " + what);
        }
    }

    public static void main(String[] args) throws Exception {
        ssaidMethod = Identity.class.getDeclaredMethod("ssaid", String.class, byte[][].class);
        ssaidMethod.setAccessible(true);

        System.out.println("SSAID (AOSP algorithm, Java port)");
        check("16-byte key, one signature",
              derive("00112233445566778899aabbccddeeff", b("signature-one")),
              "2e9cbbd1cbba42e2");
        check("32-byte key, one signature",
              derive("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
                     b("signature-one")),
              "642f2380d0e4627f");
        check("16-byte key, two signatures in order",
              derive("AABBCCDDEEFF00112233445566778899", b("sigA"), b("signature-B")),
              "941cfd46edd36929");

        System.out.println("properties the port must preserve");
        check("length prefix prevents concatenation collision",
              derive("00112233445566778899aabbccddeeff", b("one"), b("two"))
                      .equals(derive("00112233445566778899aabbccddeeff", b("onetwo")))
                      ? "collided" : "distinct",
              "distinct");
        check("signature order matters",
              derive("00112233445566778899aabbccddeeff", b("sigA"), b("sigB"))
                      .equals(derive("00112233445566778899aabbccddeeff", b("sigB"), b("sigA")))
                      ? "same" : "different",
              "different");
        check("key hex case does not matter",
              derive("00112233445566778899aabbccddeeff", b("x"))
                      .equals(derive("00112233445566778899AABBCCDDEEFF", b("x")))
                      ? "same" : "different",
              "same");
        check("output is 16 chars", String.valueOf(derive("00112233445566778899aabbccddeeff", b("x")).length()), "16");
        check("output is lower-case hex",
              derive("00112233445566778899aabbccddeeff", b("x")).matches("[0-9a-f]{16}")
                      ? "yes" : "no",
              "yes");

        System.out.println("rejections (the caller keeps the real value)");
        expectThrows("no signers", () -> {
            try { derive("00112233445566778899aabbccddeeff"); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        expectThrows("12-byte key", () -> {
            try { derive("00112233445566778899aabb", b("x")); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        expectThrows("odd-length key", () -> {
            try { derive("abc", b("x")); }
            catch (Exception e) { throw new RuntimeException(e); }
        });
        expectThrows("non-hex key", () -> {
            try { derive("zz112233445566778899aabbccddeeff", b("x")); }
            catch (Exception e) { throw new RuntimeException(e); }
        });

        System.out.println("a realistic certificate (DER length ~1.2 KB)");
        byte[] der = new byte[1206];
        der[0] = 0x30; der[1] = (byte) 0x82; der[2] = 0x04; der[3] = (byte) 0xb2;
        for (int i = 4; i < der.length; i++) der[i] = (byte) 0x11;
        check("long DER matches the python reference",
              derive("00".repeat(32), der), "22d0cdfd60b8cd29");

        if (failed > 0) {
            System.out.println("\n" + failed + " FAILURE(S)");
            System.exit(1);
        }
        System.out.println("\nall host identity tests passed");
    }
}
