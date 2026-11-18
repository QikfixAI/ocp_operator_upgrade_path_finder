#!/usr/bin/env bash
#
# End-to-end test for the Operator Upgrade Path Finder.
#
#   ./e2e-test.sh [catalogDir]        default: ./catalog
#   ./e2e-test.sh --keep              keep the temp workspace for inspection
#   ./e2e-test.sh --no-browser        skip the browser phase
#
# Three phases:
#   1. build   -- run build-index.sh into a temp dir and verify it produced
#                 every file it should, with well-formed contents
#   2. serve   -- start a web server and check the app's assets are reachable
#   3. browser -- load the page once in headless Chrome and drive EVERY
#                 operator through the UI, asserting nothing throws
#
# The working tree is not modified: the index is built into a temp directory
# and served from a temp root of symlinks. Exits non-zero on any failure.

set -u

CATALOG="catalog"
KEEP="no"
RUN_BROWSER="yes"

while [ $# -gt 0 ]; do
  case "$1" in
    --keep) KEEP="yes"; shift ;;
    --no-browser) RUN_BROWSER="no"; shift ;;
    -h|--help) sed -n '2,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) CATALOG="$1"; shift ;;
  esac
done

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT" || exit 1

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=""

say()  { printf '%s\n' "$*"; }
head2() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); FAILED_NAMES="$FAILED_NAMES
    - $1"; printf '  \033[31mFAIL\033[0m  %s\n' "$*"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s\n' "$*"; }
info() { printf '        %s\n' "$*"; }

