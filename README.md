# rpi-sb-provisioner_custom

DTEBX(ADM) 向けに **rpi-sb-provisioner の initramfs を改造し、プロビジョニング実行環境へ反映する**ためのリポジトリ。

## このリポジトリの位置づけ（先に読むこと）

- **ここは initramfs を作る場所であり、rpi-sb-provisioner が動く場所ではない。**
- 実行環境は別ホスト。開発環境では **prov = `192.168.128.111`（rpi-sb-provisioner 2.0.4・§3。2 号機用）** と **prov2 = `192.168.128.112`（2.3.5・§4。1 号機用）** の 2 台。udev → systemd `rpi-sb-*@.service` → `ExecStart=/usr/bin/rpi-sb-*.sh` という経路で、**実際に動くのは apt で入れたパッケージの `/usr/bin` 配下だけ**。このリポジトリのファイルが直接実行されることはない。
- したがって **上流ソース（`service/` 等）をここで編集しても実行環境には反映されない**。実行環境側のスクリプトに手を入れる必要がある場合は、ソースを抱えるのではなく **「§3 実行環境への反映」のパッチ手順として持つ**。
  - 2026-07-17 に fastboot 転送路の修正を `service/rpi-sb-common.sh` に対して行ったが、**配られる経路が無いため一度も反映されず**、2026-08-15 に書き込み先の取り違えとして表面化した（→ §3.3）。同じことを繰り返さないために `service/` 以下の上流ソースは本リポジトリから削除してある。

### 構成

| パス | 役割 |
|---|---|
| `host-support/cryptroot_initramfs` | 上流の initramfs 原本。§1 の展開の**入力** |
| `work/extract_initramfs/` | 展開して改造した initramfs ツリー（`usr/bin/init_cryptroot.sh` ほか）。**実質の成果物はここ** |
| `work/cryptroot_initramfs.new*` | リパック結果。ビルド成果物のため git 管理外 |
| `patches-2.3.5/` | 2.3.5 用のパッチ（§4）。`p4-1`・`p4-3` は prov2 の `/usr/bin` 向け、`p4-*_initramfs*.py` は initramfs 向け、`kernel_modules.list` は `/etc/rpi-sb-provisioner/` 向け |
| `work-2.3.5/overlay/`・`work-2.3.5/MANIFEST` | 2.3.5 用 initramfs に**足す** 10 ファイルと、その由来・sha256（§4.3） |
| `build-initramfs-2.3.5.sh` | 2.3.5 用 initramfs を「`work/extract_initramfs` の写し＋overlay＋パッチ」から組み立てる（§4.3） |

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

### 3.7 `rpi-sb-provisioner.sh` へのパッチ（dm-verity／overlay モジュールの埋め込み・2026-09-25）

> dm-verity 下層＋overlay 上層のルート構成（`~/deforion/docs/assets/20260925_verity_overlay_adm2b_test_plan.md`）用。
> `init_cryptroot.sh` が initramfs 内で `modprobe overlay`／`modprobe dm-verity` するので、§3.2 の btrfs と同じ形で
> `dm-verity`（依存 `dm-bufio`）と `overlay` を `augment_initramfs` に足す。冪等（マーカー `DTEBX_VERITY_OVERLAY_MODULES`）。
> 2026-09-25 prov に適用済み（退避 `rpi-sb-provisioner.sh.bak.verity.20260925163034`）。

