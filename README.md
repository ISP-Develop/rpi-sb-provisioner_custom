rpi-sb-provisionerで使用されるinitramfs(LUKS環境にて開錠・マウントして実際のOSを起動するFS)を改造

※rpi-sb-provisionerをクローン(git clone git@github.com:raspberrypi/rpi-sb-provisioner.git)して作業専用のディレクトリを準備して実施する。

* 改造の為initramfsを展開

  ```bash
  mkdir -p ~/rpi-sb-provisioner_custom/work/extract_initramfs
  cd ~/rpi-sb-provisioner_custom/work/extract_initramfs
  
  # 展開コマンド
  zstd -d -c ~/rpi-sb-provisioner_custom/host-support/cryptroot_initramfs | cpio -idm
  ```

  ※以降は展開したinitramfs内の相対パスで記載する。

* `init_cryptroot.sh` の修正

  ```bash
  #!/bin/sh
  # /usr/bin/init_cryptroot.sh
  /usr/bin/busybox mdev -s
  /usr/bin/busybox sleep 2
  exec > /dev/ttyAMA0 2>&1  # 全ての出力を画面に強制表示
  set -x                    # 実行コマンドを逐一表示
  /usr/bin/busybox sleep 3
  #trap 'echo "ERROR DETECTED. Dropping to shell..."; /bin/sh' 0 1 2 3 15
  #set -e
  
  /usr/bin/cryptkey-fetch | /sbin/cryptsetup luksOpen /dev/mmcblk0p2 cryptroot || {
      echo "FATAL: LUKS open failed."
      sleep 30 && reboot -f
  }
  
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
    mount_lv "log"    "/var/log" "btrfs" "compress=zstd:6"
    mount_lv "audit"  "/var/log/audit" "btrfs" "compress=zstd:6"
  
    # アプリケーション用 (階層構造)
    # 親ディレクトリを先にマウント
    mount_lv "currentApp" "/home/ot-admin/dfx_dtebx_docker"
    # 子ディレクトリ
    mount_lv "adm_ini"    "/home/ot-admin/dfx_dtebx_docker/adm_ini"
    mount_lv "adm_clean"  "/home/ot-admin/dfx_dtebx_docker/adm_clean"
    mount_lv "dbvol"      "/home/ot-admin/dfx_dtebx_docker/pgvol"
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
              restore_lv_tar "sfs" "/home/ot-admin/dfx_dtebx_docker/sfs" "verify" && \
              restore_lv_tar "app_main" "/home/ot-admin/dfx_dtebx_docker" "verify" && \
              restore_lv_tar "cert" "/var/lib/dtebx/" "verify" && \
              restore_lv_tar "root" "/" "verify"; then
  
            recovery_log "Phase 2: All components verified. Starting restoration..."
            restore_lv_tar "boot" "/boot/firmware" "restore"
            restore_lv_tar "log" "/var/log" "restore"
            restore_lv_tar "log_audit" "/var/log/audit" "restore"
            restore_lv_tar "adm_ini" "/home/ot-admin/dfx_dtebx_docker/adm_ini" "restore"
            restore_lv_tar "adm_clean" "/home/ot-admin/dfx_dtebx_docker/adm_clean" "restore"
            restore_lv_tar "pgvol" "/home/ot-admin/dfx_dtebx_docker/pgvol" "restore"
            restore_lv_tar "sfs" "/home/ot-admin/dfx_dtebx_docker/sfs" "restore"
            restore_lv_tar "app_main" "/home/ot-admin/dfx_dtebx_docker" "restore"
  
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
          else
            recovery_failed_log "Individual verification of the backup file failed. The file may be corrupted."
          fi
  
          # 完了処理
          echo "$BACKUP_FILE" > /mnt/var/lib/dtebx/needs_recovery
          rm -f "$TARGET_LIST"
          rm -fr "$STAGING"
  
          recovery_log "Recovery successful. Rebooting in 5 seconds..."
          cp "$RECOVERY_LOG" "/mnt/var/log/recovery_$BACKUP_FILE.log"
          sleep 5
          reboot -f
        else
          recovery_failed_log "Failed to download backup. Skipping recovery..."
          [ -f "$TARGET_LIST" ] && mv "$TARGET_LIST" "${TARGET_LIST}.failed"
        fi
      fi
      ##### RECOVERY LOGIC END #####
    ) || {
      # サブシェルが1（エラー）で終了した場合の処理
      recovery_failed_log "Recovery failed, but proceeding to boot with existing OS..."
      [ -f "$TARGET_LIST" ] && mv "$TARGET_LIST" "${TARGET_LIST}.failed"
    }
  fi
  exec > /dev/console 2>&1
  ##### custom end
  
  systemctl switch-root /mnt /usr/sbin/init
  
  ```

