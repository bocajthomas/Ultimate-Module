require_new_ksu() {
  ui_print "**********************************"
  ui_print " Please install KernelSU v0.6.6+! "
  ui_print "**********************************"
  exit 1
}
umount_mirrors() {
  [ -d $ORIGDIR ] || return 0
  for i in $ORIGDIR/*; do
    umount -l $i 2>/dev/null
  done
  rm -rf $ORIGDIR 2>/dev/null
  $KSU && mount -o ro,remount $MAGISKTMP
}
cleanup() {
  if $KSU || [ $MAGISK_VER_CODE -ge 27000 ]; then umount_mirrors; fi
  rm -rf $MODPATH/common $MODPATH/install.zip 2>/dev/null
}
abort() {
  ui_print "$1"
  rm -rf $MODPATH 2>/dev/null
  cleanup
  rm -rf $TMPDIR 2>/dev/null
  exit 1
}
device_check() {
  local opt=`getopt -o dm -- "$@"` type=device
  eval set -- "$opt"
  while true; do
    case "$1" in
      -d) local type=device; shift;;
      -m) local type=manufacturer; shift;;
      --) shift; break;;
      *) abort "Invalid device_check argument $1! Aborting!";;
    esac
  done
  local prop=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  for i in /system /vendor /odm /product; do
    if [ -f $i/build.prop ]; then
      for j in "ro.product.$type" "ro.build.$type" "ro.product.vendor.$type" "ro.vendor.product.$type"; do
        [ "$(sed -n "s/^$j=//p" $i/build.prop 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]')" == "$prop" ] && return 0
      done
      [ "$type" == "device" ] && [ "$(sed -n "s/^"ro.build.product"=//p" $i/build.prop 2>/dev/null | head -n 1 | tr '[:upper:]' '[:lower:]')" == "$prop" ] && return 0
    fi
  done
  return 1
}
cp_ch() {
  local opt=`getopt -o nr -- "$@"` BAK=true UBAK=true FOL=false
  eval set -- "$opt"
  while true; do
    case "$1" in
      -n) UBAK=false; shift;;
      -r) FOL=true; shift;;
      --) shift; break;;
      *) abort "Invalid cp_ch argument $1! Aborting!";;
    esac
  done
  local SRC="$1" DEST="$2" OFILES="$1"
  $FOL && local OFILES=$(find $SRC -type f 2>/dev/null)
  [ -z $3 ] && PERM=0644 || PERM=$3
  case "$DEST" in
    $TMPDIR/*|$MODULEROOT/*|$NVBASE/modules/$MODID/*) BAK=false;;
  esac
  for OFILE in ${OFILES}; do
    if $FOL; then
      if [ "$(basename $SRC)" == "$(basename $DEST)" ]; then
        local FILE=$(echo $OFILE | sed "s|$SRC|$DEST|")
      else
        local FILE=$(echo $OFILE | sed "s|$SRC|$DEST/$(basename $SRC)|")
      fi
    else
      [ -d "$DEST" ] && local FILE="$DEST/$(basename $SRC)" || local FILE="$DEST"
    fi
    if $BAK && $UBAK; then
      [ ! "$(grep "$FILE$" $INFO 2>/dev/null)" ] && echo "$FILE" >> $INFO
      [ -f "$FILE" -a ! -f "$FILE~" ] && { mv -f $FILE $FILE~; echo "$FILE~" >> $INFO; }
    elif $BAK; then
      [ ! "$(grep "$FILE$" $INFO 2>/dev/null)" ] && echo "$FILE" >> $INFO
    fi
    install -D -m $PERM "$OFILE" "$FILE"
  done
}
install_script() {
  case "$1" in
    -b) shift; 
        if $KSU; then
          local INPATH=$NVBASE/boot-completed.d
        else
          local INPATH=$SERVICED
          sed -i -e '1i (\nwhile [ "$(getprop sys.boot_completed)" != "1" ]; do\n  sleep 1\ndone\nsleep 3\n' -e '$a)&' $1
        fi;;
    -l) shift; local INPATH=$SERVICED;;
    -p) shift; local INPATH=$POSTFSDATAD;;
    *) local INPATH=$SERVICED;;
  esac
  [ "$(grep "#!/system/bin/sh" $1)" ] || sed -i "1i #!/system/bin/sh" $1
  local i; for i in "MODPATH" "LIBDIR" "MODID" "INFO" "MODDIR"; do
    case $i in
      "MODPATH") sed -i "1a $i=$NVBASE/modules/$MODID" $1;;
      "MODDIR") sed -i "1a $i=\${0%/*}" $1;;
      *) sed -i "1a $i=$(eval echo \$$i)" $1;;
    esac
  done
  case $1 in
    "$MODPATH/post-fs-data.sh"|"$MODPATH/service.sh"|"$MODPATH/uninstall.sh") sed -i "s|^MODPATH=.*|MODPATH=\$MODDIR|" $1;; # MODPATH=MODDIR for these scripts (located in module directory)
    "$MODPATH/boot-completed.sh") $KSU && sed -i "s|^MODPATH=.*|MODPATH=\$MODDIR|" $1 || { cp_ch -n $1 $INPATH/$MODID-$(basename $1) 0755; rm -f $MODPATH/boot-completed.sh; };;
    *) cp_ch -n $1 $INPATH/$(basename $1) 0755;;
  esac
}
prop_process() {
  sed -i -e "/^#/d" -e "/^ *$/d" $1
  [ -f $MODPATH/system.prop ] || mktouch $MODPATH/system.prop
  while read LINE; do
    echo "$LINE" >> $MODPATH/system.prop
  done < $1
}
mount_mirrors() {
  $KSU && mount -o rw,remount $MAGISKTMP
  mkdir -p $ORIGDIR/system
  if $SYSTEM_ROOT; then
    mkdir -p $ORIGDIR/system_root
    mount -o ro / $ORIGDIR/system_root
    mount -o bind $ORIGDIR/system_root/system $ORIGDIR/system
  else
    mount -o ro /system $ORIGDIR/system
  fi
  for i in /vendor $PARTITIONS; do
    [ ! -d $i -o -d $ORIGDIR$i ] && continue
    mkdir -p $ORIGDIR$i
    mount -o ro $i $ORIGDIR$i
  done
}
ANDROID_SDK=$(getprop ro.build.version.sdk)
REQUIRED_SDK=36  # Android 16
wait_for_key() {
  while :; do
    keyevent=$(getevent -qlc 1 2>/dev/null | grep "KEY_" | head -n 1)
    case "$keyevent" in
      *KEY_VOLUMEUP*) echo "UP"; return ;;
      *KEY_VOLUMEDOWN*) echo "DOWN"; return ;;
      *KEY_POWER*) echo "POWER"; return ;;
    esac
  done
}
if [ "$ANDROID_SDK" -lt "$REQUIRED_SDK" ]; then
  ui_print "***************************************"
  ui_print " Device is not running Android 16/ONEUI 8, "
  ui_print "            Not Supported!             "
  ui_print "***************************************"
  ui_print "***********************************************"
  ui_print "Press Volume Up to continue at your own risk..."
  ui_print "***********************************************"
  FIRST_KEY=$(wait_for_key)
  if [ "$FIRST_KEY" = "UP" ]; then
    ui_print " Are you sure? Press Volume Down to confirm... "
	  ui_print "***********************************************"
    sleep 1  # pause to allow user to release Volume Up
    SECOND_KEY=$(wait_for_key)
    if [ "$SECOND_KEY" = "DOWN" ]; then
    ui_print " Confirmed, Proceeding with module flashing... "
	  ui_print "***********************************************"
    else
    ui_print "   Only Supported Android 16/ONEUI 8, Exiting!  "
	  ui_print "***********************************************"
	  echo " "
    exit 1
    fi
  else
    ui_print "   Supported Android 16/ONEUI 8, Exiting!  "
	  ui_print "***********************************************"
	  echo " "
    exit 1
  fi
else
  ui_print "***************************************"
  ui_print " Android version supported 16/ONEUI 8, "
  ui_print "   Proceeding with Installation....  "
  ui_print "***************************************"
  continue # remove this if you want print above texts.
fi
ui_print "*   AI thanks to @iman8943   *"
ui_print "******************************************"
[ -z $MINAPI ] || { [ $API -lt $MINAPI ] && abort "! Your system API of $API is less than the minimum api of $MINAPI! Aborting!"; }
[ -z $MAXAPI ] || { [ $API -gt $MAXAPI ] && abort "! Your system API of $API is greater than the maximum api of $MAXAPI! Aborting!"; }
[ -z $KSU ] && KSU=false
$KSU && { [ $KSU_VER_CODE -lt 11184 ] && require_new_ksu; }
[ -z $APATCH ] && APATCH=false
[ "$APATCH" == "true" ] && KSU=true
set -x
[ -z $ARCH32 ] && ARCH32="$(echo $ABI32 | cut -c-3)"
[ $API -lt 26 ] && DYNLIB=false
[ -z $DYNLIB ] && DYNLIB=false
[ -z $PARTOVER ] && PARTOVER=false
[ -z $SYSTEM_ROOT ] && SYSTEM_ROOT=$SYSTEM_AS_ROOT # renamed in magisk v26.3
[ -z $SERVICED ] && SERVICED=$NVBASE/service.d # removed in magisk v26.2
[ -z $POSTFSDATAD ] && POSTFSDATAD=$NVBASE/post-fs-data.d # removed in magisk v26.2
INFO=$NVBASE/modules/.$MODID-files
if $KSU; then
  MAGISKTMP="/mnt"
  ORIGDIR="$MAGISKTMP/mirror"
  mount_mirrors
elif [ "$(magisk --path 2>/dev/null)" ]; then
  if [ $MAGISK_VER_CODE -ge 27000 ]; then # Atomic Mount
    if [ -z $MAGISKTMP ]; then
      [ -d /sbin ] && MAGISKTMP=/sbin || MAGISKTMP=/debug_ramdisk
    fi
    ORIGDIR="$MAGISKTMP/mirror"
    mount_mirrors
  else
    ORIGDIR="$(magisk --path 2>/dev/null)/.magisk/mirror"
  fi
elif [ "$(echo $MAGISKTMP | awk -F/ '{ print $NF}')" == ".magisk" ]; then
  ORIGDIR="$MAGISKTMP/mirror"
else
  ORIGDIR="$MAGISKTMP/.magisk/mirror"
fi
if $DYNLIB; then
  LIBPATCH="\/vendor"
  LIBDIR=/system/vendor
else
  LIBPATCH="\/system"
  LIBDIR=/system
fi
EXTRAPART=false
if $KSU || [ "$(echo $MAGISK_VER | awk -F- '{ print $NF}')" == "delta" ] || [ "$(echo $MAGISK_VER | awk -F- '{ print $NF}')" == "kitsune" ]; then
  EXTRAPART=true
elif ! $PARTOVER; then
  unset PARTITIONS
fi
if ! $BOOTMODE; then
  ui_print "- Only uninstall is supported in recovery"
  ui_print "  Uninstalling!"
  touch $MODPATH/remove
  [ -s $INFO ] && install_script $MODPATH/uninstall.sh || rm -f $INFO $MODPATH/uninstall.sh
  recovery_cleanup
  cleanup
  rm -rf $NVBASE/modules_update/$MODID $TMPDIR 2>/dev/null
  exit 0
fi

ui_print "- Downloading required files..."

# Function to download a file
# $1: file name
# $2: destination path
download_file() {
  local file_name="$1"
  local dest_path="$2"
  local url="https://github.com/DaDevMikey/one-ui-8.5-apk-s/releases/download/3.0.0-CYK7/$file_name"
  local download_path="$TMPDIR/$file_name"

  ui_print "  Downloading $file_name..."
  # Using curl with location following and output to file
  if ! curl -L -o "$download_path" "$url"; then
    abort "! Download failed for $file_name"
  fi

  mkdir -p "$(dirname "$dest_path")"
  mv -f "$download_path" "$dest_path"
  ui_print "  $file_name downloaded."
}

# List of files to download
download_file "AODService_v80.apk" "$MODPATH/system/priv-app/AODService_v80/AODService_v80.apk"
download_file "DeviceDiagnostics.apk" "$MODPATH/system/priv-app/DeviceDiagnostics/DeviceDiagnostics.apk"
download_file "DigitalWellbeing.apk" "$MODPATH/system/priv-app/DigitalWellbeing/DigitalWellbeing.apk"
download_file "DressRoom.apk" "$MODPATH/system/priv-app/DressRoom/DressRoom.apk"
download_file "GalaxyApps_OPEN.apk" "$MODPATH/system/priv-app/GalaxyApps_OPEN/GalaxyApps_OPEN.apk"
download_file "GalaxyResourceUpdater.apk" "$MODPATH/system/app/GalaxyResourceUpdater/GalaxyResourceUpdater.apk"
download_file "GalleryWidget.apk" "$MODPATH/system/app/GalleryWidget/GalleryWidget.apk"
download_file "Moments.apk" "$MODPATH/system/priv-app/Moments/Moments.apk"
download_file "MultiControl.apk" "$MODPATH/system/priv-app/MultiControl/MultiControl.apk"
download_file "MyDevice.apk" "$MODPATH/system/priv-app/MyDevice/MyDevice.apk"
download_file "PhotoEditor_AIFull.apk" "$MODPATH/system/priv-app/PhotoEditor_AIFull/PhotoEditor_AIFull.apk"
download_file "PhotoRemasterService.apk" "$MODPATH/system/priv-app/PhotoRemasterService/PhotoRemasterService.apk"
download_file "PrivacyDashboard.apk" "$MODPATH/system/priv-app/PrivacyDashboard/PrivacyDashboard.apk"
download_file "Routines.apk" "$MODPATH/system/priv-app/Routines/Routines.apk"
download_file "SamsungContacts.apk" "$MODPATH/system/priv-app/SamsungContacts/SamsungContacts.apk"
download_file "SamsungDialer.apk" "$MODPATH/system/priv-app/SamsungDialer/SamsungDialer.apk"
download_file "SamsungGallery2018.apk" "$MODPATH/system/priv-app/SamsungGallery2018/SamsungGallery2018.apk"
download_file "SamsungInCallUI.apk" "$MODPATH/system/priv-app/SamsungInCallUI/SamsungInCallUI.apk"
download_file "SamsungSmartSuggestions.apk" "$MODPATH/system/priv-app/SamsungSmartSuggestions/SamsungSmartSuggestions.apk"
download_file "SamsungWeather.apk" "$MODPATH/system/priv-app/SamsungWeather/SamsungWeather.apk"
download_file "SecMyFiles2020.apk" "$MODPATH/system/priv-app/SecMyFiles2020/SecMyFiles2020.apk"
download_file "SecSettings.apk" "$MODPATH/system/priv-app/SecSettings/SecSettings.apk"
download_file "SecSettingsIntelligence.apk" "$MODPATH/system/priv-app/SecSettingsIntelligence/SecSettingsIntelligence.apk"
download_file "SecTelephonyProvider.apk" "$MODPATH/system/priv-app/SecTelephonyProvider/SecTelephonyProvider.apk"
download_file "SettingsProvider.apk" "$MODPATH/system/priv-app/SettingsProvider/SettingsProvider.apk"
download_file "SmartCapture.apk" "$MODPATH/system/priv-app/SmartCapture/SmartCapture.apk"
download_file "SmartManager_v5.apk" "$MODPATH/system/priv-app/SmartManager_v5/bruh"
download_file "SmartManager_v6_DeviceSecurity.apk" "$MODPATH/system/app/SmartManager_v6_DeviceSecurity/bruh"
download_file "TelephonyUI.apk" "$MODPATH/system/priv-app/TelephonyUI/TelephonyUI.apk"

ui_print "- Extracting module files"
unzip -o "$ZIPFILE" -x 'META-INF/*' 'common/functions.sh' -d $MODPATH >&2
[ -f "$MODPATH/common/addon.tar.xz" ] && tar -xf $MODPATH/common/addon.tar.xz -C $MODPATH/common 2>/dev/null
if [ "$(ls -A $MODPATH/common/addon/*/install.sh 2>/dev/null)" ]; then
  ui_print " "; ui_print "- Running Addons -"
  for i in $MODPATH/common/addon/*/install.sh; do
    ui_print "  Running $(echo $i | sed -r "s|$MODPATH/common/addon/(.*)/install.sh|\1|")..."
    . $i
  done
fi
ui_print "- Removing old files"
if [ -f $INFO ]; then
  while read LINE; do
    if [ "$(echo -n $LINE | tail -c 1)" == "~" ]; then
      continue
    elif [ -f "$LINE~" ]; then
      mv -f $LINE~ $LINE
    else
      rm -f $LINE
      while true; do
        LINE=$(dirname $LINE)
        [ "$(ls -A $LINE 2>/dev/null)" ] && break 1 || rm -rf $LINE
      done
    fi
  done < $INFO
  rm -f $INFO
fi
ui_print "- Installing"
[ -f "$MODPATH/common/install.sh" ] && . $MODPATH/common/install.sh
ui_print "   Installing for $ARCH SDK $API device..."
for i in $(find $MODPATH -type f -name "*.sh" -o -name "*.prop" -o -name "*.rule"); do
  [ -f $i ] && { sed -i -e "/^#/d" -e "/^ *$/d" $i; [ "$(tail -1 $i)" ] && echo "" >> $i; } || continue
  case $i in
    "$MODPATH/boot-completed.sh") install_script -b $i;;
    "$MODPATH/service.sh") install_script -l $i;;
    "$MODPATH/post-fs-data.sh") install_script -p $i;;
    "$MODPATH/uninstall.sh") if [ -s $INFO ] || [ "$(head -n1 $MODPATH/uninstall.sh)" != "# Don't modify anything after this" ]; then                          
                               cp -f $MODPATH/uninstall.sh $MODPATH/$MODID-uninstall.sh # Fallback script in case module manually deleted
                               sed -i "1i[ -d \"\$MODPATH\" ] && exit 0" $MODPATH/$MODID-uninstall.sh
                               echo 'rm -f $0' >> $MODPATH/$MODID-uninstall.sh
                               install_script -l $MODPATH/$MODID-uninstall.sh
                               rm -f $MODPATH/$MODID-uninstall.sh
                               install_script $MODPATH/uninstall.sh
                             else
                               rm -f $INFO $MODPATH/uninstall.sh
                             fi;;
  esac
done
$IS64BIT || for i in $(find $MODPATH/system -type d -name "lib64"); do rm -rf $i 2>/dev/null; done  
[ -d "/system/priv-app" ] || mv -f $MODPATH/system/priv-app $MODPATH/system/app 2>/dev/null
[ -d "/system/xbin" ] || mv -f $MODPATH/system/xbin $MODPATH/system/bin 2>/dev/null
if $DYNLIB; then
  for FILE in $(find $MODPATH/system/lib* -type f 2>/dev/null | sed "s|$MODPATH/system/||"); do
    [ -s $MODPATH/system/$FILE ] || continue
    case $FILE in
      lib*/modules/*) continue;;
    esac
    mkdir -p $(dirname $MODPATH/system/vendor/$FILE)
    mv -f $MODPATH/system/$FILE $MODPATH/system/vendor/$FILE
    [ "$(ls -A `dirname $MODPATH/system/$FILE`)" ] || rm -rf `dirname $MODPATH/system/$FILE`
  done
  # Delete empty lib folders (busybox find doesn't have this capability)
  toybox find $MODPATH/system/lib* -type d -empty -delete >/dev/null 2>&1
fi
ui_print "  Press Volume Up for Device Care  "
ui_print "  Press Volume Down for Smart Manager(+ App Lock)  "
ui_print "***********************************************"
  SM_KEY=$(wait_for_key)
  if [ "$SM_KEY" = "UP" ]; then
    ui_print " Installing Device Care "
	  ui_print "***********************************************"
	rm -rf "$MODPATH/system/app/SmartManager_v6_DeviceSecurity_CN"
	rm -rf "$MODPATH/system/app/TencentWifiSecurity"
	rm -rf "$MODPATH/system/priv-app/SmartManagerCN"
	rm -rf "$MODPATH/system/priv-app/SAppLock"
	rm -rf "$MODPATH/system/etc/floating_feature-cn.xml"
	rm -rf "$MODPATH/system/etc/floating_feature-s23-cn.xml"
    sleep 2
    ui_print " Device Care Installed! :D "
  fi
	  
  if [ "$SM_KEY" = "DOWN" ]; then
    ui_print " Installing Smart Manager "
	ui_print "***********************************************"
	rm -f "$MODPATH/system/app/SmartManager_v6_DeviceSecurity/SmartManager_v6_DeviceSecurity.apk"
	rm -f "$MODPATH/system/priv-app/SmartManager_v5/SmartManager_v5.apk"
	rm -f "$MODPATH/system/etc/floating_feature.xml"
	rm -f "$MODPATH/system/etc/floating_feature-s23.xml"
	mv -f "$MODPATH/system/app/SmartManager_v6_DeviceSecurity/bruh" "$MODPATH/system/app/SmartManager_v6_DeviceSecurity/SmartManager_v6_DeviceSecurity.apk"
	mv -f "$MODPATH/system/priv-app/SmartManager_v5/bruh" "$MODPATH/system/priv-app/SmartManager_v5/SmartManager_v5.apk"
	mv -f "$MODPATH/system/etc/floating_feature-cn.xml" "$MODPATH/system/etc/floating_feature.xml"
	mv -f "$MODPATH/system/etc/floating_feature-s23-cn.xml" "$MODPATH/system/etc/floating_feature-s23.xml"
	sleep 2
    ui_print " Smart Manager Installed! :D "
  fi  
ui_print "***********************************************"
ui_print " Would you like to change Device Wallpapers? "
sleep 1
ui_print " Press Volume up to keep stock Walls "
ui_print " Press Volume Down to choose between S22U and S24U Walls "

WALL_KEY=$(wait_for_key)
  if [ "$WALL_KEY" = "UP" ]; then
	ui_print "***********************************************"
    ui_print " Keeping Stock Wallpapers... "
    rm -rf "$MODPATH/system/priv-app/wallpaper-res"
  fi
  if [ "$WALL_KEY" = "DOWN" ]; then
  ui_print "***********************************************"
    ui_print " Press Volume Up for S24U Walls "
    ui_print " Press Volume Down for S22U Walls "
    sleep 2
    WALLC_KEY=$(wait_for_key)
    if [ "$WALLC_KEY" = "UP" ]; then
      ui_print " Setting S24U Walls... "
      ui_print "***********************************************"
      download_file "wallpaper-res-s24u.apk" "$MODPATH/system/priv-app/wallpaper-res/wallpaper-res.apk"
    fi
    if [ "$WALLC_KEY" = "DOWN" ]; then
      ui_print " Setting S22U Walls... "
      ui_print "***********************************************"
      download_file "wallpaper-res.apk" "$MODPATH/system/priv-app/wallpaper-res/wallpaper-res.apk"
    fi
  fi
# Device values: 0=S23,1=S23+,2=S23U,3=Support more devices wen?
MODEL="$(getprop ro.boot.em.model)"
case "$MODEL" in
  SM-S911B|SM-S911N|SM-S9110|SM-S931B)
    is_device=0
    ;;
  SM-S916B|SM-S916N|SM-S9160|SM-S936B)
    is_device=1
    ;;
  SM-S918B|SM-S918N|SM-S9180|SM-S938B)
    is_device=2
    ;;
esac
if [ "$is_device" = "0" ]; then
  ui_print "  Detected S23 Base  "
  rm -f "$MODPATH/system/cameradata/camera-feature.xml"
  rm -f "$MODPATH/system/etc/floating_feature.xml"
  rm -f "$MODPATH/system.prop"
  rm -f "$MODPATH/module.prop"
  rm -f "$MODPATH/system/product/overlay/framework-res__dm3qxxx__auto_generated_rro_product.apk"
  rm -f "$MODPATH/system/media/bootsamsung.qmg"
  rm -f "$MODPATH/system/media/bootsamsungloop.qmg"
  rm -f "$MODPATH/system/media/shutdown.qmg"
  mv -f "$MODPATH/system/media/bootsamsung-s23.qmg" "$MODPATH/system/media/bootsamsung.qmg"
  mv -f "$MODPATH/system/media/bootsamsungloop-s23.qmg" "$MODPATH/system/media/bootsamsungloop.qmg"
  mv -f "$MODPATH/system/media/shutdown-s23.qmg" "$MODPATH/system/media/shutdown.qmg"
  mv -f "$MODPATH/system/cameradata/camera-feature-s23.xml" "$MODPATH/system/cameradata/camera-feature.xml"
  mv -f "$MODPATH/system/etc/floating_feature-s23.xml" "$MODPATH/system/etc/floating_feature.xml"
  mv -f "$MODPATH/system-s23.prop" "$MODPATH/system.prop"
  mv -f "$MODPATH/module-s23.prop" "$MODPATH/module.prop"
  ui_print "  After rebooting, check data/adb/modules/CyberK_S23X/product/overlay/instructions.txt for auto aod  "
fi
if [ "$is_device" = "1" ]; then
  ui_print "  Detected S23+  "
  rm -f "$MODPATH/system/cameradata/camera-feature.xml"
  rm -f "$MODPATH/system/etc/floating_feature.xml"
  rm -f "$MODPATH/system.prop"
  rm -f "$MODPATH/module.prop"
  rm -f "$MODPATH/system/product/overlay/framework-res__dm3qxxx__auto_generated_rro_product.apk"
  rm -f "$MODPATH/system/media/bootsamsung.qmg"
  rm -f "$MODPATH/system/media/bootsamsungloop.qmg"
  rm -f "$MODPATH/system/media/shutdown.qmg"
  mv -f "$MODPATH/system/media/bootsamsung-s23.qmg" "$MODPATH/system/media/bootsamsung.qmg"
  mv -f "$MODPATH/system/media/bootsamsungloop-s23.qmg" "$MODPATH/system/media/bootsamsungloop.qmg"
  mv -f "$MODPATH/system/media/shutdown-s23.qmg" "$MODPATH/system/media/shutdown.qmg"
  mv -f "$MODPATH/system/cameradata/camera-feature-s23.xml" "$MODPATH/system/cameradata/camera-feature.xml"
  mv -f "$MODPATH/system/etc/floating_feature-s23.xml" "$MODPATH/system/etc/floating_feature.xml"
  mv -f "$MODPATH/system-s23+.prop" "$MODPATH/system.prop"
  mv -f "$MODPATH/module-s23+.prop" "$MODPATH/module.prop"
  ui_print "  After rebooting, check data/adb/modules/CyberK_S23X/product/overlay/instructions.txt for auto aod  "
fi
if [ "$is_device" = "2" ]; then
  ui_print "  Detected S23 Ultra  " 
  rm -rf "$MODPATH/system/cameradata/camera-feature-s23.xml"
  rm -rf "$MODPATH/system/etc/floating_feature-s23.xml"
  rm -rf "$MODPATH/system-s23.prop"
  rm -rf "$MODPATH/module-s23.prop"
  rm -rf "$MODPATH/system-s23+.prop"
  rm -rf "$MODPATH/module-s23+.prop"
  rm -rf "$MODPATH/system/media/bootsamsung-s23.qmg"
  rm -rf "$MODPATH/system/media/bootsamsungloop-s23.qmg"
  rm -rf "$MODPATH/system/media/shutdown-s23.qmg"
  rm -rf "$MODPATH/system/product/overlay/auto_aod.apk"
  rm -rf "$MODPATH/system/product/overlay/instructions.txt"
fi
sleep 1
ui_print " Device based changes applied 🥳 "
ui_print " "
ui_print "- Setting Permissions"
set_perm_recursive $MODPATH 0 0 0755 0644
for i in /system/vendor /vendor /system/vendor/app /vendor/app /system/vendor/etc /vendor/etc /system/odm/etc /odm/etc /system/vendor/odm/etc /vendor/odm/etc /system/vendor/overlay /vendor/overlay; do
  if [ -d "$MODPATH$i" ] && [ ! -L "$MODPATH$i" ]; then
    case $i in
      *"/vendor") set_perm_recursive $MODPATH$i 0 0 0755 0644 u:object_r:vendor_file:s0;;
      *"/app") set_perm_recursive $MODPATH$i 0 0 0755 0644 u:object_r:vendor_app_file:s0;;
      *"/overlay") set_perm_recursive $MODPATH$i 0 0 0755 0644 u:object_r:vendor_overlay_file:s0;;
      *"/etc") set_perm_recursive $MODPATH$i 0 2000 0755 0644 u:object_r:vendor_configs_file:s0;;
    esac
  fi
done
for i in $(find $MODPATH/system/vendor $MODPATH/vendor -type f -name *".apk" 2>/dev/null); do
  chcon u:object_r:vendor_app_file:s0 $i
done
set_permissions
cleanup
