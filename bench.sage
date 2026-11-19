"""
repeatable measurements of the attack

  sage main.sage bench values=5,17 repeats=10    specific values
  sage main.sage bench values=random count=50    random distinct values
  sage main.sage bench values=all                every value of [0, p-1], in random order
  sage main.sage bench values=from:file count=50 the values of another result file
  sage main.sage bench primes=37,109,163 ...     the same command for several instances
  sage main.sage report                          summaries of all results, and CSV, LaTeX
                                                 tables and histograms in results/export/

Other options: model, order, workers, seed, tag (keeps a separate series), out (directory),
rounds and bits (with primes; otherwise the instance comes from SKY_P, SKY_ROUNDS, SKY_BITS).
Optional measurements:
  timeout=seconds  stop a run at this limit and record it as timed out; such a run is
                   retried only by a command with a higher limit, or with none
  details=1        also save the solving trail and the seconds per basis shape

Each configuration has one append-only JSON-lines file, written and synced after
every run, so an interruption loses at most the run in progress and earlier data
is never modified. count and repeats are totals, not increments: running the same
command again continues where it stopped, and raising either one adds only what
is missing. Repeats are done in passes over the values, so a partial run stays
balanced. The result files are only read by report; results/export/ is replaced.

For clean timings run one benchmark at a time on a pinned core: `taskset -c 2 sage main.sage bench ...`
"""

import csv, fcntl, gc, glob, json, platform, random, resource, statistics, subprocess
import sage.version
from datetime import datetime, timezone

PERCENT = float(100)  # Python floats: Sage reals do not serialize or format reliably


