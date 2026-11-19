"""
instance parameters

  SKY_P           prime field modulus                       (default 587)
  SKY_ROUNDS      6, 10 or 18                               (default 6)
  SKY_BITS        chunk width omega: 4 or 8                 (default 4)
  SKY_GB          Sage Groebner basis algorithm             (default libsingular:slimgb) e.g. magma:GroebnerBasis, msolve, singular:slimgb
  SKY_LOG         error, warning, info, debug, trace        (default info), see attack.sage
  SKY_LOG_FILE    optional file that also receives debug detail
"""

import os, shutil

P = Integer(os.environ.get("SKY_P", 587))
ROUNDS = Integer(os.environ.get("SKY_ROUNDS", 6))
BITS = Integer(os.environ.get("SKY_BITS", 4))
GB_ALG = os.environ.get("SKY_GB", "libsingular:slimgb")

# Bar rounds of each permutation; all other rounds are Square rounds.
#   R=6   SSBBSS
#   R=10  SSBBSSBBSS
#   R=18  SSSSSSBBSSBBSSSSSS
BAR_ROUNDS_BY_R = {6: (2, 3), 10: (2, 3, 6, 7), 18: (6, 7, 10, 11)}

if ROUNDS not in BAR_ROUNDS_BY_R:
    raise ValueError("SKY_ROUNDS must be 6, 10 or 18")
if BITS not in (4, 8):
    raise ValueError("SKY_BITS must be 4 or 8: the only widths with an affine cover")
if not P.is_prime() or P <= 2 ^ BITS:
    raise ValueError(
        "SKY_P must be a prime > 2^omega, so that chunk values stay distinct in F_p"
    )
for _tool in ("magma", "msolve"):
    if GB_ALG.startswith(_tool) and shutil.which(_tool) is None:
        raise ValueError(f"SKY_GB={GB_ALG} requires {_tool}, which is not installed")

BAR_ROUNDS = BAR_ROUNDS_BY_R[ROUNDS]
BARS = len(BAR_ROUNDS)
CARDINALITY = 2 ^ BITS
M = ceil(P.nbits() / BITS)  # chunks per field element
ROT = M // 2  # chunk rotation of the Bar function
HEAD_MAX = P >> (BITS * (M - 1))  # d0, the most significant chunk of P
