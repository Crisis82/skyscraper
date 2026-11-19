"""
benchmark and logging
"""

import os, sys

SKY_DIR = globals().get("SKY_DIR") or os.path.dirname(
    os.path.dirname(os.path.abspath(sys.argv[0]))
)
load(os.path.join(SKY_DIR, "tests", "common.sage"))

import contextlib, glob, io, json, shutil, signal, subprocess, tempfile, time

OUT = tempfile.mkdtemp(prefix="sky_bench_test_")
MAIN = os.path.join(SKY_DIR, "main.sage")


def quiet_bench(*args, **kwargs):
    with contextlib.redirect_stdout(io.StringIO()) as output:
        run_bench(*args, out=OUT, **kwargs)
    return output.getvalue()


def results_of(**kwargs):
    return ResultStore(
        store_path(
            kwargs.get("model", "reduced"),
            kwargs.get("order", "ranked"),
            kwargs.get("workers", 1),
            kwargs.get("tag"),
            OUT,
        )
    ).load()[1]


def _environment(*changes):
    environment = dict(os.environ)
    for change in changes:
        environment.update(change)
    return environment


def sage_main(args, **env):
    return subprocess.run(
        ["sage", MAIN] + args,
        capture_output=True,
        text=True,
        env=_environment({"SKY_LOG": "info"}, env),
    )


print("planning")
counts = {3: 2, 9: 1}
check(
    "repeats are totals, done in passes",
    planned_runs([3, 9, 12], 3, counts)
    == [(12, 0), (9, 1), (12, 1), (3, 2), (9, 2), (12, 2)],
)
drawn = target_values("random", 10, counts, random.Random(int(1)))
check(
    "random: earlier values kept, distinct, topped up to the total",
    drawn[:2] == [3, 9] and len(set(drawn)) == 10 and all(0 <= v < P for v in drawn),
)
check(
    "random: no new values once the total is reached",
    target_values("random", 2, counts, random.Random()) == [3, 9],
)
everything = target_values("all", None, counts, random.Random())
check("all: every value exactly once", sorted(everything) == list(range(P)))
check("all: not in increasing order", everything[2:] != sorted(everything[2:]))
check(
    "random: seed reproduces the choice",
    target_values("random", 8, {}, random.Random(int(5)))
    == target_values("random", 8, {}, random.Random(int(5))),
)

print("specific values and repeats")
quiet_bench([5, 17], repeats=3, tag="a")
rows = results_of(tag="a")
check(
    "3 repeats of 2 values give 6 runs",
    len(rows) == 6 and run_counts(rows) == {5: 3, 17: 3},
)
before = open(store_path("reduced", "ranked", 1, "a", OUT)).read()
quiet_bench([5, 17], repeats=3, tag="a")
check(
    "the same command again runs nothing",
    open(store_path("reduced", "ranked", 1, "a", OUT)).read() == before,
)
quiet_bench([5, 17], repeats=5, tag="a")
after = open(store_path("reduced", "ranked", 1, "a", OUT)).read()
check(
    "raising repeats appends and keeps earlier data",
    after.startswith(before) and len(results_of(tag="a")) == 10,
)
needed = {
    "xR0",
    "repeat",
    "found",
    "solution",
    "tried",
    "space",
    "ratio",
    "gb_calls",
    "shapes",
    "seconds",
    "cpu_seconds",
    "max_rss_kb",
    "time",
}
check("every record has all fields", all(needed <= set(r) for r in results_of(tag="a")))
check(
    "session records state how the data was made",
    {"commit", "dirty", "host", "sage", "gb", "command"}
    <= set(ResultStore(store_path("reduced", "ranked", 1, "a", OUT)).load()[0][0]),
)
check(
    "a stored time is in seconds and positive",
    all(r["seconds"] > 0 and r["cpu_seconds"] >= 0 for r in results_of(tag="a")),
)