class ResultStore:
    """One append-only file of JSON records. Only one process may write to it."""

    def __init__(self, path):
        self.path = path
        self.file = None

    def load(self):
        """Returns (sessions, results, unreadable lines). The last line is unreadable
        if the process was killed while writing it."""
        sessions, results, errors, bad = [], [], [], 0
        if os.path.exists(self.path):
            with open(self.path) as f:
                for line in f:
                    try:
                        record = json.loads(line)
                        {"session": sessions, "result": results, "error": errors}[
                            record["type"]
                        ].append(record)
                    except (ValueError, KeyError, TypeError):
                        bad += 1
        return sessions, results, bad

    def __enter__(self):
        os.makedirs(os.path.dirname(self.path), exist_ok=True)
        self.file = open(self.path, "a+")
        try:
            fcntl.flock(self.file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.file.close()
            raise RuntimeError(f"another process is writing to {self.path}")
        size = self.file.seek(0, os.SEEK_END)
        if size:
            self.file.seek(size - 1)
            if self.file.read(1) != "\n":  # do not join a cut line to the next record
                self.file.write("\n")
        return self

    def __exit__(self, *exc):
        self.file.close()

    def append(self, record):
        self.file.write(json.dumps(record) + "\n")
        self.file.flush()
        os.fsync(self.file.fileno())


def results_root(out=None):
    return out or os.path.join(SKY_DIR, "results")


def instance_dir(out=None):
    return os.path.join(results_root(out), f"p{P}_R{ROUNDS}_omega{BITS}")


def store_path(model, order, workers, tag=None, out=None):
    parts = (
        [model]
        + ([order] if model == "reduced" else [])
        + [f"workers{workers}", GB_ALG.replace(":", "-")]
    )
    return os.path.join(
        instance_dir(out), "_".join(parts + ([tag] if tag else [])) + ".jsonl"
    )


def run_counts(results, time_limit=None):
    """value of finished runs, in order of first appearance."""
    counts = {}
    for r in results:
        stands = not r.get("timed_out") or (
            time_limit is not None and r["time_limit"] >= time_limit
        )
        counts[r["xR0"]] = counts.get(r["xR0"], 0) + int(bool(stands))
    return counts


def values_from_file(path, count=None):
    """The distinct values of a result file, so that two configurations can be compared on the same instances."""
    sessions, results, _ = ResultStore(path).load()
    if not results:
        raise ValueError(f"no results in {path}")
    if any(s["P"] != P for s in sessions):
        raise ValueError(f"{path} was measured for another prime")
    values = list(run_counts(results))
    return values if count is None else values[:count]


def target_values(values, count, counts, rng):
    """The values a command asks for: earlier values first, topped up with new
    random ones. values is a list, "random" or "all"."""
    if isinstance(values, list):
        return values
    p = int(P)
    wanted = p if values == "all" else min(count, p)
    if len(counts) >= wanted:
        return list(counts)[:wanted]
    drawn = rng.sample(range(p), min(p, wanted + len(counts)))
    return list(counts) + [v for v in drawn if v not in counts][: wanted - len(counts)]


def planned_runs(targets, repeats, counts):
    """(value, repeat index) still missing, one pass over the values per repeat."""
    return [(v, r) for r in range(repeats) for v in targets if counts.get(v, 0) <= r]


def _git_state():
    def git(*args):
        return subprocess.run(
            ["git", "-C", SKY_DIR] + list(args), capture_output=True, text=True
        ).stdout.strip()

    try:
        return git("rev-parse", "--short", "HEAD") or None, bool(
            git("status", "--porcelain")
        )
    except OSError:
        return None, None


def _read_first_line(path, default=None):
    try:
        with open(path) as f:
            return f.readline().strip()
    except OSError:
        return default


def machine_state():
    cpu_model = None
    try:
        with open("/proc/cpuinfo") as f:
            cpu_model = next(
                (
                    line.split(":", 1)[1].strip()
                    for line in f
                    if line.startswith("model name")
                ),
                None,
            )
    except OSError:
        pass
    return {
        "host": platform.node(),
        "cpu_model": cpu_model or platform.processor(),
        "cpu_count": os.cpu_count(),
        "cpu_affinity": sorted(os.sched_getaffinity(0)),
        "load_average": os.getloadavg()[0],
        "cpu_governor": _read_first_line(
            "/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor"
        ),
        "sage": sage.version.version,
        "python": platform.python_version(),
    }


def _now():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _cpu_seconds():
    """User and system time of this process and its finished workers."""
    total = float(0)
    for who in (resource.RUSAGE_SELF, resource.RUSAGE_CHILDREN):
        usage = resource.getrusage(who)
        total += usage.ru_utime + usage.ru_stime
    return total


def _measure(x, model, order, workers, details):
    """One attack as the fields of a result record."""
    gc.collect()
    cpu = _cpu_seconds()
    r = attack(x, model, order, workers)
    record = {
        "xR0": int(x),
        "found": r.found,
        "solution": None if r.solution is None else int(r.solution),
        "tried": int(r.tried),
        "space": int(r.space),
        "ratio": r.ratio,
        "gb_calls": int(r.gb_calls),
        "shapes": {k: int(v) for k, v in r.shapes.items()},
        "seconds": r.time,
        "cpu_seconds": _cpu_seconds() - cpu,
        "max_rss_kb": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
    }
    if details:
        record["trail"] = (
            None if r.trail is None else [[int(k) for k in case] for case in r.trail]
        )
        record["gb_seconds"] = {k: float(v) for k, v in r.shape_seconds.items()}
    return record


def _measure_child(conn, args):
    signal.signal(signal.SIGINT, signal.SIG_IGN)  # the parent handles Ctrl-C
    die_with_parent()
    quiet_progress()
    try:
        conn.send(("ok", _measure(*args)))
    except Exception:
        conn.send(("error", traceback.format_exc()))


def _measure_limited(time_limit, *args):
    """_measure in a child process, because only killing a process reliably stops a GB computation.
    Returns None if the limit is reached. The child's own workers die with it through die_with_parent.
    """
    ctx = mp.get_context("fork")
    parent_end, child_end = ctx.Pipe()
    child = ctx.Process(target=_measure_child, args=(child_end, args))
    try:
        child.start()
        child_end.close()
        deadline = time.monotonic() + time_limit
        while time.monotonic() < deadline:
            ready = wait([parent_end, child.sentinel], timeout=0.1)
            tick()
            if parent_end in ready:
                try:
                    status, value = parent_end.recv()
                except EOFError:
                    break
                if status == "error":
                    raise WorkerError(value)
                return value
            if child.sentinel in ready:
                break
        else:
            return None
        child.join()
        raise WorkerError(f"measuring process died with exit code {child.exitcode}")
    finally:
        if child.pid is not None:
            child.kill()
            child.join()
            child.close()
        parent_end.close()
        child_end.close()


def run_bench(
    values="random",
    count=None,
    repeats=1,
    model="reduced",
    order="ranked",
    workers=1,
    seed=None,
    tag=None,
    out=None,
    timeout=None,
    details=False,
    primes=None,
    rounds=None,
    bits=None,
):
    if primes is not None:
        return _sweep(
            primes,
            rounds,
            bits,
            {
                "values": values,
                "count": count,
                "repeats": repeats,
                "model": model,
                "order": order,
                "workers": workers,
                "seed": seed,
                "tag": tag,
                "out": out,
                "timeout": timeout,
                "details": details,
            },
        )
    if rounds is not None or bits is not None:
        raise ValueError(
            "rounds and bits go with primes; otherwise set SKY_ROUNDS and SKY_BITS"
        )
    if isinstance(values, (int, Integer)):
        values = [values]
    repeats, workers = int(repeats), int(workers)
    count = None if count is None else int(count)
    seed = None if seed is None else int(seed)
    timeout = None if timeout is None else float(timeout)
    command = {
        "values": values,
        "count": count,
        "repeats": repeats,
        "seed": seed,
        "timeout": timeout,
        "details": bool(details),
    }
    if isinstance(values, str) and values.startswith("from:"):
        values = values_from_file(values[len("from:") :], count)
        command["values_read"] = values
    elif isinstance(values, list):
        values = [int(v) for v in values]
        command["values"] = values
        if count is not None:
            raise ValueError("count does not apply to a list of values")
    elif values not in ("random", "all"):
        raise ValueError(
            "values must be random, all, from:<file> or a comma-separated list"
        )
    if isinstance(values, list) and (
        any(not 0 <= v < P for v in values) or len(set(values)) != len(values)
    ):
        raise ValueError(f"values must be distinct and in [0, {P - 1}]")
    if repeats < 1 or workers < 1:
        raise ValueError("repeats and workers must be positive")
    if timeout is not None and timeout <= 0:
        raise ValueError("timeout must be positive")
    if model not in ("reduced", "lagrange"):
        raise ValueError(f"unknown model: {model!r}")
    if order not in ("ranked", "lexicographic"):
        raise ValueError(f"unknown enumeration order: {order!r}")

    store = ResultStore(store_path(model, order, workers, tag, out))
    with store:
        _, results, bad = store.load()
        if bad:
            log.warning(
                f"{bad} unreadable line(s) in {store.path}: ignored, left in place"
            )
        counts = run_counts(results, timeout)
        rng = random.Random(seed)
        targets = target_values(values, 50 if count is None else count, counts, rng)
        runs = planned_runs(targets, repeats, counts)
        if not runs:
            log.info("nothing to do: this data is already complete")
            return print_report(store.path)

        machine = machine_state()
        if machine["load_average"] > 1.5:
            log.warning(
                f"load average is {machine['load_average']:.1f}: other processes may disturb the timings"
            )
        if log.isEnabledFor(logging.DEBUG):
            log.warning("debug logging is on: the timings include its cost")

        # Warm-up, so that setup cost does not land on the first measured run.
        setup_start = time.time()
        system = _system(model)
        if model == "reduced":
            solve_trail(system, digest(0), next(enumerate_trails(order)))
        commit, dirty = _git_state()
        session = {
            "type": "session",
            "time": _now(),
            "P": int(P),
            "ROUNDS": int(ROUNDS),
            "BITS": int(BITS),
            "M": int(M),
            "model": model,
            "order": order,
            "workers": workers,
            "gb": GB_ALG,
            "command": command,
            "planned": len(runs),
            "setup_seconds": time.time() - setup_start,
            "commit": commit,
            "dirty": dirty,
            "debug_logging": log.isEnabledFor(logging.DEBUG),
        }
        session.update(machine)
        store.append(session)
        log.info(
            f"saving to {store.path} ({len(results)} earlier runs kept, {len(runs)} to do)"
        )

        spent = float(0)
        try:
            with progress("bench", total=len(runs), unit="runs") as bar:
                for done, (x, repeat) in enumerate(runs):
                    args = (x, model, order, workers, details)
                    try:
                        record = (
                            _measure_limited(timeout, *args)
                            if timeout
                            else _measure(*args)
                        )
                    except WorkerError as e:
                        store.append(
                            {
                                "type": "error",
                                "time": _now(),
                                "xR0": int(x),
                                "message": str(e),
                            }
                        )
                        raise
                    if record is None:
                        log.warning(f"xR0={x}: stopped at the limit of {timeout:.0f}s")
                        record = {
                            "xR0": int(x),
                            "found": False,
                            "solution": None,
                            "timed_out": True,
                            "time_limit": timeout,
                            "seconds": timeout,
                        }
                    row = {
                        "type": "result",
                        "time": _now(),
                        "repeat": int(repeat),
                        "load": os.getloadavg()[0],
                    }
                    row.update(record)
                    store.append(row)
                    spent += record["seconds"]
                    left = spent / (done + 1) * (len(runs) - done - 1)
                    bar.update(
                        done + 1,
                        f"last {record['seconds']:.2f}s, about {left:.0f}s left",
                    )
        except KeyboardInterrupt:
            log.warning("interrupted: everything up to the last finished run is saved")
    return print_report(store.path)


def _as_list(value, default):
    value = default if value is None else value
    return [int(v) for v in value] if isinstance(value, list) else [int(value)]


def _sweep(primes, rounds, bits, options):
    """Runs the bench command once per instance, each in its own process because
    the parameters are fixed at load time. All instances are validated first."""
    instances = [
        (p, r, b)
        for p in _as_list(primes, None)
        for r in _as_list(rounds, 6)
        for b in _as_list(bits, 4)
    ]
    for p, r, b in instances:
        if (
            not Integer(p).is_prime()
            or p <= 2 ^ b
            or r not in BAR_ROUNDS_BY_R
            or b not in (4, 8)
        ):
            raise ValueError(f"invalid instance: p={p}, R={r}, omega={b}")
    defaults = {
        "values": "random",
        "repeats": 1,
        "model": "reduced",
        "order": "ranked",
        "workers": 1,
        "details": False,
    }
    arguments = [
        f"{k}="
        + (
            ",".join(map(str, v))
            if isinstance(v, list)
            else str(int(v) if isinstance(v, bool) else v)
        )
        for k, v in options.items()
        if v is not None and v != defaults.get(k)
    ]
    for i, (p, r, b) in enumerate(instances):
        log.info(f"sweep {i + 1}/{len(instances)}: p={p}, R={r}, omega={b}")
        environment = dict(os.environ, SKY_P=str(p), SKY_ROUNDS=str(r), SKY_BITS=str(b))
        try:
            finished = subprocess.run(
                ["sage", os.path.join(SKY_DIR, "main.sage"), "bench"] + arguments,
                env=environment,
            )
        except KeyboardInterrupt:
            log.warning("sweep interrupted: rerun the same command to continue")
            return
        if finished.returncode != 0:
            raise SystemExit(
                f"sweep stopped: p={p}, R={r}, omega={b} failed with exit code {finished.returncode}"
            )


# ------------------------------------------------------ summaries and export ---


def _spread(values):
    return {
        "mean": statistics.fmean(values),
        "median": statistics.median(values),
        "min": min(values),
        "max": max(values),
        "stdev": statistics.stdev(values) if len(values) > 1 else float(0),
    }


def summarize(results):
    """summary of the bench results"""
    completed = [r for r in results if not r.get("timed_out")]
    by_value = {}
    for r in completed:
        by_value.setdefault(r["xR0"], []).append(r)
    timed_out = [r for r in results if r.get("timed_out") and r["xR0"] not in by_value]
    summary = {
        "values": len(by_value),
        "runs": len(completed),
        "timed_out_runs": sum(bool(r.get("timed_out")) for r in results),
        "timed_out_values": len({r["xR0"] for r in timed_out}),
    }
    if not completed:
        return summary

    def per_value(field):
        return [
            statistics.fmean(run[field] for run in runs) for runs in by_value.values()
        ]

    n = len(by_value)
    seconds, ratios = per_value("seconds"), per_value("ratio")
    noise = [
        statistics.stdev(run["seconds"] for run in runs)
        for runs in by_value.values()
        if len(runs) > 1
    ]
    time_spread = _spread(seconds)
    gb_seconds, gb_counts = {}, {}
    for r in completed:
        for shape, value in r.get("gb_seconds", {}).items():
            gb_seconds[shape] = gb_seconds.get(shape, float(0)) + value
            gb_counts[shape] = gb_counts.get(shape, 0) + r["shapes"][shape]
    summary.update(
        {
            "success_pct": PERCENT
            * sum(r["found"] for r in completed)
            / (len(completed) + len(timed_out)),
            "other_preimage_pct": PERCENT
            * sum(r["found"] and r["solution"] != r["xR0"] for r in completed)
            / len(completed),
            "seconds": time_spread,
            "seconds_ci95": float(1.96) * time_spread["stdev"] / float(sqrt(n)),
            "cpu_seconds_mean": statistics.fmean(per_value("cpu_seconds")),
            "run_noise_seconds": statistics.fmean(noise) if noise else None,
            "tried_mean": statistics.fmean(per_value("tried")),
            "ratio_pct": {k: PERCENT * v for k, v in _spread(ratios).items()},
            "ratio_le10_pct": PERCENT * sum(x <= float(0.1) for x in ratios) / n,
            "ratio_le20_pct": PERCENT * sum(x <= float(0.2) for x in ratios) / n,
            "values_with_varying_tried": sum(
                len({run["tried"] for run in runs}) > 1 for runs in by_value.values()
            ),
            "gb_ms": {
                shape: 1000 * gb_seconds[shape] / gb_counts[shape]
                for shape in gb_seconds
            },
        }
    )
    return summary


def format_summary(s):
    lines = []
    if s["timed_out_runs"]:
        lines.append(
            f"  timed out: {s['timed_out_runs']} run(s), {s['timed_out_values']} value(s) never finished; "
            "the means below leave them out and so underestimate"
        )
    if not s["runs"]:
        return "\n".join(lines or ["  no finished runs"])
    t, q = s["seconds"], s["ratio_pct"]
    noise = (
        ""
        if s["run_noise_seconds"] is None
        else f"  (between repeats of a value: {s['run_noise_seconds']:.4f})"
    )
    lines += [
        f"  values {s['values']}, runs {s['runs']}, success {s['success_pct']:.1f}%, "
        f"solved by another pre-image {s['other_preimage_pct']:.1f}%",
        f"  seconds: mean {t['mean']:.4f} +- {s['seconds_ci95']:.4f}, median {t['median']:.4f}, "
        f"min {t['min']:.4f}, max {t['max']:.4f}{noise}",
        f"  cpu seconds: mean {s['cpu_seconds_mean']:.4f}",
        f"  trails tried: mean {s['tried_mean']:.1f}",
        # Plain strings here: the preparser rewrites numbers in f-string text.
        f"  comb. ratio: mean {q['mean']:.2f}%, median {q['median']:.2f}%, "
        + "solved within 10% of the space: "
        + f"{s['ratio_le10_pct']:.1f}%, "
        + "within 20%: "
        + f"{s['ratio_le20_pct']:.1f}%",
    ]
    if s["gb_ms"]:
        lines.append(
            "  ms per GB: "
            + ", ".join(f"{k} {v:.2f}" for k, v in sorted(s["gb_ms"].items()))
        )
    if s["values_with_varying_tried"]:
        lines.append(
            f"  WARNING: trails tried varies between repeats on {s['values_with_varying_tried']} value(s)"
        )
    return "\n".join(lines)


def print_report(path):
    sessions, results, bad = ResultStore(path).load()
    print(os.path.join(os.path.basename(os.path.dirname(path)), os.path.basename(path)))
    if not results:
        print("  no results yet")
        return
    commits = sorted({str(s["commit"]) + ("+" if s["dirty"] else "") for s in sessions})
    machines = sorted({f"{s.get('host')} ({s.get('cpu_model')})" for s in sessions})
    print(
        f"  code versions: {', '.join(commits)}"
        + (f"; {bad} unreadable line(s)" if bad else "")
    )
    highest = max(r.get("load", 0) for r in results)
    print(
        f"  machines: {', '.join(machines)}; highest load during runs "
        + "%.1f" % highest
    )
    print(format_summary(summarize(results)))


def report(out=None):
    """Summaries of every result file, then the export."""
    paths = sorted(glob.glob(os.path.join(results_root(out), "*", "*.jsonl")))
    if not paths:
        print(f"no results in {results_root(out)}")
        return
    for path in paths:
        print_report(path)
    _export(out)


# ---export ---

RUN_COLUMNS = [
    "config",
    "p",
    "R",
    "omega",
    "xR0",
    "repeat",
    "found",
    "solution",
    "timed_out",
    "tried",
    "space",
    "ratio",
    "gb_calls",
    "seconds",
    "cpu_seconds",
    "max_rss_kb",
    "load",
    "trail",
    "gb_seconds",
    "time",
]


def _load_all(out):
    """(config name, first session, results, summary) of every result file with data."""
    loaded = []
    for path in sorted(glob.glob(os.path.join(results_root(out), "*", "*.jsonl"))):
        sessions, results, _ = ResultStore(path).load()
        if sessions and results:
            loaded.append(
                (
                    os.path.basename(path)[: -len(".jsonl")],
                    sessions[0],
                    results,
                    summarize(results),
                )
            )
    return sorted(loaded, key=lambda t: (t[1]["P"], t[1]["ROUNDS"], t[1]["BITS"], t[0]))


def _write_runs_csv(path, loaded):
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, RUN_COLUMNS, extrasaction="ignore")
        writer.writeheader()
        for config, session, results, _ in loaded:
            for r in results:
                row = {
                    "config": config,
                    "p": session["P"],
                    "R": session["ROUNDS"],
                    "omega": session["BITS"],
                }
                row.update(r)
                for key in ("trail", "gb_seconds"):
                    if key in row:
                        row[key] = json.dumps(row[key])
                writer.writerow(row)


