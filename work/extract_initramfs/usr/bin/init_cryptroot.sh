#!/bin/sh
# /usr/bin/init_cryptroot.sh
/usr/bin/busybox mdev -s
/usr/bin/busybox sleep 2
exec > /dev/ttyAMA0 2>&1  # 全ての出力を画面に強制表示
set -x                    # 実行コマンドを逐一表示
/usr/bin/busybox sleep 3
#trap 'echo "ERROR DETECTED. Dropping to shell..."; /bin/sh' 0 1 2 3 15
#set -e


##### C-311 / A-36: WDT の蹴り(initramfs 区間) #####
# 蹴りはアプリ(570-1 adm-diag-control)が叩くことに決まったが、**rootfs に移るまでアプリは居ない**。
# WDT は「最初の蹴り込みまで開始しない」仕様なので**電源投入直後は落ちない**が、
# 一度武装した後のソフト再起動・リストアでは IC が数え続ける。この区間はリストアの
# バンドル取得・展開に**十数分**かかるので、IC のタイムアウト 5 分を確実に超える。
# ∴ この区間は initramfs が自分で蹴る。
#
# 口: GPIO8 を `/sys/class/gpio` で直接トグルする。initramfs には `adm-gpiod` も CLI も居ないので
# ここは直接叩くしかない(`config.txt` の `dtoverlay=spi0-1cs,cs0_pin=7` で SPI0 CE0 からも外してある)。
# rootfs へ渡す前に**必ず止めて unexport する**——2026-08-27 の HW 対応(pi-gen eec93cb)で
# ドライバは GPIO8 に触らなくなったが、rootfs 側の蹴り手は `adm-gpiod` 経由で同じピンを使うので、
# sysfs に export したまま残すと競合しうる。
# ★2026-08-28 実機で判明: `/sys/class/gpio` の旧インタフェースは **グローバル番号**を要求する。
# 当初 `8` を export していたが、実機の RP1 は `pinctrl-rp1` の **base=569**(ngpio=54) なので
# GPIO8 のグローバル番号は **577**。`8` はどのチップの範囲にも当たらず export が黙って失敗し、
# `|| true` で握り潰していたため **initramfs の蹴りは一度も効いていなかった**
# (起動から 2 分以上 `WDT_ON`=1 のままだったことで発覚)。
# ★base は固定しない——カーネル/DT で変わる。**label が `pinctrl-rp1` のチップから毎回計算する**。
WDT_GPIO_OFFSET=8
WDT_GPIO=""
WDT_KICK_PID=""

wdt_gpio_num() {
  for c in /sys/class/gpio/gpiochip*; do
    [ -r "$c/label" ] || continue
    if [ "$(/usr/bin/busybox cat "$c/label" 2>/dev/null)" = "pinctrl-rp1" ]; then
      b=$(/usr/bin/busybox cat "$c/base" 2>/dev/null) || return 1
      echo $((b + WDT_GPIO_OFFSET))
      return 0
    fi
  done
  return 1
}

wdt_kick_start() {
  WDT_GPIO="$(wdt_gpio_num)" || {
    echo "WDT: pinctrl-rp1 gpiochip not found; not kicking in initramfs"
    return 1
  }
  echo "WDT: rp1 base -> global gpio ${WDT_GPIO} (offset ${WDT_GPIO_OFFSET})"
  if [ ! -d "/sys/class/gpio/gpio${WDT_GPIO}" ]; then
    echo "${WDT_GPIO}" > /sys/class/gpio/export 2>/dev/null || {
      echo "WDT: cannot export gpio${WDT_GPIO}; not kicking in initramfs"
      return 1
    }
  fi
  echo out > "/sys/class/gpio/gpio${WDT_GPIO}/direction" 2>/dev/null || return 1
  (
    while : ; do
      v=$(/usr/bin/busybox cat "/sys/class/gpio/gpio${WDT_GPIO}/value" 2>/dev/null || echo 0)
      if [ "$v" = "1" ]; then echo 0 > "/sys/class/gpio/gpio${WDT_GPIO}/value" 2>/dev/null
      else echo 1 > "/sys/class/gpio/gpio${WDT_GPIO}/value" 2>/dev/null; fi
      /usr/bin/busybox sleep 10
    done
  ) &
  WDT_KICK_PID=$!
  echo "WDT: kicking gpio${WDT_GPIO} from initramfs (pid=${WDT_KICK_PID})"
}