print("random and all")
quiet_bench("random", 5, tag="b")
first = list(run_counts(results_of(tag="b")))
quiet_bench("random", 8, tag="b")
second = list(run_counts(results_of(tag="b")))
check(
    "count is a total over all sessions",
    len(first) == 5 and len(second) == 8 and second[:5] == first,
)
quiet_bench("all", tag="b")
check(
    "values=all completes it without repeating a value",
    sorted(run_counts(results_of(tag="b"))) == list(range(P))
    and len(results_of(tag="b")) == P,
)
check(
    "every run of the p=37 sweep found a pre-image",
    all(r["found"] for r in results_of(tag="b")),
)
summary = summarize(results_of(tag="b"))
quiet_bench("all", order="lexicographic", tag="b")
lex = summarize(results_of(order="lexicographic", tag="b"))
check(
    "lexicographic sweep gives the known mean ratio",
    abs(lex["ratio_pct"]["mean"] - 19.14) < 0.01,
    f"{lex['ratio_pct']['mean']:.2f}%",
)
check(
    "options use separate files, no mixing",
    store_path("reduced", "ranked", 1, None, OUT)
    != store_path("reduced", "ranked", 2, None, OUT)
    != store_path("reduced", "lexicographic", 1, None, OUT),
)
quiet_bench([5, 17], workers=2, order="lexicographic", tag="c")
quiet_bench([5, 17], order="lexicographic", tag="c")
check(
    "workers=2 stores the same trail counts as sequential",
    [r["tried"] for r in results_of(workers=2, order="lexicographic", tag="c")]
    == [r["tried"] for r in results_of(order="lexicographic", tag="c")],
)
check(
    "worker CPU time is counted",
    any(
        r["cpu_seconds"] > 0
        for r in results_of(workers=2, order="lexicographic", tag="c")
    ),
)

print("summaries")


def fake(x, seconds, tried=10, found=True):
    seconds = float(seconds)  # as in records loaded from JSON
    return {
        "xR0": int(x),
        "seconds": seconds,
        "cpu_seconds": seconds,
        "ratio": float(tried) / float(100),
        "tried": int(tried),
        "found": found,
        "solution": int(x) if found else None,
    }


s = summarize([fake(1, 1.0)] * 9 + [fake(2, 3.0)])
check(
    "repeating one value does not bias the mean",
    abs(s["seconds"]["mean"] - 2.0) < 1e-9 and s["values"] == 2 and s["runs"] == 10,
)
s = summarize(
    [fake(1, 1.0, 20), fake(2, 1.0, 5), fake(3, 1.0, 50, False), fake(4, 1.0, 10)]
)
check(
    "thresholds and success share",
    s["ratio_le10_pct"] == 50 and s["ratio_le20_pct"] == 75 and s["success_pct"] == 75,
)
check(
    "varying trail counts are flagged",
    summarize([fake(1, 1.0, 10), fake(1, 1.0, 11)])["values_with_varying_tried"] == 1,
)
check(
    "a single run does not crash the summary",
    summarize([fake(1, 1.0)])["seconds"]["stdev"] == 0,
)
check("no preparser damage in the report text", "_sage_const" not in format_summary(s))