```bash
# 念のためバックアップ
sudo cp -a /usr/bin/rpi-sb-provisioner.sh \
  /usr/bin/rpi-sb-provisioner.sh.bak.verity.$(date +%Y%m%d%H%M%S)
# パッチ実行
sudo python3 - <<'PY'
from pathlib import Path
path = Path("/usr/bin/rpi-sb-provisioner.sh")
s = path.read_text()
MARK = "DTEBX_VERITY_OVERLAY_MODULES"
if MARK in s:
    print("already patched"); raise SystemExit(0)
func_pos = s.find("augment_initramfs()")
if func_pos < 0: raise SystemExit("augment_initramfs() not found")
insert_pos = s.find("# Generate depmod information", func_pos)
if insert_pos < 0: raise SystemExit("depmod insertion point not found")
insert_pos = s.rfind("\n", 0, insert_pos) + 1
block = r'''    # DTEBX_VERITY_OVERLAY_MODULES: dm-verity (+dm-bufio) and overlay for the verity/overlay root (2026-09-25).
    command -v modprobe >/dev/null 2>&1 || die "modprobe not found on provisioner host"
    for kdir in "${rootfs_mount}"/usr/lib/modules/*; do
        [ -d "${kdir}" ] || continue
        kernel="$(basename "${kdir}")"
        for vmod in dm-verity overlay; do
            depfile="${TMP_DIR}/${vmod}-deps.${kernel}"
            errfile="${TMP_DIR}/${vmod}-deps.${kernel}.err"
            if ! modprobe -d "${rootfs_mount}" -S "${kernel}" --show-depends "${vmod}" > "${depfile}" 2> "${errfile}"; then
                cat "${errfile}" >&2 || true
                die "Failed to resolve ${vmod} module dependencies for ${kernel}"
            fi
            while read -r action modpath rest; do
                [ "${action}" = "insmod" ] || continue
                rel="${modpath#${rootfs_mount}/}"
                rel="${rel#/}"
                case "${rel}" in
                    lib/modules/*) rel="usr/${rel}" ;;
                esac
                if [ ! -f "${rootfs_mount}/${rel}" ]; then
                    echo "Missing ${vmod} dependency: ${modpath}" >&2
                    die "Failed to copy ${vmod} dependency for ${kernel}"
                fi
                ( cd "${rootfs_mount}" || exit 1; cp -p --parents "${rel}" "${initramfs_dir}" ) || die "Failed to copy ${rel} into initramfs"
            done < "${depfile}"
            rm -f "${depfile}" "${errfile}"
        done
    done
    for vko in 'drivers/md/dm-verity.ko' 'fs/overlayfs/overlay.ko'; do
        if ! find "${initramfs_dir}usr/lib/modules" -path "*/kernel/${vko}*" | grep -q .; then
            die "${vko} was not copied into initramfs"
        fi
    done

'''
s = s[:insert_pos] + block + s[insert_pos:]
path.write_text(s)
print("patched /usr/bin/rpi-sb-provisioner.sh")
PY

# 念のため構文チェック
sudo sh -n /usr/bin/rpi-sb-provisioner.sh
grep -n "DTEBX_VERITY_OVERLAY_MODULES" /usr/bin/rpi-sb-provisioner.sh
```

反映確認は §3.5 と同じ。戻すときは `.bak.verity.*` を `/usr/bin/rpi-sb-provisioner.sh` に戻す。


### 3.9 書ける LV を `noexec,nodev,nosuid` で mount する（2026-09-27・docs/42 §7／docs/43 項 4d・J-14・J-19）

**何が変わるか**: `init_cryptroot.sh` の `mount_lv` で、p3 の LV のうち **`lv_docker`（コンテナ rootfs は exec 要＝層 C の一覧で守る）と
`lv_adm_ini`（560-2 本体と自己更新を残す）以外の 9 本**に `noexec,nodev,nosuid` を付ける。当社ホストアプリの実行物は
項 4c で OS イメージ（下層）に焼かれ、活性化の make は `dfx-lower-install` で一致を確かめるだけになったので、書ける LV に
実行物は無い（adm2b・adm1b で 0 本を確認）。**先に 4c の pi-gen 像（`06-isp-apps/01-run.sh` が焼く）を入れてから**この
initramfs を入れること。順序を逆にすると活性化の make が下層に無い実行物を LV に置けず止まる。

反映は §3.8 の ② と同じ（initramfs の再パック・差し替え）。判定: 起動後 `findmnt -no TARGET,OPTIONS /home/ot-admin/dfx_dtebx_docker`
に `noexec` が在り、`/var/lib/docker` と `…/adm_ini` には無い。ホット確認（remount で 9 本に当てて service 再起動・cron・
docker exec・postgres・3c が通ること）は adm2b で 2026-09-27 に済ませてある（docs/43 §6-20）。


### 3.10 boot.img の決定的パック（2026-09-28・docs/43 項 7e-β）

