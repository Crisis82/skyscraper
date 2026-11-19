"""
correctness checks that depend on the instance parameters;
"""

import os, sys

SKY_DIR = globals().get("SKY_DIR") or os.path.dirname(
    os.path.dirname(os.path.abspath(sys.argv[0]))
)
load(os.path.join(SKY_DIR, "tests", "common.sage"))

import time
from itertools import product

_rng = random.Random(int(1))


def true_trail(xR0):
    """The trail followed by the evaluation of P(0, xR0). With overlapping pieces
    (omega = 8) each chunk gets the first piece containing it; the head chunk is
    at most d0, so its piece is always a head piece."""
    return tuple(
        tuple(next(k for k, S in enumerate(POINTS) if c in S) for c in decompose(x))
        for x in bar_inputs(xR0)
    )


def sample_inputs(n=20):
    return list(range(P)) if P <= n else [_rng.randrange(P) for _ in range(n)]


# ------------------------------------------------------------- layouts ---
print("round layouts")
load(
    os.path.join(SKY_DIR, "tests", "reference.sage")
)  # defines PATTERNS, reference_permutation
for R, pattern in PATTERNS.items():
    check(
        f"R={R} is {pattern}",
        "".join("B" if i in BAR_ROUNDS_BY_R[R] else "S" for i in range(R)) == pattern,
    )
check("BARS matches the layout", BARS == PATTERNS[ROUNDS].count("B"))

# -------------------------------------------------------------- cipher ---
print("cipher")


check("T is a bijection", sorted(SBOX) == list(range(CARDINALITY)))
check(
    "permutation matches an independent implementation",
    all(
        tuple(map(int, permutation(a, b)))
        == reference_permutation(Integer(a), Integer(b), P, ROUNDS, BITS)
        for a, b in zip(sample_inputs(), reversed(sample_inputs()))
    ),
)
check(
    "inverse_permutation inverts permutation",
    all(
        inverse_permutation(*permutation(a, b)) == (F(a), F(b))
        for a, b in zip(sample_inputs(), reversed(sample_inputs()))
    ),
)
# Digests of xR0 = 0, 1, 5, 17, 36 from the original sky/ code with MONTGOMERY = False
# (sigma = 1); its R=10 layout is wrong, so there is no R=10 entry.
KNOWN_DIGESTS = {
    (37, 6): [6, 30, 19, 9, 21],
    (587, 6): [368, 128, 208, 154, 26],
    (587, 18): [560, 128, 204, 276, 328],
}
if (P, ROUNDS) in KNOWN_DIGESTS and BITS == 4:
    check(
        "digests match the original code",
        [digest(x) for x in (0, 1, 5, 17, 36)] == KNOWN_DIGESTS[(P, ROUNDS)],
    )

# --------------------------------------------------------------- cover ---
print("affine covers")
for w, pieces in COVERS.items():
    table = lookup_table(w)
    check(
        f"omega={w}: pieces agree with T and cover the domain",
        all(alpha * s + beta == table[s] for alpha, beta, S in pieces for s in S)
        and set().union(*(S for _, _, S in pieces)) == set(range(2 ^ w)),
    )
check(
    "head pieces are those with a point <= d0",
    HEAD_INDEXES == [k for k, S in enumerate(POINTS) if any(s <= HEAD_MAX for s in S)],
)
check(
    "the head set of each piece is S ∩ {0..d0}",
    all(S == {s for s in POINTS[k] if s <= HEAD_MAX} for k, S in HEAD_POINTS.items()),
)

# ------------------------------------------------------------- systems ---
print("polynomial systems")
reduced = _system("reduced")
lagrange = _system("lagrange")
domain = range(CARDINALITY)


def zeros(poly):
    return {z for z in domain if poly(z) == 0}


def true_point(system, xR0):
    """Values of every ring variable along the evaluation of P(0, xR0)."""
    values = {system.xR0: F(xR0)}
    xL, xR = F(0), F(xR0)
    layer = 0
    for i in range(ROUNDS):
        if i in BAR_ROUNDS:
            a, b, s = system.layers[layer]
            chunks = decompose(xL)
            values.update(zip(a, map(F, chunks)))
            values.update(zip(b, [F(SBOX[c]) for c in chunks]))
            values[s] = xR + bar(xL) + ROUND_CONSTANTS[i]
            layer += 1
        xL, xR = xR + _round_function(i, xL) + ROUND_CONSTANTS[i], xL
    return [values[v] for v in system.ring.gens()]