wdt_kick_stop() {
  [ -n "$WDT_KICK_PID" ] && kill "$WDT_KICK_PID" 2>/dev/null
  WDT_KICK_PID=""
  # ★unexport を忘れると rootfs 側(adm-gpiod 経由)が同じピンを扱えない。
  [ -n "$WDT_GPIO" ] && [ -d "/sys/class/gpio/gpio${WDT_GPIO}" ] && echo "${WDT_GPIO}" > /sys/class/gpio/unexport 2>/dev/null
  echo "WDT: stopped kicking from initramfs (handing over to 570-1 via adm-boot-dispatcher)"
}

wdt_kick_start || true
##### C-311 END #####

/usr/bin/cryptkey-fetch | /sbin/cryptsetup luksOpen /dev/mmcblk0p2 cryptroot || {
    echo "FATAL: LUKS open failed."
    sleep 30 && reboot -f
}

##### custom start
PART_SIZE=$(cat /sys/class/block/mmcblk0p2/size)
TARGET_GIB=6
# セクタ数の計算 (1GiB = 1024^3 / 512 = 2097152 sectors)
# 20GiB の場合: 20 * 2097152 = 41943040
TARGET_P2_SIZE=$((TARGET_GIB * 2097152))
TARGET_P2_END="${TARGET_P2_SIZE}s"
TARGET_P3_START="$((TARGET_P2_SIZE + 1))s"
if [ "$PART_SIZE" -gt $((TARGET_P2_SIZE + 2048)) ]; then
  # ファイルシステムを強制的に縮小する
  /sbin/e2fsck -y -f /dev/mapper/cryptroot || true
  echo "Starting resize2fs to ${TARGET_GIB}G..."
  /sbin/resize2fs -p /dev/mapper/cryptroot "${TARGET_GIB}G"
  # 物理パーティションの強制リサイズ
  echo "Creating physical partition wall with parted..."
  yes | /sbin/parted /dev/mmcblk0 ---pretend-input-tty resizepart 2 ${TARGET_P2_END}
  # p3 を作成
  /sbin/parted -s /dev/mmcblk0 mkpart primary ${TARGET_P3_START} 100%
  # LUKSレイヤーのリサイズ
  /usr/bin/cryptkey-fetch | /sbin/cryptsetup resize cryptroot
  # パーティションテーブルの変更をカーネルに通知
  /sbin/partprobe /dev/mmcblk0 || true
  /usr/bin/busybox mdev -s || true
  /bin/udevadm settle || true
  /usr/bin/busybox sleep 2
  # 最終リサイズ
  /sbin/resize2fs -f /dev/mapper/cryptroot
  yes | /sbin/e2fsck -y -f /dev/mapper/cryptroot || true
  # fstabの調整
  echo "First boot: Fixing PARTUUIDs..."
  /usr/bin/busybox mount /dev/mapper/cryptroot /mnt || {
    echo "FATAL: cryptroot mount failed."
    sleep 30 && reboot -f
  }
  NEW_P1_UUID=$(blkid -s PARTUUID -o value /dev/mmcblk0p1)
  NEW_P2_UUID=$(blkid -s PARTUUID -o value /dev/mmcblk0p2)
  if [ -n "$NEW_P1_UUID" ] && [ -n "$NEW_P2_UUID" ]; then
    sed -i "s/PARTUUID=[^ ]*-01/PARTUUID=${NEW_P1_UUID}/g" /mnt/etc/fstab
    sed -i "s/PARTUUID=[^ ]*-02/PARTUUID=${NEW_P2_UUID}/g" /mnt/etc/fstab
  fi
  /usr/bin/busybox umount /mnt
else
  echo "Already resized. Skipping..."
  /sbin/resize2fs -f /dev/mapper/cryptroot
  yes | /sbin/e2fsck -y -f /dev/mapper/cryptroot || true
fi

/usr/bin/busybox mount /dev/mapper/cryptroot /mnt
/usr/bin/busybox mount /dev/mmcblk0p1 /mnt/boot/firmware

# 自動リサイズ処理の強制削除
sed -i 's/init=\/usr\/lib\/raspi-config\/init_resize.sh//g' /mnt/boot/cmdline.txt
# 使い捨てスクリプトの「残骸」や「フラグファイル」を念のため掃除
rm -f /mnt/var/lib/systemd/deb-systemd-helper-enabled/resize2fs_once.service
rm -f /mnt/etc/rc.d/resize2fs_once