print("optional: time limit")
quiet_bench([5, 17], order="lexicographic", timeout=30, tag="t")
limited = results_of(order="lexicographic", tag="t")
check(
    "a generous limit changes nothing",
    [r["tried"] for r in limited]
    == [r["tried"] for r in results_of(order="lexicographic", tag="c")]
    and all(r["max_rss_kb"] > 0 and r["cpu_seconds"] > 0 for r in limited),
)
t0 = time.time()
quiet_bench([5, 17], model="lagrange", timeout=2, tag="t")
timed = results_of(model="lagrange", tag="t")
check(
    "a run over the limit is stopped and recorded",
    time.time() - t0 < 30
    and len(timed) == 2
    and all(r["timed_out"] and r["time_limit"] == 2 for r in timed),
)
check("no process left behind by the limit", not mp.active_children())
check(
    "timed-out runs are done for an equal or lower limit",
    run_counts(timed, 2) == {5: 1, 17: 1} and run_counts(timed, 1) == {5: 1, 17: 1},
)
check(
    "timed-out runs are retried with a higher limit or none",
    run_counts(timed, 3) == {5: 0, 17: 0} and run_counts(timed) == {5: 0, 17: 0},
)
s = summarize(timed)
check(
    "a report with only timed-out runs works",
    s["runs"] == 0 and s["timed_out_values"] == 2 and "timed out" in format_summary(s),
)
quiet_bench([5, 17], model="lagrange", timeout=2, tag="t")
check(
    "rerunning with the same limit runs nothing",
    len(results_of(model="lagrange", tag="t")) == 2,
)
s = summarize(
    [
        fake(1, 1.0),
        fake(2, 3.0),
        {
            "xR0": 3,
            "found": False,
            "solution": None,
            "timed_out": True,
            "time_limit": 9,
            "seconds": 9.0,
        },
    ]
)
check(
    "the means leave out timed-out values; success counts them as unsolved",
    s["seconds"]["mean"] == 2
    and s["values"] == 2
    and abs(s["success_pct"] - float(200) / 3) < 1e-9,
)
s = summarize(
    [
        {
            "xR0": 1,
            "found": False,
            "solution": None,
            "timed_out": True,
            "time_limit": 1,
            "seconds": 1.0,
        },
        fake(1, 5.0),
    ]
)
check(
    "a later finished run replaces a timed-out one",
    s["timed_out_values"] == 0 and s["success_pct"] == 100,
)
check(
    "a crash under a limit raises WorkerError",
    raises(
        WorkerError,
        lambda: _measure_limited(30, "not a value", "reduced", "ranked", 1, False),
    ),
)

print("optional: same values, details")
source = store_path("reduced", "ranked", 1, "b", OUT)
quiet_bench("from:" + source, 6, order="lexicographic", tag="same")
check(
    "from:file reuses the values of another file, up to count",
    list(run_counts(results_of(order="lexicographic", tag="same")))
    == list(run_counts(results_of(tag="b")))[:6],
)
check(
    "from:file rejects an empty file",
    raises(ValueError, lambda: run_bench("from:" + source + ".missing")),
)
plain = results_of(tag="a")[0]
check("details are off by default", "trail" not in plain and "gb_seconds" not in plain)
quiet_bench([6, 8], details=True, order="lexicographic", tag="det")
detailed = results_of(order="lexicographic", tag="det")
check(
    "details=1 saves the solving trail",
    all(len(r["trail"]) == BARS and len(r["trail"][0]) == M for r in detailed),
)
check(
    "the saved trail really has the solution",
    all(
        solve_trail(
            _system("reduced"), digest(r["xR0"]), tuple(tuple(c) for c in r["trail"])
        )[0]
        is not None
        for r in detailed
    ),
)
check(
    "details=1 saves the seconds per basis shape",
    all(set(r["gb_seconds"]) == set(r["shapes"]) for r in detailed)
    and summarize(detailed)["gb_ms"]["unit"] > 0,
)
quiet_bench([6, 8], details=True, workers=2, order="lexicographic", tag="det")
check(
    "parallel details give the same trail",
    [r["trail"] for r in results_of(workers=2, order="lexicographic", tag="det")]
    == [r["trail"] for r in detailed],
)

print("machine record")
session = ResultStore(store_path("reduced", "ranked", 1, "a", OUT)).load()[0][0]
check(
    "sessions record the machine conditions",
    {"host", "cpu_model", "cpu_count", "cpu_affinity", "load_average", "cpu_governor"}
    <= set(session),
)
check("every run records the load", all("load" in r for r in results_of(tag="a")))

print("report and several instances")
export_dir = os.path.join(OUT, "export")
with contextlib.redirect_stdout(io.StringIO()):
    report(OUT)
import csv

