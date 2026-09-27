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
  && bash -n /tmp/rpi-sb-provisioner.sh.new && sudo install -m 755 -o root -g root /tmp/rpi-sb-provisioner.sh.new /usr/bin/rpi-sb-provisioner.sh'
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
