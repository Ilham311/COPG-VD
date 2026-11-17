/*
 * Host test for the scope decision. Builds scope.cpp/spoof_module.cpp's logic
 * in isolation (the function under test has no JNI or Android dependency) and
 * asserts the security-relevant boundaries.
 *
 *   g++ -std=c++17 -O2 -Izygisk tests/scope_test.cpp -o scope_test
 *
 * The regression this exists for: inScope() used to end with `return true`,
 * so a misspelled scope_mode ("PlayStore", "whitelst", "playstore ") scoped
 * the spoof to EVERY process on the device with no error. Every unknown-mode
 * case below must stay narrow, not wide.
 */
#include <cstdio>
#include <string>
#include <vector>
#include <cctype>

/* The pieces of spoof_module.cpp that inScope() depends on, copied verbatim in
 * spirit but compiled here so the test has no Zygisk link step. If the two
 * ever drift, the real module is still covered by the ABI syntax gate in
 * run_host_tests.sh; this file's job is the decision table. */
namespace {

struct ScopeConfig {
    std::string mode = "playstore";
    std::vector<std::string> whitelist;
    std::vector<std::string> blacklist;
    std::vector<std::string> playstore;
    std::vector<std::string> drm_targets;
};

bool procMatches(const std::string& entry, const std::string& proc) {
    return proc == entry || proc.rfind(entry + ":", 0) == 0;
}

bool isKnownMode(const std::string& m) {
    return m == "playstore" || m == "global" || m == "whitelist" || m == "blacklist";
}

bool inScope(const ScopeConfig& sc, const std::string& proc) {
    if (sc.mode == "whitelist") {
        for (const auto& e : sc.whitelist) if (procMatches(e, proc)) return true;
        return false;
    }
    if (sc.mode == "blacklist") {
        for (const auto& e : sc.blacklist) if (procMatches(e, proc)) return false;
        return true;
    }
    static const char* kPlayDefaults[] = {"com.google.android.gms", "com.android.vending"};
    if (sc.mode == "playstore") {
        if (sc.playstore.empty()) {
            if (proc == "com.google.android.gms.unstable") return true;
            for (const char* e : kPlayDefaults) if (procMatches(e, proc)) return true;
            return false;
        }
        for (const auto& e : sc.playstore) if (procMatches(e, proc)) return true;
        return false;
    }
    if (sc.mode == "global") return true;
    /* fail closed for anything unrecognised */
    if (proc == "com.google.android.gms.unstable") return true;
    for (const char* e : kPlayDefaults) if (procMatches(e, proc)) return true;
    return false;
}

bool inDrmScope(const ScopeConfig& sc, const std::string& proc) {
    if (!sc.drm_targets.empty()) {
        for (const auto& e : sc.drm_targets) if (procMatches(e, proc)) return true;
        return false;
    }
    return inScope(sc, proc);
}

int g_fail = 0;
void want(const char* what, bool got, bool expected) {
    if (got == expected) {
        std::printf("  ok   %-52s %s\n", what, expected ? "in scope" : "out of scope");
    } else {
        std::printf("  FAIL %-52s got %s, want %s\n", what,
                    got ? "in scope" : "out of scope", expected ? "in scope" : "out of scope");
        g_fail++;
    }
}

}  // namespace

int main() {
    const std::vector<std::string> play = {
        "com.google.android.gms", "com.google.android.gms.unstable", "com.android.vending"};

    std::printf("playstore (default shape)\n");
    {
        ScopeConfig sc;  // mode defaults to playstore, all lists empty
        want("gms", inScope(sc, "com.google.android.gms"), true);
        want("gms.unstable", inScope(sc, "com.google.android.gms.unstable"), true);
        want("vending", inScope(sc, "com.android.vending"), true);
        want("gms:remote child", inScope(sc, "com.google.android.gms:remote"), true);
        want("an unrelated app", inScope(sc, "com.example.bank"), false);
        want("a similar prefix (gms2)", inScope(sc, "com.google.android.gms2"), false);
    }

    std::printf("playstore with an explicit target list\n");
    {
        ScopeConfig sc;
        sc.playstore = {"com.google.android.gsf"};
        want("listed package", inScope(sc, "com.google.android.gsf"), true);
        want("gms is NOT implicitly included", inScope(sc, "com.google.android.gms"), false);
    }

    std::printf("whitelist\n");
    {
        ScopeConfig sc;
        sc.mode = "whitelist";
        sc.whitelist = {"com.example.app"};
        want("listed", inScope(sc, "com.example.app"), true);
        want("child process of listed", inScope(sc, "com.example.app:push"), true);
        want("empty whitelist blocks everything",
             [] { ScopeConfig e; e.mode = "whitelist"; return inScope(e, "com.google.android.gms"); }(),
             false);
    }

    std::printf("blacklist\n");
    {
        ScopeConfig sc;
        sc.mode = "blacklist";
        sc.blacklist = {"com.example.bank"};
        want("unlisted app still spoofed", inScope(sc, "com.example.other"), true);
        want("listed app excluded", inScope(sc, "com.example.bank"), false);
        want("child of listed app excluded", inScope(sc, "com.example.bank:remote"), false);
    }

    std::printf("global\n");
    {
        ScopeConfig sc;
        sc.mode = "global";
        want("everything", inScope(sc, "com.example.anything"), true);
    }

    std::printf("unknown mode must fail CLOSED (the regression)\n");
    {
        const char* bad_modes[] = {"PlayStore", "PLAYSTORE", "playstore ", " whitelst",
                                   "whitelist2", "blacklst", "", "globall"};
        for (const char* m : bad_modes) {
            ScopeConfig sc;
            sc.mode = m;
            std::string label = std::string("mode \"") + m + "\": unrelated app stays out";
            want(label.c_str(), inScope(sc, "com.example.bank"), false);
        }
        /* and the narrow default is still useful */
        ScopeConfig sc;
        sc.mode = "PlayStore";
        want("unknown mode still covers gms", inScope(sc, "com.google.android.gms"), true);
    }

    std::printf("mode recognition table\n");
    {
        want("playstore is known", isKnownMode("playstore"), true);
        want("global is known", isKnownMode("global"), true);
        want("whitelist is known", isKnownMode("whitelist"), true);
        want("blacklist is known", isKnownMode("blacklist"), true);
        want("PlayStore is not known (caller lower-cases)", isKnownMode("PlayStore"), false);
        want("empty is not known", isKnownMode(""), false);
    }

    std::printf("DRM scope is independent of the main scope\n");
    {
        ScopeConfig sc;
        sc.mode = "playstore";
        sc.drm_targets = {"com.netflix.mediaclient"};
        want("drm target outside the main scope", inDrmScope(sc, "com.netflix.mediaclient"), true);
        want("main-scope app is not a drm target", inDrmScope(sc, "com.google.android.gms"), false);
        ScopeConfig empty;
        want("empty drm_targets follows the main scope",
             inDrmScope(empty, "com.google.android.gms"), true);
        want("empty drm_targets excludes outsiders", inDrmScope(empty, "com.example.bank"), false);
    }

    if (g_fail) {
        std::printf("\n%d failure(s)\n", g_fail);
        return 1;
    }
    std::printf("\nall scope tests passed\n");
    return 0;
}
