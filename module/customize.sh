# ======================================================================
#  COPG-VD  ::  global device spoofer
#  Spoof your device fingerprint and build: Zygisk, KernelSU/APatch/Magisk.
#
#  Copyright (C) 2026  AlirezaParsi & VD171
#  SPDX-License-Identifier: Apache-2.0
#  Fork by VD171.
#
#  Licensed under the Apache License, Version 2.0; you may obtain a copy at
#  http://www.apache.org/licenses/LICENSE-2.0
#
#  Site           : https://vd171.ru
#  Site           : https://vd.priv8.ru
#  Source         : https://github.com/VD171/COPG-VD
#  GitHub         : @VD171 https://github.com/VD171
#  XDA-Developers : @VD171 https://xdaforums.com/m/vd171.4699873/
#  XDA thread     : https://xdaforums.com/t/COPG-VD.4807698/
#  Telegram       : @VD_Priv8 https://t.me/VD_Priv8
#  Channel        : @Priv8_VD https://t.me/Priv8_VD
#  Discord        : @VD.Priv8 https://discord.com/users/1296831918989639721
#  E-mail         : vd.priv8@pm.me
# ======================================================================

ENABLE_GPHOTO_SPOOF=false
DATA_DIR="/data/adb/COPG-VD"
CONFIG_FILE="$DATA_DIR/COPG-VD.json"
LEGACY_JSON="/data/adb/COPG-VD.json"
CONFLICT_MODULES="COPG playintegrity playintegrityfix [i][n][t][e][g][r][i][t][y][-]*[b][o][x]"

# There are no volume-key prompts left in this installer. Both of them used to
# wait 10s and then pick a default, and the conflict prompt's default was to
# ABORT the install - which is what made a plain flash from the manager fail
# with "Failed to install module script" when a conflicting module was present.
# Choices are now read from the environment or from marker files under
# /data/local/tmp, so a flash is deterministic and never blocks.

print_box_start() {
  ui_print "╔═════════════════════════════════╗"
  ui_print "                                 "
}

print_box_end() {
  ui_print "                                 "
  ui_print "╚═════════════════════════════════╝"
}

print_empty_line() {
  ui_print "                                 "
}

print_failure_and_exit() {
  print_empty_line
  ui_print " ✗ Installation Failed!          "
  print_box_end
  exit 1
}

grep_prop() {
  local PROP_FILE="$1"
  local PROP_NAME="$2"
  if [ -f "$PROP_FILE" ]; then
    grep "^${PROP_NAME}=" "$PROP_FILE" | cut -d'=' -f2- | head -n 1
  else
    echo ""
  fi
}

print_module_version() {
  print_box_start
  ui_print "      ✦ COPG-VD Module Version ✦    "
  print_empty_line
  MODULE_PROP="$MODPATH/module.prop"
  if [ -f "$MODULE_PROP" ]; then
    MODULE_VERSION=$(grep_prop "$MODULE_PROP" "version")
    MODULE_VERSION_CODE=$(grep_prop "$MODULE_PROP" "versionCode")
    if [ -n "$MODULE_VERSION" ]; then
      ui_print " ✔ Module Version: $MODULE_VERSION "
      [ -n "$MODULE_VERSION_CODE" ] && ui_print " ✔ Version Code: $MODULE_VERSION_CODE "
    else
      ui_print " ✗ Could Not Read Module Version! "
    fi
  else
    ui_print " ✗ module.prop Not Found!        "
  fi
  print_box_end
  print_empty_line
}