check(
    "reduced: pieces and constraints match the cover",
    all(reduced.maps[k](s) == SBOX[s] for k, S in enumerate(POINTS) for s in S)
    and all(zeros(reduced.members[k]) == set(S) for k, S in enumerate(POINTS))
    and all(zeros(reduced.head_members[k]) == set(S) for k, S in HEAD_POINTS.items()),
)
check(
    "lagrange: interpolates T with degree 2^omega - 1",
    all(lagrange.maps[0](z) == SBOX[z] for z in domain)
    and lagrange.maps[0].degree() == CARDINALITY - 1,
)
check(
    "lagrange: constraint vanishes exactly on the chunk domain, degree 2^omega",
    zeros(lagrange.members[0]) == set(domain)
    and lagrange.members[0].degree() == CARDINALITY
    and lagrange.head_members[0] == lagrange.members[0],
)
if P == 587 and BITS == 4:
    check(
        "lagrange: coefficients match thesis Table " + "3.3",
        lagrange.maps[0].list()
        == [0, 231, 456, 550, 263, 92, 184, 447, 508, 547, 391, 285, 258, 306, 169, 11],
    )

xs = sample_inputs(10)
check(
    "reduced: the true evaluation satisfies the true trail's equations",
    all(
        all(
            e(*true_point(reduced, x)) == 0
            for e in reduced.equations(digest(x), true_trail(x))
        )
        for x in xs
    ),
)
check(
    "lagrange: the true evaluation satisfies the equations",
    all(
        all(
            e(*true_point(lagrange, x)) == 0
            for e in lagrange.equations(digest(x), LAGRANGE_TRAIL)
        )
        for x in xs
    ),
)
check(
    "both: a wrong target breaks only the target equation",
    all(
        sum(e(*true_point(s, xs[0])) != 0 for e in s.equations(digest(xs[0]) + 1, t))
        == 1
        for s, t in ((reduced, true_trail(xs[0])), (lagrange, LAGRANGE_TRAIL))
    ),
)


def system_outputs(xR0):
    """All right outputs the polynomial model allows for this xR0, by brute force.
    The model enforces the chunk decomposition modulo p only, so a Bar round
    accepts every representation xL + k*p < 2^(omega*m) of its input."""
    states = {(F(0), F(xR0))}
    for i in range(ROUNDS):
        next_states = set()
        for xL, xR in states:
            if i in BAR_ROUNDS:
                for z in range(int(xL), CARDINALITY ^ M, int(P)):
                    chunks = Integer(z).digits(CARDINALITY, padto=M)[::-1]
                    out = sum(
                        SBOX[c] * CARDINALITY ^ (M - 1 - j)
                        for j, c in enumerate(chunks[ROT:] + chunks[:ROT])
                    )
                    next_states.add((xR + F(out) + ROUND_CONSTANTS[i], xL))
            else:
                next_states.add((xR + square(xL) + ROUND_CONSTANTS[i], xL))
        states = next_states
    return {xR for _, xR in states}


# Fixing xR0 makes the Lagrange system easy, so its GB can be checked exactly
# against the brute force, for a pre-image, a wrap-around solution and a value
# with no solution. The full search is not part of the selftest, see README.md.
if ROUNDS == 6 and BITS == 4:
    x = xs[0]
    target = digest(x)
    eqs = lagrange.equations(target, LAGRANGE_TRAIL)
    outputs = {v: target in system_outputs(v) for v in range(P)}
    spurious = next((v for v in range(P) if outputs[v] and digest(v) != target), None)
    impossible = next((v for v in range(P) if not outputs[v]), None)
    check(
        "lagrange: brute force finds all three kinds of xR0",
        spurious is not None and impossible is not None,
    )
    check(
        "lagrange: GB has a solution exactly when the brute force does",
        all(
            lagrange.ring.ideal(eqs + [lagrange.xR0 - v])
            .groebner_basis(GB_ALG)[0]
            .is_constant()
            != outputs[v]
            for v in (x, spurious, impossible)
            if v is not None
        ),
    )

# --------------------------------------------------------- enumeration ---
print("enumeration")
if P <= 5000:
    ok = True
    for _ in range(int(200)):
        subsets = [POINTS[_rng.randrange(len(POINTS))] for _ in range(M)]
        ok &= agreement_count(subsets) == sum(
            all(c in S for c, S in zip(decompose(z), subsets)) for z in range(P)
        )
    check("Omega equals a brute-force count", ok)

