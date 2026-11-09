#!/bin/bash
# Signed-approval verifier v2 (chg-2026-11-09-003, tsk-2026-11-08-901): several pinned keys, UV per key, and the inbox
# read once into a root-only snapshot (closes a rename race that v1 had). Argus review 2026-11-09 applied.
#
# RUN ONLY FROM A ROOT-ONLY COPY (the repo is writable by uid 501, i.e. by every agent). On vdhmini01:
#   sudo install -d -m 0700 -o root -g wheel /var/root/av2
#   sudo install -m 0600 -o root -g wheel hack/atlas-approval/atlas-approval-verify.py hack/atlas-approval/INSTALL-v2-for-sander.sh /var/root/av2/
#   sudo shasum -a 256 /var/root/av2/*        # compare BOTH with the hashes in the message you got (not with this file)
#   sudo bash /var/root/av2/INSTALL-v2-for-sander.sh install <verifier-sha256-from-the-message>
# Later, one YubiKey at a time (the line `approve --init` printed on the Galaxy Book; you type its fingerprint as shown there):
#   sudo bash /var/root/av2/INSTALL-v2-for-sander.sh add-key '<allowed_signers line>'
# Back to v1:
#   sudo bash /var/root/av2/INSTALL-v2-for-sander.sh rollback
#
# install: checks the staged verifier against the hash you typed, shows the Secure Enclave key's fingerprint and asks
# you to type it in full (it becomes the only UV-exempt key), keeps v1, installs v2, restarts the daemon, then checks the
# installed hash and a fresh `start` line in verify.log; if either is wrong it puts v1 back by itself.
# add-key: refuses control characters and anything but `sander namespaces="atlas-approval"[,valid-before="YYYYMMDD"]
# sk-ssh-ed25519@openssh.com <key> [comment]`, requires the key's application to be ssh:atlas-approval, asks for the full
# fingerprint, appends a line REBUILT from the parsed fields and checks the file grew by exactly one line.
# Atlas cannot do any of this: only root writes /usr/local/etc/atlas-approval, and root is you with sudo.
set -euo pipefail
umask 077
[ "$(id -u)" -eq 0 ] || { echo "run with sudo"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd -P)"
[ "$(stat -f '%u %Lp' "$HERE")" = "0 700" ] || { echo "STOP: run the root-only copy in /var/root/av2 (see the top of this file)"; exit 1; }
PY=/usr/bin/python3
ETC=/usr/local/etc/atlas-approval
BIN=/usr/local/libexec/atlas-approval-verify.py
VLOG=/usr/local/var/atlas-approval/verify.log
LABEL=system/net.vdhict.atlas-approval-verify
V1_SHA=e8daa426bcebc2c0e4d1670ff7996e095034bfbb3f3c8b2e4edf1a03faf265eb
TS=$(date -u +%Y%m%dT%H%M%SZ)
sha() { shasum -a 256 "$1" | cut -c1-64; }

# parse <line> <want-type>: prints "<fingerprint> <rebuilt line>" or fails. Fields by position, principal sander only.
parse() {
  "$PY" -I -c '
import base64, hashlib, re, struct, sys
line, want = sys.argv[1], sys.argv[2]
if any(ord(c) < 32 or ord(c) == 127 for c in line): sys.exit("control character in line")
f = line.split(" ")
if len(f) not in (4, 5) or f[0] != "sander": sys.exit("need: sander <options> <type> <key> [comment]")
if not re.fullmatch(r"namespaces=\"atlas-approval\"(,valid-before=\"[0-9]{8}\")?", f[1]): sys.exit("options must be namespaces=\"atlas-approval\"[,valid-before=\"YYYYMMDD\"]")
if f[2] != want: sys.exit(f"key type must be {want}")
if len(f) == 5 and not re.fullmatch(r"[A-Za-z0-9._@-]{1,64}", f[4]): sys.exit("comment may only use A-Z a-z 0-9 . _ @ -")
blob = base64.b64decode(f[3], validate=True)
def s(b, o):
    (n,) = struct.unpack(">I", b[o:o+4]); return b[o+4:o+4+n], o+4+n
t, o = s(blob, 0)
if t.decode() != want: sys.exit("key blob type differs from the type field")
if want == "sk-ssh-ed25519@openssh.com":
    pub, o = s(blob, o)
    if len(pub) != 32: sys.exit("bad ed25519 key")
else:
    _, o = s(blob, o); pub, o = s(blob, o)
app, o = s(blob, o)
if o != len(blob): sys.exit("trailing bytes in key blob")
if want == "sk-ssh-ed25519@openssh.com" and app != b"ssh:atlas-approval": sys.exit(f"application is {app!r}, must be ssh:atlas-approval")
fp = "SHA256:" + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip("=")
print(fp, " ".join(f))
' "$1" "$2"
}
confirm_fp() { # <fp> <what>
  echo "$2 fingerprint: $1"
  echo "Type that fingerprint IN FULL as shown on $3 (SHA256:...):"
  read -r typed
  [ "$typed" = "$1" ] || { echo "does not match: nothing changed"; exit 1; }
}
postcheck() { # <expected sha> <since-line-count>
  launchctl kickstart -k "$LABEL"
  for i in $(seq 1 20); do
    [ "$(tail -n +$(( $2 + 1 )) "$VLOG" | grep -c 'atlas-approval-verify start')" -ge 1 ] && break; sleep 1
  done
  [ "$(sha "$BIN")" = "$1" ] && [ "$(tail -n +$(( $2 + 1 )) "$VLOG" | grep -c 'atlas-approval-verify start')" -ge 1 ]
}