# No volume-key prompt. A flash from the manager has nobody to press a key, and
# waiting 10s only to fall back was pure delay; two prompts meant a failed
# install could be caused by a timeout rather than by anything wrong.
#
# Unlimited Photos is on by default because it is the shipped intent of this
# block (it patches the Pixel sysconfig files that gate the feature), and it is
# one of the two things the upstream README tells you the module is for. To keep
# it off, either set COPGVD_GPHOTO=false in the environment, or write
# /data/local/tmp/.copgvd_gphoto containing "false".
prompt_gphoto_spoof() {
  ENABLE_GPHOTO_SPOOF=true

  if [ -n "${COPGVD_GPHOTO:-}" ]; then
    ENABLE_GPHOTO_SPOOF="$COPGVD_GPHOTO"
  elif [ -f /data/local/tmp/.copgvd_gphoto ]; then
    ENABLE_GPHOTO_SPOOF="$(cat /data/local/tmp/.copgvd_gphoto 2>/dev/null || echo true)"
  fi

  case "$ENABLE_GPHOTO_SPOOF" in
    false|no|0|off) ENABLE_GPHOTO_SPOOF=false ;;
    *)              ENABLE_GPHOTO_SPOOF=true ;;
  esac

  print_box_start
  ui_print "      ✦ Google Photos Spoof ✦    "
  print_empty_line
  if $ENABLE_GPHOTO_SPOOF; then
    ui_print " ✔ Unlimited Photos: enabled     "
    ui_print "   (disable: COPGVD_GPHOTO=false)"
  else
    ui_print " ✗ Unlimited Photos: disabled    "
  fi
  print_box_end
}

setup_gphoto_spoof() {
  print_box_start
  ui_print "      ✦ Google Photos Spoof ✦    "
  print_empty_line
  ui_print " ⚙ Configuring Sysconfig Files   "
  mkdir -p "$MODPATH/system/product/etc/sysconfig" "$MODPATH/system/etc/sysconfig" 2>/dev/null
  if [ -d "/system/product/etc/sysconfig" ]; then
    find /system/product/etc/sysconfig -type f | while read -r file; do
      if grep -qE "PIXEL_2020_|PIXEL_2021_|PIXEL_2019_PRELOAD|PIXEL_2018_PRELOAD|PIXEL_2017_PRELOAD|PIXEL_2022_" "$file"; then
        filename=$(basename "$file")
        grep -vE "PIXEL_2020_|PIXEL_2021_|PIXEL_2022_|PIXEL_2018_PRELOAD|PIXEL_2019_PRELOAD|PIXEL_2017_PRELOAD" "$file" > \
          "$MODPATH/system/product/etc/sysconfig/$filename" 2>/dev/null
      fi
    done
  fi
  if [ -d "/system/etc/sysconfig" ]; then
    find /system/etc/sysconfig -type f | while read -r file; do
      if grep -qE "PIXEL_2020_|PIXEL_2021_|PIXEL_2019_PRELOAD|PIXEL_2018_PRELOAD|PIXEL_2017_PRELOAD|PIXEL_2022_" "$file"; then
        filename=$(basename "$file")
        grep -vE "PIXEL_2020_|PIXEL_2021_|PIXEL_2022_|PIXEL_2018_PRELOAD|PIXEL_2019_PRELOAD|PIXEL_2017_PRELOAD" "$file" > \
          "$MODPATH/system/etc/sysconfig/$filename" 2>/dev/null
      fi
    done
  fi
  find "$MODPATH/system/product/etc/sysconfig" "$MODPATH/system/etc/sysconfig" -type f 2>/dev/null | while read -r file; do
    chmod 0644 "$file"
    chcon u:object_r:system_file:s0 "$file"
  done

  ui_print " ✔ Unlimited Photos Configured   "
  print_box_end
}

cleanup_gphoto_directories() {
  rm -rf "$MODPATH/system/etc/sysconfig" 2>/dev/null
  rm -rf "$MODPATH/system/product/etc/sysconfig" 2>/dev/null
  rm -rf "$MODPATH/product/etc/sysconfig" 2>/dev/null
  
  find "$MODPATH" -type d -empty -delete 2>/dev/null
}

