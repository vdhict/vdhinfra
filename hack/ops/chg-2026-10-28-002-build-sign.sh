#!/usr/bin/env bash
# chg-2026-10-28-002: build the cursus-gast guest image ONCE on the Mini from one commit of the course repo, gate it,
# and (with --push) push it to forge, sign it by digest with a fresh per-release cosign keypair and verify it.
# No in-pod git or build in cursus-gast: the HelmRelease pins the digest this script prints.
#
#   hack/ops/chg-2026-10-28-002-build-sign.sh <full-40-hex-commit> [--push]
#
# Environment (all optional unless noted; values are never printed):
#   CURSUS_BUILD_KEYDIR   dir with the read-only deploy key: id, kh (known_hosts), url (mode 600 each).
#                         Default: <session scratchpad>/cursus-build
#   CONTAINERFILE         build file name in the course repo (default Dockerfile)
#   EDITION               build arg (default gast)
#   CURSUS_FORGE_OWNER    forge namespace for the push (default cursus-publisher). Refused: palamedes, mypka*, vdhict,
#                         wires-publisher, anything with passkey in it.
#   CURSUS_PUSH_AUTHFILE  REQUIRED with --push: podman/docker auth.json (mode 600, only host forge.bluejungle.net) with
#                         a write:package token of CURSUS_FORGE_OWNER. Minted and revoked OUTSIDE this script.
#   SCRATCH               base for work/trash dirs (default: the session scratchpad)
#   POD_TMPFS             writable tmpfs paths of the local pod-shaped run; must equal the emptyDirs of the
#                         courseware-gast HelmRelease (default "/tmp /var/cache/nginx")
#
# Steps: 1 fetch (git init + fetch --depth 1 of exactly <commit>, rev-parse must equal it, git archive -> clean tree)
#        2 build (podman, linux/amd64, --build-arg EDITION=...)
#        3 inspect + gate (uid, port, web root, no .git/.map/source dirs, /healthz, pod-shaped local run + markers)
#        4 with --push only, and only if every gate in 3 passed: push, read back the digest, ephemeral cosign keypair,
#          sign by digest (no transparency log), cosign verify with the new public key; the public key is written to
#          kubernetes/main/apps/cursus-gast/courseware-gast/cosign.pub; the private key is MOVED to a trash dir.
#        5 write-once evidence ops/evidence/chg-2026-10-28-002/<NN>-build-<UTC>.txt (counts, digests, paths; no content)
#
# Never prints key, token, password or URL values. Never deletes files (AGR-121): leftovers are moved to a trash dir.
# Course content is not read beyond the asserted markers (<html data-edition/data-mode>, count of "Leerling").
set -euo pipefail
umask 077

COMMIT=${1:-}; MODE=${2:-}
case "$COMMIT" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) ;;
  *) echo "usage: $0 <full-40-hex-commit> [--push]" >&2; exit 64;;