**何が変わるか**: 同じ像から焼いた機体で `boot.img` の sha256 が違っていた（initramfs の再パックで cpio の mtime/inode が、
FAT でボリューム ID とラベルの時刻が毎回変わる。中身のファイルは全機体で同一＝実測）。`rpi-sb-provisioner.sh` で
①initramfs は `touch -d @<GOLD_MASTER の mtime>`＋`LC_ALL=C sort`＋`cpio --reproducible`、②bootfs の全ファイルも同じ mtime に揃え
`SOURCE_DATE_EPOCH` を渡して `rpi-make-boot-image`、③作成後に FAT のボリューム ID（主＋バックアップブートセクタ）と
ラベル "BOOT" の dir entry の時刻を epoch 由来の固定値に書き直す（`dfx_fix_fat_volume_id`。dosfstools 4.2 は
`SOURCE_DATE_EPOCH` をラベル時刻に効かせない＝実測）。prov で同じ bootfs から 2 回作って sha256 一致・`fsck.fat` 正常を確認済み。
ログに `7e-β: boot.img sha256 …` を出すので、機体ごとに同じ値になることを provisioner.log で確かめる。

⚠ **このスクリプトは `#!/bin/sh`＝prov では dash で動く。** 初版の `dfx_fix_fat_volume_id` は bash 固有の書き方
（`${v:6:2}`・`$(( 10#09 ))`・`printf '\x..'`）を使っていたため、2026-09-28 の焼き込みで `Bad substitution` →
`set -e` で boot.img 作成の直後に落ちた（provisioner.log 12:5x）。POSIX sh に書き直し（8 進エスケープの `dfx_byte`/`dfx_le16`、
`date '+%-m'` で先頭 0 を出さない）、prov の dash で同じ bootfs から 2 回作って sha256 一致・volume id と label 時刻の
書き込み・`fsck.fat` 正常を確認した。§3.8 ① の差し替え前検査は `sh -n` と `bash -n` の両方を通す。

反映は §3.8 の ①（`/usr/bin/rpi-sb-provisioner.sh` の差し替え）だけ。


### 3.11 工場スナップショット（p7m）の鍵階層化（2026-09-28・C-412／docs/40・docs/43 項 7c）

**何が変わるか**: p7m の本体鍵が固定値から「DEK＋その機体の TPM に封印した `internal_backup_master_key`」になった。
initramfs は Phase 1 の前に `dtebx_unseal_file` で鍵を開封（`/mnt/var/lib/dtebx/shared/internal_backup_master_key/`）し、
`adm-diag-svd_arm64 --mode verify … --kek-file` に渡す。開封できなければ `failed-verification` で既存 OS を起動する。
`usr/bin/` に **`dtebx_unseal_file`（静的）を追加**、`adm-diag-svd_arm64` は新版（`DTBXSVD2`。旧 `DTBXSVD1` は拒む）。

反映は §3.8 ②（initramfs の再パック・差し替え）。⚠ **sign 側（560-4／560-2＝活性化。pi-gen 像と prov AppMaster の adm-ini）と同時に入れ、
クリーンインストールでバンドルを作り直す**。片方だけだと消去が必ず失敗する。

### 3.6 再プロビジョニング時の注意

- セキュアブート設定済みの端末は EEPROM と boot.img の署名不一致で失敗しやすい → `/etc/rpi-sb-provisioner/special-reprovision-device/<シリアル下8桁>` を touch する。
- `GOLD_MASTER_OS_FILE` は `/etc/rpi-sb-provisioner/config` の**単一のグローバル値**で、**どのイメージを使ったかはログに残らない**。ADM1/ADM2 を続けて書くときは run の間に書き換えること。

### 3.8 dm-verity 本流 — pi-gen 固定の下層・hash 木を焼き、root.hash を initramfs に同梱する（2026-09-27・docs/42 §6-1／docs/43 項 7e）

**何が変わるか**: 従来 prov は rootfs を `mke2fs -d` で作り直していた（機体ごとに UUID・hash_seed が変わり、
機体で hash を作る r2 形になっていた）。本流では pi-gen の `export-image/06-dfx-verity` が作った
sidecar（`<GOLD_MASTER_OS_FILE>.verity/`＝`lower.ext4.zst`・`hash.img`・`root.hash`・`manifest`）を
**そのまま**書き、root.hash を署名済み initramfs（`/etc/dtebx/root.hash`）に入れる。
∴ 全機体で下層・root hash・boot.img が同じになる。sidecar が無ければ従来（r2）どおり動く。

