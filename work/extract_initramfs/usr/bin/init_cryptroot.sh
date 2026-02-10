#!/bin/sh
# /usr/bin/init_cryptroot.sh
exec > /dev/console 2>&1  # 全ての出力を画面に強制表示
set -x                    # 実行コマンドを逐一表示
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
  echo "Starting resize2fs to ${TARGET_GIB}G..." > /dev/console
  /sbin/resize2fs -p /dev/mapper/cryptroot "${TARGET_GIB}G" 2>&1 > /dev/console
  # 物理パーティションの強制リサイズ
  echo "Creating physical partition wall with parted..." > /dev/console
  yes | /sbin/parted /dev/mmcblk0 ---pretend-input-tty resizepart 2 ${TARGET_P2_END} 2>&1 > /dev/console
  # p3 を作成
  /sbin/parted -s /dev/mmcblk0 mkpart primary ${TARGET_P3_START} 100% 2>&1 > /dev/console
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
  echo "First boot: Fixing PARTUUIDs..." > /dev/console
  /usr/bin/busybox mount /dev/mapper/cryptroot /mnt
  NEW_P1_UUID=$(blkid -s PARTUUID -o value /dev/mmcblk0p1)
  NEW_P2_UUID=$(blkid -s PARTUUID -o value /dev/mmcblk0p2)
  if [ -n "$NEW_P1_UUID" ] && [ -n "$NEW_P2_UUID" ]; then
    sed -i "s/PARTUUID=[^ ]*-01/PARTUUID=${NEW_P1_UUID}/g" /mnt/etc/fstab
    sed -i "s/PARTUUID=[^ ]*-02/PARTUUID=${NEW_P2_UUID}/g" /mnt/etc/fstab
  fi
  /usr/bin/busybox umount /mnt
else
  echo "Already resized. Skipping..." > /dev/console
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
  echo "Opening cryptlvm..." > /dev/console
  # 開錠
  /sbin/cryptsetup luksOpen /dev/mmcblk0p3 "cryptlvm" --key-file "$keypath"
  # LVMボリュームの有効化
  echo "Scanning LVM volumes (Forced)..." > /dev/console
  /bin/udevadm settle
  
  # フィルタを無視して全てのブロックデバイスをスキャンし、キャッシュを更新
  /sbin/lvm pvscan --cache /dev/mapper/cryptlvm > /dev/console 2>&1
  /sbin/lvm vgscan --mknodes > /dev/console 2>&1
  
  # vg_data を強制的にアクティブ化
  echo "Activating vg_data..." > /dev/console
  /sbin/lvm vgchange -ay vg_data --sysinit > /dev/console 2>&1
  echo "Forcing node creation..." > /dev/console
  /sbin/lvm vgmknodes vg_data

  # デバイスノードの確認（/dev/mapper/ 経由もチェック）
  RETRY=0
  while [ ! -e "/dev/vg_data/lv_log" ] && [ ! -e "/dev/mapper/vg_data-lv_log" ] && [ $RETRY -lt 5 ]; do
    echo "Waiting for LV nodes (Attempt $((RETRY+1)))..." > /dev/console
    /bin/udevadm settle
    sleep 1
    RETRY=$((RETRY+1))
  done
  # 個別マウント処理
  mount_lv() {
    local lv_name=$1
    local mount_point=$2
    local dev_path="/dev/mapper/vg_data-lv_${lv_name}"
    if [ -e "$dev_path" ]; then
      echo "Mounting ${lv_name} to ${mount_point}..." > /dev/console
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

fi
##### custom end

systemctl switch-root /mnt /usr/sbin/init