def _write_summary_csv(path, loaded):
    columns = [
        "config",
        "p",
        "m",
        "R",
        "omega",
        "model",
        "order",
        "workers",
        "values",
        "runs",
        "timed_out_values",
        "success_pct",
        "seconds_mean",
        "seconds_ci95",
        "seconds_median",
        "cpu_seconds_mean",
        "tried_mean",
        "ratio_mean_pct",
        "ratio_median_pct",
        "ratio_le10_pct",
        "ratio_le20_pct",
    ]
    with open(path, "w", newline="") as f:
        writer = csv.DictWriter(f, columns, extrasaction="ignore")
        writer.writeheader()
        for config, session, _, s in loaded:
            row = {
                "config": config,
                "p": session["P"],
                "m": session.get("M"),
                "R": session["ROUNDS"],
                "omega": session["BITS"],
                "model": session["model"],
                "order": session["order"],
                "workers": session["workers"],
            }
            row.update(s)
            if s["runs"]:
                row.update(
                    seconds_mean=s["seconds"]["mean"],
                    seconds_median=s["seconds"]["median"],
                    ratio_mean_pct=s["ratio_pct"]["mean"],
                    ratio_median_pct=s["ratio_pct"]["median"],
                )
            writer.writerow(row)


def _latex_table(caption, header, rows):
    lines = [
        "\\begin{table}[ht]",
        "\\centering",
        "\\caption{" + caption + "}",
        "\\begin{tabular}{" + "l" * 4 + "r" * (len(header) - 4) + "}",
        "\\toprule",
        " & ".join(header) + " \\\\",
        "\\midrule",
    ]
    lines += [" & ".join(row) + " \\\\" for row in rows]
    return "\n".join(lines + ["\\bottomrule", "\\end{tabular}", "\\end{table}", ""])


