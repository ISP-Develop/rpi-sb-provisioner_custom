# rpi-sb-provisioner_custom

DTEBX(ADM) 向けに **rpi-sb-provisioner の initramfs を改造し、プロビジョニング実行環境へ反映する**ためのリポジトリ。

## このリポジトリの位置づけ（先に読むこと）

- **ここは initramfs を作る場所であり、rpi-sb-provisioner が動く場所ではない。**
- 実行環境は別ホスト（開発環境では prov = `192.168.128.111`）。udev → systemd `rpi-sb-*@.service` → `ExecStart=/usr/bin/rpi-sb-*.sh` という経路で、**実際に動くのは apt で入れたパッケージの `/usr/bin` 配下だけ**。このリポジトリのファイルが直接実行されることはない。
- したがって **上流ソース（`service/` 等）をここで編集しても実行環境には反映されない**。実行環境側のスクリプトに手を入れる必要がある場合は、ソースを抱えるのではなく **「§3 実行環境への反映」のパッチ手順として持つ**。
  - 2026-07-17 に fastboot 転送路の修正を `service/rpi-sb-common.sh` に対して行ったが、**配られる経路が無いため一度も反映されず**、2026-08-15 に書き込み先の取り違えとして表面化した（→ §3.3）。同じことを繰り返さないために `service/` 以下の上流ソースは本リポジトリから削除してある。

### 構成

| パス | 役割 |
|---|---|
| `host-support/cryptroot_initramfs` | 上流の initramfs 原本。§1 の展開の**入力** |
| `work/extract_initramfs/` | 展開して改造した initramfs ツリー（`usr/bin/init_cryptroot.sh` ほか）。**実質の成果物はここ** |
| `work/cryptroot_initramfs.new*` | リパック結果。ビルド成果物のため git 管理外 |

上流リポジトリは `git clone git@github.com:raspberrypi/rpi-sb-provisioner.git`。原本の更新が必要になったときだけ参照する。

---

## 1. initramfs の改造

initramfs = LUKS 環境にて開錠・マウントして実際の OS を起動する FS。

* 改造の為 initramfs を展開

  ```bash
  mkdir -p ~/rpi-sb-provisioner_custom/work/extract_initramfs
  cd ~/rpi-sb-provisioner_custom/work/extract_initramfs

  # 展開コマンド
  zstd -d -c ~/rpi-sb-provisioner_custom/host-support/cryptroot_initramfs | cpio -idm
  ```

  ※以降は展開した initramfs 内の相対パスで記載する。

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
  ```

## 2. リパック

```bash
cd ~/rpi-sb-provisioner_custom/work/extract_initramfs
find . -print0 | sudo cpio --null -ov --format=newc | zstd -z -19 -T0 -o ~/rpi-sb-provisioner_custom/work/cryptroot_initramfs.new
```

---

## 3. 実行環境（prov）への反映

**§3 は全て rpi-sb-provisioner の実行環境で実行すること。** 対象パッケージ版数は `rpi-sb-provisioner 2.0.4`（`dpkg -l | grep rpi-sb` で確認）。

反映後に何が変わっているかは `sudo dpkg -V rpi-sb-provisioner` で一覧できる（パッケージ原本と異なるファイルが出る）。

### 3.1 initramfs の配置

§2 でリパックした `cryptroot_initramfs.new` を実行環境へ送り、配置する。

```bash
sudo cp -a /var/lib/rpi-sb-provisioner/cryptroot_initramfs \
  /var/lib/rpi-sb-provisioner/cryptroot_initramfs.bak.$(date +%Y%m%d%H%M%S)
sudo cp <送り込んだcryptroot_initramfs.new> /var/lib/rpi-sb-provisioner/cryptroot_initramfs
```

### 3.2 `rpi-sb-provisioner.sh` へのパッチ（btrfs モジュールの埋め込み）

> **Note:** `augment_initramfs` では、展開済み initramfs 内の `usr/lib/modules` を削除してから再作成するが、その際にコピーされる module が現 Ver では固定されているため `rpi-sb-provisioner.sh` にパッチを当てて対象を拡張する必要がある。

```bash
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

### 3.3 `rpi-sb-common.sh` へのパッチ（fastboot 転送路を USB に固定）