| 場所 | 変更 | 正本 |
|---|---|---|
| prov `/usr/bin/rpi-sb-provisioner.sh` | `augment_initramfs()` 末尾で root.hash を同梱／`prepare_rootfs_image()` に sidecar 分岐（`truncate`→下層 `dd conv=sparse`→sha 突合→hash 木を `hash_offset` へ→`img2simg`。★イメージは下層＋hash 木の大きさだけ・`-s` 無し＝穴（DONT_CARE）を作らない。cryptroot 全域にすると末尾 54GiB の DONT_CARE を機体の fastbootd が拒む＝2026-09-27 実測） | `host-support/rpi-sb-provisioner.sh`（**prov の現物と同一にしておく＝J-9**。差し替えは下の手順） |
| initramfs `usr/bin/init_cryptroot.sh` | 起動時に `6GiB-64MiB` の verity 超ブロックを探し、在れば**本流**＝下層に触らず（e2fsck/resize2fs を掛けない）p2/p3 を切るだけ。`dtebx_carve` は hash 木から下層サイズを復元し、上層に FS が無ければ 1 回だけ `mke2fs`。`/etc/dtebx/root.hash` が在れば `veritysetup open` | `work/extract_initramfs/usr/bin/init_cryptroot.sh` |
| pi-gen | `export-image/06-dfx-verity/`（05-finalise の後。下層＝p2 を最小化＋1GiB、salt/uuid/時刻固定で再現性あり） | `rpi-deploy/pi-gen` |

**prov への反映手順（sudo が要る。開発機 `~/rpi-sb-provisioner_custom` から）**

```bash
# ① スクリプト（退避→構文検査→差し替え）
scp host-support/rpi-sb-provisioner.sh prov:/tmp/rpi-sb-provisioner.sh.new
ssh prov 'D=$(date +%Y%m%d%H%M%S); sudo cp -p /usr/bin/rpi-sb-provisioner.sh /usr/bin/rpi-sb-provisioner.sh.bak.$D \
  && sh -n /tmp/rpi-sb-provisioner.sh.new && bash -n /tmp/rpi-sb-provisioner.sh.new && sudo install -m 755 -o root -g root /tmp/rpi-sb-provisioner.sh.new /usr/bin/rpi-sb-provisioner.sh'
# ② initramfs（木を prov で root 所有にして再パック→退避→差し替え）
#    ⚠ 2 回目以降は prov 側の木が root 所有で rsync が書けないので先に消す
ssh prov 'sudo rm -rf /tmp/extract_initramfs'
rsync -a --delete work/extract_initramfs/ prov:/tmp/extract_initramfs/
ssh prov 'D=$(date +%Y%m%d%H%M%S); cd /tmp/extract_initramfs && sudo chown -R root:root . \
  && sudo sh -c "find . -print0 | cpio --null -o --format=newc 2>/dev/null | zstd -q -z -19 -T0 -f -o /tmp/cryptroot_initramfs.new" \
  && sudo cp -p /var/lib/rpi-sb-provisioner/cryptroot_initramfs /var/lib/rpi-sb-provisioner/cryptroot_initramfs.bak.$D \
  && sudo install -m 644 -o ot-admin -g ot-admin /tmp/cryptroot_initramfs.new /var/lib/rpi-sb-provisioner/cryptroot_initramfs \
  && zstd -d -c /var/lib/rpi-sb-provisioner/cryptroot_initramfs | cpio -i --to-stdout usr/bin/init_cryptroot.sh 2>/dev/null | grep -c DTEBX_MAINLINE'
# ③ sidecar を GOLD_MASTER の隣へ（pi-gen の deploy/image_<日付>-DTEBX-ADM-RSP-lite.img.verity/ を丸ごと。既存は消してから）
#    例: ssh prov 'sudo rm -rf /srv/rpi-sb-provisioner/images/image_2026-09-27-DTEBX-ADM-RSP-lite.img.verity && sudo cp -r ~/image_2026-09-27-DTEBX-ADM-RSP-lite.img.verity /srv/rpi-sb-provisioner/images/'
```

**レイアウトと 2026-09-27 の失敗（同じ轍を踏まないため）**
- cryptroot = `[ lower | hash 木（下層の直後・manifest の hash_offset）| upper（残り。初回起動で mkfs）]`。位置は sidecar の
  `manifest`（`hash_sector`）が正本で、prov がそれを initramfs の `/etc/dtebx/verity.layout` に同梱し、initramfs はそれを読んで
  probe する。**cryptroot の大きさから逆算しない**——初版は「6GiB−64MiB」と決め打ちしたが、cryptroot は p2 先頭（520MiB）と
  LUKS ヘッダ（16MiB）を引いた 11485185 セクタ（5.47GiB）で、hash 木が外に落ちて本流に入らなかった。