* 必要資材の移植

  ```bash
  # pi-genで生成したイメージから取得する。※lvm2やcryptsetupのパッケージが入っているイメージ
  IMG_FILE="/home/masadat/rpi-deploy/pi-gen/deploy/2026-05-20-DTEBX-ADM1-RSP-lite.img" # 例
  LOOP_DEV=$(sudo losetup -fP --show "${IMG_FILE}")
  mkdir -p /tmp/rpi_rootfs
  sudo mount "${LOOP_DEV}p2" /tmp/rpi_rootfs
  
  # 実行ファイル(ARM64)のコピー
  DEST="${HOME}/rpi-sb-provisioner_custom/work/extract_initramfs" # 例
  mkdir -p "${DEST}/sbin" "${DEST}/bin" "${DEST}/lib/aarch64-linux-gnu" "${DEST}/etc/lvm"
  sudo cp -p /tmp/rpi_rootfs/sbin/lvm "${DEST}/sbin/"
  sudo cp -p /tmp/rpi_rootfs/sbin/resize2fs "${DEST}/sbin/"
  sudo cp -p /tmp/rpi_rootfs/sbin/e2fsck "${DEST}/sbin/"
  sudo cp -p /tmp/rpi_rootfs/bin/udevadm "${DEST}/bin/"
  sudo cp -p /tmp/rpi_rootfs/sbin/parted "${DEST}/sbin/"
  sudo cp -p /tmp/rpi_rootfs/sbin/partprobe "${DEST}/sbin/"
  # LVMの設定ファイルをコピー
  sudo cp -p /tmp/rpi_rootfs/etc/lvm/lvm.conf "${DEST}/etc/lvm/"
  
  # ライブラリ(ARM64)のコピー
  # ※ /lib/aarch64-linux-gnu/ から必要なものをまとめてコピー
  LIBS=(
      "libdevmapper-event.so.1.02.1"
      "libedit.so.2"
      "libsystemd.so.0"
      "libblkid.so.1"
      "libaio.so.1"
      "libselinux.so.1"
      "libudev.so.1"
      "libm.so.6"
      "libc.so.6"
      "ld-linux-aarch64.so.1"
      "libdevmapper.so.1.02.1"
      "libtinfo.so.6"
      "libbsd.so.0"
      "libcap.so.2"
      "libgcrypt.so.20"
      "liblzma.so.5"
      "libzstd.so.1"
      "liblz4.so.1"
      "libpcre2-8.so.0"
      "libmd.so.0"
      "libgpg-error.so.0"
      "libe2p.so.2"
      "libext2fs.so.2"
      "libcom_err.so.2"
      "libparted.so.2"
      "libreadline.so.8"
      "libuuid.so.1"
  )
  for LIB in "${LIBS[@]}"; do
      if [ -f "/tmp/rpi_rootfs/lib/aarch64-linux-gnu/${LIB}" ]; then
          sudo cp -p "/tmp/rpi_rootfs/lib/aarch64-linux-gnu/${LIB}" "${DEST}/lib/aarch64-linux-gnu/"
      fi
  done
  
  # LVMのシンボリックリンク作成
  # initramfs内でコマンドとして叩けるようにリンクを張る
  sudo ln -sf lvm "${DEST}/sbin/pvcreate"
  sudo ln -sf lvm "${DEST}/sbin/vgcreate"
  sudo ln -sf lvm "${DEST}/sbin/lvcreate"
  sudo ln -sf lvm "${DEST}/sbin/vgchange"
  
  # 4. modprobeコマンドの確保 (Busyboxのmodprobeで動かない場合に備えてkmodを入れる)
  if [ -f "/tmp/rpi_rootfs/bin/kmod" ]; then
      sudo cp -p /tmp/rpi_rootfs/bin/kmod "${DEST}/bin/"
      sudo ln -sf kmod "${DEST}/bin/modprobe"
  fi
  
  # マウントしたイメージの後片付け
  sudo umount /tmp/rpi_rootfs
  sudo losetup -d "${LOOP_DEV}"
  
  # 権限と実行属性の一括設定
  sudo chown -R $(whoami):$(whoami) "${DEST}"
  sudo chmod +x "${DEST}/sbin/"* "${DEST}/bin/udevadm" "${DEST}/usr/bin/init_cryptroot.sh"
  
  # リパック
  cd ~/rpi-sb-provisioner_custom/work/extract_initramfs # 例
  find . -print0 | sudo cpio --null -ov --format=newc | zstd -z -19 -T0 -o ~/rpi-sb-provisioner_custom/work/cryptroot_initramfs.new
  
  # リパックしたcryptroot_initramfs.newをrpi-sb-provisioner実行環境の/var/lib/rpi-sb-provisioner/cryptroot_initramfsにコピーする。
  ```