> **Note:** `setup_fastboot_and_id_vars` は、USB シリアルで掴んだ相手に IP アドレスを問い合わせ、TCP で到達できればそちらへ **接続先を差し替える**。**fastboot over TCP は IP でしか相手を選べず、デバイスシリアルとの結び付きが無い**ため、同一ネットワーク上に複数台のターゲットが居ると **別の個体へ書き込まれる**。
>
> 本関数は `rpi-sb-provisioner.sh` の中で 2 回呼ばれる。1 回目は起動直後で IP が取れず USB のまま進むため `erase` / `partinit` / `partapp` / `cryptinit` / `cryptopen` は正しい個体に当たるが、**`flash` の直前の 2 回目で差し替わる**。結果、片方は 2 回書かれ、もう片方は rootfs が書かれないまま、**両方のログが `Provisioning completed.` になる**（2026-08-15 に発生）。
>
> パッチは既存の IP プローブを `RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT` で括り、既定を `usb`（＝USB シリアルに固定し、IP の問い合わせも TCP の疎通確認も行わない）にする。従来の Ethernet 優先動作が必要な場合のみ `auto` を設定する（**1 台ずつ書く場合に限る**）。

```bash
# 念のためバックアップ
sudo cp -a /usr/bin/rpi-sb-common.sh \
  /usr/bin/rpi-sb-common.sh.bak.transport.$(date +%Y%m%d%H%M%S)
# パッチ実行
sudo python3 - <<'PY'
from pathlib import Path

path = Path("/usr/bin/rpi-sb-common.sh")
s = path.read_text()

if "RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT" in s:
    print("already patched")
    raise SystemExit(0)

start_marker = '    announce_start "Testing Fastboot IP connectivity"'
end_marker = "    # Set TARGET_USB_PATH based on TARGET_DEVICE_SERIAL"

start = s.find(start_marker)
end = s.find(end_marker)
if start < 0 or end < 0 or end < start:
    raise SystemExit("IP probe block not found in setup_fastboot_and_id_vars()")

block = s[start:end]
# 既存ブロックを 4 スペース深くして auto 分岐の中へ入れる
indented = "".join(("    " + l if l.strip() else l) for l in block.splitlines(keepends=True))

new = (
    '    # Select the fastboot transport. Default is "usb", which pins the connection\n'
    '    # to the USB serial and never probes/uses TCP. Fastboot over TCP binds to an\n'
    '    # IP address with no association to the device serial, so with several targets\n'
    '    # on one network the connection can be routed to an unintended device.\n'
    '    # Set RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT=auto to restore the previous\n'
    '    # behaviour of preferring an Ethernet (TCP) connection.\n'
    '    if [ "${RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT:-usb}" = "auto" ]; then\n'
    + indented +
    '    else\n'
    '        log "Fastboot transport forced to USB for device ${TARGET_DEVICE_SERIAL}"\n'
    '        FASTBOOT_DEVICE_SPECIFIER="${TARGET_DEVICE_SERIAL}"\n'
    '    fi\n\n'
)

path.write_text(s[:start] + new + s[end:])
print("patched /usr/bin/rpi-sb-common.sh")
PY

# 念のため構文チェック
sudo sh -n /usr/bin/rpi-sb-common.sh

# 既定値は usb だがスクリプト側の既定に依存しないよう明示する
grep -q '^RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT=' /etc/rpi-sb-provisioner/config \
  || echo 'RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT=usb' | sudo tee -a /etc/rpi-sb-provisioner/config
```

### 3.4 パッケージ更新でパッチが戻らないようにする

`/usr/bin/*` はパッケージ所有のため、`apt upgrade` で §3.2 / §3.3 が**黙って元に戻る**。

```bash
sudo apt-mark hold rpi-sb-provisioner
apt-mark showhold   # rpi-sb-provisioner が出ること
```

上流を上げるときは hold を外し、**上げた後に §3.2 / §3.3 を再適用する**（どちらのパッチも適用済みなら `already patched` で抜けるので、再実行して構わない）。

### 3.5 反映確認

| 見るもの | 期待 |
|---|---|
| `sudo dpkg -V rpi-sb-provisioner` | `/usr/bin/rpi-sb-provisioner.sh` と `/usr/bin/rpi-sb-common.sh` が改変ありとして出る |
| `apt-mark showhold` | `rpi-sb-provisioner` |
| 書き込み時の `/var/log/rpi-sb-provisioner/<serial>/provisioner.log` | **`Fastboot transport forced to USB for device <serial>` が出る**（出なければ §3.3 が効いていない）。`Testing Fastboot IP connectivity` と `tcp:` は**出ない** |

### 3.6 再プロビジョニング時の注意

- セキュアブート設定済みの端末は EEPROM と boot.img の署名不一致で失敗しやすい → `/etc/rpi-sb-provisioner/special-reprovision-device/<シリアル下8桁>` を touch する。
- `GOLD_MASTER_OS_FILE` は `/etc/rpi-sb-provisioner/config` の**単一のグローバル値**で、**どのイメージを使ったかはログに残らない**。ADM1/ADM2 を続けて書くときは run の間に書き換えること。
