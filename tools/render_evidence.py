"""Renders excerpts of the captured psql output (evidence/*.txt) to PNG images with headless Chrome.
These are renders of the real captured text, not live terminal screenshots.
Usage: python tools/render_evidence.py   (needs Google Chrome; run db/run_proof.sh first)"""
import html, pathlib, re, subprocess, sys, tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
EV, OUT = ROOT / "evidence", ROOT / "evidence" / "screenshots"
CHROME = next((p for p in [r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                           r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"] if pathlib.Path(p).exists()), None)
OUT.mkdir(parents=True, exist_ok=True)

def clean(lines):
    keep = []
    for l in lines:
        l = re.sub(r"^psql:[^ ]+ ", "", l.rstrip("\n"))
        if l.startswith(("LOCATION:", "SELECT set_config", "\\")): continue
        keep.append(l)
    while keep and not keep[0].strip(): keep.pop(0)
    while keep and not keep[-1].strip(): keep.pop()
    return [l for i, l in enumerate(keep) if l.strip() or (i and keep[i-1].strip())]

def sections(path, marker):
    cur, out = None, {}
    for l in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if l.startswith(marker): cur = l; out[cur] = []
        elif cur: out[cur].append(l)
    return out

def render(name, title, lines):
    width = min(2200, max(900, 9 * max((len(l) for l in lines), default=80) + 70))
    height = 40 + 21 * (len(lines) + 3)
    body = "\n".join(html.escape(l) for l in lines)
    page = f"""<!doctype html><meta charset=utf-8><body style="margin:0;background:#0f1419">
<div style="padding:14px 18px;font:13px/21px Consolas,'Cascadia Mono',monospace;color:#d4d7da;white-space:pre">
<span style="color:#7fd1b9">$ {html.escape(title)}</span>
{body.replace('ERROR', '<b style="color:#ff6b6b">ERROR</b>')}</div>"""
    page = page.replace("&lt;b", "<b").replace("&lt;/b&gt;", "</b>")
    with tempfile.TemporaryDirectory() as td:
        f = pathlib.Path(td) / "e.html"; f.write_text(page, encoding="utf-8")
        subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--window-size={width},{height}",
                        f"--screenshot={OUT / (name + '.png')}", f.as_uri()], check=True, capture_output=True)
    print("wrote", OUT / (name + ".png"))

inv = sections(EV / "30_invalid_inserts.txt", "################")
def pick(key): return next(v for k, v in inv.items() if key in k)
render("violation_1_oversell", "psql duka_task3 -f proof/30_invalid_inserts.sql   # REQUIRED 1: oversell", clean(pick("REQUIRED 1")))
render("violation_2_review_without_completed_order", "psql duka_task3 -f proof/30_invalid_inserts.sql   # REQUIRED 2: review on a paid (not completed) order", clean(pick("REQUIRED 2")))
render("violation_3_illegal_transition", "psql duka_task3 -f proof/30_invalid_inserts.sql   # REQUIRED 3: completed -> shipped", clean(pick("REQUIRED 3")))
extra = []
for k in ("EXTRA 4", "EXTRA 5", "EXTRA 7"): extra += ["# " + next(kk for kk in inv if k in kk).strip("# ")] + clean(pick(k)) + [""]
render("violation_extras_cancelled_to_paid_shipped_to_cancelled_double_payment", "psql ... # extra rejections", extra)

plans = sections(EV / "20_query_plans.txt", "########")
def plan(key): return next(v for k, v in plans.items() if key in k)
render("plan_1_search_gin", "EXPLAIN (ANALYZE, BUFFERS) keyword search  (200k listings)", clean(plan("PLAN 1")))
render("plan_2_seller_queue", "EXPLAIN (ANALYZE, BUFFERS) seller fulfilment queue  (power seller, 60k orders)", clean(plan("PLAN 2")))
render("plan_counterfactual_without_indexes", "same two queries with their indexes dropped (rolled back)", clean(plan("COUNTERFACTUAL")))
render("erasure", "psql ... -f proof/40_erasure.sql", clean((EV / "40_erasure.txt").read_text(encoding="utf-8").splitlines()))
render("late_capture_cancelled_to_paid", "psql ... -f proof/50_late_capture.sql", clean((EV / "50_late_capture.txt").read_text(encoding="utf-8").splitlines()))
