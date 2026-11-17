#!/system/bin/sh
# ======================================================================
#  COPG-VD  ::  identity engine (SSAID / GSF / AAID)
#  Spoof your device fingerprint and build: Zygisk, KernelSU/APatch/Magisk.
#
#  SPDX-License-Identifier: Apache-2.0
#  Fork by VD171.  Identity module by Ilham311.
#
#  The three identifiers that are not part of the Build profile, and who owns
#  each one:
#
#    SSAID  Settings.Secure.ANDROID_ID
#           /data/system/users/<user>/settings_ssaid.xml    (system_server)
#    GSF ID the Play check-in id
#           /data/data/com.google.android.gms/databases/gservices.db
#    AAID   the advertising id
#           /data/data/com.google.android.gms/shared_prefs/adid_settings.xml
#
#  SSAID is derived, never invented: Android 8+ computes it as
#      HMAC-SHA256(ssaid_user_key, sum of len32be(sig)||sig)[:16]
#  over the package's signing certificates. Only PackageManager can hand out
#  those certificates, so the derivation runs in etc/copgvd_identity.dex
#  (com.vd171.copgvd.Identity), not here. This script only reads the user key,
#  calls the helper, and writes files with a backup first.
#
#  Usage:
#    identity.sh status
#    identity.sh generate [--seed S] [--ssaid HEX16] [--gsf DEC] [--aaid UUID]
#    identity.sh apply
#    identity.sh restore
#    identity.sh backup-list
#    identity.sh ssaid-for <user> <package>   read-only
#    identity.sh verify <user> <package>      compare derived vs stored
# ======================================================================

set -u

