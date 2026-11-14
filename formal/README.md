# Formal check of the verify decision (R10, R11)

`verify_model.py` is a finite transition system with a discrete clock, explored
exhaustively by breadth-first search. It is plain Python 3 with no dependencies.

```bash
python3 formal/verify_model.py
python3 formal/verify_model.py --faulty
```

The first command is expected to exit 0. The second seeds a bug (success is checked before the deadline) and is expected to exit 1 with a counterexample trace.

## Mapping to the code

| Model | Code |
|---|---|
| tick = 0.1 s, deadline tick 50 inclusive | `VerifyKernel.deadlineSeconds = 5.0`, check `elapsed > 5.0` |
| t = 0 | `VerifySession.t0`, the time of the first camera frame (Q7) |
| `valid` event setting flags | `FrameGate.check == .valid` followed by `BlinkDetector`, `HeadTurnChallenge`, `MotionCheck` and the embedding append in `VerifySession.process` |
| `drop` | `FrameGate.Verdict.drop` (0 faces, low quality) |
| `reset` | `FrameGate.Verdict.resetTrack` (>1 face, IoU < 0.3, gap > 0.3 s) → `resetProgress()` |
| `wrongturn` | `HeadTurnChallenge.Status.wrongDirection` |
| `stall` | `VerifySession.tick(now:)` driven by a timer when no frames arrive |
| `decide` | `VerifyKernel.decide` |

## Abstractions and assumptions

- **Detectors as flags.** The detectors are abstracted as monotone flags set by the environment. Their correctness is covered by unit tests (R7–R9), not by this model.
- **Discrete time.** The real clock is continuous. Values between ticks are covered by the Swift test `VerifyKernelTests.exhaustive`, which runs the real `VerifyKernel.decide` on every flag combination over a 0.1 s grid plus the boundary values 4.9999999, 5.0 and 5.0000001.
- **One event per tick.** The environment chooses one event per tick. That is enough for these safety and termination properties, because the decision depends only on the accumulated flags and the elapsed time.
- **No fairness assumption.** Termination comes from the clock, not from the user's behaviour.
- **Not modelled:** camera start-up (the 3 s limit, exit 2) and errors (exit 2). Both are handled outside the decision loop in the CLI.