# ログパーティションの解錠とマウント
keypath="/mnt/etc/cryptsetup-keys/p3_system.key"
if [ -f "$keypath" ]; then
  echo "Opening cryptlvm..."
  # 開錠
  /sbin/cryptsetup luksOpen /dev/mmcblk0p3 "cryptlvm" --key-file "$keypath"
  # LVMボリュームの有効化
  echo "Scanning LVM volumes (Forced)..."
  /bin/udevadm settle
  /usr/bin/busybox sleep 2
  
  # フィルタを無視して全てのブロックデバイスをスキャンし、キャッシュを更新
  /sbin/lvm pvscan --cache /dev/mapper/cryptlvm
  /sbin/lvm vgscan --mknodes
  
  # vg_data を強制的にアクティブ化
  echo "Activating vg_data..."
  /sbin/lvm vgchange -ay vg_data --sysinit
  echo "Forcing node creation..."
  /sbin/lvm vgmknodes vg_data

  # Btrfsモジュールのロード
  echo "Loading Btrfs module..."
  /bin/modprobe btrfs || echo "WARN: Failed to load btrfs module (might be built-in)"

  # デバイスノードの確認（/dev/mapper/ 経由もチェック）
  RETRY=0
  while [ ! -e "/dev/vg_data/lv_log" ] && [ ! -e "/dev/mapper/vg_data-lv_log" ] && [ $RETRY -lt 5 ]; do
    echo "Waiting for LV nodes (Attempt $((RETRY+1)))..."
    /bin/udevadm settle
    /usr/bin/busybox sleep 2
    RETRY=$((RETRY+1))
  done
  # 個別マウント処理
  mount_lv() {
    lv_name=$1
    mount_point=$2
    fstype=${3:-ext4}
    mnt_opts=${4:-""}
    dev_path="/dev/mapper/vg_data-lv_${lv_name}"
    if [ -e "$dev_path" ]; then
      echo "Mounting ${lv_name} to ${mount_point} (Type: ${fstype})..."
      mkdir -p "/mnt${mount_point}"
      if [ -n "$mnt_opts" ]; then
        /usr/bin/busybox mount -t "$fstype" -o "$mnt_opts" "$dev_path" "/mnt${mount_point}"
      else
        /usr/bin/busybox mount -t "$fstype" "$dev_path" "/mnt${mount_point}"
      fi
    fi
  }
  # 独立したパス
  mount_lv "backup" "/backup"
  mount_lv "docker" "/var/lib/docker"
  mount_lv "cert" "/var/lib/dtebx"
  mount_lv "log"    "/var/log"       "btrfs" "compress=zstd:6"
  mount_lv "audit"  "/var/log/audit" "btrfs" "compress=zstd:6"

  # アプリケーション用 (階層構造)
  # 親ディレクトリを先にマウント
  mount_lv "currentApp" "/home/ot-admin/dfx_dtebx_docker"
  # 子ディレクトリ
  mount_lv "adm_ini"    "/home/ot-admin/dfx_dtebx_docker/adm_ini"
  mount_lv "adm_clean"  "/home/ot-admin/dfx_dtebx_docker/adm_clean"
  mount_lv "dbvol"      "/home/ot-admin/dfx_dtebx_docker/pgvol"
  mount_lv "media"      "/home/ot-admin/dfx_dtebx_docker/media"
  mount_lv "sfs"        "/home/ot-admin/dfx_dtebx_docker/sfs"

  /bin/udevadm settle
  /usr/bin/busybox sleep 2

  ##### RECOVERY LOGIC START #####
  TARGET_LIST="/mnt/backup/restore-target"
  RECOVERY_LOG="/run/recovery.log"
  STAGING="/mnt/backup/.recovery_staging"
  RECOVERY_FAILED_FLAG="/mnt/var/log/recovery_failed.log"
  BACKUP_FILE=""
  [ -f "$TARGET_LIST" ] && BACKUP_FILE=$(cat "$TARGET_LIST" | /usr/bin/busybox head -n 1)
  recovery_log() {
    target_name="${BACKUP_FILE:-unknown_target}"
    msg="[target: $target_name] $*"
    echo "$msg"
    echo "$msg" >> "$RECOVERY_LOG"
  }
  recovery_failed_log() {
    target_name="${BACKUP_FILE:-unknown_target}"
    msg="[target: $target_name] $*"
    echo "$msg"
    echo "$msg" >> "$RECOVERY_FAILED_FLAG"
  }
  # 消去の実行結果を残す独立ゾーン。/var/log は消去(復元)対象なので、そこに書くと
  # 「消えた記録」しか残らない。lv_backup 配下のこのディレクトリだけは消去の対象外とし、
  # 消去のたびに 1 行追記する(結果の追跡可能性)。
  # ⚠ 利用者名・内部識別子は書かない(取り残された装置は攻撃者の手元に渡りうる)。
  #    書くのは「いつ・どうなったか」だけ。バンドル名も内部識別子なので入れない。
  ERASE_ZONE="/mnt/backup/eraselog"
  ERASE_LOG="$ERASE_ZONE/erase-history.log"
  ERASE_STATE="$ERASE_ZONE/.last-result"
  erase_record() {
    /usr/bin/busybox mkdir -p "$ERASE_ZONE"
    echo "$(/usr/bin/busybox date -u '+%Y-%m-%dT%H:%M:%SZ') result=$1" >> "$ERASE_LOG"
    echo "$1" > "$ERASE_STATE"
  }
  (
    set -e
    if [ -f "$TARGET_LIST" ]; then
      recovery_log "=== [RESTORE MODE] Recovery target detected! ==="

      # ネットワークが必要なため、このタイミングで起動
      IS_PRIME=$(cat "/mnt/home/ot-admin/dfx_dtebx_docker/primary.check" | /usr/bin/busybox head -n 1)
      /usr/bin/busybox ip link set eth0 up || exit 1
      if [ "$IS_PRIME" -eq 1 ]; then
        /usr/bin/busybox ip addr add 172.16.0.1/24 dev eth0
        TARGET_IP=172.16.0.2
        recovery_log "Mode: Primary (Self: 172.16.0.1, Target: $TARGET_IP)"
      else
        /usr/bin/busybox ip addr add 172.16.0.2/24 dev eth0
        TARGET_IP=172.16.0.1
        recovery_log "Mode: Secondary (Self: 172.16.0.2, Target: $TARGET_IP)"
      fi

      BACKUP_FILE=$(cat "$TARGET_LIST" | /usr/bin/busybox head -n 1)
      recovery_log "Retrieving bundle: $BACKUP_FILE"
      mkdir -p "$STAGING"

      # ★取得は「一発勝負」にしない（2026-08-22 実機ドリルで adm2 の消去がここで落ちた）。
      #   旧実装は疎通確認が **ping** だったが、**この ADM 間経路の ICMP は返らない**
      #   （実測: booted 同士でも `ping 172.16.0.1` は 100% ロス、TCP/80 は 1ms 未満で繋がる）。
      #   ∴ ping のループは必ず外れる空待ちで切り分けにならず、その後の wget も 1 回だけだった。
      #
      # 🔴 **`wget` に `-T` を渡してはいけない**（2026-08-23 実機で判明）。
      #   このビルドの busybox wget は `-T` を付けると **必ず Segmentation fault で死ぬ**
      #   （`busybox wget -T 30 -O /tmp/x http://.../nonexistent` で exit=139 を再現）。
      #   タイムアウトを効かせるつもりで足した結果、**動いていた取得を毎回落とす改悪**になり、
      #   20 回すべて同じ場所で即死して消去が失敗した。呼び出しは**素のまま**にすること。
      #
      # ■ 打ち切り方
      #   ・**総時間**で区切る（回数ではない）。wget 自身のタイムアウトは実測で約 3 分あり、
      #     回数で持つと最悪が読めない。
      #   ・★**シグナルで死んだ(rc>=128)ときは即やめる**。それはネットワーク条件ではなく
      #     決定的な失敗なので、待っても回数を重ねても結果は変わらない（上の -T 事故がこれ）。
      # ■ 疎通確認は **TCP** で行う（ping は使わない）
      #
      # 🔴 旧実装は `busybox ping` を 10 回試していたが、**この ADM 間経路(172.16.0.0/24)では
      #   ICMP が返らない**。両系とも `icmp_echo_ignore_all=0` で iptables にも icmp ルールは無く、
      #   同じ相手の **VLAN15 側(.41/.42)へは ping が通る**のに 172.16 側だけ返らない（2026-08-23 実測、
      #   スイッチの ACE も VID/TCP-3389 のみで ICMP は落としていない＝原因は未解明）。
      #   結果あの 10 回は**対向の状態と無関係に必ず全部外れる空待ち**で、切り分けの材料に
      #   なっていなかった（「10 回失敗した後に実際に取ると成功する」の正体）。
      #   ∴ **原因が分かっていない挙動に判定を預けない**。TCP で直接確かめる。
      #
      # ★`nc` の使い方に注意: このビルド(busybox v1.35.0)の nc には **`-z` が無い**。
      #   `-w SEC HOST PORT </dev/null` の終了コードで見る（開=0 / 閉・到達不能=1 を実機確認）。
      RDY=0
      RDY_BUDGET_SEC=300
      RDY_DEADLINE=$(( $(/usr/bin/busybox date +%s) + RDY_BUDGET_SEC ))
      recovery_log "Waiting for $TARGET_IP:80 to accept connections (budget ${RDY_BUDGET_SEC}s)"
      while :; do
        if /usr/bin/busybox nc -w 5 "$TARGET_IP" 80 </dev/null >/dev/null 2>&1; then
          RDY=1
          recovery_log "$TARGET_IP:80 is accepting connections."
          break
        fi
        if [ $(/usr/bin/busybox date +%s) -ge $RDY_DEADLINE ]; then
          recovery_log "$TARGET_IP:80 did not accept connections within ${RDY_BUDGET_SEC}s"
          break
        fi
        /usr/bin/busybox sleep 5
      done

      # ■ 取得本体
      #
      # 🔴 **`wget` に `-T` を渡してはいけない**（2026-08-23 実機で判明）。このビルドの
      #   busybox wget は `-T` を付けると **必ず Segmentation fault で死ぬ**
      #   (`busybox wget -T 30 -O /tmp/x http://.../nonexistent` で exit=139 を再現)。
      #   タイムアウトを効かせるつもりで足した結果、**動いていた取得を毎回落とす改悪**になり、
      #   20 回すべて即死して消去が失敗した。呼び出しは**素のまま**にすること。
      #
      # 打ち切りは **総時間**（回数だと wget 自身のタイムアウト約 3 分と掛け算になって最悪が読めない）。
      # ★**シグナル死(rc>=128)は即やめる**。決定的な失敗なので待っても回数を重ねても変わらない。
      DL_BUDGET_SEC=600
      DL_WAIT=15
      DL_OK=0
      DL_ATTEMPT=0
      DL_LAST_ERR=""
      DL_ABORT=""
      DL_DEADLINE=$(( $(/usr/bin/busybox date +%s) + DL_BUDGET_SEC ))
      recovery_log "Fetching bundle from http://$TARGET_IP/backup/$BACKUP_FILE (budget ${DL_BUDGET_SEC}s)"
      while :; do
        DL_ATTEMPT=$((DL_ATTEMPT+1))
        /usr/bin/busybox wget -O "$STAGING/bundle.tar" \
          "http://$TARGET_IP/backup/$BACKUP_FILE" 2>"$STAGING/wget.err"
        DL_RC=$?
        if [ $DL_RC -eq 0 ]; then
          DL_OK=1
          recovery_log "Bundle downloaded on attempt $DL_ATTEMPT."
          break
        fi
        DL_LAST_ERR=$(/usr/bin/busybox tail -n 2 "$STAGING/wget.err" 2>/dev/null | /usr/bin/busybox tr '\n' ' ')
        /usr/bin/busybox rm -f "$STAGING/bundle.tar"
        if [ $DL_RC -ge 128 ]; then
          DL_ABORT="wget died with signal (rc=$DL_RC) - deterministic, retrying cannot help"
          recovery_log "Download attempt $DL_ATTEMPT aborted: $DL_ABORT [$DL_LAST_ERR]"
          break
        fi
        recovery_log "Download attempt $DL_ATTEMPT failed (rc=$DL_RC): $DL_LAST_ERR"
        if [ $(/usr/bin/busybox date +%s) -ge $DL_DEADLINE ]; then
          DL_ABORT="download budget of ${DL_BUDGET_SEC}s exhausted after $DL_ATTEMPT attempts"
          recovery_log "$DL_ABORT"
          break
        fi
        /usr/bin/busybox sleep $DL_WAIT
      done

      if [ $DL_OK -eq 1 ]; then
        recovery_log "Extracting bundle..."
        /usr/bin/busybox tar -C "$STAGING" -xf "$STAGING/bundle.tar"
        rm -f "$STAGING/bundle.tar"

        # 各LVの展開 (すでに /mnt/xxx にマウント済み)
        restore_lv_tar() {
          pattern=$1
          target_path=$2
          mode=$3
          target_file=$(ls "$STAGING"/${pattern}_[0-9]*.tar.gz.p7m 2>/dev/null | head -n 1)
          if [ -z "$target_file" ]; then
            recovery_log "[WARN] No archive(encrypted) found for $pattern"
            exit 1
          fi
          # 署名検証・復号を実行
          /usr/bin/adm-diag-svd_arm64 --mode verify \
            -t "$target_file" -o "$STAGING"
          decrypted_gz=$(ls "$STAGING"/${pattern}_[0-9]*.tar.gz 2>/dev/null | head -n 1)
          if [ -z "$decrypted_gz" ]; then
            recovery_log "[WARN] No archive(decrypted) found for $pattern"
            exit 1
          fi
          if [ "$mode" = "restore" ]; then
            /usr/bin/busybox rm -f "$target_file"
            if /usr/bin/busybox mount | /usr/bin/busybox grep -qE "on /mnt${target_path%/}/? type"; then
              # 一時展開用ディレクトリの作成
              tmp_extract="$STAGING/tmp_${pattern}"
              mkdir -p "$tmp_extract"
              # 一旦一時ディレクトリに展開
              /usr/bin/busybox tar -xzpf "$decrypted_gz" -C "$tmp_extract"

              if [ "$pattern" = "adm_ini" ]; then
                # activation.json の退避
                if [ -f "/mnt${target_path}/activation_recovery.json" ]; then
                  mv -f "/mnt${target_path}/activation_recovery.json" "${tmp_extract}/activation_recovery.json"
                fi
                # app_versions.jsonl の退避
                if [ -f "/mnt${target_path}/app_versions_recovery.jsonl" ]; then
                  mv -f "/mnt${target_path}/app_versions_recovery.jsonl" "${tmp_extract}/app_versions_recovery.jsonl"
                fi
              fi
              recovery_log "Syncing $pattern to $target_path via rsync..."
              if [ "$pattern" = "root" ]; then
                /usr/bin/rsync -aHAX -x --delete --numeric-ids \
                  --exclude='/boot/*' \
                  --exclude='/var/log/*' \
                  --exclude='/home/ot-admin/dfx_dtebx_docker/*' \
                  --exclude='/var/lib/dtebx/*' \
                  "$tmp_extract/" "/mnt$target_path"
              else
                /usr/bin/rsync -aHAX -x --delete --numeric-ids "$tmp_extract/" "/mnt$target_path/"
              fi
              /usr/bin/busybox rm -rf "$tmp_extract"
            else
              recovery_log "[WARN] Skip $pattern: /mnt$target_path is not mounted"
            fi
          fi
          /usr/bin/busybox rm -f "$decrypted_gz"
          return 0
        }

        recovery_log "Phase 1: Running integrity check on all components..."
        if restore_lv_tar "boot" "/boot/firmware" "verify" && \
            restore_lv_tar "log" "/var/log" "verify" && \
            restore_lv_tar "log_audit" "/var/log/audit" "verify" && \
            restore_lv_tar "adm_ini" "/home/ot-admin/dfx_dtebx_docker/adm_ini" "verify" && \
            restore_lv_tar "adm_clean" "/home/ot-admin/dfx_dtebx_docker/adm_clean" "verify" && \
            restore_lv_tar "pgvol" "/home/ot-admin/dfx_dtebx_docker/pgvol" "verify" && \
            restore_lv_tar "media" "/home/ot-admin/dfx_dtebx_docker/media" "verify" && \
            restore_lv_tar "sfs" "/home/ot-admin/dfx_dtebx_docker/sfs" "verify" && \
            restore_lv_tar "app_main" "/home/ot-admin/dfx_dtebx_docker" "verify" && \
            restore_lv_tar "cert_all" "/var/lib/dtebx" "verify" && \
            restore_lv_tar "cert" "/var/lib/dtebx/" "verify" && \
            restore_lv_tar "root" "/" "verify"; then

          recovery_log "Phase 2: All components verified. Starting restoration..."
          # ここから先で落ちると「一部だけ書き換わった」状態になる。外側のハンドラが
          # この値を見て partial として報告する(NIST SP 800-88r2 §3.2.5 の 9)。
          erase_record "in-progress"
          restore_lv_tar "boot" "/boot/firmware" "restore"
          restore_lv_tar "log" "/var/log" "restore"
          restore_lv_tar "log_audit" "/var/log/audit" "restore"
          restore_lv_tar "adm_ini" "/home/ot-admin/dfx_dtebx_docker/adm_ini" "restore"
          restore_lv_tar "adm_clean" "/home/ot-admin/dfx_dtebx_docker/adm_clean" "restore"
          restore_lv_tar "pgvol" "/home/ot-admin/dfx_dtebx_docker/pgvol" "restore"
          restore_lv_tar "media" "/home/ot-admin/dfx_dtebx_docker/media" "restore"
          restore_lv_tar "sfs" "/home/ot-admin/dfx_dtebx_docker/sfs" "restore"
          restore_lv_tar "app_main" "/home/ot-admin/dfx_dtebx_docker" "restore"

          # lv_cert(/var/lib/dtebx) を工場スナップショットへ揃える。
          # ここを復元しないと、root の rsync が --exclude='/var/lib/dtebx/*' で除外している分、
          # 前所有者が運用中に発行した端末証明書(issuedCrt/<端末名>/*.crt.pem)と step-ca の
          # 発行台帳(step-db/step-db-sca)が消去後も残る。装置 identity(機体鍵・中間 CA・
          # ConfigKEK 等)は工場スナップショット側に含まれているので、--delete で揃えても失われない。
          # ※必ず「証明書特殊マージ処理」より前に置く。逆順にすると、マージで足した対向の
          #   中間 CA 公開証明書を --delete が消してしまう。
          recovery_log "Restoring lv_cert to factory baseline..."
          restore_lv_tar "cert_all" "/var/lib/dtebx" "restore"

          # 証明書特殊マージ処理
          recovery_log "Merging Certificates..."
          mkdir -p "$STAGING/cert"
          target_file=$(ls "$STAGING"/cert_[0-9]*.tar.gz.p7m 2>/dev/null | head -n 1)
          # 署名検証・復号を実行
          /usr/bin/adm-diag-svd_arm64 --mode verify \
            -t "$target_file" -o "$STAGING"
          /usr/bin/busybox rm -f "$target_file"
          target_file=$(ls "$STAGING"/cert_[0-9]*.tar.gz 2>/dev/null | head -n 1)
          LIST_FILE="/mnt/var/lib/dtebx/intermediate_target.txt"
          /usr/bin/busybox tar -C "$STAGING/cert" -xzpf "$target_file"
          for pem in "$STAGING/cert"/*.pem; do
            [ -e "$pem" ] || continue
            pem_name=$(basename "$pem")
            if [ ! -f "/mnt/var/lib/dtebx/$pem_name" ]; then
              cp "$pem" "/mnt/var/lib/dtebx/"
              # ベース名を抽出
              base_name=$(echo "$pem_name" | sed -E 's/(_|-short).*\.pem$//')

              # 既存ファイルにその文字列が含まれていない場合のみ、末尾に追記
              if ! /usr/bin/busybox grep -qFx "$base_name" "$LIST_FILE"; then
                echo "$base_name" >> "$LIST_FILE"
              fi
            fi
          done

          # 各領域の展開 (既存の /mnt 配下へ)
          # root FS (rsyncで既存を掃除しつつ復元)
          restore_lv_tar "root" "/" "restore"

          # lv_backup(/backup) のユーザ資産を消す。
          # lv_backup は /mnt 配下ではあるがどの復元対象にも含まれないため、何もしないと
          # 前所有者のバックアップ本体(buc/user の .tar.enc)・更新ジョブの記録・移行前の
          # 設定が消去後も丸ごと残る。保持するのは装置の再利用に要るものだけ:
          #   backup/       … 対向機の工場スナップショット(相手の消去に必要)
          #   recoveryBoot/ … リカバリ起動資材
          #   vault/{app,system,catalog.jsonl} … 工場出荷版の資材(ロールバック先)
          #   eraselog/     … 本消去の記録(独立ゾーン)
          # ⚠ ディレクトリ自体は残して中身だけ消す(消えると各アプリの書き込み先が無くなる)。
          recovery_log "Erasing user assets on lv_backup..."
          for user_area in "/mnt/backup/buc" "/mnt/backup/download" "/mnt/backup/vault/premigration"; do
            if [ -d "$user_area" ]; then
              # ディレクトリ自体は残す。ドットファイル(.backup_status 等)も対象に含める。
              /usr/bin/busybox rm -rf "$user_area"/* "$user_area"/.[!.]* "$user_area"/..?* 2>/dev/null
              if [ -n "$(/usr/bin/busybox ls -A "$user_area" 2>/dev/null)" ]; then
                recovery_log "[WARN] $user_area is not empty after erase"
              fi
            fi
          done
          RESTORE_OK=1
        else
          recovery_failed_log "Individual verification of the backup file failed. The file may be corrupted."
          RESTORE_OK=0
        fi

        # 完了処理
        rm -fr "$STAGING"

        if [ "${RESTORE_OK:-0}" -eq 1 ]; then
          rm -f "$TARGET_LIST"
          # needs_recovery は「復元が済んだので次のブートでアプリを組み直せ」の合図。
          # 復元していないのに書くと、戻っていない構成で再ビルドが走る。∴ 成功時だけ書く。
          echo "$BACKUP_FILE" > /mnt/var/lib/dtebx/needs_recovery
          erase_record "completed"
          recovery_log "Recovery successful. Rebooting in 5 seconds..."
          cp "$RECOVERY_LOG" "/mnt/var/log/recovery_$BACKUP_FILE.log"
          sleep 5
          reboot -f
        fi
        # 失敗時は再起動せず既存 OS で起動を続ける(検証段で落ちているので中身は無傷)。
        # 「表示が出ない」を「失敗」と読み替えられるよう、結果を独立ゾーンに明示して残す。
        # 指示ファイルは .failed へ退避する(そのまま残すと毎ブート同じ壊れたバンドルで再試行する)。
        erase_record "failed-verification"
        recovery_failed_log "Restore was not performed. Booting the existing OS."
        # ⚠ `[ -f x ] && mv` をブロック末尾に置くと、条件が偽のとき set -e でサブシェルごと
        #    落ち、外側ハンドラが結果を "failed" で上書きしてしまう。if で書く。
        if [ -f "$TARGET_LIST" ]; then
          mv "$TARGET_LIST" "${TARGET_LIST}.failed"
        fi
      else
        # ★どちらで落ちたかを残す。「一度も TCP が張れなかった(対向が配っていない/経路が無い)」と
        #   「張れたが取得しきれなかった(途中断・サーバ側エラー)」は原因も対処も別物。
        # ★どこで落ちたかを残す。原因も対処も別物なので一緒くたにしない。
        if [ $RDY -eq 0 ]; then
          recovery_failed_log "Failed to download backup: $TARGET_IP:80 never accepted a TCP connection (the peer is not serving). Last error: $DL_LAST_ERR"
        elif [ -n "$DL_ABORT" ]; then
          recovery_failed_log "Failed to download backup: $DL_ABORT. Last error: $DL_LAST_ERR"
        else
          recovery_failed_log "Failed to download backup after $DL_ATTEMPT attempts (the peer accepted connections but the transfer did not complete). Last error: $DL_LAST_ERR"
        fi
        erase_record "failed-fetch"
        [ -f "$TARGET_LIST" ] && mv "$TARGET_LIST" "${TARGET_LIST}.failed"
      fi
    fi
    ##### RECOVERY LOGIC END #####
  ) || {
    # サブシェルが1（エラー）で終了した場合の処理
    # 復元の途中(in-progress)で落ちていれば「一部だけ書き換わった」状態なので、
    # 失敗ではなく partial として残す。ここを区別しないと、運用側は「消えたのか
    # 中途半端なのか」を判断できない。
    if [ "$(/usr/bin/busybox cat "$ERASE_STATE" 2>/dev/null)" = "in-progress" ]; then
      erase_record "partial"
      recovery_failed_log "Recovery aborted midway; the device is in a PARTIALLY restored state."
    else
      erase_record "failed"
    fi
    recovery_failed_log "Recovery failed, but proceeding to boot with existing OS..."
    [ -f "$TARGET_LIST" ] && mv "$TARGET_LIST" "${TARGET_LIST}.failed"
  }
fi
exec > /dev/console 2>&1
##### custom end

# ★C-311: rootfs へ渡す前に必ず止めて unexport する(ドライバが GPIO8 を掴めるようにする)。
# ここから 570-1 の初回の蹴りまでの窓は adm-boot-dispatcher が背景で蹴って埋める。
wdt_kick_stop || true

systemctl switch-root /mnt /usr/sbin/init