case "${1:-}" in
  install)
    want=${2:?usage: install <verifier sha256 from the message>}
    [ "$(sha "$HERE/atlas-approval-verify.py")" = "$want" ] || { echo "STOP: staged verifier is not $want"; exit 1; }
    [ "$(sha "$BIN")" = "$V1_SHA" ] || { echo "STOP: installed verifier is not the known v1 ($V1_SHA)"; exit 1; }
    se_line=$(grep -v '^#' "$ETC/allowed_signers" | grep -c . | grep -qx 1 && grep -v '^#' "$ETC/allowed_signers" | grep -m1 .) \
      || { echo "STOP: allowed_signers must hold exactly one key line before v2"; exit 1; }
    read -r se_fp _ <<<"$(parse "$se_line" sk-ecdsa-sha2-nistp256@openssh.com)"
    confirm_fp "$se_fp" "Secure Enclave key (will be the ONLY key allowed without UV)" "your Mac (approve --init or ~/.config output)"
    printf '# fingerprints that may sign without the UV bit (Mac Secure Enclave only); chg-2026-11-09-003 %s\n%s\n' "$TS" "$se_fp" > "$ETC/uv_exempt.new"
    chown root:wheel "$ETC/uv_exempt.new"; chmod 0644 "$ETC/uv_exempt.new"; mv "$ETC/uv_exempt.new" "$ETC/uv_exempt"
    cp -p "$BIN" "$HERE/atlas-approval-verify.py.v1-$TS"
    n=$(wc -l < "$VLOG")
    install -o root -g wheel -m 0755 "$HERE/atlas-approval-verify.py" "$BIN"
    if postcheck "$want" "$n"; then echo "v2 installed and running ($(tail -1 "$VLOG"))"
    else
      echo "POST-CHECK FAILED: putting v1 back"
      install -o root -g wheel -m 0755 "$HERE/atlas-approval-verify.py.v1-$TS" "$BIN"
      n=$(wc -l < "$VLOG"); postcheck "$V1_SHA" "$n" && echo "v1 restored" || echo "v1 restore check failed: tell Atlas"
      exit 1
    fi ;;
  add-key)
    line=${2:?usage: add-key '<allowed_signers line>'}
    out=$(parse "$line" sk-ssh-ed25519@openssh.com) || exit 1
    new_fp=${out%% *}; rebuilt=${out#* }
    while IFS= read -r l; do
      [ -n "$l" ] && [ "${l#\#}" = "$l" ] || continue
      t=$(printf '%s' "$l" | awk '{print $3}')
      have=$(parse "$l" "$t" 2>/dev/null | cut -d' ' -f1) || true
      [ "$have" = "$new_fp" ] && { echo "already pinned: $new_fp"; exit 0; }
    done < "$ETC/allowed_signers"
    confirm_fp "$new_fp" "New YubiKey" "the Galaxy Book (what approve --init printed)"
    before=$(wc -l < "$ETC/allowed_signers")
    cp -p "$ETC/allowed_signers" "$HERE/allowed_signers.bak-$TS"
    printf '%s\n' "$rebuilt" >> "$ETC/allowed_signers"
    chown root:wheel "$ETC/allowed_signers"; chmod 0644 "$ETC/allowed_signers"
    after=$(wc -l < "$ETC/allowed_signers")
    if [ "$after" -ne $(( before + 1 )) ] || [ "$(tail -1 "$ETC/allowed_signers")" != "$rebuilt" ]; then
      cp -p "$HERE/allowed_signers.bak-$TS" "$ETC/allowed_signers"; echo "STOP: file did not grow by exactly one line; restored"; exit 1
    fi
    echo "added $new_fp; backup $HERE/allowed_signers.bak-$TS" ;;
  rollback)
    v1=""
    for c in "$HERE"/atlas-approval-verify.py.v1-*; do [ -f "$c" ] && [ "$(sha "$c")" = "$V1_SHA" ] && v1=$c; done
    [ -n "$v1" ] || { echo "STOP: no copy with the v1 hash $V1_SHA"; exit 1; }
    n=$(wc -l < "$VLOG")
    install -o root -g wheel -m 0755 "$v1" "$BIN"
    postcheck "$V1_SHA" "$n" && echo "v1 restored (uv_exempt is ignored by v1)" || { echo "v1 restore check failed: tell Atlas"; exit 1; } ;;
  *) echo "usage: $0 install <sha256> | add-key '<line>' | rollback"; exit 64 ;;
esac