MODDIR=${0%/*}
MODULE_ID=COPG-VD
DATA_DIR=${COPGVD_DATA_DIR:-/data/adb/COPG-VD}
MODULE_DIR=${COPGVD_MODULE_DIR:-/data/adb/modules/COPG-VD}
STATE="$DATA_DIR/identity"
BACKUP="$STATE/backup"
OUT="$STATE/generated.conf"
DEX="$MODULE_DIR/etc/copgvd_identity.dex"

SSAID_DIR=/data/system/users
GS=com.google.android.gms
GSF_DB=/data/data/$GS/databases/gservices.db
GSF_DB_ALT=/data/data/com.google.android.gsf/databases/gservices.db
AAID_XML=/data/data/$GS/shared_prefs/adid_settings.xml

log() { echo "[$MODULE_ID:id] $*"; }
die() { echo "[$MODULE_ID:id] ERROR: $*" >&2; exit 1; }

# ------------------------------------------------------------- framework
# app_process needs BOOTCLASSPATH and friends. ksu.exec can strip the
# environment, so recover it from system_server once (the same trick the
# WebUI uses for the scope helper).
dex_env() {
    echo 'if [ -z "$BOOTCLASSPATH" ]; then S=$(pgrep system_server 2>/dev/null | head -1); ' \
         '[ -n "$S" ] && export $(cat /proc/$S/environ 2>/dev/null | tr "\0" "\n" | ' \
         'grep -E "^(BOOTCLASSPATH|DEX2OATBOOTCLASSPATH|SYSTEMSERVERCLASSPATH|ANDROID_ART_ROOT|ANDROID_I18N_ROOT|ANDROID_TZDATA_ROOT|ANDROID_DATA|ANDROID_ROOT)="); fi'
}

# identity_dex <verb> [args...] -> one JSON object on stdout
identity_dex() {
    [ -f "$DEX" ] || return 1
    _env=$(dex_env)
    sh -c "$_env; LD_LIBRARY_PATH= app_process -Djava.class.path='$DEX' /system/bin com.vd171.copgvd.Identity \"\$@\"" \
        sh "$@" 2>/dev/null
}

json_str() {  # json_str <json> <key> -> value, or empty
    printf '%s' "$1" | sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" | head -n 1
}

json_raw() {  # json_raw <json> <key> -> numeric/boolean value
    printf '%s' "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p" | head -n 1
}

# ---------------------------------------------------------------- helpers
mkstamp() { date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s; }

# mkdir is the only atomic create that is reliable across toybox versions.
new_backup_dir() {
    _stamp=$(mkstamp); _d="$BACKUP/$_stamp"; _n=1
    mkdir -p "$_d" 2>/dev/null || return 1
    while [ -n "$(ls -A "$_d" 2>/dev/null)" ]; do
        _d="$BACKUP/$_stamp-$_n"; _n=$((_n + 1))
        [ "$_n" -gt 50 ] && return 1
        mkdir -p "$_d" 2>/dev/null || return 1
    done
    printf '%s' "$_d"
}

rand_hex() {  # rand_hex <bytes>
    od -An -tx1 -N "$1" /dev/urandom 2>/dev/null | tr -d ' \n'
}

rand_uuid() {
    _h=$(rand_hex 16)
    [ "${#_h}" -eq 32 ] || return 1
    # version 4 in the third group, RFC 4122 variant in the fourth
    _w=$(printf '%s' "$_h" | cut -c17-20)
    _x=$(printf '%s' "$_h" | cut -c21-32)
    _var=$(printf '%s' "$_w" | cut -c1)
    case "$_var" in [89ab]) : ;; *) _w="a$(printf '%s' "$_w" | cut -c2-)";; esac
    printf '%s-%s-4%s-%s-%s' \
        "$(printf '%s' "$_h" | cut -c1-8)" "$(printf '%s' "$_h" | cut -c9-12)" \
        "$(printf '%s' "$_h" | cut -c14-16)" "$_w" "$_x"
}

valid_ssaid() {
    [ "${#1}" -eq 16 ] || return 1
    case "$1" in *[!0-9a-f]*) return 1;; esac
    [ "$1" = "9774d56d682e549c" ] && return 1   # pre-O placeholder
    return 0
}

valid_gsf() {
    case "$1" in ''|0*|*[!0-9]*) return 1;; esac
    [ "${#1}" -ge 2 ] && [ "${#1}" -le 20 ]
}

valid_aaid() {
    # 8-4-4-4-12, version 4, RFC 4122 variant. Checked by position rather than
    # as one long case pattern: a split pattern is accepted by bash and mksh
    # differently, and this file must run on whatever /system/bin/sh is.
    [ "${#1}" -eq 36 ] || return 1
    case "$1" in *[!0-9a-fA-F-]*) return 1;; esac
    [ "$(printf '%s' "$1" | cut -c9)" = "-" ] || return 1
    [ "$(printf '%s' "$1" | cut -c14)" = "-" ] || return 1
    [ "$(printf '%s' "$1" | cut -c19)" = "-" ] || return 1
    [ "$(printf '%s' "$1" | cut -c24)" = "-" ] || return 1
    [ "$(printf '%s' "$1" | cut -c15)" = "4" ] || return 1
    case "$(printf '%s' "$1" | cut -c20)" in
        [89abAB]) return 0;;
    esac
    return 1
}

user_key_of() {  # user_key_of <userId>
    _f="$SSAID_DIR/$1/settings_ssaid.xml"
    [ -f "$_f" ] || return 0
    sed -n 's/.*ssaid_user_key[^A-Fa-f0-9]*\([A-Fa-f0-9]\{32,64\}\).*/\1/p' "$_f" 2>/dev/null | head -n 1
}

first_package() {
    for p in com.google.android.gms com.android.vending com.google.android.gsf; do
        pm path "$p" >/dev/null 2>&1 && { echo "$p"; return 0; }
    done
    pm list packages 2>/dev/null | sed -n 's/^package://p' | head -n 1
}

