#!/usr/bin/env bash
#
# Distil an OLM file-based catalog tree into the slim graph data that
# index.html needs.
#
#   ./build-index.sh [catalogDir] [outDir]        defaults: ./catalog ./data
#   ./build-index.sh --engine jq catalog data     force a specific engine
#   ./build-index.sh --version-only               refresh version.js only
#
# Each sub-directory of catalogDir is one operator. Only the olm.package
# and olm.channel records matter; the olm.bundle records are the bulk of
# the bytes (easily 200 MB in a single file) and hold nothing the upgrade
# graph needs, so they are streamed past and discarded.
#
# Layouts handled:
#   catalog.json | index.json        JSON stream (concatenated objects)
#   channels/ *.json + package.json
#   channel.json + package.json
#   channels.yaml + package.yaml     multi-document YAML (python3 only)
#
# Writes <outDir>/operators.json and <outDir>/<operator>.json.
#
# Requires python3 (preferred) or jq. Pure shell/awk is not an option
# here: a 14 MB catalog takes BSD awk over 10 minutes to scan character
# by character, versus well under a second for python3 or jq.

set -eu

CATALOG=""
OUT=""
ENGINE="auto"
VERSION_ONLY="no"

while [ $# -gt 0 ]; do
  case "$1" in
    --engine) ENGINE="${2:-}"; shift 2 ;;
    --engine=*) ENGINE="${1#*=}"; shift ;;
    --version-only) VERSION_ONLY="yes"; shift ;;
    -h|--help)
      sed -n '2,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *)
      if [ -z "$CATALOG" ]; then CATALOG="$1"
      elif [ -z "$OUT" ]; then OUT="$1"
      else echo "unexpected argument: $1" >&2; exit 2; fi
      shift ;;
  esac
done

CATALOG="${CATALOG:-catalog}"
OUT="${OUT:-data}"

# ---------- version ----------
# version.conf is the source of truth. We also emit version.js, because a
# page opened straight from disk cannot fetch() a sibling file -- but it
# can load one with <script src>.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
VERSION_CONF=""
APP_VERSION=""
for vf in "./version.conf" "$SCRIPT_DIR/version.conf"; do
  if [ -f "$vf" ]; then
    VERSION_CONF="$vf"
    APP_VERSION=$(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$vf" \
                  | grep -v '^$' | head -1 \
                  | sed -e 's/^[Vv]ersion[[:space:]]*[=:][[:space:]]*//' -e 's/^[Vv]//' \
                  | tr -d '"\\')
    break
  fi
done

write_version_js() {
  [ -n "$VERSION_CONF" ] || { echo "version.conf not found; skipping version.js" >&2; return 0; }
  vdir=$(dirname "$VERSION_CONF")
  cat > "$vdir/version.js" <<EOF
// Generated from $(basename "$VERSION_CONF") by build-index.sh -- do not edit.
// Lets the page show its version when opened directly from disk, where
// fetch() of a sibling file is blocked by the browser.
window.APP_VERSION = "$APP_VERSION";
EOF
  echo "version : $APP_VERSION  (wrote $vdir/version.js)"
}

if [ "$VERSION_ONLY" = "yes" ]; then
  write_version_js
  exit 0
fi

if [ ! -d "$CATALOG" ]; then
  echo "catalog directory not found: $CATALOG" >&2
  echo "see the Setup steps in index.html for how to extract one with podman" >&2
  exit 1
fi

# ---------- pick an engine ----------

have() { command -v "$1" >/dev/null 2>&1; }

if [ "$ENGINE" = "auto" ]; then
  if have python3; then ENGINE=python3
  elif have jq;    then ENGINE=jq
  else
    echo "need python3 or jq on PATH (neither found)." >&2
    echo "  RHEL/Fedora:  sudo dnf install -y python3" >&2
    echo "  Debian/Ubuntu: sudo apt-get install -y python3" >&2
    echo "  macOS:        python3 ships with the Xcode command line tools" >&2
    exit 1
  fi
else
  case "$ENGINE" in
    python3|jq) ;;
    *) echo "unsupported engine: $ENGINE (use python3 or jq)" >&2; exit 2 ;;
  esac
  if ! have "$ENGINE"; then
    echo "requested engine not found on PATH: $ENGINE" >&2
    exit 1
  fi
fi