* rpi-sb-provisioner.shへのパッチ

  > **Note: ** `augment_initramfs` では、展開済み initramfs 内の `usr/lib/modules` を削除してから再作成するが、その際にコピーされるmoduleが現Verでは固定されているため `rpi-sb-provisioner.sh` にパッチを当てて対象を拡張する必要がある。

```bash
###################################################
### 以下はrpi-sb-provisionerの実行環境で実行すること ###
###################################################
# 念のためバックアップ
sudo cp -a /usr/bin/rpi-sb-provisioner.sh \
  /usr/bin/rpi-sb-provisioner.sh.bak.btrfs.$(date +%Y%m%d%H%M%S)
# パッチ実行
sudo python3 - <<'PY'
from pathlib import Path

path = Path("/usr/bin/rpi-sb-provisioner.sh")
s = path.read_text()

if "show-depends btrfs" in s:
    print("already patched")
    raise SystemExit(0)

func_pos = s.find("augment_initramfs()")
if func_pos < 0:
    raise SystemExit("augment_initramfs() not found")

# Prefer the comment immediately before the depmod loop.
insert_pos = s.find("# Generate depmod information", func_pos)

# Fallback: find the depmod loop itself.
if insert_pos < 0:
    insert_pos = s.find('find "${initramfs_dir}usr/lib/modules"', func_pos)

if insert_pos < 0:
    raise SystemExit("depmod insertion point not found in augment_initramfs()")

# Move insertion point to beginning of the line.
insert_pos = s.rfind("\n", 0, insert_pos) + 1

block = r'''    # Insert Btrfs and all dependency modules required for initramfs-time Btrfs mounts.
    command -v modprobe >/dev/null 2>&1 || die "modprobe not found on provisioner host"

    for kdir in "${rootfs_mount}"/usr/lib/modules/*; do
        [ -d "${kdir}" ] || continue

        kernel="$(basename "${kdir}")"
        depfile="${TMP_DIR}/btrfs-deps.${kernel}"
        errfile="${TMP_DIR}/btrfs-deps.${kernel}.err"

        if ! modprobe -d "${rootfs_mount}" -S "${kernel}" --show-depends btrfs > "${depfile}" 2> "${errfile}"; then
            cat "${errfile}" >&2 || true
            die "Failed to resolve btrfs module dependencies for ${kernel}"
        fi

        while read -r action modpath rest; do
            [ "${action}" = "insmod" ] || continue

            rel="${modpath#${rootfs_mount}/}"
            rel="${rel#/}"

            case "${rel}" in
                lib/modules/*)
                    rel="usr/${rel}"
                    ;;
            esac

            if [ ! -f "${rootfs_mount}/${rel}" ]; then
                echo "Missing btrfs dependency: ${modpath}" >&2
                die "Failed to copy btrfs dependency for ${kernel}"
            fi

            (
                cd "${rootfs_mount}" || exit 1
                cp -p --parents "${rel}" "${initramfs_dir}"
            ) || die "Failed to copy ${rel} into initramfs"
        done < "${depfile}"

        rm -f "${depfile}" "${errfile}"
    done

    if ! find "${initramfs_dir}usr/lib/modules" -path '*/kernel/fs/btrfs/btrfs.ko*' | grep -q .; then
        die "btrfs.ko was not copied into initramfs"
    fi

'''

s = s[:insert_pos] + block + s[insert_pos:]
path.write_text(s)

print("patched /usr/bin/rpi-sb-provisioner.sh")
PY

# 念のため構文チェック
sudo sh -n /usr/bin/rpi-sb-provisioner.sh

# 念のため中間成果物を確認して削除
if [ -f /etc/rpi-sb-provisioner/config ]; then
    . /etc/rpi-sb-provisioner/config
fi

if [ -n "${RPI_SB_WORKDIR:-}" ] && [ -d "${RPI_SB_WORKDIR}" ]; then
    sudo rm -f \
      "${RPI_SB_WORKDIR}/bootfs-temporary.simg" \
      "${RPI_SB_WORKDIR}/rootfs-temporary.simg"
fi

```