esac
[ "${#COMMIT}" = 40 ] || { echo "commit must be the full 40-hex sha (GitHub will not serve a short sha by fetch)" >&2; exit 64; }
case "$MODE" in ""|--push) ;; *) echo "unknown argument (only --push)" >&2; exit 64;; esac
[ $# -le 2 ] || { echo "too many arguments" >&2; exit 64; }

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SCRATCH=${SCRATCH:-/private/tmp/claude-501/-Users-sheijden-Code-homelab-migration-vdhinfra/afcadc58-4205-42d9-9959-d09214284b31/scratchpad}
KEYDIR=${CURSUS_BUILD_KEYDIR:-$SCRATCH/cursus-build}
CONTAINERFILE=${CONTAINERFILE:-Dockerfile}
EDITION=${EDITION:-gast}
OWNER=${CURSUS_FORGE_OWNER:-cursus-publisher}
FORGE=forge.bluejungle.net
SHORT=${COMMIT:0:7}
LOCAL_TAG=localhost/cursus-gast:$EDITION-$SHORT
PUBKEY_REPO=kubernetes/main/apps/cursus-gast/courseware-gast/cosign.pub
EVDIR=$REPO_ROOT/ops/evidence/chg-2026-10-28-002

PODMAN_BIN=$HOME/.local/opt/podman-6.1.3/bin
export CONTAINERS_HELPER_BINARY_DIR=${CONTAINERS_HELPER_BINARY_DIR:-$PODMAN_BIN}
P=$PODMAN_BIN/podman
COSIGN=$HOME/.local/share/mise/installs/cosign/3.1.4/cosign
CRANE=$HOME/.local/share/mise/installs/aqua-google-go-containerregistry/0.22.1/crane
JQ=$(command -v jq || echo "$HOME/.local/share/mise/installs/aqua-jqlang-jq/1.8.1/jq")
for t in "$P" "$COSIGN" "$CRANE" "$JQ"; do [ -x "$t" ] || { echo "missing tool $t" >&2; exit 2; }; done

RUN=$(date -u +%Y%m%dT%H%M%SZ)
WORK=$(mktemp -d "$SCRATCH/cursus-build-$SHORT-$RUN.XXXXXX")
TRASH=$SCRATCH/trash/cursus-build-$SHORT-$RUN
EV=$WORK/evidence.txt; : > "$EV"
ev() { printf '%s\n' "$*" | tee -a "$EV"; }
FAILS=0
check() { # check <name> <PASS|FAIL> <detail>
  [ "$2" = PASS ] || FAILS=$((FAILS + 1))
  ev "check $1: $2 ($3)"
}

STARTED_MACHINE=0; CTR=""; RCTR=""; KWORK=""
finish() {
  rc=$?
  set +e
  [ -n "$RCTR" ] && { "$P" stop -t 2 "$RCTR" >/dev/null 2>&1; "$P" container rm -f "$RCTR" >/dev/null 2>&1; }
  [ -n "$CTR" ] && "$P" container rm -f "$CTR" >/dev/null 2>&1
  if [ -n "$KWORK" ] && [ -d "$KWORK" ]; then
    [ -f "$KWORK/docker/config.json" ] && : > "$KWORK/docker/config.json"
    mkdir -p "$TRASH"; [ -e "$KWORK/cosign.key" ] && mv "$KWORK/cosign.key" "$TRASH/cosign.key.$RUN"
    if grep -rIl 'PRIVATE KEY-----' "$KWORK" >/dev/null 2>&1; then echo "KEY MATERIAL LEFT in the sign dir" >&2; rc=99; fi
  fi
  [ "$STARTED_MACHINE" = 1 ] && { "$P" machine stop >/dev/null 2>&1 && echo "podman machine stopped again (this run started it)"; }
  ev "result: rc=$rc gate_failures=$FAILS mode=${MODE:-build-only} finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # write-once evidence, next free NN
  mkdir -p "$EVDIR"
  n=$(find "$EVDIR" -maxdepth 1 -name '[0-9][0-9]-*' 2>/dev/null | sed 's|.*/||' | cut -c1-2 | sort -n | tail -1)
  nn=$(printf '%02d' $(( 10#${n:-0} + 1 )))
  out=$EVDIR/$nn-build-$RUN.txt
  if ( set -o noclobber; cat "$EV" > "$out" ) 2>/dev/null; then chmod 644 "$out"; echo "evidence: ${out#$REPO_ROOT/}"
  else echo "evidence NOT written ($out exists?)" >&2; rc=98; fi
  mkdir -p "$TRASH"; mv "$WORK" "$TRASH/work" 2>/dev/null
  echo "EXIT $rc"
  exit "$rc"
}
trap finish EXIT

ev "== chg-2026-10-28-002 cursus-gast image build, run $RUN, actor k8s-engineer (Heph) for Atlas"
ev "AGR-109: tests are the gate"
ev "commit $COMMIT edition $EDITION containerfile $CONTAINERFILE mode ${MODE:-build-only}"
ev "tools: podman $("$P" --version | awk '{print $3}'), cosign $("$COSIGN" version 2>&1 | sed -n 's/^GitVersion: *//p'), crane $("$CRANE" version)"

# ---- 1 fetch ---------------------------------------------------------------------------------------------------------
for f in id kh url; do
  [ -s "$KEYDIR/$f" ] || { echo "missing $KEYDIR/$f" >&2; exit 3; }
  [ "$(stat -f %Lp "$KEYDIR/$f")" = 600 ] || { echo "$f is not mode 600; refusing" >&2; exit 3; }
done
URL=$(head -1 "$KEYDIR/url" | tr -d '\n')
URL_RE=$(printf '%s' "$URL" | sed 's/[][\.*^$|/]/\\&/g')
redact() { sed -e "s|$URL_RE|<url>|g"; }
export GIT_TERMINAL_PROMPT=0 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export GIT_SSH_COMMAND="ssh -F /dev/null -i $KEYDIR/id -o IdentitiesOnly=yes -o UserKnownHostsFile=$KEYDIR/kh -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=20"
G="git -c init.defaultBranch=x -c advice.detachedHead=false -C $WORK/git"
mkdir "$WORK/git" "$WORK/src"
$G init -q
$G remote add origin "$URL"
if ! $G fetch --quiet --depth 1 --no-tags origin "$COMMIT" 2> "$WORK/fetch.err"; then
  redact < "$WORK/fetch.err" | tail -3 >&2; ev "fetch: FAILED (commit not reachable on the remote)"; exit 4
fi
HEAD=$($G rev-parse --verify 'FETCH_HEAD^{commit}')
[ "$HEAD" = "$COMMIT" ] || { ev "fetch: rev-parse $HEAD != $COMMIT; refusing"; exit 4; }
# umask 022 for the build context: COPY keeps file modes, and a 0600 tree is unreadable for the non-root uid
( umask 022; $G archive "$HEAD" | tar -x -C "$WORK/src" )
unset URL
ev "fetch: depth 1, rev-parse == $COMMIT, clean tree via git archive (no .git in the build context)"
[ -f "$WORK/src/$CONTAINERFILE" ] || { ev "build file $CONTAINERFILE: ABSENT at this commit"; exit 5; }
ev "build file $CONTAINERFILE sha256 $(shasum -a 256 "$WORK/src/$CONTAINERFILE" | cut -c1-64)"
grep -E '^[[:space:]]*FROM[[:space:]]' "$WORK/src/$CONTAINERFILE" | sed 's/^[[:space:]]*/base: /' | tee -a "$EV"
if grep -qE '^[[:space:]]*ARG[[:space:]]+EDITION' "$WORK/src/$CONTAINERFILE"; then ev "build file declares ARG EDITION: yes"
else ev "build file declares ARG EDITION: NO (the --build-arg is ignored at this commit)"; fi
ev "build context: $(find "$WORK/src" -type f | wc -l | tr -d ' ') files; .dockerignore $( [ -f "$WORK/src/.dockerignore" ] && echo present || echo absent)"

# ---- 2 build ---------------------------------------------------------------------------------------------------------
if [ "$("$P" machine inspect --format '{{.State}}' 2>/dev/null | head -1)" != running ]; then
  "$P" machine start >/dev/null 2>&1 || { echo "podman machine start failed" >&2; exit 6; }
  STARTED_MACHINE=1; ev "podman machine: started by this run (stopped again at exit)"
else ev "podman machine: already running (left running)"; fi
B0=$(date -u +%s)
if ! "$P" build --platform linux/amd64 --pull=newer --build-arg "EDITION=$EDITION" \
     --label "org.opencontainers.image.revision=$COMMIT" --label "net.vdhict.chg=chg-2026-10-28-002" \
     -t "$LOCAL_TAG" -f "$WORK/src/$CONTAINERFILE" "$WORK/src" > "$WORK/build.log" 2>&1; then
  grep -E 'STEP [0-9]|Error|error' "$WORK/build.log" | tail -5 | redact >&2; ev "build: FAILED"; exit 7
fi
ev "build: OK in $(( $(date -u +%s) - B0 ))s, $(grep -cE 'STEP [0-9]+/[0-9]+' "$WORK/build.log" || true) steps, $(grep -cE '^--> Using cache' "$WORK/build.log" || true) cached"
IMGID=$("$P" image inspect "$LOCAL_TAG" --format '{{.Id}}')
"$P" image inspect "$LOCAL_TAG" --format '{{.Architecture}}|{{.Os}}|{{.Config.User}}|{{json .Config.ExposedPorts}}|{{json .Config.Entrypoint}}|{{json .Config.Cmd}}|{{.Size}}' > "$WORK/inspect.txt"
IFS='|' read -r ARCH OS CUSER PORTS EP CMD SIZE < "$WORK/inspect.txt"
ev "image: $LOCAL_TAG id sha256:$IMGID arch $ARCH/$OS size $SIZE bytes"
ev "config: user '$CUSER' ports $PORTS entrypoint $EP cmd $CMD"
[ "$ARCH" = amd64 ] && check arch PASS amd64 || check arch FAIL "$ARCH"

# ---- 3 inspect -------------------------------------------------------------------------------------------------------
CTR=$("$P" create --platform linux/amd64 "$LOCAL_TAG")
"$P" export "$CTR" > "$WORK/fs.tar"
"$P" container rm -f "$CTR" >/dev/null; CTR=""
tar -tf "$WORK/fs.tar" | sed 's|^\./||' > "$WORK/files.txt"
xo() { tar -xOf "$WORK/fs.tar" "$@" 2>/dev/null; }

# uid: numeric Config.User, else resolve the name in /etc/passwd of the image
U=${CUSER%%:*}; GRP=""
case "$CUSER" in *:*) GRP=${CUSER#*:};; esac
if [ -z "$U" ]; then UID_N=0
elif [ "$U" -eq "$U" ] 2>/dev/null; then UID_N=$U
else UID_N=$(xo etc/passwd | awk -F: -v u="$U" '$1==u{print $3}'); fi
if [ -z "$GRP" ]; then GID_N=$(xo etc/passwd | awk -F: -v u="$UID_N" '$3==u{print $4; exit}')
elif [ "$GRP" -eq "$GRP" ] 2>/dev/null; then GID_N=$GRP
else GID_N=$(xo etc/group | awk -F: -v g="$GRP" '$1==g{print $3}'); fi
ev "uid $UID_N gid ${GID_N:-?} (Config.User '$CUSER' $( [ "$U" -eq "$U" ] 2>/dev/null && echo numeric || echo 'by NAME: the pod must set runAsUser') )"
[ -n "$UID_N" ] && [ "$UID_N" != 0 ] && check non_root_uid PASS "uid $UID_N" || check non_root_uid FAIL "uid '${UID_N}'"
PORT=$(printf '%s' "$PORTS" | "$JQ" -r 'keys[0] // empty' 2>/dev/null | cut -d/ -f1)
[ "$PORT" = 8080 ] && check exposed_port PASS 8080 || check exposed_port FAIL "'$PORT'"

# nginx config: root, listen, health locations, pid and temp paths
grep -E '^etc/nginx/.*\.conf$' "$WORK/files.txt" > "$WORK/nginx-files.txt" || true
ev "nginx conf files: $(tr '\n' ' ' < "$WORK/nginx-files.txt")"
: > "$WORK/nginx-lines.txt"
while read -r f; do
  xo "$f" | grep -nE '^[^#]*\b(listen|root|location|pid|_temp_path|return)\b' | sed "s|^|$f:|" >> "$WORK/nginx-lines.txt" || true
done < "$WORK/nginx-files.txt"
sed 's/^/nginx: /' "$WORK/nginx-lines.txt" | tee -a "$EV"
HZ=$(grep -cE 'location[^{]*/healthz' "$WORK/nginx-lines.txt" || true)
ev "nginx /healthz location: $( [ "$HZ" -gt 0 ] && echo "present ($HZ)" || echo 'ABSENT (probe / instead)')"
ROOT=$(grep -E '\broot\b' "$WORK/nginx-lines.txt" | sed -E 's/.*root[[:space:]]+([^;]+);.*/\1/' | sort -u | head -1)
ev "nginx root: ${ROOT:-<none>}"
grep -E '(^|/)index\.html$' "$WORK/files.txt" > "$WORK/index.txt" || true
ev "index.html in image: $(wc -l < "$WORK/index.txt" | tr -d ' ') ($(sed 's|/index.html$||' "$WORK/index.txt" | sed 's|^|/|' | tr '\n' ' '))"
WEBROOT=${ROOT:-/usr/share/nginx/html}; WR=${WEBROOT#/}
grep -qx "$WR/index.html" "$WORK/index.txt" && check web_root_index PASS "/$WR/index.html" || check web_root_index FAIL "no index.html under $WEBROOT"
WRN=$(grep -c "^$WR/" "$WORK/files.txt" || true)
ev "web root $WEBROOT: $WRN entries"
# every regular file under the web root and /etc/nginx must be world-readable (the pod runs as a non-root uid)
c_unread=$(tar -tvf "$WORK/fs.tar" | awk -v wr="$WR/" '$1 ~ /^-/ && substr($1,8,1) != "r" { n=$NF; sub(/^\.\//,"",n); if (index(n,wr)==1 || index(n,"etc/nginx/")==1) c++ } END { print c+0 }')
[ "$c_unread" = 0 ] && check world_readable PASS "0 unreadable files in web root + /etc/nginx" || check world_readable FAIL "$c_unread files not world-readable"

c_git=$(grep -cE '(^|/)\.git(/|$)' "$WORK/files.txt" || true)
c_map=$(grep -cE '\.map$' "$WORK/files.txt" || true)
c_nm=$(grep -cE '(^|/)node_modules(/|$)' "$WORK/files.txt" || true)
c_bm=$(grep -cE '(^|/)build\.mjs$' "$WORK/files.txt" || true)
c_src=$(grep -E '(^|/)src(/|$)' "$WORK/files.txt" | grep -cvE '^usr/(local/)?src/?$' || true)
c_pkg=$(grep -cE "^$WR/(package(-lock)?\.json|Dockerfile|\.dockerignore|\.env.*)$" "$WORK/files.txt" || true)
for x in "no_dot_git $c_git" "no_source_maps $c_map" "no_node_modules $c_nm" "no_build_mjs $c_bm" "no_src_dirs $c_src" "no_repo_files_in_webroot $c_pkg"; do
  set -- $x; [ "$2" = 0 ] && check "$1" PASS "0" || check "$1" FAIL "$2 entries"
done

# writable paths nginx needs: pod-shaped run (read-only rootfs, numeric uid, no caps, tmpfs only where the pod has
# emptyDirs: POD_TMPFS, default /tmp /var/cache/nginx).
assert_markers() { # $1 = base url; writes counts into $WORK/markers-<tag>.txt
  curl -sS --max-time 10 -o "$WORK/index.body" -w '%{http_code}' "$1/" > "$WORK/index.code" || echo 000 > "$WORK/index.code"
  HTML_TAG=$(grep -oiE '<html[^>]*>' "$WORK/index.body" | head -1 || true)
  M_ED=$(printf '%s' "$HTML_TAG" | grep -c 'data-edition="gast"' || true)
  M_MO=$(printf '%s' "$HTML_TAG" | grep -c 'data-mode="volwassene"' || true)
  M_ED_ANY=$(printf '%s' "$HTML_TAG" | grep -oE 'data-edition="[a-z0-9-]*"' | head -1 || true)
  M_MO_ANY=$(printf '%s' "$HTML_TAG" | grep -oE 'data-mode="[a-z0-9-]*"' | head -1 || true)
  M_LEER=$(grep -o 'Leerling' "$WORK/index.body" | wc -l | tr -d ' ' || true)
  : > "$WORK/index.body"
}
podrun() { # podrun <tmpfs paths...> -> sets RCTR, RPORT
  local args=(--platform linux/amd64 -d --read-only --user "$UID_N:${GID_N:-$UID_N}" --cap-drop ALL
              --security-opt no-new-privileges -p "127.0.0.1::${PORT:-8080}")
  for t in "$@"; do args+=(--tmpfs "$t:rw,size=16m,mode=1777"); done
  RCTR=$("$P" run "${args[@]}" "$LOCAL_TAG")
  RPORT=$("$P" port "$RCTR" "${PORT:-8080}/tcp" | head -1 | sed 's/.*://')
}
up() { for _ in $(seq 1 40); do curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$RPORT/" && return 0
       "$P" container exists "$RCTR" || return 1; sleep 0.5; done; return 1; }
# POD_TMPFS must equal the emptyDirs of app/helmrelease.yaml (persistence): the local run is the pod's shape, no fallback.
MOUNTS=${POD_TMPFS:-/tmp /var/cache/nginx}
# shellcheck disable=SC2086
podrun $MOUNTS
if ! up; then
  ev "pod-shaped run with tmpfs $MOUNTS: nginx NOT up; log: $("$P" logs "$RCTR" 2>&1 | grep -iE 'emerg|error|denied|read-only' | head -3 | redact | tr '\n' ' ')"
  check pod_shaped_run FAIL "no listener"; exit 8
fi
check pod_shaped_run PASS "read-only rootfs, uid $UID_N, cap-drop ALL, tmpfs: $MOUNTS, random port"
ev "container log warnings (read-only rootfs): $("$P" logs "$RCTR" 2>&1 | grep -ciE 'read-only|can not modify|warn' | tr -d ' ')"
assert_markers "http://127.0.0.1:$RPORT"
ev "GET / -> HTTP $(cat "$WORK/index.code")"
[ "$(cat "$WORK/index.code")" = 200 ] && check get_root_200 PASS 200 || check get_root_200 FAIL "$(cat "$WORK/index.code")"
[ "$M_ED" = 1 ] && check html_data_edition_gast PASS "1" || check html_data_edition_gast FAIL "<html> has ${M_ED_ANY:-no data-edition}"
[ "$M_MO" = 1 ] && check html_data_mode_volwassene PASS "1" || check html_data_mode_volwassene FAIL "<html> has ${M_MO_ANY:-no data-mode}"
[ "$M_LEER" = 0 ] && check index_no_Leerling PASS "0" || check index_no_Leerling FAIL "$M_LEER occurrences in /"
HC=$(curl -s -o /dev/null --max-time 5 -w '%{http_code}' "http://127.0.0.1:$RPORT/healthz" || echo 000)
ev "GET /healthz -> HTTP $HC"
# count "Leerling" across all text assets of the web root, streamed from the export (nothing written, nothing shown)
grep -E "^$WR/.*\.(html|js|mjs|css|json|txt|svg)$" "$WORK/files.txt" > "$WORK/text-assets.txt" || true
WLEER=0
while read -r f; do c=$(xo "$f" | grep -o 'Leerling' | wc -l | tr -d ' ' || true); WLEER=$((WLEER + c)); done < "$WORK/text-assets.txt"
[ "$WLEER" = 0 ] && check webroot_no_Leerling PASS "0 in $(wc -l < "$WORK/text-assets.txt" | tr -d ' ') text assets" \
                 || check webroot_no_Leerling FAIL "$WLEER in $(wc -l < "$WORK/text-assets.txt" | tr -d ' ') text assets"
"$P" stop -t 2 "$RCTR" >/dev/null 2>&1; "$P" container rm -f "$RCTR" >/dev/null 2>&1; RCTR=""
: > "$WORK/fs.tar"

ev "gate: $FAILS failure(s)"
if [ "$MODE" != --push ]; then
  ev "no --push: nothing pushed, nothing signed"
  [ "$FAILS" = 0 ] || exit 1
  exit 0
fi

# ---- 4 push + sign ---------------------------------------------------------------------------------------------------
[ "$FAILS" = 0 ] || { ev "push REFUSED: $FAILS gate failure(s)"; exit 10; }
case "$OWNER" in
  palamedes|mypka*|vdhict|VDHICT|wires-publisher|*passkey*|"") ev "push REFUSED: owner '$OWNER' is reserved"; exit 11;;
esac
AUTH=${CURSUS_PUSH_AUTHFILE:-}
[ -n "$AUTH" ] && [ -s "$AUTH" ] || { ev "push REFUSED: CURSUS_PUSH_AUTHFILE unset or empty"; exit 12; }
[ "$(stat -f %Lp "$AUTH")" = 600 ] || { ev "push REFUSED: authfile not 0600"; exit 12; }
[ "$("$JQ" -c '.auths | keys' "$AUTH")" = "[\"$FORGE\"]" ] || { ev "push REFUSED: authfile must hold exactly $FORGE"; exit 12; }
REPO=$FORGE/$OWNER/cursus-gast
KWORK=$WORK/sign; mkdir -m 700 "$KWORK" "$KWORK/docker"
cp "$AUTH" "$KWORK/docker/config.json"; chmod 600 "$KWORK/docker/config.json"
export DOCKER_CONFIG=$KWORK/docker REGISTRY_AUTH_FILE=$AUTH
"$P" push --authfile "$AUTH" --digestfile "$KWORK/digest" "$LOCAL_TAG" "docker://$REPO:$EDITION-$SHORT" > "$WORK/push.log" 2>&1 \
  || { tail -3 "$WORK/push.log" >&2; ev "push: FAILED"; exit 13; }
DIGEST=$(cat "$KWORK/digest")
RB=$("$CRANE" digest "$REPO:$EDITION-$SHORT")
[ "$RB" = "$DIGEST" ] || { ev "push read-back: tag resolves to $RB, pushed $DIGEST; refusing"; exit 14; }
"$CRANE" validate --remote "$REPO@$DIGEST" > "$WORK/validate.txt" 2>&1 || { ev "crane validate (full pull) FAILED"; exit 14; }
CFGD=$("$CRANE" manifest "$REPO@$DIGEST" | "$JQ" -r .config.digest)
ev "pushed $REPO:$EDITION-$SHORT digest $DIGEST; tag read-back equal; full pull validated; config $CFGD (local id sha256:$IMGID)"
[ "$CFGD" = "sha256:$IMGID" ] || { ev "config digest != local image id; refusing to sign"; exit 14; }

printf '%s\n' '{"mediaType":"application/vnd.dev.sigstore.signingconfig.v0.2+json","caUrls":[],"oidcUrls":[],"rekorTlogUrls":[],"tsaUrls":[],"rekorTlogConfig":{"selector":"ANY"},"tsaConfig":{"selector":"ANY"}}' > "$KWORK/signing-config.no-tlog.json"
COSIGN_PASSWORD=$(openssl rand -base64 33 | tr -d '\n'); export COSIGN_PASSWORD
( cd "$KWORK" && "$COSIGN" generate-key-pair >/dev/null 2>&1 ) || { ev "cosign generate-key-pair FAILED"; exit 15; }
[ "$(stat -f %Lp "$KWORK/cosign.key")" = 600 ] || chmod 600 "$KWORK/cosign.key"
"$COSIGN" sign --yes --key "$KWORK/cosign.key" --signing-config "$KWORK/signing-config.no-tlog.json" \
  -a "commit=$COMMIT" -a "chg=chg-2026-10-28-002" "$REPO@$DIGEST" > "$KWORK/sign.log" 2>&1 \
  || { grep -v -i 'password' "$KWORK/sign.log" | tail -3 >&2; ev "cosign sign FAILED"; exit 16; }
unset COSIGN_PASSWORD
grep -qi 'tlog entry created' "$KWORK/sign.log" && { ev "cosign reports a transparency-log upload; refusing"; exit 16; }
mkdir -p "$TRASH"; mv "$KWORK/cosign.key" "$TRASH/cosign.key.$RUN"
ev "private key moved to the trash dir (never committed, never printed)"
umask 022; cp "$KWORK/cosign.pub" "$REPO_ROOT/$PUBKEY_REPO"; umask 077
PUBDER=$(openssl pkey -pubin -in "$REPO_ROOT/$PUBKEY_REPO" -outform DER | shasum -a 256 | cut -c1-64)
ev "public key -> $PUBKEY_REPO (DER sha256 $PUBDER)"
"$COSIGN" verify --key "$REPO_ROOT/$PUBKEY_REPO" --insecure-ignore-tlog "$REPO@$DIGEST" > "$WORK/verify.json" 2> "$WORK/verify.err" \
  || { tail -3 "$WORK/verify.err" >&2; ev "cosign verify FAILED"; exit 17; }
VD=$("$JQ" -r '.[0].critical.image["docker-manifest-digest"]' "$WORK/verify.json")
[ "$VD" = "$DIGEST" ] || { ev "cosign verify digest $VD != $DIGEST"; exit 17; }
check cosign_verify PASS "digest $VD, key DER sha256 $PUBDER"
: > "$KWORK/docker/config.json"
ev "== RESULT image $REPO@$DIGEST (tag $EDITION-$SHORT)"
ev "next: content gate  COSIGN_KEY=$PUBKEY_REPO CONTENT_ROOT=$WEBROOT hack/ops/chg-2026-10-28-002-content-gate.sh $REPO@$DIGEST"
ev "next: revoke the push token of $OWNER (this script does not hold it)"
echo "DIGEST $DIGEST"
