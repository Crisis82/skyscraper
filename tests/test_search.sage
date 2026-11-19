"""
search engine misc functions
"""

import os, sys

SKY_DIR = globals().get("SKY_DIR") or os.path.dirname(
    os.path.dirname(os.path.abspath(sys.argv[0]))
)
load(os.path.join(SKY_DIR, "tests", "common.sage"))

import gc, resource, signal, time

print("search engine")


def job_table(table):
    """A job with scripted outcomes: trail i -> solution (default None)."""

    def job(trail):
        action = table.get(trail)
        if callable(action):
            action = action()
        return action, "test"

    return job


def slow(value, seconds):
    def action():
        time.sleep(seconds)
        return value

    return action


def die():
    os.kill(os.getpid(), signal.SIGKILL)


def fail():
    raise ValueError("scripted failure")


check(
    "parallel: no solution gives the same as sequential",
    _search_parallel(job_table({}), range(1, 50), 4)[:3] == (None, None, 49),
)
check(
    "parallel: earliest success wins over a faster later one",
    _search_parallel(job_table({5: slow(555, 1), 7: 777}), range(1, 50), 4)[:2]
    == (5, 555),
)
check(
    "parallel: earlier running trails can still win after a later success",
    _search_parallel(job_table({3: slow(333, 1), 4: 444}), range(1, 50), 2)[:2]
    == (3, 333),
)
t0 = time.time()
_search_parallel(job_table({1: 111, 2: slow(None, 60)}), range(1, 50), 2)
check("parallel: later trails are abandoned at once", time.time() - t0 < 10)
source = iter(range(1, 10 ^ 9))
_search_parallel(job_table({2: 22}), source, 2)
check("parallel: the enumeration is not consumed ahead", next(source) <= 5)
check(
    "parallel: empty enumeration",
    _search_parallel(job_table({}), [], 2)[:3] == (None, None, 0),
)
check(
    "parallel: a killed worker raises WorkerError instead of hanging",
    raises(WorkerError, lambda: _search_parallel(job_table({3: die}), range(1, 50), 2)),
)
check(
    "parallel: a job exception raises WorkerError",
    raises(
        WorkerError, lambda: _search_parallel(job_table({3: fail}), range(1, 50), 2)
    ),
)


class _Stop(Exception):
    pass


def _bad_trails():
    yield 1
    raise _Stop


check(
    "parallel: a failing enumerator propagates",
    raises(_Stop, lambda: _search_parallel(job_table({}), _bad_trails(), 2)),
)
check("parallel: no worker left behind after failures", not mp.active_children())

fd0 = fd_count()
gc.collect()
for _ in range(int(100)):
    _search_parallel(job_table({2: 22}), range(1, 50), 4)
gc.collect()
rss0 = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
for _ in range(int(300)):
    _search_parallel(job_table({2: 22}), range(1, 50), 4)
gc.collect()
rss1 = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
check(
    "parallel: no file descriptor or process leak over 400 searches",
    fd_count() == fd0 and not mp.active_children(),
)
check(
    "parallel: no memory growth over 300 searches",
    rss1 - rss0 < 5000,
    f"{rss1 - rss0} KB",
)

finish()