def _write_latex(path, loaded):
    label = lambda session: [
        str(session["P"]),
        str(session["ROUNDS"]),
        str(session["BITS"]),
        session["model"]
        + ("" if session["model"] == "lagrange" else ", " + session["order"]),
    ]
    finished = [t for t in loaded if t[3]["runs"]]
    times = [
        label(t[1])
        + [
            str(t[3]["values"]),
            "%.3f" % t[3]["seconds"]["mean"],
            "%.3f" % t[3]["seconds_ci95"],
            "%.3f" % t[3]["seconds"]["median"],
        ]
        for t in finished
    ]
    ratios = [
        label(t[1])
        + [
            str(t[3]["values"]),
            "%.1f" % t[3]["ratio_pct"]["mean"],
            "%.1f" % t[3]["ratio_le10_pct"],
            "%.1f" % t[3]["ratio_le20_pct"],
        ]
        for t in finished
        if t[1]["model"] == "reduced"
    ]
    with open(path, "w") as f:
        f.write(
            _latex_table(
                "Solving times.",
                [
                    "$p$",
                    "$R$",
                    "$\\omega$",
                    "Model",
                    "Values",
                    "Mean (s)",
                    "$\\pm$ 95\\%",
                    "Median (s)",
                ],
                times,
            )
        )
        f.write("\n")
        f.write(
            _latex_table(
                "Combination ratios.",
                [
                    "$p$",
                    "$R$",
                    "$\\omega$",
                    "Order",
                    "Searches",
                    "Mean (\\%)",
                    "$\\leq 10\\%$",
                    "$\\leq 20\\%$",
                ],
                ratios,
            )
        )