rows = list(csv.DictReader(open(os.path.join(export_dir, "runs.csv"))))
check(
    "runs.csv has every run of every file",
    len(rows)
    == sum(
        len(ResultStore(p).load()[1])
        for p in glob.glob(os.path.join(OUT, "*", "*.jsonl"))
    ),
)
summary_rows = list(csv.DictReader(open(os.path.join(export_dir, "summary.csv"))))
check(
    "summary.csv has the known mean ratio",
    any(
        r["config"].endswith("lexicographic_workers1_libsingular-slimgb_b")
        and abs(float(r["ratio_mean_pct"]) - 19.14) < 0.01
        for r in summary_rows
    ),
)
tex = open(os.path.join(export_dir, "tables.tex")).read()
check(
    "tables.tex has both tables, without preparser damage",
    "Solving times." in tex
    and "Combination ratios." in tex
    and "_sage_const" not in tex,
)
check("histograms are written", len(glob.glob(os.path.join(export_dir, "*.png"))) > 0)
before = {p: open(p).read() for p in glob.glob(os.path.join(OUT, "*", "*.jsonl"))}
with contextlib.redirect_stdout(io.StringIO()):
    report(OUT)
check(
    "export leaves the result files untouched",
    all(open(p).read() == c for p, c in before.items()),
)
sweep_out = os.path.join(OUT, "sweep")
done_sweep = sage_main(
    ["bench", "primes=37,109", "values=3,4", f"out={sweep_out}"], SKY_LOG="warning"
)
check(
    "primes= runs each instance in its own process",
    done_sweep.returncode == 0
    and all(
        os.path.exists(
            os.path.join(
                sweep_out,
                f"p{p}_R6_omega4",
                "reduced_ranked_workers1_libsingular-slimgb.jsonl",
            )
        )
        for p in (37, 109)
    ),
)
bad_sweep = sage_main(
    ["bench", "primes=37,4", "values=3,4", f"out={sweep_out}x"], SKY_LOG="warning"
)
check(
    "primes= validates all instances before starting",
    bad_sweep.returncode != 0 and not os.path.exists(sweep_out + "x"),
)

print("optional: log file")
log_path = os.path.join(OUT, "run.log")
logged = sage_main(
    ["attack", "xR0=11", "order=lexicographic"],
    SKY_LOG="warning",
    SKY_P="37",
    SKY_ROUNDS="6",
    SKY_LOG_FILE=log_path,
)
content = open(log_path).read()
check(
    "the log file has debug detail while the console stays quiet",
    "solve_trail(" in content
    and "solve_trail(" not in logged.stderr
    and logged.stderr == "",
)
sage_main(
    ["attack", "xR0=11", "order=lexicographic"],
    SKY_LOG="warning",
    SKY_P="37",
    SKY_ROUNDS="6",
    SKY_LOG_FILE=log_path,
)
check(
    "the log file is appended to",
    open(log_path).read().startswith(content)
    and len(open(log_path).read()) > len(content),
)

print("damaged and concurrent files")
path = store_path("reduced", "ranked", 1, "d", OUT)
quiet_bench([5], tag="d")
good = open(path).read()
with open(path, "a") as f:
    f.write('{"type": "result", "xR0": 9, "secon')
quiet_bench([5, 17], tag="d")
content = open(path).read()
check(
    "a cut last line is kept, skipped, and not joined to new data",
    content.startswith(good)
    and ResultStore(path).load()[2] == 1
    and run_counts(results_of(tag="d")) == {5: 1, 17: 1},
)
with ResultStore(path):
    check(
        "a second writer on the same file is refused",
        raises(RuntimeError, lambda: quiet_bench([5, 17], repeats=2, tag="d")),
    )