migrate_version_keys() {
  UPDATER="$MODPATH/fingerprint-update.sh"
  [ -f "$UPDATER" ] || return
  saida=$(sh "$UPDATER" migrate 2>&1)
  case "$saida" in
    *status:\ migrated*)
      print_box_start
      ui_print "    ✦ Android version removed ✦   "
      print_empty_line
      ui_print " ✔ The config asked to spoof the  "
      ui_print "   Android version. That is what  "
      ui_print "   makes Google apps crash and    "
      ui_print "   the phone reboot in circles.   "
      ui_print " ➤ Removed; backup kept as .bak   "
      print_box_end
      ;;
  esac
}

check_config_file() {
  mkdir -p "$DATA_DIR"
  chmod 0700 "$DATA_DIR"
  chcon u:object_r:system_file:s0 "$DATA_DIR" 2>/dev/null
  for pair in "$LEGACY_JSON|$CONFIG_FILE" \
              "/data/adb/COPG-VD.update.state|$DATA_DIR/update.state" \
              "/data/adb/COPG-VD.update.log|$DATA_DIR/update.log"; do
      old=${pair%%|*}; new=${pair##*|}
      [ -f "$old" ] && { [ -e "$new" ] || mv -f "$old" "$new"; rm -f "$old"; }
  done
  rm -f /data/adb/COPG-VD.json.bak /data/adb/.COPG-VD.update.* 2>/dev/null
  [ -f "$CONFIG_FILE" ] || cp "$MODPATH/COPG-VD.json.example" "$CONFIG_FILE"
  chmod 0644 "$CONFIG_FILE"
  chcon u:object_r:system_file:s0 "$CONFIG_FILE"
}

setup_vdlu() {
  [ -f "$MODPATH/vdlu/update.sh" ] || return 0
  chmod 0755 "$MODPATH/vdlu/update.sh" "$MODPATH/vdlu/vdlu-verify" 2>/dev/null
  [ -f "$MODPATH/post-fs-data.sh" ] && chmod 0755 "$MODPATH/post-fs-data.sh" 2>/dev/null
  # Slim build (Approach B): no bin/ ships. The embedded ed25519-mini verifiers
  # (all ABIs, ~20KB each) stay so the on-device tree matches the VDLU manifest;
  # the heavy curl toolchain is fetched into Tier-2 on first use, not bundled.
  [ -d "$MODPATH/vdlu/verify" ] &&
    find "$MODPATH/vdlu/verify" -name ed25519-mini -exec chmod 0755 {} + 2>/dev/null
  VDLU_DIR="$DATA_DIR/vdlu"
  if [ ! -f "$VDLU_DIR/config" ] && [ -f "$MODPATH/vdlu/config.default" ]; then
    mkdir -p "$VDLU_DIR"
    cp -f "$MODPATH/vdlu/config.default" "$VDLU_DIR/config"
    chmod 0644 "$VDLU_DIR/config"
    chcon u:object_r:system_file:s0 "$VDLU_DIR/config" 2>/dev/null
  fi
}

check_conflict_modules() {
  FOUND=""
  for module in $CONFLICT_MODULES; do
    for dir in $(find /data/adb/modules -mindepth 1 -maxdepth 1 -type d -iname "$module" 2>/dev/null); do
      FOUND="$FOUND $dir"
    done
  done
  [ -z "$FOUND" ] && return

  # No prompt. The install used to wait 10s for a volume key and then ABORT when
  # nobody pressed it, which made a normal flash from the manager fail with
  # "Failed to install module script" and left the user with nothing installed.
  # Removing the conflicting modules is the only outcome that leaves a working
  # spoof, so it happens automatically.
  #
  # Two guards keep that from being destructive:
  #   * the module is removed by the manager's own `remove` marker, not by rm -rf,
  #     so its own uninstall hook runs;
  #   * its directory is copied to /data/adb/COPG-VD/removed-modules/<stamp>/ first,
  #     so "why did my module disappear" has an answer and a way back.
  print_box_start
  ui_print " ✦ Found Conflicting Modules: ✦ "
  print_empty_line
  for found in $FOUND; do
    ui_print " . ${found##*/} "
  done
  print_empty_line
  ui_print " ➤ Removing them automatically   "
  ui_print " ➤ They cannot work together:    "
  ui_print "   both rewrite the same props.  "
  print_box_end
  print_empty_line

  if [ -n "$COPGVD_CONFLICT_KEEP" ]; then
    # Escape hatch for anyone who wants to decide for themselves.
    ui_print " ⌨ COPGVD_CONFLICT_KEEP set - leaving them in place"
    ui_print "   (the spoof may not apply until they are removed)"
    return
  fi

  STAMP=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)
  KEEP_DIR="$DATA_DIR/removed-modules/$STAMP"
  mkdir -p "$KEEP_DIR" 2>/dev/null
  chcon u:object_r:system_file:s0 "$DATA_DIR/removed-modules" 2>/dev/null

  for found in $FOUND; do
    name=${found##*/}
    # Keep a copy so the removal is reversible, then use the manager's markers.
    if [ -d "$KEEP_DIR" ]; then
      cp -a "$found" "$KEEP_DIR/$name" 2>/dev/null &&
        chcon -R u:object_r:system_file:s0 "$KEEP_DIR/$name" 2>/dev/null
    fi
    touch "$found/disable" 2>/dev/null
    touch "$found/remove" 2>/dev/null
    ui_print " ✔ removed: $name"
  done

  if [ -d "$KEEP_DIR" ]; then
    ui_print "   copy kept at:"
    ui_print "   $KEEP_DIR"
    ui_print "   restore: move it back to /data/adb/modules/"
  fi
  print_empty_line
}


print_module_version

if ! $BOOTMODE; then
  print_box_start
  ui_print "      ✦ Installation Error ✦     "
  print_empty_line
  ui_print " ✗ Recovery Mode Not Supported!  "
  ui_print " ➤ Install via Magisk/KSU/APatch "
  print_failure_and_exit
fi

if [ "$API" -lt 28 ]; then
  print_box_start
  ui_print "      ✦ Installation Error ✦     "
  print_empty_line
  ui_print " ✗ Android Version Too Old!      "
  ui_print " ➤ Requires Android 9.0+         "
  print_failure_and_exit
fi

check_conflict_modules
check_config_file
migrate_version_keys
setup_vdlu

chmod 0755 "$MODPATH/service.sh"
chmod 0755 "$MODPATH/fingerprint-update.sh"
# The identity writer rewrites files owned by system_server and Play services;
# it must be executable from boot, and its state directory must exist with the
# same context as the rest of the module data.
[ -f "$MODPATH/identity.sh" ] && chmod 0755 "$MODPATH/identity.sh" 2>/dev/null
[ -f "$MODPATH/etc/copgvd_identity.dex" ] && chmod 0644 "$MODPATH/etc/copgvd_identity.dex" 2>/dev/null
mkdir -p "$DATA_DIR/identity" 2>/dev/null
chmod 0700 "$DATA_DIR/identity" 2>/dev/null
chcon u:object_r:system_file:s0 "$DATA_DIR/identity" 2>/dev/null
chmod 0644 "$CONFIG_FILE"
chcon u:object_r:system_file:s0 "$CONFIG_FILE"

prompt_gphoto_spoof
if $ENABLE_GPHOTO_SPOOF; then
  setup_gphoto_spoof
else
  print_box_start
  ui_print "      ✦ Google Photos Spoof ✦    "
  print_empty_line
  ui_print " ⚙ Removing Google Photos Config "
  
  cleanup_gphoto_directories
  
  ui_print " ✔ Unlimited Photos Disabled    "
  print_box_end
fi

print_empty_line
print_box_start
ui_print " ✅ Module Successfully Installed "
print_box_end
