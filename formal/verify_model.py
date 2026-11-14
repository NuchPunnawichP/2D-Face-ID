"""Exhaustive check of the faceauth verify decision logic (SPEC R10, R11).

A finite transition system with a discrete clock: one tick = 0.1 s, so the
5.0 s deadline is tick 50 (inclusive). Python 3, no dependencies.

Abstraction (see formal/README.md for the mapping to the code):
  - Detectors are abstracted to monotone flags (blink, turn, motion) that the
    environment may set on any valid frame, an embedding counter capped at 3,
    and a match flag the environment may set or clear once 3 embeddings exist
    (the mean embedding changes as frames arrive).
  - Each tick the environment chooses exactly one event: a valid frame that
    sets any subset of flags, a dropped frame (no face), a reset (second face
    or lost track), a wrong-direction turn, or no frame at all (camera stall;
    the timer tick still runs).
  - Ghost variables record, independently of the flags, which liveness events
    really happened since the last reset. The properties are stated over the
    ghosts so that they do not just restate the guard.

Properties:
  R10  Success => blink, turn and motion events since the last reset, >= 3
       frontal embeddings, a match, and t <= 50.
  R11  No reachable non-final state has t > 50 (termination by the deadline),
       and every non-final state has a successor (no deadlock).
  Reachability (non-vacuity): Success, Timeout and WrongTurn are all
  reachable, and so are the boundary ticks 50 (success still allowed) and 51.

Usage:  python3 formal/verify_model.py            (expect exit 0)
        python3 formal/verify_model.py --faulty   (success checked before the
                                                   deadline; expect exit 1)
"""
import argparse
import itertools
import sys
from collections import deque

DEADLINE = 50  # ticks of 0.1 s
MAX_T = DEADLINE + 1
FLAGS = ("blink", "turn", "motion")


def decide(t, flags, emb, match, wrong, faulty):
    """Mirror of VerifyKernel.decide."""
    all_ok = all(flags) and emb >= 3 and match
    if faulty and all_ok and not wrong:
        return "Success"
    if t > DEADLINE:
        return "Timeout"
    if wrong:
        return "WrongTurn"
    if all_ok:
        return "Success"
    return "Pending"


def successors(state, faulty):
    phase, t, flags, emb, match, ghosts = state
    if phase != "Pending":
        return
    nt = t + 1
    events = []
    # Valid frame: any subset of flags may become true, optionally one more embedding,
    # and the match flag may change once 3 embeddings exist.
    for newly in itertools.product((False, True), repeat=3):
        for add_emb in (False, True):
            nemb = min(3, emb + (1 if add_emb else 0))
            match_options = (False, True) if nemb >= 3 else (False,)
            for nmatch in match_options:
                nflags = tuple(f or n for f, n in zip(flags, newly))
                nghosts = tuple(g or n for g, n in zip(ghosts, newly))
                events.append(("valid", nflags, nemb, nmatch, nghosts, False))
    events.append(("drop", flags, emb, match, ghosts, False))
    events.append(("stall", flags, emb, match, ghosts, False))
    events.append(("reset", (False,) * 3, 0, False, (False,) * 3, False))
    events.append(("wrongturn", flags, emb, match, ghosts, True))
    for name, nflags, nemb, nmatch, nghosts, wrong in events:
        if name in ("drop", "stall", "reset") and nt > DEADLINE:
            # Timer tick or a frame after the deadline: not evaluated, deadline fires.
            nphase = "Timeout"
        elif nt > DEADLINE and not faulty:
            nphase = "Timeout"
        else:
            nphase = decide(nt, nflags, nemb, nmatch, wrong, faulty)
        yield name, (nphase, nt, nflags, nemb, nmatch, nghosts)


def check(faulty):
    init = ("Pending", 0, (False,) * 3, 0, False, (False,) * 3)
    queue = deque([init])
    parent = {init: None}
    reached_phases, reached_ticks = set(), set()

    def trace(s):
        out = []
        while s is not None:
            prev = parent[s]
            out.append(s if prev is None else (prev[1], s))
            s = prev[0] if prev else None
        return list(reversed(out))

    while queue:
        s = queue.popleft()
        phase, t, flags, emb, match, ghosts = s
        reached_phases.add(phase)
        reached_ticks.add(t)
        if phase == "Success":
            if not (all(ghosts) and emb >= 3 and match and t <= DEADLINE):
                print("R10 VIOLATED. Shortest trace (event, state):")
                for step in trace(s)[-6:]:
                    print("  ", step)
                return 1
        if phase == "Pending" and t > DEADLINE:
            print("R11 VIOLATED: non-final state past the deadline:", s)
            return 1
        succ = list(successors(s, faulty))
        if phase == "Pending" and not succ:
            print("R11 VIOLATED: deadlock in", s)
            return 1
        for event, nxt in succ:
            if nxt not in parent:
                parent[nxt] = (s, event)
                queue.append(nxt)

    missing = {"Success", "Timeout", "WrongTurn"} - reached_phases
    if missing or not {DEADLINE, DEADLINE + 1} <= reached_ticks:
        print("INCONCLUSIVE: unreachable outcomes or boundary ticks:", missing)
        return 2
    success_ticks = sorted({t for (p, t, *_rest) in parent if p == "Success"})
    print(f"R10 and R11 satisfied in model. Exhausted {len(parent)} reachable states.")
    print(f"Outcomes reached: {sorted(reached_phases)}")
    print(f"Success reachable at ticks {success_ticks[0]}..{success_ticks[-1]} "
          f"(deadline {DEADLINE}, inclusive). Max tick {max(reached_ticks)}.")
    return 0


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--faulty", action="store_true",
                    help="evaluate success before the deadline (seeded bug)")
    sys.exit(check(ap.parse_args().faulty))
