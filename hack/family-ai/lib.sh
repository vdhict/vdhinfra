# Shared helpers for hack/family-ai/*.sh (sourced, not executed).
# Mack's delivery layout (e.g. ~/family-ai-bundle/<rev>/):
#   SHA256SUMS                      covers EVERY file, paths relative to the root
#   profiel-<n>/...                 Hermes profile bundle (config.yaml, SOUL.md, plugins/**)
#   gezinsdienst/{gezinsdienst.py,config.json,teksten.json}
#   openwebui-plan.json             NOT shipped (contains logins)
#   VERVANGEN.txt                   if present: this delivery is SUPERSEDED - refuse
die() { echo "${0##*/}: $*" >&2; exit 1; }
verify_delivery() { # $1 = delivery root
  local d="$1"
  [ -d "$d" ] || die "delivery '$d' not found"
  [ ! -e "$d/VERVANGEN.txt" ] || die "delivery is marked SUPERSEDED: $(head -c 200 "$d/VERVANGEN.txt")"
  [ -f "$d/SHA256SUMS" ] || die "no SHA256SUMS in $d"
  [ -z "$(cd "$d" && find . -type l)" ] || die "symlinks in delivery - refused"
  ( cd "$d" && shasum -a 256 -c --strict SHA256SUMS >/dev/null ) || die "SHA256SUMS verification FAILED"
  local listed present
  listed=$(awk '{p=$2; sub(/^\*/,"",p); sub(/^\.\//,"",p); print p}' "$d/SHA256SUMS" | sort)
  present=$(cd "$d" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | sort)
  [ "$listed" = "$present" ] || { diff <(echo "$listed") <(echo "$present") >&2 || true; die "SHA256SUMS does not cover exactly the files present"; }
  echo "${0##*/}: delivery $(basename "$d"): $(echo "$present" | wc -l | tr -d ' ') files, SHA256SUMS OK"
}
sops_write() { # $1 plaintext yaml (in a temp dir), $2 target path in repo
  local root; root="$(git rev-parse --show-toplevel)"
  ( cd "$root" && sops --encrypt --filename-override "$2" --input-type yaml --output-type yaml "$1" ) > "$1.enc" || die "sops encrypt failed"
  grep -q '^sops:' "$1.enc" || die "output is not SOPS-encrypted - refusing to write"
  mv "$1.enc" "$2"
}