- 下層の書込みに **`dd conv=sparse` を使わない**。ファイル内の全ゼロブロック（ファーム・.so の 0 埋め）が穴になり、
  `img2simg -s` がそこを「書かない（don't care）」にする。dm-crypt 越しでは書かれなかったセクタは**前の暗号文＝ゴミ**として
  読める（実測: `dpkg -V` で両系 35〜43 ファイルが内容不一致、壊れたファイルは機体ごとに違う）。上層領域の穴だけ don't care でよい。

**焼いた後の判定**（docs/43 項 7e 完了条件）: `dmsetup table` に `dtebx_rootro … verity` が在り、その root hash が
sidecar の `root.hash` と一致／`/boot/firmware/ROOTHASH.TXT` が**無い**（機体で hash を作っていない）／
両系で root hash が同じ／下層 1 ブロック改ざんで I/O エラー（REPORT-20260925 §2 の再現）。
⚠ 本流の初回起動が失敗したときの落ち方: 本流検出に失敗すると r2 経路（`resize2fs -M` で下層を触る）に入り
hash が壊れ `veritysetup open` が失敗 → 「plain lower」（verity 無しの overlay）で起動する＝文鎮にはならない。

---

## 4. rpi-sb-provisioner 2.3.5 用（prov2 = `192.168.128.112`・2026-09-29）

§3（2.0.4・prov）とは**別の実行環境**である。prov2 は Debian 13 trixie の Raspberry Pi 5 で、上流 `v2.3.5`（9dcec25）を
自前でビルドした deb を入れている（apt で入るのは非支援の 2.3.4 まで）。計画と経緯の正本はハブの
`~/deforion/docs/assets/20260929_prov2_setup_plan.md`（P1〜P4 と §5「実行の記録」）。

**§3 との関係**
- **2 号機（adm1b・adm2b）は prov（2.0.4・§3）で継続する。1 号機（adm1・adm2）は prov2（2.3.5・§4）で書く**（2026-09-29 責任者裁定 J-6）。
- 2.3.5 用の initramfs は、**§1 の木 `work/extract_initramfs` をそのまま土台にし、写しに overlay とパッチを重ねて作る**。
  元の木そのものは 2.3.5 用に書き換えない。
- ⚠ **元の木に入れた変更は両系に効く。** 2026-09-29 に入れた P4-5b（`pcr_decoy_seed` を `SHA256("dtebx-pcr-decoy-v2:<n>")` の
  固定値に変更。生鍵を使わない）がそれで、prov で §3.8 ② のとおり再パックして再プロビジョニングすれば、2 号機も同じ値になる。
  それまでの 2 号機は、新しい 575-1（hc.pcr）が届いた時点で hc.pcr が WARN になる（移行期間の挙動として責任者了承済み）。
- pi-gen の `firstboot-partition-setup.sh`（P4-5a）も両系で共通の像に入る。`/dev/mapper/cryptlvm` が開いていれば（2.3.5 の
  initramfs）LVM から後だけ行い、開いていなければ（2.0.4 の initramfs）従来どおり全部行う。
  ⚠ **2.3.5 の initramfs を、P4-5a より前の firstboot の像と組んではいけない**（`parted rm 3` が使用中で失敗し、起動のたびに止まる）。

### 4.1 `/usr/bin` へのパッチと `kernel_modules.list`（prov2 で実行）

2.3.5 は §3.2・§3.3・§3.7 のパッチの目印が合わない（当てると `exit 1` で何も書かずに止まる）。代わりに次を使う。

| 物 | 何を変えるか | 置き先 |
|---|---|---|
| `patches-2.3.5/p4-1_fastboot_transport_usb.py`（目印 `DTEBX_FASTBOOT_TRANSPORT_V235`） | §3.3 の後継。`setup_fastboot_and_id_vars` で、制御（`FASTBOOT_DEVICE_SPECIFIER`）に加え **`flash`（`FASTBOOT_TCP_FLASH_SPECIFIER`）も USB シリアルに固定**する。2.3.5 は分割モードで `flash` だけを `tcp:` へ送るため | `/usr/bin/rpi-sb-common.sh` |
| `patches-2.3.5/p4-3_verity_reproducible.py`（目印 `DTEBX_P43_V235`） | §3.8 の root.hash・verity.layout の同梱、§3.10 の boot.img を毎回同じにする処理、§3.8 の固定の下層を書く処理を 2.3.5 の当て先に当て直す（当社の塊は `host-support/rpi-sb-provisioner.sh` から機械的に切り出したもの） | `/usr/bin/rpi-sb-provisioner.sh` |
| `patches-2.3.5/kernel_modules.list` | §3.2・§3.7 の後継。上流の一覧に `btrfs`・`blake2b_generic`（btrfs の softdep。`rpi-modcopy` は softdep を追わない）・`dm-verity`・`overlay` を足したもの。スクリプトのパッチは不要 | `/etc/rpi-sb-provisioner/kernel_modules.list` |

