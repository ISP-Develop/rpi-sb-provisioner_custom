#!/bin/sh
# /usr/bin/init_cryptroot.sh
/usr/bin/busybox mdev -s
/usr/bin/busybox sleep 2
exec > /dev/ttyAMA0 2>&1  # 全ての出力を画面に強制表示
set -x                    # 実行コマンドを逐一表示
/usr/bin/busybox sleep 3
trap 'echo "ERROR DETECTED. Dropping to shell..."; /bin/sh' 0 1 2 3 15
set -e

/usr/bin/cryptkey-fetch | /sbin/cryptsetup luksOpen /dev/mmcblk0p2 cryptroot

##### custom start
PART_SIZE=$(cat /sys/class/block/mmcblk0p2/size)
TARGET_GIB=4
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
  # 最終リサイズ
  /sbin/resize2fs -f /dev/mapper/cryptroot
  yes | /sbin/e2fsck -y -f /dev/mapper/cryptroot || true
  # fstabの調整
  echo "First boot: Fixing PARTUUIDs..."
  /usr/bin/busybox mount /dev/mapper/cryptroot /mnt
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
  
  # フィルタを無視して全てのブロックデバイスをスキャンし、キャッシュを更新
  /sbin/lvm pvscan --cache /dev/mapper/cryptlvm
  /sbin/lvm vgscan --mknodes
  
  # vg_data を強制的にアクティブ化
  echo "Activating vg_data..."
  /sbin/lvm vgchange -ay vg_data --sysinit
  echo "Forcing node creation..."
  /sbin/lvm vgmknodes vg_data

  # デバイスノードの確認（/dev/mapper/ 経由もチェック）
  RETRY=0
  while [ ! -e "/dev/vg_data/lv_log" ] && [ ! -e "/dev/mapper/vg_data-lv_log" ] && [ $RETRY -lt 5 ]; do
    echo "Waiting for LV nodes (Attempt $((RETRY+1)))..."
    /bin/udevadm settle
    sleep 1
    RETRY=$((RETRY+1))
  done
  # 個別マウント処理
  mount_lv() {
    lv_name=$1
    mount_point=$2
    dev_path="/dev/mapper/vg_data-lv_${lv_name}"
    if [ -e "$dev_path" ]; then
      echo "Mounting ${lv_name} to ${mount_point}..."
      mkdir -p "/mnt${mount_point}"
      /usr/bin/busybox mount -t ext4 "$dev_path" "/mnt${mount_point}"
    fi
  }
  # 独立したパス
  mount_lv "backup" "/backup"
  mount_lv "docker" "/var/lib/docker"
  mount_lv "cert" "/var/lib/dtebx"
  mount_lv "log"    "/var/log"
  mount_lv "audit"  "/var/log/audit"

  # アプリケーション用 (階層構造)
  # 親ディレクトリを先にマウント
  mount_lv "currentApp" "/home/ot-admin/dfx_dtebx_docker"
  # 子ディレクトリ
  mount_lv "adm_ini"    "/home/ot-admin/dfx_dtebx_docker/adm_ini"
  mount_lv "adm_clean"  "/home/ot-admin/dfx_dtebx_docker/adm_clean"
  mount_lv "dbvol"      "/home/ot-admin/dfx_dtebx_docker/pgvol"
  mount_lv "sfs"        "/home/ot-admin/dfx_dtebx_docker/sfs"

  /bin/udevadm settle
  /usr/bin/busybox sleep 1

  ##### RECOVERY LOGIC START #####
  TARGET_LIST="/mnt/backup/restore-target"
  RECOVERY_LOG="/run/recovery.log"
  recovery_log() {
    echo "$@"
    echo "$@" >> "$RECOVERY_LOG"
  }
  if [ -f "$TARGET_LIST" ]; then
    recovery_log "=== [RESTORE MODE] Recovery target detected! ==="

    # ネットワークが必要なため、このタイミングで起動
    IS_PRIME=$(cat "/mnt/home/ot-admin/dfx_dtebx_docker/primary.check" | /usr/bin/busybox head -n 1)
    /usr/bin/busybox ip link set eth0 up
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

    STAGING="/mnt/backup/.recovery_staging"
    mkdir -p "$STAGING"

    recovery_log "Waiting for network link up..."
    RETRY_NW=0
    while [ $RETRY_NW -lt 10 ]; do
      if /usr/bin/busybox ping -c 1 -W 1 "$TARGET_IP" > /dev/null 2>&1; then
        recovery_log "Network is UP. Target $TARGET_IP is reachable."
        break
      fi
      recovery_log "Waiting for $TARGET_IP... ($((RETRY_NW+1))/10)"
      /usr/bin/busybox sleep 1
      RETRY_NW=$((RETRY_NW+1))
    done

    if /usr/bin/busybox wget -O "$STAGING/bundle.tar" "http://$TARGET_IP/backup/$BACKUP_FILE"; then
      recovery_log "Extracting bundle..."
      /usr/bin/busybox tar -C "$STAGING" -xf "$STAGING/bundle.tar"

      # 各LVの展開 (すでに /mnt/xxx にマウント済み)
      restore_lv_tar() {
        pattern=$1
        target_path=$2
        target_file=$(ls "$STAGING"/${pattern}_[0-9]*.tar.gz 2>/dev/null | head -n 1)
        if [ -z "$target_file" ]; then
          recovery_log "[WARN] No archive found for $pattern"
          return
        fi
        if /usr/bin/busybox mount | /usr/bin/busybox grep -q "on /mnt$target_path type"; then
          # 一時展開用ディレクトリの作成
          tmp_extract="$STAGING/tmp_${pattern}"
          mkdir -p "$tmp_extract"
          # 一旦一時ディレクトリに展開
          /usr/bin/busybox tar -C "$tmp_extract" -xzpf "$target_file"

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
          /usr/bin/rsync -aHAX -x --delete --numeric-ids "$tmp_extract/" "/mnt$target_path/"
          /usr/bin/busybox rm -rf "$tmp_extract"
          /usr/bin/busybox rm -f "$target_file"
        else
          recovery_log "[WARN] Skip $pattern: /mnt$target_path is not mounted"
        fi
      }
      restore_lv_tar "boot" "/boot/firmware"
      restore_lv_tar "log" "/var/log"
      restore_lv_tar "log_audit" "/var/log/audit"
      restore_lv_tar "adm_ini" "/home/ot-admin/dfx_dtebx_docker/adm_ini"
      restore_lv_tar "adm_clean" "/home/ot-admin/dfx_dtebx_docker/adm_clean"
      restore_lv_tar "pgvol" "/home/ot-admin/dfx_dtebx_docker/pgvol"
      restore_lv_tar "sfs" "/home/ot-admin/dfx_dtebx_docker/sfs"
      restore_lv_tar "app_main" "/home/ot-admin/dfx_dtebx_docker"

      # 証明書特殊マージ処理
      recovery_log "Merging Certificates..."
      mkdir -p "$STAGING/cert"
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
      recovery_log "Restoring Root FS..."
      mkdir -p "$STAGING/root"
      /usr/bin/busybox tar -C "$STAGING/root" -xzpf "$STAGING"/root_*.tar.gz
      /usr/bin/rsync -aHAX -x --delete --numeric-ids "$STAGING/root/" /mnt/
      /usr/bin/busybox rm -f "$STAGING"/root_*.tar.gz

      # 完了処理
      echo "$BACKUP_FILE" > /mnt/var/lib/dtebx/needs_recovery
      rm -f "$TARGET_LIST"
      rm -fr "$STAGING"

      recovery_log "Recovery successful. Rebooting in 5 seconds..."
      cp "$RECOVERY_LOG" "/mnt/var/log/recovery_$BACKUP_FILE.log"
      sleep 5
      reboot -f
    else
      echo "Failed to download backup. Skipping recovery..."
    fi
  fi
  ##### RECOVERY LOGIC END #####
fi
##### custom end

systemctl switch-root /mnt /usr/sbin/init
