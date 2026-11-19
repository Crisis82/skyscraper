"""
Skyscraper permutation over F_p, the affine covers of its lookup table and the polynomial systems of CICO pre-image.
"""

from hashlib import sha256


# ---permutation ---

F = GF(P)

def lookup_table(w):
    """The w-bit lookup table T as a list."""
    mask = 2^w - 1

    def rot(z, s):
        return ((z << s) & mask) | (z >> (w - s))

    return [rot(z ^^ (rot(z ^^ mask, 1) & rot(z, 2) & rot(z, 3)), 1) for z in range(2^w)]


SBOX = lookup_table(BITS)


def _round_constants():
    """gamma_0 = gamma_{R-1} = 0; the others come from SHA-256."""
    label = b"Skyscraper".ljust(28, b"\0")
    return ([F(0)]
            + [F(int.from_bytes(sha256(int(r).to_bytes(4, "big") + label).digest(), "big"))
               for r in range(ROUNDS - 2)]
            + [F(0)])


ROUND_CONSTANTS = _round_constants()


def decompose(x):
    """Chunks of an element of F_p, most significant first."""
    return Integer(x).digits(CARDINALITY, padto=M)[::-1]


def square(x):
    """Square round function, with sigma = 1 (no Montgomery multiplication)."""
    return x^2


def bar(x):
    chunks = decompose(x)
    out = 0
    for c in chunks[ROT:] + chunks[:ROT]:
        out = (out << BITS) + SBOX[c]
    return F(out)


def _round_function(i, x):
    return bar(x) if i in BAR_ROUNDS else square(x)


def permutation(xL, xR):
    xL, xR = F(xL), F(xR)
    for i in range(ROUNDS):
        xL, xR = xR + _round_function(i, xL) + ROUND_CONSTANTS[i], xL
    return xL, xR


def inverse_permutation(yL, yR):
    xL, xR = F(yL), F(yR)
    for i in range(ROUNDS - 1, -1, -1):
        xL, xR = xR, xL - _round_function(i, xR) - ROUND_CONSTANTS[i]
    return xL, xR


def digest(xR0):
    """Target of a pre-image instance: the right output of P(0, xR0)."""
    return permutation(0, xR0)[1]


def bar_inputs(xR0):
    """The values entering each Bar round during the evaluation of P(0, xR0)."""
    xL, xR = F(0), F(xR0)
    seen = []
    for i in range(ROUNDS):
        if i in BAR_ROUNDS:
            seen.append(xL)
        xL, xR = xR + _round_function(i, xL) + ROUND_CONSTANTS[i], xL
    return seen


# ---affine covers ---

COVERS = {
    4: [
        (2,    0,     (0, 1, 2, 4, 5)),
        (2/3,  5,     (3, 9, 12, 15)),
        (1,    -5,    (10, 11, 14)),
        (-2,   26,    (6, 7)),
        (2/5,  -11/5, (8, 13)),
    ],
    8: [
        (2, 0,    (0,1,2,4,5,8,9,10,16,17,18,20,21,32,33,34,36,37,40,41,42,64,65,66,68,69,72,73,74,80,81,82,84,85)),
        (2, -263, (133,149,165,197,213,229,245,253)),
        (2, -259, (194,202,210,226,234,242,250,254)),
        (2, -256, (176,178,180,184,186,188,190,191)),
        (2, -255, (128,130,132,136,138,144,146,148,160,162,164,168,170,255)),
        (2, -251, (192,196,200,208,212,224,228,232,240,244,248,252)),
        (2, -247, (129,137,145,161,169,193,201,209,225,233,241,249)),
        (2, -239, (131,147,163,195,211,227,243)),
        (2, -128, (88,89,90,92,93,94,95)),
        (2, -127, (152,154,156,158,159)),
        (2, -64,  (44,45,46,47)),
        (2, -62,  (108,110)),
        (2, -2,   (97,101,105,113,117,121,125,127)),
        (2, 1,    (48,49,50,52,53,56,57,58,60,61,62,63)),
        (2, 2,    (96,98,100,104,106,112,114,116,120,122,124,126)),
        (2, 16,   (3,19,35,67,83)),
        (2, 32,   (6,7,38,39,70,71)),
        (2, 64,   (12,13,14,15,76,77,78,79)),
        (2, 128,  (24,25,26,28,29,30,31)),
        (-2, 442, (102,103,118,119)),
        (2/3, -257/3, (133,139,151,175,217,220,223)),
        (2/3, -5/3,   (142,166)),
        (2/3, -4/3,   (11,23,47,95,179,185,191)),
        (2/3, -1/3,   (143,167,194,197,203,215,236,239)),
        (2/3, 85,     (51,63,153,159,204,207,231,243,249,252,255)),
        (6, -1275,    (219,221,222,223,237,238,239,246,247,251,253,254,255)),
        (6, -1019,    (173,175,192,193,195,198,199,205,206,207)),
        (6, -763,     (129,131,135,141,143,155,157,159)),
        (-6, 806,     (99,101,109)),
        (-2/5, 493/5, (54,134,174)),
        (-2/5, 697/5, (51,141,161,171,216,221)),
        (-2/5, 884/5, (27,67,87,177,187)),
        (6/11, -757/11,    (128,139,150,172)),
        (11/4, -289/4,     (55,75,115)),
        (-49/37, 12495/37, (107,181,218)),
        (70/43, 0,         (0,43,86)),
        (38/91, 0,         (0,91,182)),
        (91/37, -1558/37,  (22,59,96)),
        (-7/13, 2805/13,   (85,111,189)),
        (-139/17, 20973/17, (123,140)),
        (59/31, -8379/31,   (183,214)),
        (-34/5, 1797,       (230,235)),
    ],
}