```bash
# 開発機から（sudo は prov2 で要る。どのパッチも冪等＝当て済みなら "already patched"）
scp patches-2.3.5/p4-1_fastboot_transport_usb.py patches-2.3.5/p4-3_verity_reproducible.py patches-2.3.5/kernel_modules.list prov2:dfx-patches/
ssh prov2 'set -e; D=$(date +%Y%m%d%H%M%S)
sudo cp -a /usr/bin/rpi-sb-common.sh /usr/bin/rpi-sb-common.sh.bak.p41.$D
sudo cp -a /usr/bin/rpi-sb-provisioner.sh /usr/bin/rpi-sb-provisioner.sh.bak.p43.$D
sudo python3 ~/dfx-patches/p4-1_fastboot_transport_usb.py /usr/bin/rpi-sb-common.sh
sudo python3 ~/dfx-patches/p4-3_verity_reproducible.py /usr/bin/rpi-sb-provisioner.sh
sh -n /usr/bin/rpi-sb-common.sh && bash -n /usr/bin/rpi-sb-common.sh && sh -n /usr/bin/rpi-sb-provisioner.sh && bash -n /usr/bin/rpi-sb-provisioner.sh
sudo install -m 644 -o root -g root ~/dfx-patches/kernel_modules.list /etc/rpi-sb-provisioner/kernel_modules.list'
```

`/etc/rpi-sb-provisioner/config` の `RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT=usb` は P4-1 が読む当社の変数。**行末にコメントを書かない**
（2.3.5 の UI は `=` の後ろを全部値として読む＝`provisioner-service/src/utils.cpp:1296-1305`）。
⚠ **UI の Options で保存すると、config は UI が書き直す**（2026-09-29 に確認）: 変数は名前の順に並べ替えられ、空の値は `''` になり、既定値のファイルにある変数が足され、**コメントの行は消える**。当社の変数 `RPI_SB_PROVISIONER_FASTBOOT_TRANSPORT` は残る。`RPI_DEVICE_FIRMWARE_FILE` は UI の選択肢と同じ `/usr/lib/firmware/raspberrypi/bootloader-2712/default/pieeprom-2026-09-25.bin` の書き方にする（`/lib/…` と書くと同じファイルでも UI では未選択に見える。trixie の `/lib` は `usr/lib` への symlink）。UI で保存した後は、この変数と `RPI_DEVICE_BOOT_ORDER_MATCH_STORAGE=0` が残っていることを確かめる。

### 4.2 initramfs へのパッチ（`patches-2.3.5/p4-*_initramfs*.py`）

`build-initramfs-2.3.5.sh` が**名前の順**に当てる。順序に依存がある（後のパッチは前のパッチの目印・関数が無いと、何も書かずに止まる）。

| パッチ（目印） | 何を変えるか | 依存 |
|---|---|---|
| `p4-4_initramfs_hmac.py`（`DTEBX_P44_HMAC_V235`） | p2 の解錠を `hex(firmware HMAC(key-id 1, block-device-id))` に、p3 の鍵を `firmware HMAC(key-id 1, "dtebx-p3-luks-v1")`（32B）に変える。使う前に CID（16 進 32 桁）と合言葉（16 進 64 桁）を確かめ、失敗の原因を `FATAL(p2-pass): CID unavailable`／`firmware HMAC unavailable` に分けて出す。p3 の鍵は終了コード＋32 バイトで確かめる（`dtebx_p3_key_ok`）。生鍵への戻りは無い | なし（最初に当てる） |
| `p4-5a_initramfs_p3.py`（`DTEBX_P45A_P3_V235`） | p3 を 1MiB 境界（`TARGET_P2_SIZE + 2048`）で作り、初回起動（目印 `/etc/cryptsetup-keys/.p3_initialized` が無い）だけ p3 を HMAC の鍵で**無条件に** `luksFormat` して `cryptlvm` として開いたまま switch_root する（firstboot は LVM から後だけ行う）。⚠ 2026-09-29 の修正: 当初は「p3 がまだ LUKS でないときだけ」作っていたため、`fastboot erase`（discard は中身を 0 にしない）で残った前の p3 のヘッダを見て作り直しを飛ばし、前の p3 を開いてしまった | P4-4（`dtebx_p3_key_ok`） |
| `p4-5c_initramfs_resize.py`（`DTEBX_P45C_RESIZE_V235`） | 初回の `cryptsetup resize cryptroot` を HMAC の合言葉で行い、合言葉の確認と resize の結果を見て、失敗なら `FATAL(resize)` で再起動する | P4-4（`dtebx_p2_pass_check`） |
| `p4-7_initramfs_hmac_lock.py`（`DTEBX_P47_HMAC_LOCK_V235`） | `systemctl switch-root` の直前に `rpi-fw-crypto set-key-status 1 READ_LOCKED HMAC_LOCKED`。成否は終了コードでなく `get-key-status` の読み直し（bit8＋bit11＝`0x900`）で決める。5 回・1 秒おきにやり直し、閉じられなければ switch_root せず `FATAL(hmac-lock)` → 再起動（案 B）。失敗は `/mnt/var/log/dtebx-hmac-lock-failed.log` にも残す | P4-4（`rpi-fw-crypto` が initramfs に在ること） |

