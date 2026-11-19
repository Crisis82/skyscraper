"""
pre-image attack implementation with trail enumeration

Logging.
  SKY_LOG selects what is shown on stderr (results always go to stdout):

    error     failures only
    warning   and anomalies
    info      and progress lines with a spinner (default)
    debug     and every @traced call, with arguments, result and time
    trace     and the full equations and Groebner bases

    @traced                   logs each call of a function at debug level
    log.info(...), trace(...) explicit messages; arguments are only formatted if shown
    with progress(title, total) as bar: bar.update(done); bar.success(message)

  SKY_LOG_FILE=path also appends everything down to debug (trace if SKY_LOG=trace) to
  that file, with times and process ids, whatever the console shows.

Enumeration. A case assigns one piece to each of the M chunks of a Bar layer, and
a trail one case to each of the BARS layers. The head restriction leaves
(h * l^(M-1))^BARS trails
"""

import ctypes, functools, heapq, logging, os, shutil, signal, sys, time, traceback
import multiprocessing as mp
from dataclasses import dataclass
from itertools import product
from multiprocessing.connection import wait
from typing import NamedTuple

# ------------------------------------------------------------------- logging ---

TRACE = int(5)
SUCCESS = int(25)
logging.addLevelName(TRACE, "TRACE")
logging.addLevelName(SUCCESS, "SUCCESS")

_LEVELS = {
    "error": logging.ERROR,
    "warning": logging.WARNING,
    "info": logging.INFO,
    "debug": logging.DEBUG,
    "trace": TRACE,
}
_SYMBOLS = {
    logging.ERROR: "[-]",
    logging.WARNING: "[!]",
    SUCCESS: "[+]",
    logging.INFO: "[*]",
    logging.DEBUG: "[.]",
    TRACE: "[ ]",
}
_COLORS = {
    logging.ERROR: "31",
    logging.WARNING: "33",
    SUCCESS: "32",
    logging.DEBUG: "2",
    TRACE: "2",
}
_SPINNER = "|/-\\"
_MAIN_PID = os.getpid()
_IS_TTY = sys.stderr.isatty()

_bars = []  # active progress bars, outermost first
_last_render = time.monotonic()
_frame = 0


class _Console(logging.Handler):
    def emit(self, record):
        symbol = _SYMBOLS.get(record.levelno, "[?]")
        worker = "" if record.process == _MAIN_PID else f"worker {record.process}: "
        text = f"{symbol} {worker}{record.getMessage()}"
        color = _COLORS.get(record.levelno)
        if _IS_TTY and color:
            text = f"\x1b[{color}m{text}\x1b[0m"
        _clear_line()
        sys.stderr.write(text + "\n")
        sys.stderr.flush()
        _render()


log = logging.getLogger("sky")
log.propagate = False
if os.environ.get("SKY_LOG", "info") not in _LEVELS:
    raise ValueError(f"SKY_LOG must be one of {sorted(_LEVELS)}")
_console = _Console()
_console.setLevel(_LEVELS[os.environ.get("SKY_LOG", "info")])
log.addHandler(_console)
LOG_FILE = os.environ.get("SKY_LOG_FILE")
log.setLevel(min(_console.level, logging.DEBUG) if LOG_FILE else _console.level)
if LOG_FILE:
    _file = logging.FileHandler(LOG_FILE)  # appends
    _file.setFormatter(
        logging.Formatter("%(asctime)s %(process)d %(levelname)s %(message)s")
    )
    log.addHandler(_file)


def quiet_progress():
    """For a child process whose parent draws the progress: keep only problems,
    unless the console was asked for more than progress."""
    if _console.level == logging.INFO:
        _console.setLevel(logging.WARNING)


def trace(message, *args):
    log.log(TRACE, message, *args)


def _short(value, limit=int(100)):
    text = repr(value)
    return text if len(text) <= limit else text[:limit] + "..."


def traced(fn):
    """Log each call of fn at debug level. Costs one level check when disabled."""

    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        if not log.isEnabledFor(logging.DEBUG):
            return fn(*args, **kwargs)
        shown = ", ".join(
            [_short(a) for a in args] + [f"{k}={_short(v)}" for k, v in kwargs.items()]
        )
        start = time.perf_counter()
        try:
            result = fn(*args, **kwargs)
        except BaseException as e:
            log.debug("%s(%s) raised %s", fn.__name__, shown, _short(e))
            raise
        log.debug(
            "%s(%s) -> %s  [%.2f ms]",
            fn.__name__,
            shown,
            _short(result),
            1000 * (time.perf_counter() - start),
        )
        return result

    return wrapper


# ---progress ---


def _clear_line():
    if _IS_TTY and _bars:
        sys.stderr.write("\r\x1b[K")