# ------------------------------------------------------------- generators
gen_conf() {
    _seed=$1
    [ -n "$_seed" ] || die "generate needs a seed"
    _ssaid=${OV_SSAID:-}
    _gsf=${OV_GSF:-}
    _aaid=${OV_AAID:-}

    if [ -z "$_ssaid" ]; then
        _pkg=$(first_package)
        [ -n "$_pkg" ] || die "no installed package found to derive from"
        _j=$(identity_dex ssaid 0 "$_pkg") ||
            die "identity helper failed (is $DEX present and executable?)"
        case "$_j" in *'"ok":true'*) : ;; *) die "helper refused: $_j";; esac
        _ssaid=$(json_str "$_j" ssaid)
        log "derived SSAID for $_pkg from $(json_raw "$_j" signers) signer(s)"
    fi
    # Validate whatever we ended up with, derived or supplied. The check used
    # to sit inside the derive branch only, so an explicit --ssaid bypassed it.
    valid_ssaid "$_ssaid" || die "invalid SSAID: '$_ssaid' (want 16 lower-case hex)"

    if [ -z "$_gsf" ]; then
        # 16-18 decimal digits, high bit clear: the shape the checkin server
        # returns. sha256 of the seed, folded to digits, no leading zero.
        _gsf=$(printf '%s' "gsf:$_seed" | sha256sum | cut -d' ' -f1 |
               tr 'a-f' '0123456789' | sed 's/^0*//' | cut -c1-17)
    fi
    valid_gsf "$_gsf" || die "invalid GSF id: '$_gsf'"

    [ -n "$_aaid" ] || _aaid=$(rand_uuid) || die "no entropy for AAID"
    valid_aaid "$_aaid" || die "invalid AAID: '$_aaid'"

    mkdir -p "$STATE" 2>/dev/null || die "cannot create $STATE"
    { echo "# generated $(mkstamp) by identity.sh"
      echo "SSAID=$_ssaid"
      echo "GSF_ID=$_gsf"
      echo "AAID=$_aaid"
    } > "$OUT.tmp" && mv -f "$OUT.tmp" "$OUT" || die "cannot write $OUT"
    chmod 0600 "$OUT" 2>/dev/null
    log "SSAID=$_ssaid GSF=$_gsf AAID=$_aaid"
}

# ---------------------------------------------------------------- writes
# Every writer backs the file up first and refuses to continue if the backup
# is not readable: an identity write with no way back is not worth doing.
backup_file() {  # backup_file <file> <dest-name> -> 0 on success
    _src=$1; _name=$2
    _bd=$(new_backup_dir) || return 1
    cp -a "$_src" "$_bd/$_name" 2>/dev/null || return 1
    [ -s "$_bd/$_name" ] || return 1
    printf '%s' "$_bd"
}

apply_ssaid() {
    _val=$1
    _found=0
    for d in "$SSAID_DIR"/*; do
        [ -d "$d" ] || continue
        _f="$d/settings_ssaid.xml"
        [ -f "$_f" ] || continue
        _u=${d##*/}
        _bd=$(backup_file "$_f" "settings_ssaid.$_u.xml") ||
            die "backup failed for $_f - refusing to modify it"
        # Rewrite the value of every existing per-UID entry, keeping the UIDs,
        # the package names and the defaultValue fields untouched.
        sed -i "s/\(value=\"\)[0-9a-f]\{16\}\(\"\)/\1$_val\2/g" "$_f" 2>/dev/null
        _n=$(grep -c "value=\"$_val\"" "$_f" 2>/dev/null)
        log "user $_u: $_n entr(y|ies) now contain $_val (backup: $_bd)"
        _found=1
    done
    [ "$_found" = 1 ] || log "no settings_ssaid.xml yet; the value is derived on first read"
}

prop_of_db() {  # prop_of_db <db> -> current android_id, or empty
    [ -f "$1" ] || return 0
    if command -v sqlite3 >/dev/null 2>&1; then
        sqlite3 "$1" "SELECT value FROM main WHERE name='android_id';" 2>/dev/null | head -n 1
    else
        strings "$1" 2>/dev/null | grep -A1 -x 'android_id' | tail -n 1 | tr -dc '0-9'
    fi
}