⚠ この initramfs は `set -x` で動き、出力はシリアルに出る。**合言葉・鍵は変数に入れずパイプだけで渡す**（パッチはすべてこの作法）。

### 4.3 initramfs の組み立て（`build-initramfs-2.3.5.sh`）

```bash
# 開発機から材料を送る（元の木 83MB を含む）
tar -cf - work/extract_initramfs work-2.3.5 patches-2.3.5 build-initramfs-2.3.5.sh | ssh prov2 'rm -rf ~/dfx-build && mkdir -p ~/dfx-build && tar -C ~/dfx-build -xf -'
# prov2 で組み立てる（引数: <材料のディレクトリ> <出力ファイル>。出力ファイルと作業用の一時ディレクトリ以外は書かない）
ssh prov2 'cd ~/dfx-build && sudo sh build-initramfs-2.3.5.sh ~/dfx-build ~/dfx-build/cryptroot_initramfs.v235'
```

- 期待する出力: `patched: …/usr/bin/init_cryptroot.sh` が **4 行**、`built: …`、大きさ（2026-09-29 は 24.2MB）、sha256。
- 所要時間: zstd `-19` の圧縮が大半で、1〜2 分の見込み。
- 組み立て後の確認（2026-09-29 に行ったもの）: 展開して `init_cryptroot.sh` が開発機で同じ 4 本を当てた写しと一致／目印 4 種と
  `dtebx-pcr-decoy-v2:` がある／`cryptkey-fetch`・`rpi-otp-private-key` の呼び出しが 0 件／initramfs の busybox で `sh -n` が通る／
  overlay の 10 ファイルが `work-2.3.5/MANIFEST` の sha256 と一致（`cd <展開先> && sha256sum -c`）。

**持ち込む 10 ファイル（`work-2.3.5/overlay`。由来と sha256 は `work-2.3.5/MANIFEST`）**

| 物 | 出どころ | 理由 |
|---|---|---|
| `usr/bin/rpi-fw-crypto`・`usr/lib/aarch64-linux-gnu/librpifwcrypto.so.0` | **trixie** 版 `rpifwcrypto_20260626-1`・`librpifwcrypto0_20260626-1`（archive.raspberrypi.com） | bookworm には 20251002 版までしか無く、`HMAC_LOCKED` を指定できない。要求は `GLIBC_2.34` まで・gnutls は `GNUTLS_3_4` だけ（`objdump -T`）で、元の木の libc 2.36 で動く |
| `usr/bin/block-device-id` | **trixie** 版 `block-device-id_0.1.1` | bookworm には無い。要求は `GLIBC_2.34` まで |
| `libgnutls.so.30` と依存 `libidn2.so.0`・`libunistring.so.2`・`libtasn1.so.6`・`libnettle.so.8`・`libhogweed.so.6`・`libgmp.so.10`（実体 7 個＋soname の symlink） | **GOLD_MASTER の像**（bookworm。`libgnutls30 3.7.9-2+deb12u7` ほか） | trixie の gnutls を持ち込むと glibc 2.36 より新しい物を要求する依存が混ざりうるので、bookworm の物を使う。`libp11-kit`・`libffi`・`libgcc_s`・libc は元の木に既にある |