def _render():
    global _last_render, _frame
    if not (_IS_TTY and _bars and _console.level <= logging.INFO):
        return
    _last_render = time.monotonic()
    _frame += 1
    width = shutil.get_terminal_size().columns
    sys.stderr.write(f"\r\x1b[K{_SPINNER[_frame % 4]} " + _status_text()[: width - 3])
    sys.stderr.flush()


def _status_text():
    return " | ".join(bar.status() for bar in _bars)


def tick():
    """Redraw at most 10 times per second, or write a line every 30 s without a terminal."""
    global _last_render
    now = time.monotonic()
    if _IS_TTY:
        if now - _last_render >= 0.1:
            _render()
    elif _bars and now - _last_render >= 30:
        _last_render = now
        log.info("%s", _status_text())


class progress:
    """A status line for a loop. Nested bars share one line."""

    def __init__(self, title, total=None, unit=""):
        self.title, self.total, self.unit = title, total, unit
        self.done = 0
        self.note = ""

    def __enter__(self):
        self.start = time.monotonic()
        _bars.append(self)
        _render()
        return self

    def __exit__(self, *exc):
        _clear_line()
        sys.stderr.flush()
        _bars.remove(self)
        _render()

    def update(self, done=None, note=None):
        if done is not None:
            self.done = done
        if note is not None:
            self.note = note
        tick()

    def status(self):
        count = f" {self.done}/{self.total}" if self.total else ""
        unit = f" {self.unit}" if self.unit else ""
        note = f" {self.note}" if self.note else ""
        return f"{self.title}{count}{unit}{note} ({time.monotonic() - self.start:.0f}s)"

    def success(self, message):
        """Final message: shown at info level for an outermost bar, debug if nested."""
        log.log(
            SUCCESS if _bars and _bars[0] is self else logging.DEBUG,
            "%s: %s (%.2fs)",
            self.title,
            message,
            time.monotonic() - self.start,
        )


def _after_fork_in_child():
    _bars.clear()  # only the parent draws progress


os.register_at_fork(after_in_child=_after_fork_in_child)


# ---enumeration ---


def head_restricted_size():
    return (len(HEAD_INDEXES) * len(POINTS) ^ (M - 1)) ^ BARS


def _layer_cases():
    return product(HEAD_INDEXES, *[range(len(POINTS))] * (M - 1))


def lexicographic_trails(layers=BARS):
    for case in _layer_cases():
        if layers == 1:
            yield (case,)
        else:
            for rest in lexicographic_trails(layers - 1):
                yield (case,) + rest


P_DIGITS = Integer(P).digits(CARDINALITY, padto=M)[::-1]


def agreement_count(subsets):
    """Omega: how many x in {0, ..., p-1} have chunk j in subsets[j], for every
    j. Partitions those x by the first chunk where they differ from p: the chunks
    before it equal the digits of p, the chunk itself is below the digit, and the
    chunks after it are free. O(M) set operations."""
    free = [1] * (M + 1)
    for j in range(M - 1, -1, -1):
        free[j] = free[j + 1] * len(subsets[j])
    total = 0
    for j in range(M):
        d = P_DIGITS[j]
        total += sum(1 for s in subsets[j] if s < d) * free[j + 1]
        if d not in subsets[j]:
            break
    return int(total)


_RANKING = None


def layer_ranking():
    """Reachable single-layer cases as (cases, Omegas), by decreasing Omega."""
    global _RANKING
    if _RANKING is None:
        scored = []
        for case in _layer_cases():
            omega = agreement_count(
                [HEAD_POINTS[case[0]]] + [POINTS[k] for k in case[1:]]
            )
            if omega > 0:
                scored.append((omega, case))
        scored.sort(key=lambda t: t[0], reverse=True)
        _RANKING = [c for _, c in scored], [w for w, _ in scored]
    return _RANKING


def best_first_product(lists):
    if not all(lists):
        return

    def value(idx):
        v = 1
        for lst, i in zip(lists, idx):
            v *= lst[i]
        return v

    start = (0,) * len(lists)
    heap = [(-value(start), start)]
    while heap:
        neg_value, idx = heapq.heappop(heap)
        yield idx, -neg_value
        last = max((d for d, i in enumerate(idx) if i), default=0)
        for d in range(last, len(lists)):
            if idx[d] + 1 < len(lists[d]):
                nxt = idx[:d] + (idx[d] + 1,) + idx[d + 1 :]
                heapq.heappush(heap, (-value(nxt), nxt))


def ranked_trails():
    cases, omegas = layer_ranking()
    for idx, _ in best_first_product([omegas] * BARS):
        yield tuple(cases[i] for i in idx)