apply_gsf() {
    _val=$1
    _db=""
    [ -f "$GSF_DB" ] && _db=$GSF_DB
    [ -z "$_db" ] && [ -f "$GSF_DB_ALT" ] && _db=$GSF_DB_ALT
    [ -n "$_db" ] || { log "no gservices.db - Play services not installed; skipped"; return 0; }

    _bd=$(backup_file "$_db" "gservices.db") || die "backup failed for $_db - refusing to modify it"
    if command -v sqlite3 >/dev/null 2>&1; then
        _before=$(prop_of_db "$_db")
        sqlite3 "$_db" "UPDATE main SET value='$_val' WHERE name='android_id';" 2>/dev/null
        _after=$(prop_of_db "$_db")
        if [ "$_after" = "$_val" ]; then
            log "gservices.db: android_id $_before -> $_val (backup: $_bd)"
        else
            log "gservices.db: update did not stick (still '$_after'); backup kept at $_bd"
        fi
    else
        log "sqlite3 is not available in this image; gservices.db left untouched"
        log "backup already taken at $_bd - write the row from the WebUI or install sqlite3"
    fi
}

apply_aaid() {
    _val=$1
    [ -f "$AAID_XML" ] || { log "no adid_settings.xml - Play services absent; skipped"; return 0; }
    _bd=$(backup_file "$AAID_XML" "adid_settings.xml") ||
        die "backup failed for $AAID_XML - refusing to modify it"
    sed -i "s|\(<string name=\"adid_key\">\)[^<]*\(</string>\)|\1$_val\2|g" "$AAID_XML" 2>/dev/null
    if grep -q "adid_key\">$_val<" "$AAID_XML" 2>/dev/null; then
        log "adid_settings.xml: adid_key now $_val (backup: $_bd)"
    else
        log "adid_settings.xml has no adid_key entry; left untouched (backup: $_bd)"
    fi
}

restart_consumers() {
    for p in $GS com.google.android.gms.unstable com.google.android.gsf com.android.vending; do
        _pid=$(pidof "$p" 2>/dev/null)
        [ -n "$_pid" ] && kill -9 $_pid 2>/dev/null && log "restarted $p"
    done
    # SettingsProvider caches the SSAID table inside system_server and has no
    # reload path that a script may use. A reboot is the honest answer.
    log "reboot so system_server re-reads settings_ssaid.xml"
}

# -------------------------------------------------------------- commands
cmd_status() {
    echo "state dir      : $STATE"
    echo "helper         : $([ -f "$DEX" ] && echo "$DEX" || echo "${DEX} (MISSING)")"
    echo "user 0 key     : $(user_key_of 0)"
    if [ -f "$OUT" ]; then
        echo "generated      :"
        sed -n 's/^\([A-Z_]*\)=/  \1=/p' "$OUT"
    else
        echo "generated      : none (run: identity.sh generate)"
    fi
    for d in "$SSAID_DIR"/*; do
        _f="$d/settings_ssaid.xml"
        [ -f "$_f" ] && echo "ssaid file     : $_f ($(wc -c < "$_f" 2>/dev/null) bytes)"
    done
    for f in "$GSF_DB" "$GSF_DB_ALT" "$AAID_XML"; do
        if [ -f "$f" ]; then echo "present        : $f"; else echo "absent         : $f"; fi
    done
    _gsf=$(prop_of_db "$GSF_DB")
    [ -z "$_gsf" ] && _gsf=$(prop_of_db "$GSF_DB_ALT")
    echo "gsf id in db   : ${_gsf:-unavailable}"
    echo "aaid in xml    : $(sed -n 's/.*adid_key">\([^<]*\)<.*/\1/p' "$AAID_XML" 2>/dev/null | head -n 1)"
    if [ -d "$BACKUP" ]; then
        echo "backups        : $(ls -1 "$BACKUP" 2>/dev/null | wc -l) set(s)"
    else
        echo "backups        : none"
    fi
    return 0
}