mkdir -p "$OUT"
echo "catalog : $CATALOG"
echo "output  : $OUT"
echo "engine  : $ENGINE"
write_version_js

# ======================================================================
# python3 engine -- handles every layout, including YAML
# ======================================================================

run_python() {
  python3 -I - "$CATALOG" "$OUT" "${APP_VERSION:-}" <<'PYEOF'
import json, os, sys, datetime

catalog_dir, out_dir = sys.argv[1], sys.argv[2]
app_version = sys.argv[3] if len(sys.argv) > 3 else ""

# ---- streaming reader: bounded memory regardless of file size ----
def stream_records(path):
    dec = json.JSONDecoder()
    buf = ""
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        while True:
            chunk = fh.read(1 << 20)
            if not chunk:
                break
            buf += chunk
            i = 0
            while True:
                while i < len(buf) and buf[i].isspace():
                    i += 1
                if i >= len(buf):
                    break
                try:
                    obj, j = dec.raw_decode(buf, i)
                except ValueError:
                    break                      # incomplete; need more input
                yield obj
                i = j
            buf = buf[i:]
    buf = buf.strip()
    while buf:
        try:
            obj, j = dec.raw_decode(buf, 0)
        except ValueError:
            break
        yield obj
        buf = buf[j:].strip()

def read_stream(path):
    channels, pkg = [], None
    for o in stream_records(path):
        if not isinstance(o, dict):
            continue
        s = o.get("schema")
        if s == "olm.channel":
            channels.append(o)
        elif s == "olm.package" and pkg is None:
            pkg = o
    return channels, pkg

# A small .json here may be one object, an array, or a concatenated stream.
def read_records(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    try:
        o = json.loads(text)
        return o if isinstance(o, list) else [o]
    except ValueError:
        return [o for o in stream_records(path) if isinstance(o, dict)]

# ---- minimal YAML reader for olm.* documents ----
def unq(s):
    t = s.strip()
    if len(t) >= 2 and t[0] == t[-1] and t[0] in "'\"":
        return t[1:-1]
    return t

def parse_olm_yaml(text):
    docs = []
    for doc in text.split("\n---"):
        obj, entries, cur, skip_block, list_key = {}, None, None, False, None
        for raw in doc.split("\n"):
            if not raw.strip() or raw.lstrip().startswith("#") or raw.strip() == "---":
                continue
            indent = len(raw) - len(raw.lstrip())
            line = raw.strip()

            if line == "-" or line.startswith("- "):
                if skip_block:
                    continue
                item = line[1:].strip()
                if cur is not None and list_key:
                    cur[list_key].append(unq(item))
                    continue
                if entries is not None:
                    cur, list_key = {}, None
                    entries.append(cur)
                    if ":" in item:
                        k, _, v = item.partition(":")
                        cur[k.strip()] = unq(v)
                continue

            if ":" not in line:
                continue
            k, _, v = line.partition(":")
            k, v = k.strip(), v.strip()

            if indent == 0:
                skip_block = False
                if k == "entries":
                    entries, cur, list_key = [], None, None
                    obj["entries"] = entries
                elif v == "":
                    skip_block = True
                else:
                    obj[k] = unq(v)
            elif not skip_block and cur is not None:
                if v == "":
                    cur[k] = []
                    list_key = k
                else:
                    cur[k] = unq(v)
                    list_key = None
        if obj:
            docs.append(obj)
    return docs

def read_yaml(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        docs = parse_olm_yaml(fh.read())
    channels = [d for d in docs if d.get("schema") == "olm.channel"]
    pkg = next((d for d in docs if d.get("schema") == "olm.package"), None)
    return channels, pkg

def read_package_file(d):
    p = os.path.join(d, "package.json")
    if not os.path.isfile(p):
        return None
    try:
        return next((x for x in read_records(p)
                     if isinstance(x, dict) and x.get("schema") == "olm.package"), None)
    except Exception:
        return None

def load_operator(d):
    for name in ("catalog.json", "index.json"):
        p = os.path.join(d, name)
        if os.path.isfile(p):
            ch, pkg = read_stream(p)
            return name, ch, pkg

    chdir = os.path.join(d, "channels")
    if os.path.isdir(chdir):
        channels = []
        for f in sorted(os.listdir(chdir)):
            if f.endswith(".json"):
                channels += [c for c in read_records(os.path.join(chdir, f))
                             if isinstance(c, dict) and c.get("schema") == "olm.channel"]
        return "channels/", channels, read_package_file(d)

    p = os.path.join(d, "channel.json")
    if os.path.isfile(p):
        recs = read_records(p)
        channels = [c for c in recs if isinstance(c, dict) and c.get("schema") == "olm.channel"]
        pkg = read_package_file(d) or next(
            (c for c in recs if isinstance(c, dict) and c.get("schema") == "olm.package"), None)
        return "channel.json", channels, pkg

    p = os.path.join(d, "channels.yaml")
    if os.path.isfile(p):
        channels, _ = read_yaml(p)
        pkg = None
        pp = os.path.join(d, "package.yaml")
        if os.path.isfile(pp):
            _, pkg = read_yaml(pp)
        return "yaml", channels, pkg

    return None, [], None

def distil(name, channels, pkg):
    out = []
    for c in channels:
        entries = []
        for e in (c.get("entries") or []):
            if not isinstance(e, dict) or not e.get("name"):
                continue
            o = {"name": e["name"]}
            if e.get("replaces"):
                o["replaces"] = e["replaces"]
            if e.get("skips"):
                o["skips"] = e["skips"]
            if e.get("skipRange"):
                o["skipRange"] = e["skipRange"]
            entries.append(o)
        if entries:
            out.append({"name": c.get("name"), "entries": entries})
    versions = {e["name"] for c in out for e in c["entries"]}
    return {
        "package": (pkg or {}).get("name") or name,
        "defaultChannel": (pkg or {}).get("defaultChannel") or "",
        "channels": out,
    }, len(versions)

def human(b):
    for unit, size in (("G", 1 << 30), ("M", 1 << 20)):
        if b >= size:
            return "%.1f%s" % (b / size, unit)
    return "%dK" % (b / 1024)

dirs = sorted(d for d in os.listdir(catalog_dir)
              if os.path.isdir(os.path.join(catalog_dir, d)))
operators, skipped = [], []

for n, name in enumerate(dirs, 1):
    sys.stdout.write("\r[%3d/%d] %-42.42s" % (n, len(dirs), name))
    sys.stdout.flush()
    try:
        layout, channels, pkg = load_operator(os.path.join(catalog_dir, name))
    except Exception as err:
        skipped.append((name, str(err)))
        continue
    if not channels:
        skipped.append((name, "unrecognised layout" if layout is None else "no olm.channel records"))
        continue
    data, nversions = distil(name, channels, pkg)
    fname = name + ".json"
    with open(os.path.join(out_dir, fname), "w", encoding="utf-8") as fh:
        json.dump(data, fh, separators=(",", ":"))
    operators.append({
        "name": name,
        "package": data["package"],
        "defaultChannel": data["defaultChannel"],
        "channels": len(data["channels"]),
        "versions": nversions,
        "layout": layout,
        "file": fname,
    })

sys.stdout.write("\r" + " " * 70 + "\r")

with open(os.path.join(out_dir, "operators.json"), "w", encoding="utf-8") as fh:
    json.dump({
        "generated": datetime.datetime.now(datetime.timezone.utc)
                        .isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "version": app_version,
        "catalogDir": os.path.basename(os.path.normpath(catalog_dir)),
        "operators": operators,
    }, fh, indent=1)

total = sum(os.path.getsize(os.path.join(out_dir, f)) for f in os.listdir(out_dir))
print("indexed %d operators -> %s (%s)" % (len(operators), out_dir, human(total)))
print("  versions: %d, channels: %d"
      % (sum(o["versions"] for o in operators), sum(o["channels"] for o in operators)))
layouts = {}
for o in operators:
    layouts[o["layout"]] = layouts.get(o["layout"], 0) + 1
print("  layouts: " + " ".join("%s=%d" % kv for kv in sorted(layouts.items())))
if skipped:
    print("  skipped %d:" % len(skipped))
    for name, why in skipped:
        print("    %s: %s" % (name, why))
PYEOF
}

# ======================================================================
# jq engine -- JSON layouts only (no YAML)
# ======================================================================

JQ_DISTIL='
  [inputs | select(type == "object")
          | select(.schema == "olm.channel" or .schema == "olm.package")] as $r
  | ($r | map(select(.schema == "olm.package")) | first) as $p
  | ($r | map(select(.schema == "olm.channel"))
        | map({ name: .name,
                entries: [ (.entries // [])[]
                           | select(.name != null)
                           | {name: .name}
                             + (if .replaces   then {replaces:  .replaces}  else {} end)
                             + (if (.skips // []) | length > 0 then {skips: .skips} else {} end)
                             + (if .skipRange  then {skipRange: .skipRange} else {} end) ] })
        | map(select((.entries | length) > 0))) as $ch
  | { package:        (($p.name) // $opname),
      defaultChannel: (($p.defaultChannel) // ""),
      channels:       $ch }
'

run_jq() {
  summary_file=$(mktemp)
  trap 'rm -f "$summary_file"' EXIT
  total=0
  for d in "$CATALOG"/*/; do [ -d "$d" ] && total=$((total + 1)); done

  n=0
  for d in "$CATALOG"/*/; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    n=$((n + 1))
    printf '\r[%3d/%d] %-42.42s' "$n" "$total" "$name" >&2

    layout=""; inputs=""
    if   [ -f "$d/catalog.json" ]; then layout="catalog.json"; inputs="$d/catalog.json"
    elif [ -f "$d/index.json"  ]; then layout="index.json";   inputs="$d/index.json"
    elif [ -d "$d/channels"    ]; then
      layout="channels/"
      inputs=$(find "$d/channels" -maxdepth 1 -name '*.json' | sort | tr '\n' ' ')
      [ -f "$d/package.json" ] && inputs="$inputs $d/package.json"
    elif [ -f "$d/channel.json" ]; then
      layout="channel.json"; inputs="$d/channel.json"
      [ -f "$d/package.json" ] && inputs="$inputs $d/package.json"
    elif [ -f "$d/channels.yaml" ]; then
      echo "" >&2; echo "  skip $name: YAML layout needs the python3 engine" >&2
      continue
    else
      echo "" >&2; echo "  skip $name: unrecognised layout" >&2
      continue
    fi

    # shellcheck disable=SC2086
    if ! jq -n -c --arg opname "$name" "$JQ_DISTIL" $inputs > "$OUT/$name.json" 2>/dev/null; then
      echo "" >&2; echo "  skip $name: jq could not parse it" >&2
      rm -f "$OUT/$name.json"
      continue
    fi

    jq -r --arg name "$name" --arg layout "$layout" '
      if (.channels | length) == 0 then empty else
        [$name, .package, .defaultChannel,
         (.channels | length),
         ([.channels[].entries[].name] | unique | length),
         $layout] | @tsv
      end' "$OUT/$name.json" >> "$summary_file"

    [ -s "$OUT/$name.json" ] || rm -f "$OUT/$name.json"
    if ! grep -q "^$name	" "$summary_file" 2>/dev/null; then
      rm -f "$OUT/$name.json"
      echo "" >&2; echo "  skip $name: no olm.channel records" >&2
    fi
  done
  printf '\r%-70s\r' "" >&2

  jq -R -s --arg dir "$(basename "$CATALOG")" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
           --arg version "${APP_VERSION:-}" '
    { generated: $now, version: $version, catalogDir: $dir,
      operators: [ split("\n")[] | select(length > 0) | split("\t")
                   | { name: .[0], package: .[1], defaultChannel: .[2],
                       channels: (.[3] | tonumber), versions: (.[4] | tonumber),
                       layout: .[5], file: (.[0] + ".json") } ] }
  ' < "$summary_file" > "$OUT/operators.json"

  count=$(jq '.operators | length' "$OUT/operators.json")
  vers=$(jq '[.operators[].versions] | add // 0' "$OUT/operators.json")
  chans=$(jq '[.operators[].channels] | add // 0' "$OUT/operators.json")
  size=$(du -sh "$OUT" | cut -f1)
  echo "indexed $count operators -> $OUT ($size)"
  echo "  versions: $vers, channels: $chans"
}

case "$ENGINE" in
  python3) run_python ;;
  jq)      run_jq ;;
  *)       echo "unsupported engine: $ENGINE (use python3 or jq)" >&2; exit 1 ;;
esac

echo
echo "Next: serve this directory and open the page."
echo "  python3 -m http.server 8000     # then open http://localhost:8000/"