check() { # check <description> <command...>
  desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/oupf-e2e.XXXXXX") || exit 1
SRV_PID=""

cleanup() {
  [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null
  if [ "$KEEP" = "yes" ]; then
    say ""; say "workspace kept at: $TMP"
  else
    rm -rf "$TMP"
  fi
}
trap cleanup EXIT INT TERM

say "Operator Upgrade Path Finder -- end-to-end test"
say "root    : $ROOT"
say "catalog : $CATALOG"
say "workspace: $TMP"

# ======================================================================
head2 "0. preflight"
# ======================================================================

for f in index.html build-index.sh version.conf; do
  if [ -f "$f" ]; then ok "source present: $f"; else bad "source missing: $f"; fi
done

if [ -d "$CATALOG" ]; then
  NOPS=$(find "$CATALOG" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
  ok "catalog directory present ($NOPS operator sub-directories)"
else
  bad "catalog directory missing: $CATALOG"
  say ""; say "Cannot continue without a catalog. See README 'Quick start'."
  exit 1
fi

if command -v python3 >/dev/null 2>&1; then
  ok "python3 available ($(python3 --version 2>&1))"
else
  bad "python3 not available (needed to build and to serve)"
  exit 1
fi

# locate a headless-capable browser
BROWSER=""
for cand in \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "/Applications/Chromium.app/Contents/MacOS/Chromium" \
  google-chrome google-chrome-stable chromium chromium-browser; do
  if [ -x "$cand" ]; then BROWSER="$cand"; break; fi
  if command -v "$cand" >/dev/null 2>&1; then BROWSER=$(command -v "$cand"); break; fi
done
if [ "$RUN_BROWSER" = "no" ]; then
  info "browser phase disabled with --no-browser"
elif [ -n "$BROWSER" ]; then
  ok "browser found: $BROWSER"
else
  info "no Chrome/Chromium found -- phase 3 will be skipped"
fi

# ======================================================================
head2 "1. build -- does build-index.sh produce everything it should?"
# ======================================================================

OUT="$TMP/data"
BUILD_LOG="$TMP/build.log"

if ./build-index.sh "$CATALOG" "$OUT" >"$BUILD_LOG" 2>&1; then
  ok "build-index.sh exited 0"
else
  bad "build-index.sh exited non-zero"
  tail -5 "$BUILD_LOG" | sed 's/^/        /'
fi

# the progress counter uses \r, so split on it before matching
info "$(tr '\r' '\n' < "$BUILD_LOG" | grep -E '^indexed ' || echo 'no summary line')"

check "operators.json created" test -f "$OUT/operators.json"
check "version.js created"     test -f "$ROOT/version.js"

if [ -f "$ROOT/version.js" ] && [ -f "$ROOT/version.conf" ]; then
  VC=$(sed -e 's/[[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' version.conf \
       | grep -v '^$' | head -1 | sed -e 's/^[Vv]ersion[[:space:]]*[=:][[:space:]]*//' -e 's/^[Vv]//')
  if grep -q "\"$VC\"" "$ROOT/version.js"; then
    ok "version.js matches version.conf ($VC)"
  else
    bad "version.js does not match version.conf ($VC)"
  fi
fi

# Deep validation of the generated index, including one file per operator.
if [ -f "$OUT/operators.json" ]; then
  VALIDATE=$(python3 -I - "$OUT" "$CATALOG" <<'PYEOF'
import json, os, sys
out_dir, catalog_dir = sys.argv[1], sys.argv[2]
problems, notes = [], []

try:
    idx = json.load(open(os.path.join(out_dir, "operators.json")))
except Exception as e:
    print("FATAL|operators.json is not valid JSON: %s" % e); raise SystemExit(0)

for key in ("generated", "version", "catalogDir", "operators"):
    if key not in idx:
        problems.append("operators.json missing top-level key: %s" % key)

ops = idx.get("operators", [])
if not ops:
    problems.append("operators.json lists no operators")

on_disk = {d for d in os.listdir(catalog_dir)
           if os.path.isdir(os.path.join(catalog_dir, d))}
indexed = {o["name"] for o in ops}
missing = sorted(on_disk - indexed)
if missing:
    notes.append("not indexed (%d): %s" % (len(missing), ", ".join(missing[:6])))

extra_files = {f for f in os.listdir(out_dir)} - {"operators.json"} - {o["file"] for o in ops}
if extra_files:
    problems.append("orphan files in %s: %s" % (out_dir, ", ".join(sorted(extra_files)[:6])))

tot_v = tot_c = 0
for o in ops:
    for key in ("name", "package", "defaultChannel", "channels", "versions", "layout", "file"):
        if key not in o:
            problems.append("%s: index entry missing %s" % (o.get("name", "?"), key)); break

    p = os.path.join(out_dir, o["file"])
    if not os.path.isfile(p):
        problems.append("%s: data file missing (%s)" % (o["name"], o["file"])); continue
    if os.path.getsize(p) == 0:
        problems.append("%s: data file is empty" % o["name"]); continue
    try:
        d = json.load(open(p))
    except Exception as e:
        problems.append("%s: invalid JSON (%s)" % (o["name"], e)); continue

    for key in ("package", "defaultChannel", "channels"):
        if key not in d:
            problems.append("%s: data file missing key %s" % (o["name"], key))
    chans = d.get("channels", [])
    if not chans:
        problems.append("%s: no channels in data file" % o["name"]); continue

    seen = set()
    for c in chans:
        if not c.get("name"):
            problems.append("%s: channel with no name" % o["name"])
        if not c.get("entries"):
            problems.append("%s: channel %s has no entries" % (o["name"], c.get("name")))
        for e in c.get("entries", []):
            if not e.get("name"):
                problems.append("%s: entry with no name in %s" % (o["name"], c.get("name")))
            seen.add(e.get("name"))

    if len(chans) != o["channels"]:
        problems.append("%s: channel count %d != index %d" % (o["name"], len(chans), o["channels"]))
    if len(seen) != o["versions"]:
        problems.append("%s: version count %d != index %d" % (o["name"], len(seen), o["versions"]))
    tot_v += len(seen); tot_c += len(chans)

print("COUNTS|%d|%d|%d|%d" % (len(ops), len(on_disk), tot_v, tot_c))
for n in notes:
    print("NOTE|%s" % n)
for p in problems:
    print("PROBLEM|%s" % p)
PYEOF
)
  COUNTS=$(printf '%s\n' "$VALIDATE" | grep '^COUNTS|' | head -1)
  if [ -n "$COUNTS" ]; then
    N_OPS=$(printf '%s' "$COUNTS" | cut -d'|' -f2)
    N_DIR=$(printf '%s' "$COUNTS" | cut -d'|' -f3)
    N_VER=$(printf '%s' "$COUNTS" | cut -d'|' -f4)
    N_CHN=$(printf '%s' "$COUNTS" | cut -d'|' -f5)
    info "indexed $N_OPS of $N_DIR sub-directories; $N_VER versions, $N_CHN channels"
    if [ "$N_OPS" -eq "$N_DIR" ]; then
      ok "every catalog sub-directory produced a data file"
    else
      bad "only $N_OPS of $N_DIR sub-directories were indexed"
    fi
  fi

  printf '%s\n' "$VALIDATE" | grep '^NOTE|' | sed 's/^NOTE|/        note: /'

  NPROB=$(printf '%s\n' "$VALIDATE" | grep -c '^PROBLEM|')
  if [ "$NPROB" -eq 0 ]; then
    ok "all per-operator data files are complete and well-formed"
  else
    bad "$NPROB problem(s) in generated data"
    printf '%s\n' "$VALIDATE" | grep '^PROBLEM|' | head -10 | sed 's/^PROBLEM|/        /'
  fi
fi

# ======================================================================
head2 "2. serve -- is the application reachable over HTTP?"
# ======================================================================

# Temp document root of symlinks, so the real tree is untouched and the
# freshly built index is what gets served.
WEBROOT="$TMP/webroot"
mkdir -p "$WEBROOT"
for f in index.html version.conf version.js; do
  [ -e "$ROOT/$f" ] && ln -s "$ROOT/$f" "$WEBROOT/$f"
done
ln -s "$ROOT/$CATALOG" "$WEBROOT/catalog"
ln -s "$OUT" "$WEBROOT/data"

PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
BASE="http://127.0.0.1:$PORT"

( cd "$WEBROOT" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 ) >"$TMP/server.log" 2>&1 &
SRV_PID=$!

# wait for the port to answer
UP="no"
i=0
while [ $i -lt 50 ]; do
  if python3 -c "
import socket,sys
s=socket.socket(); s.settimeout(0.3)
sys.exit(0 if s.connect_ex(('127.0.0.1',$PORT))==0 else 1)
" 2>/dev/null; then UP="yes"; break; fi
  i=$((i+1)); sleep 0.2
done

if [ "$UP" = "yes" ]; then
  ok "web server started on port $PORT"
else
  bad "web server did not start"
  tail -5 "$TMP/server.log" | sed 's/^/        /'
fi

http_code() {
  python3 -c "
import sys,urllib.request
try:
    with urllib.request.urlopen('$BASE/$1', timeout=10) as r: print(r.status)
except Exception as e:
    print(getattr(e,'code',0))
"
}

if [ "$UP" = "yes" ]; then
  for path in "" index.html version.conf data/operators.json data/rhods-operator.json; do
    code=$(http_code "$path")
    label="${path:-/ (index)}"
    if [ "$code" = "200" ]; then ok "HTTP 200  $label"; else bad "HTTP $code  $label"; fi
  done
fi

# ======================================================================
head2 "3. browser -- drive every operator through the UI"
# ======================================================================

if [ "$RUN_BROWSER" = "no" ]; then
  skip "browser phase disabled (--no-browser)"
elif [ -z "$BROWSER" ]; then
  skip "no Chrome/Chromium found -- install one to exercise the page itself"
elif [ "$UP" != "yes" ]; then
  skip "web server is not up"
else
  # A harness copy of the page whose bootstrap drives the whole operator list.
  python3 -I - "$ROOT/index.html" "$WEBROOT/_e2e.html" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
page = open(src, encoding="utf-8").read()

driver = r'''
window.__e2e = { errors: [] };
window.addEventListener("error", e => window.__e2e.errors.push("onerror: " + e.message));
window.addEventListener("unhandledrejection", e => window.__e2e.errors.push(
  "unhandledrejection: " + ((e.reason && e.reason.message) || e.reason)));

function e2eFinish(payload) {
  const pre = document.createElement("pre");
  pre.id = "e2e-result";
  pre.textContent = JSON.stringify(payload);
  document.body.appendChild(pre);
  document.title = "E2E-DONE";
}

boot().then(async () => {
  const results = [];
  let golden = { ran: false };

  for (const op of OPERATORS) {
    const rec = { name: op.name, ok: false };
    try {
      await selectOperator(op.name);

      if (!$("opError").classList.contains("hidden")) {
        rec.error = "load error: " + $("opErrorMsg").textContent.trim();
        results.push(rec);
        continue;
      }
      rec.versions = State.versions.length;
      rec.channels = State.channels.length;
      if (!rec.versions) { rec.error = "no versions"; results.push(rec); continue; }
      if (!$("versionPanel") || $("versionPanel").classList.contains("hidden")) {
        rec.error = "version panel stayed hidden"; results.push(rec); continue;
      }

      const newest = State.versions[0].name;
      const oldest = State.versions[State.versions.length - 1].name;
      const combos = [[oldest, newest], [newest, oldest], [newest, newest], ["", newest]];
      for (const [s, t] of combos) {
        $("src").value = s; $("tgt").value = t; $("chan").value = "";
        render();
        if (!$("resultBody").innerHTML.trim()) {
          throw new Error(`empty result for "${s}" -> "${t}"`);
        }
      }
      // pin to each channel in turn, oldest -> newest
      $("src").value = oldest; $("tgt").value = newest;
      for (const c of State.channels) {
        $("chan").value = c.name;
        render();
        if (!$("resultBody").innerHTML.trim()) {
          throw new Error("empty result on channel " + c.name);
        }
      }
      rec.ok = true;
    } catch (err) {
      rec.error = (err && err.message) || String(err);
    }
    results.push(rec);
  }

  // Known-good assertion: rhods 2.19.3 -> 2.25.12 on stable is 2 hops via 2.22.0.
  try {
    if (OPERATORS.some(o => o.name === "rhods-operator")) {
      await selectOperator("rhods-operator");
      $("src").value = "rhods-operator.2.19.3";
      $("tgt").value = "rhods-operator.2.25.12";
      $("chan").value = "stable";
      render();
      const txt = $("resultBody").textContent.replace(/\s+/g, " ");
      golden = {
        ran: true,
        hop1: /2\.19\.3\s*→\s*2\.22\.0/.test(txt),
        hop2: /2\.22\.0\s*→\s*2\.25\.12/.test(txt),
        steps2: /Upgrade steps\s*2/.test(txt)
      };
    }
  } catch (err) {
    golden = { ran: true, error: (err && err.message) || String(err) };
  }

  e2eFinish({ total: OPERATORS.length, tested: results.length,
              errors: window.__e2e.errors, golden, results });
}).catch(err => {
  e2eFinish({ total: 0, tested: 0, bootError: (err && err.message) || String(err),
              errors: window.__e2e.errors, results: [] });
});
'''

if "\nboot();" not in page:
    sys.exit("could not find the boot() call to hook into")
open(dst, "w", encoding="utf-8").write(page.replace("\nboot();", "\n" + driver, 1))
PYEOF

  if [ ! -f "$WEBROOT/_e2e.html" ]; then
    bad "could not build the browser harness"
  else
    info "driving $NOPS operators in one browser session (this takes a moment)..."
    PROFILE="$TMP/chrome-profile"
    "$BROWSER" --headless --disable-gpu --no-sandbox --no-first-run \
      --user-data-dir="$PROFILE" --virtual-time-budget=600000 \
      --dump-dom "$BASE/_e2e.html" >"$TMP/dom.html" 2>"$TMP/chrome.log"

    python3 -I - "$TMP/dom.html" >"$TMP/report.txt" 2>&1 <<'PYEOF'
import json, re, sys, html
dom = open(sys.argv[1], encoding="utf-8", errors="replace").read()
m = re.search(r'<pre id="e2e-result">(.*?)</pre>', dom, re.S)
if not m:
    print("RESULT|none")
    raise SystemExit(0)
data = json.loads(html.unescape(m.group(1)))
if data.get("bootError"):
    print("RESULT|boot|%s" % data["bootError"]); raise SystemExit(0)
failed = [r for r in data["results"] if not r.get("ok")]
print("RESULT|ok|%d|%d|%d" % (data["total"], data["tested"], len(failed)))
for r in failed[:15]:
    print("OPFAIL|%s|%s" % (r["name"], r.get("error", "unknown")))
for e in data.get("errors", [])[:10]:
    print("JSERR|%s" % e)
g = data.get("golden", {})
if g.get("ran"):
    print("GOLDEN|%s|%s|%s|%s" % (g.get("hop1"), g.get("hop2"), g.get("steps2"), g.get("error", "")))
tot = sum(r.get("versions", 0) for r in data["results"])
print("TOTALVERSIONS|%d" % tot)
PYEOF

    RLINE=$(grep '^RESULT|' "$TMP/report.txt" | head -1)
    case "$RLINE" in
      RESULT\|none)
        bad "page produced no result -- it may have crashed or timed out"
        grep -iE 'error|severe' "$TMP/chrome.log" | head -5 | sed 's/^/        /'
        ;;
      RESULT\|boot\|*)
        bad "boot() failed: ${RLINE#RESULT|boot|}"
        ;;
      RESULT\|ok\|*)
        TOT=$(printf '%s' "$RLINE" | cut -d'|' -f3)
        TESTED=$(printf '%s' "$RLINE" | cut -d'|' -f4)
        NF=$(printf '%s' "$RLINE" | cut -d'|' -f5)
        TV=$(grep '^TOTALVERSIONS|' "$TMP/report.txt" | cut -d'|' -f2)

        if [ "$TESTED" -eq "$TOT" ] && [ "$TOT" -gt 0 ]; then
          ok "all $TOT operators were loaded and rendered"
        else
          bad "only $TESTED of $TOT operators were exercised (run cut short)"
        fi

        if [ "$NF" -eq 0 ]; then
          ok "no operator crashed the page"
          info "exercised $TV versions across $TOT operators"
        else
          bad "$NF operator(s) failed"
          grep '^OPFAIL|' "$TMP/report.txt" \
            | sed 's/^OPFAIL|/        /' | sed 's/|/: /'
        fi

        if grep -q '^JSERR|' "$TMP/report.txt"; then
          bad "uncaught JavaScript errors on the page"
          grep '^JSERR|' "$TMP/report.txt" | head -5 | sed 's/^JSERR|/        /'
        else
          ok "no uncaught JavaScript errors"
        fi

        GLINE=$(grep '^GOLDEN|' "$TMP/report.txt" | head -1)
        if [ -n "$GLINE" ]; then
          H1=$(printf '%s' "$GLINE" | cut -d'|' -f2)
          H2=$(printf '%s' "$GLINE" | cut -d'|' -f3)
          S2=$(printf '%s' "$GLINE" | cut -d'|' -f4)
          if [ "$H1" = "True" ] && [ "$H2" = "True" ] && [ "$S2" = "True" ]; then
            ok "known path correct: rhods 2.19.3 -> 2.22.0 -> 2.25.12 on stable (2 steps)"
          else
            bad "known path wrong: rhods 2.19.3 -> 2.25.12 on stable (hop1=$H1 hop2=$H2 steps=$S2)"
          fi
        else
          skip "known-path assertion did not run (rhods-operator not in catalog)"
        fi
        ;;
      *)
        bad "could not parse the browser report"
        head -5 "$TMP/report.txt" | sed 's/^/        /'
        ;;
    esac
  fi
fi

# ======================================================================
head2 "summary"
# ======================================================================

say "  passed : $PASS"
say "  failed : $FAIL"
say "  skipped: $SKIP"

if [ "$FAIL" -gt 0 ]; then
  say ""
  say "failed checks:$FAILED_NAMES"
  say ""
  say "RESULT: FAIL"
  exit 1
fi

say ""
say "RESULT: PASS"
exit 0