ok = True
for _ in range(int(300)):
    lists = [
        sorted((_rng.randrange(6) for _ in range(_rng.randrange(1, 6))), reverse=True)
        for _ in range(_rng.randrange(1, 5))
    ]
    ok &= [v for _, v in best_first_product(lists)] == sorted(
        (prod(t) for t in product(*lists)), reverse=True
    )
    ok &= len({i for i, _ in best_first_product(lists)}) == prod(len(l) for l in lists)
check("best-first product equals a brute-force sort, without repeats", ok)

if head_restricted_size() <= 10 ^ 5:
    lex = list(lexicographic_trails())
    check(
        "lexicographic order has the head-restricted size, without repeats",
        len(lex) == len(set(lex)) == head_restricted_size(),
    )
    ranked = list(ranked_trails())
    check(
        "ranked order is a subset of it, without repeats",
        len(ranked) == len(set(ranked)) and set(ranked) <= set(lex),
    )
    check(
        "ranked order contains every true trail",
        all(true_trail(x) in set(ranked) for x in sample_inputs(50)),
    )
    if P == 587 and BITS == 4 and ROUNDS == 6:
        omegas = layer_ranking()[1]
        check(
            "top Ptrail matches thesis Table " + "5.1",
            abs(float(omegas[0] ^ 2 / P ^ 2) - 0.014221) < 1e-6,
        )
        check("625 reachable trails, as in thesis Section " + "5.2", len(ranked) == 625)

# -------------------------------------------------------------- attack ---
print("attack (reduced model)")
fd0 = fd_count()
saved_alg = GB_ALG
GB_ALG = "singular:slimgb"
check(
    "parallel mode is rejected on a non-libsingular backend",
    raises(ValueError, lambda: attack(0, workers=2)),
)
GB_ALG = saved_alg

if ROUNDS == 18 and P > 37:
    print("  (true-trail GB skipped: did not finish within 7 minutes at p=587, R=18)")
else:
    ok = True
    for x in sample_inputs(5):
        solution, _ = solve_trail(reduced, digest(x), true_trail(x))
        ok &= solution is not None and digest(solution) == digest(x)
    check("the true trail yields a verified pre-image", ok)

if SEARCHABLE:
    instances = sample_inputs(37 if P <= 37 and ROUNDS == 6 else 3)
    for order in ("lexicographic", "ranked"):
        results = [attack(x, order=order) for x in instances]
        check(
            f"{order}: every search finds a verified pre-image",
            all(r.found and digest(r.solution) == digest(r.xR0) for r in results),
            f"{len(results)} searches, mean ratio {100 * sum(r.ratio for r in results) / len(results):.2f}%",
        )
        for workers in (2, 4):
            par = [attack(x, order=order, workers=workers) for x in instances[:3]]
            check(
                f"{order}: {workers} workers give the same result as sequential",
                all(
                    (p.solution, p.tried) == (s.solution, s.tried)
                    for p, s in zip(par, results)
                ),
            )
    check(
        "no process or file descriptor left behind",
        not mp.active_children() and fd_count() == fd0,
    )
else:
    print("  (full searches skipped: too slow for these parameters)")

# Trials-to-success measured by running the original sky/ code (MONTGOMERY = False) on
# these instances.
REGRESSION = {
    (37, 6): {
        i: t
        for i, t in enumerate(
            [
                3,
                1,
                10,
                6,
                1,
                7,
                1,
                2,
                10,
                8,
                12,
                9,
                4,
                1,
                2,
                6,
                1,
                1,
                6,
                6,
                2,
                3,
                21,
                1,
                1,
                2,
                9,
                12,
                10,
                2,
                1,
                3,
                1,
                2,
                3,
                6,
                1,
            ]
        )
    },
    (587, 6): {5: 208, 100: 172, 222: 136, 300: 6, 401: 26, 499: 10, 586: 543, 17: 256},
}
if (P, ROUNDS) in REGRESSION and BITS == 4:
    counts = {
        x: int(attack(x, order="lexicographic").tried) for x in REGRESSION[(P, ROUNDS)]
    }
    check(
        "lexicographic trial counts equal those of the original code",
        counts == REGRESSION[(P, ROUNDS)],
    )

finish()
