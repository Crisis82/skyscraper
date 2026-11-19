# Skyscraper CICO cryptanalysis

SageMath implementation of the Gröbner basis pre-image attack on the Skyscraper hash function for my M.Sc. thesis on *Affine Cover Gröbner Basis Cryptanalysis of Lookup-Table AO Hash Functions*.

## Files

| File | Contents |
|---|---|
| `main.sage`   | The running modes (attack, bench or report) |
| `attack.sage` | The hybrid attack implementation with trail enumeration and optional parallel search |
| `cipher.sage` | Skyscraper Permutation, affine covers and polynomial systems |
| `bench.sage`  | Saved measurements, summaries and CSV/LaTeX/histogram export |
| `params.sage` | Instance parameters and round layouts |
| `tests/`      | Selftest, search and benchmark tests |

Notation in the code: `^` is power and `^^` is xor, as usual in Sage.
The Square round is x^2 with no Montgomery constant, i.e., sigma = 1.

## Commands

The instance comes from the environment; options are `key=value`, lists comma-separated.

```sh
SKY_P=587 SKY_ROUNDS=6 sage main.sage attack xR0=100                  # one pre-image search
SKY_P=587 SKY_ROUNDS=6 sage main.sage bench values=random count=300   # measurements
sage main.sage report                                                 # summaries and export
```

| Variable | Values | Default |
|---|---|---|
| `SKY_P` | prime > 2^omega | 587 |
| `SKY_ROUNDS` | 6 (`SSBBSS`), 10 (`SSBBSSBBSS`), 18 (`SSSSSSBBSSBBSSSSSS`) | 6 |
| `SKY_BITS` | chunk width omega: 4 or 8 | 4 |
| `SKY_GB` | any Sage GB algorithm, e.g. `magma:GroebnerBasis` or `msolve` if installed | `libsingular:slimgb` |
| `SKY_LOG` | `error`, `warning`, `info`, `debug`, `trace` | `info` |
| `SKY_LOG_FILE` | optional file that also receives debug detail | none |

**`attack`** options: `xR0` (random if omitted), `model=reduced|lagrange`, `order=ranked|lexicographic`, `workers=n`. `workers=n` forks n processes and returns exactly what the sequential search returns; it needs a `libsingular` backend.

**`bench`** options:

| Option | Meaning |
|---|---|
| `values=5,17`, `values=random`, `values=all`, `values=from:<file>` | Specific values, random distinct values, all of [0, p-1] shuffled, or the values of another result file |
| `count=50`, `repeats=1` | Totals, not increments: rerunning resumes, raising them adds only what is missing |
| `model`, `order`, `workers` | As for `attack` |
| `timeout=<seconds>` | Optional: stop a run at the limit and record it as timed out |
| `details=1` | Optional: also save the solving trail and the seconds per basis shape |
| `primes=37,109`, `rounds=6`, `bits=4` | Run the same command for several instances, one process each |
| `seed`, `tag`, `out` | Reproducible random values, a separate series, another results folder |

Results go to `results/p<P>_R<R>_omega<omega>/`, one append-only file per configuration, saved after every run, so nothing is lost on interruption and old data is never modified.
Summaries weigh every value once, however often it was repeated.
For clean timings it's run one benchmark at a time: `taskset -c 2 sage main.sage bench ...`.

**`report`** prints the summary of every result file and writes `runs.csv`, `summary.csv`, `tables.tex` and histograms to `results/export/`.

## Logging

`SKY_LOG` selects what appears on stderr; results stay on stdout:
- `info` shows progress with a spinner,
- `debug` also every call of a function marked `@traced` (arguments, result, time),
- `trace` also the equations and Gröbner bases.
To follow a function while debugging, put `@traced` above it instead of adding prints.

## Tests

```sh
tests/run_all.sh             # runs everything
```

## Notes

- **Spurious solutions.** The systems enforce the chunk decomposition only modulo p, so an `xR0` that is not a pre-image can satisfy them. Candidates are always verified on the permutation.
- **Several pre-images.** A digest can have more than one, so `solution` can differ from the planted `xR0`.