def _write_histograms(directory, loaded):
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        log.warning("matplotlib is not available: no histograms")
        return
    for config, session, results, s in loaded:
        if not s["runs"] or session["model"] != "reduced":
            continue
        ratios = [PERCENT * r["ratio"] for r in results if not r.get("timed_out")]
        figure, axes = plt.subplots(figsize=(6, 3.5))
        axes.hist(ratios, bins=[int(b) for b in range(0, 101, 5)], color="#4C72B0")
        axes.axvline(
            s["ratio_pct"]["mean"],
            color="black",
            label="mean %.1f%%" % s["ratio_pct"]["mean"],
        )
        axes.axvline(
            s["ratio_pct"]["median"],
            color="black",
            linestyle="--",
            label="median %.1f%%" % s["ratio_pct"]["median"],
        )
        axes.set_xlabel("% of the enumeration space tried")
        axes.set_ylabel("runs")
        axes.set_title(
            f"p={session['P']}, R={session['ROUNDS']}, omega={session['BITS']}, {session['order']}"
        )
        axes.legend()
        figure.tight_layout()
        figure.savefig(
            os.path.join(
                directory,
                f"p{session['P']}_R{session['ROUNDS']}_omega{session['BITS']}_{config}.png",
            ),
            dpi=int(150),
        )
        plt.close(figure)


def _export(out=None):
    loaded = _load_all(out)
    directory = os.path.join(results_root(out), "export")
    os.makedirs(directory, exist_ok=True)
    _write_runs_csv(os.path.join(directory, "runs.csv"), loaded)
    _write_summary_csv(os.path.join(directory, "summary.csv"), loaded)
    _write_latex(os.path.join(directory, "tables.tex"), loaded)
    _write_histograms(directory, loaded)
    print(f"exported {len(loaded)} configuration(s) to {directory}")