def enumerate_trails(order):
    if order == "ranked":
        return ranked_trails()
    if order == "lexicographic":
        return lexicographic_trails()
    raise ValueError(f"unknown enumeration order: {order!r}")


# ---search ---


class SearchResult(NamedTuple):
    position: object  # position of the first item with a solution, or None
    solution: object  # its solution, or None
    done: int  # jobs finished
    counts: dict  # label -> jobs finished
    seconds: dict  # label -> seconds spent in those jobs
    item: object  # the item at position, or None


def _search_sequential(job, trails, on_result=None):
    shapes, seconds = {}, {}
    done = 0
    for trail in trails:
        start = time.perf_counter()
        solution, shape = job(trail)
        seconds[shape] = float(seconds.get(shape, 0)) + time.perf_counter() - start
        done += 1
        shapes[shape] = shapes.get(shape, 0) + 1
        if on_result:
            on_result(done)
        if solution is not None:
            return SearchResult(done, solution, done, shapes, seconds, trail)
    return SearchResult(None, None, done, shapes, seconds, None)


# from <sys/prctl.h>
PR_SET_PDEATHSIG = 1


def die_with_parent():
    """Make the kernel kill this process when its parent dies, even in the middle of a long GB computation."""
    if sys.platform == "linux":
        ctypes.CDLL(None).prctl(int(PR_SET_PDEATHSIG), int(signal.SIGKILL))


class WorkerError(RuntimeError):
    """A parallel worker raised an exception or died."""


def _worker(job, me, pipes):
    """Worker loop. Runs after fork: job and trails are inherited, and only plain tuples cross the pipe."""
    signal.signal(signal.SIGINT, signal.SIG_IGN)  # the parent handles Ctrl-C
    die_with_parent()
    conn = pipes[me][1]
    # Keep only our own pipe end, so that recv() sees EOF if the parent dies.
    for i, (parent_end, child_end) in enumerate(pipes):
        parent_end.close()
        if i != me:
            child_end.close()
    try:
        while True:
            position, trail = conn.recv()
            try:
                start = time.perf_counter()
                solution, shape = job(trail)
                conn.send(
                    (position, solution, shape, time.perf_counter() - start, None)
                )
            except Exception:
                conn.send((position, None, None, 0, traceback.format_exc()))
                return
    except EOFError:
        pass


def _search_parallel(job, trails, workers, on_result=None):
    """Same result as _search_sequential: when a trail succeeds, trails later in
    the order are abandoned, but earlier ones still running are waited for, as
    one of them may also succeed. Each worker holds at most one trail, so the
    enumeration is consumed no faster than it is solved. A dead worker raises
    WorkerError. Workers never outlive this function."""
    ctx = mp.get_context("fork")
    pipes = [ctx.Pipe() for _ in range(workers)]
    procs = [
        ctx.Process(target=_worker, args=(job, i, pipes), daemon=True)
        for i in range(workers)
    ]
    conn_of = {p: pipes[i][0] for i, p in enumerate(procs)}
    try:
        for p in procs:
            p.start()
        for _, child_end in pipes:
            child_end.close()

        trails = iter(trails)
        idle = list(procs)
        running = {}  # proc -> (position, trail)
        position = done = 0
        best = solution = best_trail = None
        shapes, seconds = {}, {}
        exhausted = False
        while True:
            while idle and best is None and not exhausted:
                trail = next(trails, None)
                if trail is None:
                    exhausted = True
                else:
                    position += 1
                    p = idle.pop()
                    running[p] = (position, trail)
                    try:
                        conn_of[p].send((position, trail))
                    except OSError:
                        p.join()
                        raise WorkerError(
                            f"worker died with exit code {p.exitcode} on trail {position}"
                        )
            if not running:
                break

            ready = set(
                wait(
                    [conn_of[p] for p in running]
                    + [p.sentinel for p in running]
                    + [p.sentinel for p in idle],
                    timeout=0.1,
                )
            )
            tick()
            for p in list(running):
                if conn_of[p] in ready:
                    try:
                        pos, sol, shape, elapsed, error = conn_of[p].recv()
                    except EOFError:
                        continue  # died: reported below through its sentinel
                    if error is not None:
                        raise WorkerError(f"worker failed on trail {pos}:\n{error}")
                    _, finished_trail = running.pop(p)
                    idle.append(p)
                    done += 1
                    shapes[shape] = shapes.get(shape, 0) + 1
                    seconds[shape] = float(seconds.get(shape, 0)) + elapsed
                    if on_result:
                        on_result(done)
                    if sol is not None and (best is None or pos < best):
                        best, solution, best_trail = pos, sol, finished_trail
            for p in list(running) + idle:
                if p.sentinel in ready:
                    p.join()
                    raise WorkerError(
                        f"worker died with exit code {p.exitcode}"
                        + (f" on trail {running[p][0]}" if p in running else "")
                    )
            if best is not None:
                for p, (pos, _) in list(running.items()):
                    if pos > best:
                        p.kill()
                        p.join()
                        del running[p]
        return SearchResult(best, solution, done, shapes, seconds, best_trail)
    finally:
        for p in procs:
            if p.pid is not None:
                p.kill()
                p.join()
                p.close()
        for parent_end, child_end in pipes:
            parent_end.close()
            child_end.close()