- ライブラリは `ld.so.cache` 無しで既定の検索先（`/usr/lib/aarch64-linux-gnu`）から見つかる（prov2 の chroot で `ld-linux-aarch64.so.1 --list` により確認）。
- 大きさ: 2.0.4 用より +3.1MB。boot.img の上限は 180MB（Raspberry Pi 公式 `config_txt/boot.adoc:144`）。

### 4.4 配置

```bash
ssh prov2 'sudo install -m 644 -o root -g root ~/dfx-build/cryptroot_initramfs.v235 /etc/rpi-sb-provisioner/cryptroot_initramfs && sha256sum ~/dfx-build/cryptroot_initramfs.v235 /etc/rpi-sb-provisioner/cryptroot_initramfs'
```

- **置き場は `/etc/rpi-sb-provisioner/cryptroot_initramfs`。** 2.3.5 は `/etc` にあればそちらを使う（`get_cryptroot`＝`rpi-sb-provisioner.sh:175-181`）。
- パッケージの持ち物 `/var/lib/rpi-sb-provisioner/cryptroot_initramfs` は上流の原本のまま触らない（退避も不要）。
- **戻すときは `/etc/rpi-sb-provisioner/cryptroot_initramfs` を消すだけ**でよい（上流の initramfs に戻る）。

### 4.5 反映確認（`dpkg -V` の期待値）

| 見るもの | 期待 |
|---|---|
| `sudo dpkg -V rpi-sb-provisioner` | **`/usr/bin/rpi-sb-common.sh`（P4-1）と `/usr/bin/rpi-sb-provisioner.sh`（P4-3）の 2 ファイルだけ**が改変ありとして出る。`/etc` に置いた initramfs・`kernel_modules.list`・config はパッケージの持ち物ではないので出ない |
| `apt-mark showhold` | `rpi-sb-provisioner` |
| `grep -c DTEBX_FASTBOOT_TRANSPORT_V235 /usr/bin/rpi-sb-common.sh`・`grep -c DTEBX_P43_V235 /usr/bin/rpi-sb-provisioner.sh` | どちらも 1 以上 |
| 書き込み時の `provisioner.log` | `Fastboot transport forced to USB for device <serial> (control and flash)` が出て、`tcp:` が出ない |
| 書き込み後の機体 | `sudo vcmailbox 0x00030090 4 4 1` の値が `0x900` を含む（bit8 READ_LOCKED＋bit11 HMAC_LOCKED。firmware が立てる他の bit で値は変わりうる。1 号機の ADM の OS に `rpi-fw-crypto` は無い） |

### 4.6 hold と、上流を上げるとき

- 2.3.5 は **`apt-mark hold` 済み**。apt の候補は 2.3.4（上流 SECURITY.md で非支援）なので、**`apt install rpi-sb-provisioner` を打たない**。
- 上流を上げるときの手順:
  1. 新しいタグの SECURITY.md で支援対象であることを確かめる。
  2. 上流のソースから deb を組む（計画 P2 と同じ: `git archive` → `mk-build-deps` → `dpkg-buildpackage -b -uc -us`。ビルド中は GitHub へ出られること）。
  3. `sudo apt-mark unhold rpi-sb-provisioner` → 新しい deb を `apt-get install` → **すぐに** `sudo apt-mark hold rpi-sb-provisioner`。
  4. §4.1 のパッチを当て直す。目印が合わなければ `exit 1` で何も書かずに止まるので、そのときは新しい版に合わせてパッチを書き直す。
  5. `/etc/rpi-sb-provisioner/kernel_modules.list` を、新しい上流の `/var/lib/rpi-sb-provisioner/kernel_modules.list` と見比べ、上流で増えた行を取り込む（`/etc` の方が優先されるので、放っておくと上流の変更が効かない）。
  6. `/etc` の initramfs は上流を上げても置き換わらない。上流の initramfs の変更（systemd initrd の流れ等）は取り込まれないので、必要なら §4.2・§4.3 をやり直す。
  7. §4.5 を確かめる。
- ⚠ install した時点で udev の規則が有効になり、機体を USB につなぐと書き込みが自動で始まる。2026-09-29 時点では書き込み系の unit 6 つ（`rpi-sb-{bootstrap,triage,provisioner}@`・`rpi-{fde,naked,idp}-provisioner@`）を `systemctl mask` している（計画 R-2）。**上げ直した後も、試験の準備が整うまで同じく mask する。**