print("bad options")
for name, call in [
    ("out-of-range value", lambda: run_bench([P])),
    ("repeated value", lambda: run_bench([1, 1])),
    ("unknown mode", lambda: run_bench("some")),
    ("unknown model", lambda: run_bench("random", model="x")),
    ("unknown order", lambda: run_bench("random", order="x")),
    ("no repeats", lambda: run_bench("random", repeats=0)),
    ("count with a list", lambda: run_bench([1], 3)),
]:
    check(f"rejected: {name}", raises(ValueError, call))

print("interruption (real processes)")
env = {"SKY_P": "587", "SKY_ROUNDS": "6"}
args = [
    "bench",
    "values=random",
    "count=500",
    "order=lexicographic",
    "tag=kill",
    f"out={OUT}",
]
worker_path = os.path.join(
    OUT,
    "p587_R6_omega4",
    "reduced_lexicographic_workers1_libsingular-slimgb_kill.jsonl",
)
process = subprocess.Popen(
    ["sage", MAIN] + args,
    env=_environment(env),
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
time.sleep(15)
process.send_signal(signal.SIGKILL)
process.wait()


def read_lines(p):
    return [json.loads(line) for line in open(p) if line.strip()]


records = [r for r in read_lines(worker_path) if r["type"] == "result"]
saved = [r["xR0"] for r in records]
check("kill -9: finished runs are on disk", len(saved) > 0, f"{len(saved)} runs")
args[2] = f"count={len(saved) + 1}"
resumed = sage_main(args, **env)
records = [r for r in read_lines(worker_path) if r["type"] == "result"]
check(
    "resume keeps them and runs only the new value",
    resumed.returncode == 0
    and [r["xR0"] for r in records][: len(saved)] == saved
    and len(records) == len(saved) + 1
    and len(set(r["xR0"] for r in records)) == len(records),
)

process = subprocess.Popen(
    ["sage", MAIN] + args[:2] + ["count=500"] + args[3:],
    env=_environment(env),
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
)
time.sleep(10)
process.send_signal(signal.SIGINT)
output, errors = process.communicate(timeout=60)
check(
    "Ctrl-C: exits cleanly with a report",
    process.returncode == 0 and "comb. ratio" in output,
    f"exit {process.returncode}",
)

print("logging")
run = lambda level: sage_main(
    ["attack", "xR0=11", "order=lexicographic"],
    SKY_LOG=level,
    SKY_P="37",
    SKY_ROUNDS="6",
)
error, warning, normal, debug, full = [
    run(l) for l in ("error", "warning", "info", "debug", "trace")
]
check(
    "every level leaves the result on stdout",
    all(
        "AttackResult(" in r.stdout and "solution=11" in r.stdout
        for r in (error, warning, normal, debug, full)
    ),
)
check(
    "error and warning levels show nothing else on stderr",
    error.stderr == "" and warning.stderr == "",
)
check(
    "info shows the outcome, without per-call lines",
    "[+]" in normal.stderr and "solve_trail" not in normal.stderr,
)
check(
    "debug traces calls automatically",
    "solve_trail(" in debug.stderr
    and "groebner_basis(" in debug.stderr
    and "equations:" not in debug.stderr,
)
check(
    "trace also shows equations and bases",
    "equations:" in full.stderr and "basis:" in full.stderr,
)
check(
    "a parallel run reports from workers at debug level",
    "worker "
    in sage_main(
        ["attack", "xR0=11", "workers=2"], SKY_LOG="debug", SKY_P="37", SKY_ROUNDS="6"
    ).stderr,
)
check(
    "an invalid level is rejected",
    sage_main(["report", f"out={OUT}"], SKY_LOG="loud").returncode != 0,
)
print("command line")
check("no command prints the usage", "sage main.sage attack" in sage_main([]).stderr)
check(
    "an unknown option names the problem",
    "unexpected keyword argument 'colour'"
    in sage_main(["attack", "colour=red"]).stderr,
)
check(
    "a single value works like a list",
    sage_main(["bench", "values=5", f"out={OUT}", "tag=one"], SKY_P="37").returncode
    == 0,
)

shutil.rmtree(OUT)
finish()