# ---solving and attack ---


def xr0_candidates(system, gb):
    """Possible xR0 values of the ideal with reduced Groebner basis gb, and the basis shape:
    - "unit": no solution
    - "deg1": basis contains xR0 - c
    - "general": roots of the generator of I intersect F[xR0].
    """
    if gb[0].is_constant():
        return [], "unit"
    xR0 = system.xR0
    univariate = [g for g in gb if g.variables() == (xR0,)]
    for g in univariate:
        if g.degree() == 1:
            return [-g.constant_coefficient() / g.lc()], "deg1"
    if not univariate:
        others = [v for v in system.ring.gens() if v != xR0]
        univariate = [
            g
            for g in system.ring.ideal(list(gb)).elimination_ideal(others).gens()
            if g != 0
        ]
    if not univariate:
        raise ArithmeticError(
            "xR0 is not determined: the ideal is not zero-dimensional"
        )
    g = min(univariate, key=lambda f: f.degree())
    return [r for r, _ in g.univariate_polynomial().roots()], "general"


@traced
def groebner_basis(system, equations):
    trace("equations: %s", equations)
    gb = system.ring.ideal(equations).groebner_basis(GB_ALG)
    trace("basis: %s", gb)
    return gb


@traced
def solve_trail(system, target, trail):
    """Returns basis shape. Candidates are checked on the permutation,
    because the system only enforces the chunk decomposition modulo p."""
    candidates, shape = xr0_candidates(
        system, groebner_basis(system, system.equations(target, trail))
    )
    solution = next((int(c) for c in candidates if digest(c) == target), None)
    return solution, shape


@dataclass
class AttackResult:
    xR0: object  # the planted input
    solution: object  # a verified pre-image (maybe not xR0), or None
    tried: int  # position of the solving trail, or trails exhausted
    space: int  # head-restricted size (1 for the Lagrange model)
    gb_calls: int  # systems solved; in parallel it can exceed tried
    shapes: dict  # basis shape counts
    time: float  # seconds, including the enumeration
    trail: object  # the solving trail, or None
    shape_seconds: dict  # seconds spent in the GBs of each basis shape
    model: str
    order: str
    workers: int

    @property
    def found(self):
        return self.solution is not None

    @property
    def ratio(self):
        """tried / space: "comb. tried / comb. max" of thesis Table 6.4."""
        return float(self.tried) / float(self.space)


_SYSTEMS = {}


def _system(model):
    if model not in _SYSTEMS:
        _SYSTEMS[model] = reduced_system() if model == "reduced" else lagrange_system()
    return _SYSTEMS[model]


@traced
def attack(xR0=None, model="reduced", order="ranked", workers=1):
    """Pre-image search for the digest of P(0, xR0) (random xR0 by default)."""
    if workers > 1 and not GB_ALG.startswith("libsingular"):
        raise ValueError(
            f"parallel mode requires a libsingular backend, not {GB_ALG}: "
            "external backends are not known to be fork-safe"
        )
    start = time.time()
    xR0 = F.random_element() if xR0 is None else F(xR0)
    target = digest(xR0)
    if model == "reduced":
        system, trails, space = (
            _system("reduced"),
            enumerate_trails(order),
            head_restricted_size(),
        )
    elif model == "lagrange":
        system, trails, space = _system("lagrange"), iter([LAGRANGE_TRAIL]), 1
        order = "none"
    else:
        raise ValueError(f"unknown model: {model!r}")

    def job(trail):
        return solve_trail(system, target, trail)

    with progress(f"xR0={xR0}", total=space, unit="trails") as bar:
        if workers > 1:
            found = _search_parallel(job, trails, workers, bar.update)
        else:
            found = _search_sequential(job, trails, bar.update)
        result = AttackResult(
            xR0,
            None if found.solution is None else F(found.solution),
            found.done if found.position is None else found.position,
            space,
            found.done,
            found.counts,
            time.time() - start,
            found.item,
            found.seconds,
            model,
            order,
            workers,
        )
        if result.found:
            bar.success(
                f"pre-image {result.solution} after {result.tried}/{space} trails"
            )
        else:
            log.warning(
                f"xR0={xR0}: enumeration exhausted after {result.tried} trails, no pre-image"
            )
    return result
