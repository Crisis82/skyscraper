USAGE = """
It runs attack, bench or report:

  sage main.sage attack [xR0=5] [model=lagrange] [order=lexicographic] [workers=4]
  sage main.sage bench [values=5,17|random|all] [count=50] [repeats=10] ...   (see bench.sage)
  sage main.sage report

The instance comes from SKY_P, SKY_ROUNDS and SKY_BITS (see params.sage).
"""

import inspect, os, sys

# __file__ is unusable under `sage x.sage` (it names sage/all.py).
if "SKY_DIR" not in globals():
    SKY_DIR = os.path.dirname(os.path.abspath(sys.argv[0]))
for _module in ["params", "cipher", "attack", "bench"]:
    load(os.path.join(SKY_DIR, _module + ".sage"))

COMMANDS = {"attack": attack, "bench": run_bench, "report": report}


def _value(text):
    """'5' -> 5, '1.5' -> 1.5, '5,17' -> [5, 17], anything else stays text."""
    if "," in text:
        return [_value(t) for t in text.split(",")]
    for kind in (int, float):
        try:
            return kind(text)
        except ValueError:
            pass
    return text


if os.path.basename(sys.argv[0]) == "main.sage":
    command, options = (sys.argv[1], sys.argv[2:]) if len(sys.argv) > 1 else (None, [])
    if command not in COMMANDS or any("=" not in o for o in options):
        raise SystemExit(USAGE)
    kwargs = {k: _value(v) for k, v in (o.split("=", 1) for o in options)}
    try:
        inspect.signature(COMMANDS[command]).bind(**kwargs)
    except TypeError as e:
        raise SystemExit(f"{command}: {e}")
    result = COMMANDS[command](**kwargs)
    if command == "attack":
        print(result)