PIECES = COVERS[BITS]
POINTS = [frozenset(S) for _, _, S in PIECES]

# Head pieces: k -> S_k intersect {0, ..., d0}, for the pieces where that is non-empty.
HEAD_POINTS = {k: frozenset(s for s in S if s <= HEAD_MAX) for k, S in enumerate(POINTS)
               if min(S) <= HEAD_MAX}
HEAD_INDEXES = sorted(HEAD_POINTS)


# ---polynomial systems ---

_Rx = PolynomialRing(F, "x")
_x = _Rx.gen()


def _vanishing(points):
    return prod(_x - s for s in sorted(points))


class CICOSystem:
    def __init__(self, maps, members, head_members):
        """maps[k] / members[k]: T and the chunk constraint for piece k.
        head_members[k]: the constraint for piece k on the head chunk."""
        self.maps, self.members, self.head_members = maps, members, head_members
        names = [n for r in range(BARS)
                 for n in [f"a{r}_{j}" for j in range(M)] + [f"b{r}_{j}" for j in range(M)] + [f"s{r}"]]
        self.ring = PolynomialRing(F, names + ["xR0"])
        gens = self.ring.gens()
        stride = 2 * M + 1
        self.layers = [(gens[r * stride:r * stride + M],
                        gens[r * stride + M:r * stride + 2 * M],
                        gens[r * stride + 2 * M]) for r in range(BARS)]
        self.xR0 = gens[-1]
        self.weights = [CARDINALITY^(M - 1 - j) for j in range(M)]

    def _compose(self, chunks):
        return sum(c * w for c, w in zip(chunks, self.weights))

    def equations(self, target, trail):
        eqs = []
        xL, xR = self.ring.zero(), self.xR0
        layer = 0
        for i in range(ROUNDS):
            if i in BAR_ROUNDS:
                a, b, s = self.layers[layer]
                eqs.append(xL - self._compose(a))
                for j, k in enumerate(trail[layer]):
                    eqs.append((self.head_members if j == 0 else self.members)[k](a[j]))
                    eqs.append(b[j] - self.maps[k](a[j]))
                eqs.append(s - (xR + self._compose(b[ROT:] + b[:ROT]) + ROUND_CONSTANTS[i]))
                xL, xR = s, xL
                layer += 1
            else:
                xL, xR = xR + square(xL) + ROUND_CONSTANTS[i], xL
        eqs.append(xR - target)
        return eqs


def reduced_system():
    return CICOSystem([F(alpha) * _x + F(beta) for alpha, beta, _ in PIECES],
                      [_vanishing(S) for S in POINTS],
                      {k: _vanishing(S) for k, S in HEAD_POINTS.items()})


def lagrange_system():
    domain = range(CARDINALITY)
    members = [_vanishing(domain)]
    return CICOSystem([_Rx.lagrange_polynomial([(z, SBOX[z]) for z in domain])], members, members)


# The single "trail" of the Lagrange system: piece 0 for every chunk.
LAGRANGE_TRAIL = ((0,) * M,) * BARS
