#!/usr/bin/env bash
# Integration test: serve a tmp dir, mount on loopback, torture, diff trees.
set -u

BIN="$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/simplefs"
WORK="$(mktemp -d /tmp/simplefs-it.XXXXXX)"
EXPORT="$WORK/export"
MNT="$WORK/mnt"
PORT=$((20000 + RANDOM % 20000))
FAILURES=0

mkdir -p "$EXPORT" "$MNT"

cleanup() {
    fusermount3 -u -z -q "$MNT" 2>/dev/null
    [[ -n "${MOUNT_PID:-}" ]] && kill "$MOUNT_PID" 2>/dev/null
    [[ -n "${SERVE_PID:-}" ]] && kill "$SERVE_PID" 2>/dev/null
    wait 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }
ok() { echo "  ok: $*"; }

check() {
    local desc="$1"; shift
    if "$@" > /dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

echo "== setup"
"$BIN" serve "$EXPORT" --listen "127.0.0.1:$PORT" > "$WORK/serve.log" 2>&1 &
SERVE_PID=$!
sleep 0.3
"$BIN" mount "127.0.0.1:$PORT" "$MNT" > "$WORK/mount.log" 2>&1 &
MOUNT_PID=$!
for _ in $(seq 50); do
    mountpoint -q "$MNT" && break
    sleep 0.1
done
mountpoint -q "$MNT" || { echo "FATAL: mount did not appear"; exit 1; }
ok "mounted"

echo "== basic ops"
echo "hello" > "$EXPORT/pre.txt"
check "read pre-existing file" grep -q hello "$MNT/pre.txt"
check "create file" bash -c "echo created > '$MNT/created.txt'"
check "file landed in export" grep -q created "$EXPORT/created.txt"
check "mkdir" mkdir "$MNT/dir1"
check "nested mkdir" mkdir -p "$MNT/dir1/a/b/c"
check "rename" mv "$MNT/created.txt" "$MNT/dir1/renamed.txt"
check "symlink" ln -s dir1/renamed.txt "$MNT/lnk"
check "read through symlink" grep -q created "$MNT/lnk"
check "truncate" truncate -s 2 "$MNT/dir1/renamed.txt"
check "chmod" chmod 600 "$MNT/dir1/renamed.txt"
[[ "$(stat -c %a "$MNT/dir1/renamed.txt")" == "600" ]] && ok "mode persisted" || fail "mode persisted"
check "touch timestamps" touch -d "2020-01-02 03:04:05" "$MNT/pre.txt"
[[ "$(stat -c %Y "$EXPORT/pre.txt")" == "$(date -d '2020-01-02 03:04:05' +%s)" ]] && ok "mtime persisted" || fail "mtime persisted"
check "rm" rm "$MNT/lnk"
check "rmdir" rmdir "$MNT/dir1/a/b/c"
check "server-side change visible" bash -c "echo srv > '$EXPORT/srv.txt' && grep -q srv '$MNT/srv.txt'"
check "server-side delete visible" bash -c "rm '$EXPORT/srv.txt' && ! test -e '$MNT/srv.txt'"

echo "== data integrity"
dd if=/dev/urandom of="$WORK/rand.bin" bs=1M count=8 2>/dev/null
cp "$WORK/rand.bin" "$MNT/rand.bin"
cmp -s "$WORK/rand.bin" "$EXPORT/rand.bin" && ok "8MB write intact" || fail "8MB write intact"
cmp -s "$WORK/rand.bin" "$MNT/rand.bin" && ok "8MB readback intact" || fail "8MB readback intact"
dd if=/dev/urandom of="$MNT/odd.bin" bs=97 count=1000 2>/dev/null
cmp -s "$MNT/odd.bin" "$EXPORT/odd.bin" && ok "odd-sized writes intact" || fail "odd-sized writes intact"

echo "== tree copy + diff"
cp -r "$(dirname "$0")/../src" "$MNT/srccopy"
diff -r "$(dirname "$0")/../src" "$MNT/srccopy" > /dev/null && ok "cp -r + diff -r (mount)" || fail "cp -r + diff"
diff -r "$(dirname "$0")/../src" "$EXPORT/srccopy" > /dev/null && ok "cp -r + diff -r (export)" || fail "cp -r + diff export"

echo "== torture: concurrent writers both sides"
(
    for i in $(seq 50); do echo "mount-$i" >> "$MNT/torture-mnt.log"; done
) &
W1=$!
(
    for i in $(seq 50); do echo "export-$i" >> "$EXPORT/torture-exp.log"; done
) &
W2=$!
(
    mkdir -p "$MNT/storm"
    echo x > "$MNT/storm/f"
    for i in $(seq 100); do
        mv "$MNT/storm/f" "$MNT/storm/g" 2>/dev/null
        mv "$MNT/storm/g" "$MNT/storm/f" 2>/dev/null
    done
) &
W3=$!
wait $W1 $W2 $W3
[[ "$(wc -l < "$EXPORT/torture-mnt.log")" == "50" ]] && ok "50 appends via mount" || fail "50 appends via mount"
[[ "$(wc -l < "$MNT/torture-exp.log")" == "50" ]] && ok "50 appends via export" || fail "50 appends via export"
[[ -e "$MNT/storm/f" && "$(cat "$MNT/storm/f")" == "x" ]] && ok "rename storm survived" || fail "rename storm survived"

echo "== full tree diff"
diff -r "$MNT" "$EXPORT" > /dev/null && ok "mount == export" || fail "final tree diff"

echo "== unmount"
kill -INT "$MOUNT_PID"
for _ in $(seq 30); do
    mountpoint -q "$MNT" || break
    sleep 0.1
done
mountpoint -q "$MNT" && fail "clean unmount" || ok "clean unmount"

echo
if [[ "$FAILURES" -eq 0 ]]; then
    echo "ALL TESTS PASSED"
else
    echo "$FAILURES FAILURE(S)"
    exit 1
fi
