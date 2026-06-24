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

* 必要資材の移植

  ```bash
  # pi-genで生成したイメージから取得する。※lvm2やcryptsetupのパッケージが入っているイメージ
  IMG_FILE="/home/masadat/rpi-deploy/pi-gen/deploy/2026-05-20-DTEBX-ADM1-RSP-lite.img" # 例
  LOOP_DEV=$(sudo losetup -fP --show "${IMG_FILE}")
  mkdir -p /tmp/rpi_rootfs
  sudo mount "${LOOP_DEV}p2" /tmp/rpi_rootfs
  
  # 実行ファイル(ARM64)のコピー
  DEST="${HOME}/rpi-sb-provisioner_custom/work/extract_initramfs" # 例
  mkdir -p "${DEST}/sbin" "${DEST}/bin" "${DEST}/lib/aarch64-linux-gnu" "${DEST}/etc/lvm" "${DEST}/usr/bin"
  sudo cp -p /tmp/rpi_rootfs/sbin/lvm "${DEST}/sbin/"
  sudo cp -p /tmp/rpi_rootfs/sbin/resize2fs "${DEST}/sbin/"
  sudo cp -p /tmp/rpi_rootfs/sbin/e2fsck "${DEST}/sbin/"
  sudo cp -p /tmp/rpi_rootfs/bin/udevadm "${DEST}/bin/"
  sudo cp -p /tmp/rpi_rootfs/sbin/parted "${DEST}/sbin/"
  sudo cp -p /tmp/rpi_rootfs/sbin/partprobe "${DEST}/sbin/"
  sudo cp -p /tmp/rpi_rootfs/usr/bin/rsync "${DEST}/usr/bin/"
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
      "libacl.so.1"
      "libz.so.1"
      "libpopt.so.0"
      "libxxhash.so.0"
      "libcrypto.so.3"
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