cmd_apply() {
    [ "$(id -u)" = 0 ] || die "apply needs root"
    [ -f "$OUT" ] || die "no generated profile; run: identity.sh generate"
    _ssaid=$(sed -n 's/^SSAID=//p' "$OUT")
    _gsf=$(sed -n 's/^GSF_ID=//p' "$OUT")
    _aaid=$(sed -n 's/^AAID=//p' "$OUT")
    valid_ssaid "$_ssaid" || die "profile SSAID is invalid: '$_ssaid'"
    valid_gsf "$_gsf" || die "profile GSF id is invalid: '$_gsf'"
    valid_aaid "$_aaid" || die "profile AAID is invalid: '$_aaid'"
    echo "applying SSAID=$_ssaid GSF=$_gsf AAID=$_aaid"
    apply_ssaid "$_ssaid"
    apply_gsf "$_gsf"
    apply_aaid "$_aaid"
    restart_consumers
    echo "status: applied"
}

cmd_restore() {
    [ "$(id -u)" = 0 ] || die "restore needs root"
    [ -d "$BACKUP" ] || die "no backups under $BACKUP"
    _latest=$(ls -1 "$BACKUP" 2>/dev/null | sort | tail -n 1)
    [ -n "$_latest" ] || die "no backups"
    _d="$BACKUP/$_latest"
    _n=0
    for f in "$_d"/*; do
        [ -f "$f" ] || continue
        case "$(basename "$f")" in
            settings_ssaid.*.xml)
                _u=$(basename "$f"); _u=${_u#settings_ssaid.}; _u=${_u%.xml}
                cp -a "$f" "$SSAID_DIR/$_u/settings_ssaid.xml" 2>/dev/null && { _n=$((_n + 1)); log "restored user $_u"; };;
            adid_settings.xml)
                cp -a "$f" "$AAID_XML" 2>/dev/null && { _n=$((_n + 1)); log "restored AAID"; };;
            gservices.db)
                for t in "$GSF_DB" "$GSF_DB_ALT"; do
                    [ -d "$(dirname "$t")" ] || continue
                    cp -a "$f" "$t" 2>/dev/null && { _n=$((_n + 1)); log "restored $t"; break; }
                done;;
        esac
    done
    restart_consumers
    echo "status: restored $_n file(s) from $_d"
}

cmd_backup_list() {
    [ -d "$BACKUP" ] || { echo "none"; return 0; }
    for d in $(ls -1 "$BACKUP" 2>/dev/null | sort); do
        echo "$d  ($(ls -1 "$BACKUP/$d" 2>/dev/null | wc -l) file(s))"
    done
}

# ------------------------------------------------------------- arguments
MODE=${1:-status}
[ $# -gt 0 ] && shift

OV_SSAID=""; OV_GSF=""; OV_AAID=""; SEED=""
ARG1=""; ARG2=""
while [ $# -gt 0 ]; do
    case "$1" in
        --seed)  SEED=${2:-}; shift 2;;
        --ssaid) OV_SSAID=${2:-}; shift 2;;
        --gsf)   OV_GSF=${2:-}; shift 2;;
        --aaid)  OV_AAID=${2:-}; shift 2;;
        -*)      shift;;
        *)       if [ -z "$ARG1" ]; then ARG1=$1; elif [ -z "$ARG2" ]; then ARG2=$1; fi; shift;;
    esac
done

case "$MODE" in
    status)      cmd_status ;;
    generate)    [ -n "$SEED" ] || SEED=$(rand_hex 16); gen_conf "$SEED" ;;
    apply)       cmd_apply ;;
    restore)     cmd_restore ;;
    backup-list) cmd_backup_list ;;
    ssaid-for)
        [ -n "$ARG2" ] || die "usage: identity.sh ssaid-for <user> <package>"
        identity_dex ssaid "${ARG1:-0}" "$ARG2" || die "identity helper unavailable"
        ;;
    verify)
        [ -n "$ARG2" ] || die "usage: identity.sh verify <user> <package>"
        identity_dex verify "${ARG1:-0}" "$ARG2" || die "identity helper unavailable"
        ;;
    *)
        echo "usage: identity.sh {status|generate|apply|restore|backup-list|ssaid-for|verify}" >&2
        exit 64;;
esac
