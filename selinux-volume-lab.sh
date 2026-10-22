#!/usr/bin/env bash
# SELinux volume labels: container bind mounts and mount-time labels.
# Needs SELinux enforcing, podman (or docker), sudo, mkfs.ext4, losetup.
# Some steps fail on purpose (2, 13, 14, 15).

set -u

LOG="$HOME/selinux-lab-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOG") 2>&1

if command -v podman >/dev/null; then CT=podman; else CT=docker; fi
IMAGE="docker.io/library/alpine:latest"
DATA="$HOME/selinux-lab-data"
LABDIR="/var/tmp/selinux-lab"
IMG="$LABDIR/vol.img"
A="/mnt/selinux-lab-a"
B="/mnt/selinux-lab-b"
CTX_A='system_u:object_r:container_file_t:s0:c10,c20'
CTX_B='system_u:object_r:container_file_t:s0:c30,c40'
LOOP=""

step() { printf '\n## %s\n' "$*"; }

run() {
  local out="" a
  for a in "$@"; do
    if [[ "$a" =~ [[:space:]\|\;\&\$\(\)\<\>] ]]; then out+=" '$a'"; else out+=" $a"; fi
  done
  printf '\n$%s\n' "$out"
  "$@"
  local rc=$?
  [ "$rc" -ne 0 ] && printf '# exit status %d\n' "$rc"
  return 0
}

cleanup() {
  sudo umount "$B" 2>/dev/null
  sudo umount "$A" 2>/dev/null
  [ -n "$LOOP" ] && sudo losetup -d "$LOOP" 2>/dev/null
  sudo rm -f "$IMG"
  sudo rmdir "$LABDIR" "$A" "$B" 2>/dev/null
  rm -rf "$DATA"
  printf '\nlog: %s\n' "$LOG"
}
trap cleanup EXIT

step "system"
run grep PRETTY_NAME /etc/os-release
run uname -r
run "$CT" --version
run getenforce
[ "$(getenforce)" = "Enforcing" ] || { echo "SELinux is not enforcing, stopping."; exit 1; }

step "1. directory with mode 777"
rm -rf "$DATA"; mkdir "$DATA"
run chmod 777 "$DATA"
run ls -ldZ "$DATA"
run "$CT" pull -q "$IMAGE"

step "2. write from a container, no label option"
run "$CT" run --rm -v "$DATA":/data "$IMAGE" touch /data/hello

step "3. the denial"
if command -v ausearch >/dev/null && systemctl is-active -q auditd; then
  run sudo ausearch -m avc -ts recent
  step "4. audit2why"
  run sudo sh -c 'ausearch -m avc -ts recent --raw | audit2why'
else
  run sudo sh -c 'dmesg | grep "avc:  denied" | tail -n 5'
  step "4. audit2why"
  run sudo audit2why -d
fi

step "5. private label with :Z"
run "$CT" run --rm -v "$DATA":/data:Z "$IMAGE" sh -c 'echo "process label: $(cat /proc/self/attr/current)"; touch /data/hello && echo "write ok"'
run ls -lZ "$DATA"

step "6. second container with :Z, new categories"
run "$CT" run --rm -v "$DATA":/data:Z "$IMAGE" sh -c 'echo "process label: $(cat /proc/self/attr/current)"'
run ls -ldZ "$DATA"

step "7. shared label with :z"
run "$CT" run --rm -v "$DATA":/data:z "$IMAGE" touch /data/hello2
run ls -ldZ "$DATA"

step "8. restore the default label"
run restorecon -RFv "$DATA"
run ls -ldZ "$DATA"

step "9. ext4 image on a loop device"
sudo mkdir -p "$LABDIR" "$A" "$B"
run sudo truncate -s 400M "$IMG"
run sudo mkfs.ext4 -q -F -N 150000 "$IMG"
LOOP=$(sudo losetup -f --show "$IMG")
echo "loop device: $LOOP"

step "10. mount without context= and create 100000 files"
run sudo mount "$LOOP" "$A"
run findmnt -no SOURCE,TARGET,OPTIONS "$A"
run sudo mkdir "$A/data"
run sudo sh -c "cd $A/data && seq 1 100000 | xargs touch"
run sudo ls -Z "$A/data/1"

step "11. recursive relabel (what :Z does)"
time run sudo chcon -R "$CTX_A" "$A/data"
run sudo ls -Z "$A/data/1"
run sudo umount "$A"

step "12. mount with context="
time run sudo mount -o "context=\"$CTX_A\"" "$LOOP" "$A"
run findmnt -no SOURCE,TARGET,OPTIONS "$A"
run sudo ls -Z "$A/data/1"

step "13. chcon on a context= mount"
run sudo chcon -t user_home_t "$A/data/1"

step "14. second mount, different context="
run sudo mount -o "context=\"$CTX_B\"" "$LOOP" "$B"
run sudo sh -c 'dmesg | grep -i "SELinux: mount invalid" | tail -n 1'

step "15. first mount without context=, second with context="
run sudo umount "$A"
run sudo mount "$LOOP" "$A"
run sudo mount -o "context=\"$CTX_B\"" "$LOOP" "$B"
run sudo sh -c 'dmesg | grep -i "SELinux: mount invalid" | tail -n 1'

step "16. second mount, same context="
run sudo umount "$A"
run sudo mount -o "context=\"$CTX_A\"" "$LOOP" "$A"
run sudo mount -o "context=\"$CTX_A\"" "$LOOP" "$B"
run sudo ls -Zd "$A/data" "$B/data"
