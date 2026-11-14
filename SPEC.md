# faceauth — 2D webcam face unlock prototype for `sudo`, with a notch-style HUD
Status: **approved** by the user in chat on 2026-11-14, spec revision 4.

Revision history: rev 2 approved 2026-11-14. Rev 4 approved 2026-11-14 adds the root-owned enrollment for sudo (section "Revision 4"), R23–R31, Q16–Q24 and A6; the rev 3 contract stays in force. Rev 3 approved 2026-11-14 changes only the blink closed level: rev 2 used a fixed 0.21, which can overlap the open level and let a static photo "blink" when the open-eye EAR is below about 0.26.

**Operating goal.** A learning project: a Swift command-line tool `faceauth` that enrolls the owner's face from 5 live camera snaps and later verifies it with liveness checks. While it runs it shows a notch-style overlay at the top of the screen with a face-scan glyph. Milestone 2 lets `sudo` accept a face match through a PAM module, with the password still available as a fallback.

**Scope.**
- M1: `faceauth enroll | verify | calibrate | record-landmarks`, the liveness checks, unit tests and the README.
- M1-HUD: the notch-style overlay shown during `enroll` and `verify`.
- M2: `pam_faceauth.so` plus `/etc/pam.d/sudo_local`. Work starts only after every M1 requirement has passed. Each sudo command is asked for first.

**Excluded behavior.**
- The login window, lock screen, screensaver unlock, FileVault and the authorization database (`security authorizationdb`). Changing them is out of scope (confirmed in Q1).
- Editing `/etc/pam.d/sudo`.
- Importing or uploading photos. Enrollment uses only the live camera.
- Storing raw images or video frames on disk.
- Showing a live camera preview in the HUD (confirmed in Q6).
- Any network access at runtime.
- Strong anti-spoofing such as resistance to masks or video replay. The README must say so.

**Revisions.** Code: base commit `8045213` on branch `claude/faceauth-macos-prototype-82f9cd`. Model: (none yet).

**Environment observed (read-only, 2026-11-14).**
- macOS 26.6.1 on a MacBook Air with a notch.
- Swift 6.3 with Command Line Tools only (no Xcode.app).
- Python 3.11.9, without coremltools.
- `/etc/pam.d/sudo_local.template` exists.

## Open questions
| # | Question | Options | Proposed default | Answer |
|---|---|---|---|---|
| Q1 | You said "unlock the MacBook". Is that `sudo` only, or also the lock screen or login? | (a) `sudo` only, as your original spec says; (b) also the lock screen, through a SecurityAgent plugin and authorization DB changes, as a separate later milestone | (a). Mistakes in (b) can lock you out of the Mac, and FileVault still asks for the password at boot. | (a), user accepted default on 2026-11-14 |
| Q2 | The HUD glyph. SF Symbols' `faceid` and Apple's Face ID artwork (your second image) are licensed only for referring to Apple's Face ID, and this is not Face ID. | (a) our own glyph drawn in code: four corner brackets, eyes, nose and smile, the same idea in our own geometry; (b) the SF Symbol `faceid`; (c) your PNG file | (a) | (a), user accepted default on 2026-11-14 |
| Q3 | HUD size and position | (a) collapsed, it matches the notch (width from `NSScreen.auxiliaryTopLeftArea/RightArea`, height = menu bar). Expanded, it is 360 × 120 pt, top-center, grows down from the notch, corner radius 24 pt. (b) other size | (a) | (a), user accepted default on 2026-11-14 |
| Q4 | A screen without a notch (external display, clamshell mode) | (a) a pill of the same expanded size at top-center of the screen that holds the menu bar; (b) only on the built-in display; (c) no HUD | (a) | (a), user accepted default on 2026-11-14 |
| Q5 | Which commands show the HUD | (a) `enroll` and `verify`; (b) also `calibrate` | (a). `calibrate` prints numbers in the terminal. | (a), user accepted default on 2026-11-14 |
| Q6 | Show a live camera preview in the HUD? | (a) no, glyph and text only; (b) small mirrored preview | (a). Closer to Face ID, and no image is shown or kept. | (a), user accepted default on 2026-11-14 |
| Q7 | Where the 5 s verify timeout starts | (a) at the first camera frame received, with a separate 3 s limit for the camera to start (exceeding it is an error, exit 2); (b) at process start, 5 s total including camera warm-up | (a). Camera warm-up is often 0.5–1.5 s and would eat the budget. | (a), user accepted default on 2026-11-14 |
| Q8 | Exit code when the 5 s timeout expires | (a) 1, not authenticated; (b) 2, error | (a). PAM treats 1 and 2 the same. | (a), user accepted default on 2026-11-14 |
| Q9 | The user turns their head the wrong way during the challenge | (a) immediate fail, exit 1; (b) ignore it and keep waiting until the timeout | (a) | (a), user accepted default on 2026-11-14 |
| Q10 | A second face appears, or the face track is lost, during verify | (a) reset all liveness progress (blink, turn, motion, embeddings) and continue until the timeout; (b) immediate fail | (a) | (a), user accepted default on 2026-11-14 |
| Q11 | Default match threshold before you calibrate | (a) a provisional value from the model's published verification threshold, used until you calibrate. `verify` warns on stderr while it is uncalibrated. (b) `verify` refuses to run until `calibrate` has saved a threshold | (b). It is safer, and calibrating is part of setup anyway. | (b), user accepted default on 2026-11-14 |
| Q12 | Enrollment poses for the 5 snaps | (a) center, slightly left, slightly right, slightly up, slightly down. Each snap is the best of a 1 s burst, ranked by Vision `faceCaptureQuality`, and must be ≥ 0.3. (b) 5 frontal snaps | (a) | (a), user accepted default on 2026-11-14 |
| Q13 | Embedding model | (a) ArcFace or MobileFaceNet with permissively licensed weights, license checked before download; if none qualifies, fall back to facenet-pytorch (MIT) and tell you; (b) InsightFace ArcFace (weights for non-commercial research only), accepted for personal learning use | (a) | (a), user accepted default on 2026-11-14 |
| Q14 | Downloads: a Python venv with coremltools and torch (a few hundred MB), the model weights, and research-paper PDFs (ArcFace, MobileFaceNet, Soukupová & Čech blink/EAR) saved to `docs/papers/` | (a) approve all; (b) everything except the papers; (c) ask me each time | (a) | (a), user accepted default on 2026-11-14 |
| Q15 | When the HUD collapses after the result | (a) it shows the result for 0.6 s, then collapses in 0.3 s, then the process exits, so exit is ≤ 1.0 s after the decision; (b) the process exits immediately and the HUD vanishes at once | (a) | (a), user accepted default on 2026-11-14 |

## Contract
**Inputs and units.**
- Camera frames: 640 × 480 BGRA from the built-in front camera, nominally 30 fps.
- Vision outputs: face bounding box (normalized 0–1), 2D landmarks (normalized), `yaw` and `pitch` in radians (converted to degrees in code) and `faceCaptureQuality` (0–1).
- Time: seconds, from a monotonic clock (`ContinuousClock`).
- CLI arguments: `enroll`, `verify`, `calibrate`, `record-landmarks <out.json>`, plus the global flags `--no-hud` and `--verbose`.

**Outputs and units.**
- Exit codes: 0 = match, 1 = no match / liveness failed / timeout, 2 = error. Errors include no permission, no camera, no enrollment, no calibrated threshold (Q11) and a corrupt store.
- Text messages on stderr. stdout is used only by `calibrate` and `--verbose`.
- Store, in `~/Library/Application Support/faceauth/`:
  - the directory has mode 0700;
  - `enrollment.json` has mode 0600 and holds the model ID, the embedding dimension, 5 individual L2-normalized embeddings, their L2-normalized mean, the date and the format version;
  - `config.json` has mode 0600 and holds the threshold and the calibration date.
- Cosine similarity: unitless, in [-1, 1].
- Eye aspect ratio (EAR): unitless.

**Initial state.** No store. On first run with no store, any command except `enroll` and `record-landmarks` prints a notice and starts the enrollment flow. For `verify` that run then ends with exit 2 after enrolling, so a new enrollment never counts as a successful verification.

**Invalid input behavior.** An unknown command or flag prints usage and exits 2. If the store has the wrong mode, wrong owner, wrong model ID or wrong dimension, `verify` exits 2 and prints how to fix it. `verify` never re-enrolls silently.

**Verify state table.** A frame counts as "valid" when it has exactly one face, `faceCaptureQuality` ≥ 0.3, and the face track is continuous: box IoU with the previous valid frame ≥ 0.3 and a gap ≤ 0.3 s.

| Source | Event | Guard | Update | Destination |
|---|---|---|---|---|
| Start | permission check | denied or restricted | message | Error (2) |
| Start | permission check | not determined | system prompt, then recheck | Start |
| Start | first frame | within 3 s of camera start (Q7) | t0 := now; challenge := random {left, right} from `SystemRandomNumberGenerator` | Scanning |
| Start | no frame by 3 s | — | — | Error (2) |
| Scanning | frame with 0 faces | — | drop frame | Scanning |
| Scanning | frame with >1 face, or track lost | — | reset blink, turn, motion, embeddings (Q10) | Scanning |
| Scanning | valid frame | — | update EAR history, yaw history, motion score; if \|yaw\| ≤ 15° and \|pitch\| ≤ 15°, align and embed | Scanning |
| Scanning | turn in the wrong direction | yaw past the threshold opposite to the challenge, held 3 frames | — | Fail (1) (Q9) |
| Scanning | all conditions met | blink ∧ turn ∧ motion ∧ ≥ 3 frontal embeddings ∧ match | — | Success (0) |
| Scanning | deadline | now − t0 > 5.0 s | — | Fail (1) (Q8) |
| any | camera/model error | — | — | Error (2) |

Liveness and match definitions. These are the starting values; R13 lets calibration tune the numeric thresholds.
- **Blink:** EAR is ≥ open level, then < closed level for 1–8 consecutive valid frames, then back ≥ open level. Baseline = the median EAR over the first 5 valid frames. Open level = baseline × 0.8. Closed level = min(0.21, baseline × 0.7), so closed is always below open (rev 3).
- **Turn:** yaw ≥ +20° for "left" or ≤ −20° for "right", held for ≥ 3 consecutive valid frames. The sign convention is fixed by a recorded fixture.
- **Motion:** the standard deviation of the inter-ocular-normalized landmark positions over a 1 s window is above a minimum. A static photo stays below it, and a live face exceeds it during the blink and turn anyway.
- **Match:** cosine(mean of the frontal embeddings, enrolled mean) ≥ threshold, and also the maximum cosine against any of the 5 individual enrolled embeddings ≥ threshold.

**Clock and ordering.**
- The clock origin is t0 as defined in Q7. The deadline is exclusive: a decision at exactly 5.000 s still counts.
- If the success condition and the deadline become true in the same frame, the frame is evaluated before the deadline.
- If there is an error, Error takes precedence over Success and Fail.

**HUD state table.**

| Source | Event | Update | Destination |
|---|---|---|---|
| Hidden | command start, GUI session available, no `--no-hud` | panel at top-center, collapsed to the notch, then expands in 0.3 s | Scanning (glyph pulses; text "Look at the camera") |
| Scanning | challenge known | text "Blink, then turn your head left/right" | Scanning |
| Scanning | Success | glyph turns green with a check | Result |
| Scanning | Fail / Error | glyph turns red and the panel shakes (Reduce Motion: no shake) | Result |
| Result | 0.6 s elapsed | collapse in 0.3 s | Hidden, then the process exits |
| any | the HUD cannot be created (no window server, SSH) | text only, on stderr | Hidden |

The enroll HUD shows "Snap n/5" with the pose instruction and five progress dots.

**Assumptions.**

| ID | Claim | Evidence or owner | Affected |
|---|---|---|---|
| A1 | A CLI binary can show a borderless, non-activating `NSPanel` at the screen-saver window level, over full-screen apps, as an accessory app without a Dock icon. | A spike in Phase 2, with a screenshot | R14–R18 |
| A2 | When `pam_faceauth` runs `faceauth` as the invoking user under `sudo` in Terminal, it can use the camera (TCC attributes the request to Terminal) and draw the HUD. | Tested in M2 only. If false, M2 still verifies through text but has no HUD, and this spec gets a revision. | R20, R16 |
| A3 | Vision's `yaw` is reliable within ±45° on this camera at 640×480. | A recorded fixture plus `calibrate` output | R8 |
| A4 | `swift test` works with Command Line Tools only, using Swift Testing. | First Phase-2 step. If it fails, this spec gets a revision. | R21 |
| A5 | `MLModel.compileModel(at:)` compiles the `.mlpackage` at runtime without Xcode. | First Phase-2 model step | R5 |

## Requirements and verification
| ID | Observable requirement | Formal property or test | Trigger reachability check | Acceptance evidence |
|---|---|---|---|---|
| R1 | `swift build` builds `faceauth` with Swift tools 5.9+ for macOS 14+. | Build | — | Build log |
| R2 | When camera permission is denied, every camera command exits 2 with a message saying how to enable access in System Settings. | Manual: deny in System Settings, then run `verify` | The permission is actually denied | Terminal transcript |
| R3 | A frame with 0 faces or more than 1 face never contributes to enrollment, liveness or match. | Unit test on `FrameGate` using fixtures with 0, 1 and 2 faces | A fixture with 2 faces exists | Test output |
| R4 | The face is aligned with an eye-landmark similarity transform into a 112×112 crop before embedding. | Unit test: synthetic eye points map to the canonical eye positions within 1 px | — | Test output |
| R5 | `scripts/convert_model.py` downloads and converts the chosen model into a `.mlpackage`; the README records the source URL, license and checksum. | Run the script; check the SHA-256 | — | Script log, README |
| R6 | `enroll` takes exactly 5 accepted snaps (poses per Q12) and writes `enrollment.json` with 5 embeddings plus their mean. The directory is 0700, the file is 0600, and no image file is created. | Unit test on the store (permissions, round trip); runtime check with `stat` plus a listing of the directory | — | `stat` output, test output |
| R7 | Blink detection fires on the recorded blink sequences and not on the recorded open-eye or static sequences. | Unit tests with recorded landmark fixtures | The blink fixture really has an EAR dip | Test output |
| R8 | The turn challenge passes only for the requested direction held ≥ 3 frames; a wrong-direction turn fails (Q9). | Unit tests with recorded yaw sequences; checked in the formal model | A left fixture and a right fixture exist | Test output |
| R9 | The motion check rejects a static-face sequence (recorded from a phone photo) and accepts a live sequence. | Unit test with recorded fixtures | A photo fixture exists | Test output |
| R10 | `verify` exits 0 only if blink, turn, motion and match are all true for the same continuous face track within the deadline. | **Formal:** exhaustive BFS over a discrete-time model (0.1 s ticks): `Success ⇒ blink ∧ turn ∧ motion ∧ match ∧ t ≤ 50 ticks`. Also unit tests of `VerifySession` with a fake clock and fake frames. | Success is reachable; every guard flip is reachable | Model log, test output |
| R11 | `verify` always terminates: exit 1 by t0 + 5.0 s, or exit 2 if no first frame arrives by 3 s. | **Formal:** no reachable non-terminal state with t > 50 ticks; no deadlock. Plus a fake-clock unit test. | The timeout state is reachable | Model log, test output |
| R12 | Exit codes are 0, 1, 2 exactly as in the contract. | Unit tests for each path, plus runtime checks | — | Test output, transcripts |
| R13 | `calibrate` prints live and phone-photo similarity scores (min, median, max; n ≥ 20 frames each) and a suggested threshold, then saves the threshold you choose to `config.json` (0600). | Runtime check | — | Transcript; the README records your chosen threshold |
| R14 | During `enroll` and `verify` with a GUI session, the HUD appears at top-center of the screen holding the menu bar within 0.5 s of process start. It is anchored to the notch when there is one (Q3, Q4), stays above full-screen windows and does not take keyboard focus. | Runtime check: screenshot; the frontmost app before and after is unchanged (`NSWorkspace.frontmostApplication`) | Tested on the built-in display; also on an external display if one is available | Screenshots, log |
| R15 | The HUD shows the glyph (Q2) and state text: "Look at the camera" → challenge → success (green check) or fail (red, shake). Enroll shows "Snap n/5". | Snapshot of the HUD view rendered offscreen for each state | Every state is rendered | PNGs in `docs/hud/` |
| R16 | A HUD failure, or `--no-hud`, never changes the verdict or exit code; all prompts are also printed to stderr. | Unit test with a HUD stub that throws; runtime check over SSH, or with `--no-hud` | — | Test output |
| R17 | After the verdict the HUD shows the result, collapses, and the process exits within 1.0 s of the decision (Q15). | Runtime timing log | — | Log |
| R18 | With Reduce Motion on, the HUD neither pulses nor shakes. | Snapshot or unit check of the animation flags | — | Test output |
| R19 | `pam_faceauth.so` returns `PAM_SUCCESS` only on exit 0 of `faceauth verify` run as the invoking user, and `PAM_AUTH_ERR` otherwise, so the password prompt still follows. | C unit test with a stub `faceauth` (exits 0, 1, 2 and hangs) | Hang case: the module kills the child after 10 s | Test output |
| R20 | Installing touches only `/etc/pam.d/sudo_local` (`auth sufficient`). The README documents uninstall and recovery (keep a `sudo -s` shell open). | Manual install with your OK; checksum of `/etc/pam.d/sudo` before and after | — | Transcript, checksums |
| R21 | Unit tests cover cosine similarity, the EAR blink detector, the turn challenge, the motion check and the threshold decision, using recorded landmark data and no live camera. | `swift test` | — | Test output |
| R22 | The README covers setup, usage, the chosen threshold, the model source and license, and security limitations: video replay, masks, look-alikes, and that a 2D webcam is weaker than a password, Touch ID or Face ID. | Review | — | README |

## Revision 4 — root-owned enrollment for sudo (approved 2026-11-14)
**Goal.** Close review finding 1. Today `sudo` trusts `enrollment.json` and `config.json` in the user's home folder. Any program running as the user can replace them, for example with embeddings of someone else's face, and that person could then pass `sudo`. Revision 4 gives `sudo` its own copy of the enrollment and config, owned by root, that a process running as the user cannot write.

**Scope.**
- A root-owned store for `sudo`.
- `sudo faceauth enroll --system`, `sudo faceauth calibrate --system` and `sudo faceauth unenroll --system`.
- The PAM module hands the root-owned data to the verifier; the verifier ignores the user store under `sudo`.
- Under `sudo` and `--system`, only the built-in camera is used.
- Install, uninstall and README updates.

**Unchanged.** Plain `faceauth enroll | verify | calibrate` (no `sudo`) keep using the user store. Exit codes, liveness and the HUD stay as in revision 3.

**Excluded.**
- **Malware that controls the verifier process itself** (it runs as the user, because macOS camera permission is per user).
- **Malware that feeds fake frames** through an installed camera extension. That needs your approval in System Settings, and the built-in-only rule (R31) blocks it.
- Login window, lock screen and the authorization database remain out of scope.

### Open questions (revision 4)
| # | Question | Options | Proposed default | Answer |
|---|---|---|---|---|
| Q16 | Where the root-owned store lives | (a) `/var/db/faceauth/<uid>/`, directory 0700 root:wheel, files 0600 root:wheel; (b) `/Library/Application Support/faceauth/<uid>/` with the same modes | (a). `/var/db` is the conventional place for system-owned per-user data. | (a), user accepted default on 2026-11-14 |
| Q17 | How the sudo enrollment is created | (a) fresh: `sudo faceauth enroll --system` captures 5 new snaps live and root writes the result; the user store is never read; (b) copy the user's existing enrollment after a live verify against it; (c) plain copy of the user's file | (a). Copying (b, c) would trust a file that malware may already have changed. | (a), user accepted default on 2026-11-14 |
| Q18 | Where the sudo threshold and liveness settings come from | (a) `sudo faceauth calibrate --system` measures again and root saves the config, range-checked as in revision 3; (b) copy the user's `config.json` after range-checking it | (a), for the same reason as Q17 | (a), user accepted default on 2026-11-14 |
| Q19 | How the root-owned data reaches the verifier, which runs as the user | (a) the PAM module (root) reads the files, checks owner and mode, and writes them to the child over a pipe on fd 3; the child reads only that pipe; (b) make the files readable by the user (0640, group = the user's group) and let the child read them | (a). The files stay 0600 root, and other users can't read your embeddings. | (a), user accepted default on 2026-11-14 |
| Q20 | What `sudo` does when this user has no root store, or it is invalid | (a) `PAM_AUTH_ERR` without starting the verifier, so the password prompt follows; it never falls back to the user store; (b) fall back to the user store | (a) | (a), user accepted default on 2026-11-14 |
| Q21 | Which process captures the camera for `--system` | (a) root forks a child that drops to the invoking user (`SUDO_UID`) to capture (camera permission is per user); the child sends embeddings and landmarks back over a pipe; root validates and writes; (b) capture directly as root | (a). Root's camera permission is separate and untested, and (a) mirrors how verify already runs under `sudo`. | (a), user accepted default on 2026-11-14 |
| Q22 | Camera choice under `sudo` and `--system` | (a) only the built-in camera (`builtInWideAngleCamera`), no fallback; refuse with exit 2 if it is missing; (b) also allow external or Continuity cameras | (a). A virtual or external camera could replay video. | (a), user accepted default on 2026-11-14 |
| Q23 | What uninstall does with the root store | (a) `uninstall.sh` deletes `/var/db/faceauth` after printing what it will delete and asking y/N; (b) keep it; (c) delete without asking | (a). It is biometric data, so it should not be left behind silently. | (a), user accepted default on 2026-11-14 |
| Q24 | Size limit for the data sent over the pipe | (a) 64 KiB total; larger or malformed data → verifier exit 2; (b) other | (a). Today the enrollment is about 17 KB and the config under 1 KB. | (a), user accepted default on 2026-11-14 |

### Contract additions (revision 4)
**Root store.** `/var/db/faceauth/<uid>/`, with the location subject to Q16.
- `/var/db/faceauth` and `<uid>/` are directories with mode 0700, owned by root:wheel.
- `enrollment.json` and `config.json` are files with mode 0600, owned by root:wheel. Their formats are the same as in revision 3.
- Any other owner, mode or symlink makes the store invalid.

**`--system` commands.** These must run with euid 0 and `SUDO_UID` set (that is, through `sudo`); otherwise they exit 2.
- `enroll --system` and `calibrate --system`:
  1. Root starts a capture child as `SUDO_UID` (Q21), running this same root-owned binary.
  2. The child streams FaceFrames and embeddings to root over a pipe.
  3. Root runs the same selection, calibration and validation logic, then writes the root store atomically (temp file, then rename).
- `unenroll --system` deletes this user's root store.

**PAM flow.**

| Source | Event | Guard | Update | Destination |
|---|---|---|---|---|
| Start | authenticate | binary safe (revision 3 rules) | — | LoadStore |
| Start | authenticate | binary unsafe | — | AUTH_ERR |
| LoadStore | read the root store for the target uid | dir and files root:wheel, 0700/0600, not symlinks, total ≤ 64 KiB | — | Spawn |
| LoadStore | read | missing or invalid | syslog | AUTH_ERR (Q20) |
| Spawn | fork | — | the child drops to the user; the store is written to fd 3, which is then closed; exec `faceauth verify --store-fd 3` | Wait |
| Wait | child exit 0 within the timeout | — | — | SUCCESS |
| Wait | any other exit, a signal or a timeout | — | kill on timeout | AUTH_ERR |

**Verifier with `--store-fd N`.**
- Reads at most 64 KiB from fd N, as a JSON object holding `enrollment` and `config`.
- Applies the same validation as revision 3, plus the model ID and dimension checks.
- Never reads the user store.
- Uses only the built-in camera (Q22).
- Malformed, oversized or invalid data → exit 2.

**New assumption.**

| ID | Claim | Evidence or owner | Affected |
|---|---|---|---|
| A6 | A child that `sudo faceauth … --system` drops to the user can use the camera under the user's Terminal camera permission (the same question as A2). | Tested at install time. If false, `--system` enrollment fails with exit 2 and this spec gets a revision. | R25, R26 |

### Requirements (revision 4)
| ID | Observable requirement | Formal property or test | Trigger reachability check | Acceptance evidence |
|---|---|---|---|---|
| R23 | Under `sudo`, the verifier uses only the store data passed by the PAM module; a changed or deleted user store has no effect on the result. | C test: a stub verifier echoes what it received on fd 3, and the module passes exactly the root-store bytes. Swift test: `--store-fd` decoding. Runtime check: tamper with the user store and confirm the sudo result does not change. | The user store exists and differs from the root store | Test output; transcript |
| R24 | The PAM module refuses a root store with the wrong owner, wrong mode, a symlink, or more than 64 KiB: `PAM_AUTH_ERR`, and the verifier is not started. | C tests (unprivileged variant: owned by the test user) | Each invalid case is constructed | Test output |
| R25 | `sudo faceauth enroll --system` captures 5 live snaps through a capture child running as `SUDO_UID` and writes the root store (0700/0600 root:wheel). It never reads the user store. Without `sudo` it exits 2. | Swift tests for the pipe protocol and validation; runtime check with `stat` and `ls` of the store; a run without `sudo` exits 2 | — | Test output; `stat` output |
| R26 | `sudo faceauth calibrate --system` writes a range-checked root `config.json` with the same rules as R13. | Swift test of the shared validation; runtime check | — | Transcript |
| R27 | With no root store for the user, `sudo` falls through to the password prompt without starting the verifier, and never uses the user store. | C test: a stub verifier whose start would be detected, with no store | The store directory is missing | Test output |
| R28 | `--store-fd`: data over 64 KiB, malformed JSON, or out-of-range settings → exit 2. | Swift tests | Each case is constructed | Test output |
| R29 | `sudo faceauth unenroll --system` removes this user's root store. `uninstall.sh` lists `/var/db/faceauth` and deletes it only after you answer y. | Runtime check | — | Transcript |
| R30 | The README threat model states what revision 4 closes (data tampering by processes running as the user) and what remains (control of the verifier process, a physical or replayed face in front of the camera, and the revision 3 limits). | Review | — | README |
| R31 | Under `sudo` (`--store-fd`) and with `--system`, only the built-in camera is used, with no fallback to the default, external, Continuity or virtual cameras; if there is no built-in camera, exit 2. | Unit test of the device-selection rule, using a fake device list | A list with only an external camera | Test output |

## Verification report
Run on 2026-11-14 on branch `claude/faceauth-macos-prototype-82f9cd`. Local commits only: nothing has been pushed.

**Environment.** macOS 26.6.1 (MacBook Air, notch). Apple Swift 6.3 and Apple clang 21.0.0 from the Command Line Tools. Python 3.11.9, coremltools 8.3.0, torch 2.5.0.

**Commands.**

| Check | Command | Result |
|---|---|---|
| Build | `swift build` and `swift build -c release` | Both complete with no errors. |
| Unit tests | `./scripts/test.sh` (`swift test` plus framework search paths for the Command Line Tools; A4) | 76 tests in 13 suites passed. 6 recorded-fixture tests were skipped because no fixtures exist yet. An earlier run failed `closedForExactlyEightFramesCounts`; the baseline-frame bug behind it is fixed. |
| Formal model | `python3 formal/verify_model.py` | "R10 and R11 satisfied in model. Exhausted 3875 reachable states." Exit 0. |
| Seeded fault | `python3 formal/verify_model.py --faulty` | R10 violated with a counterexample: Success at tick 51. Exit 1, as expected. |
| PAM module | `make -C pam test` | 16/16 checks passed, including the hanging verifier killed at 2.02 s (`timeout=2`) and at 10.01 s (default), and a symlinked binary and a `/../` path refused. |
| Model | `scripts/.venv/bin/python -I scripts/convert_model.py` | SHA-256 matches the pinned value. Core ML vs PyTorch cosine 1.00000. |
| Model | first conversion attempts | Failed: the TorchScript graph has `prim::If` train/eval branches. Fixed by scripting and freezing the wrapper. |
| Model runtime | `faceauth self-test` (release build) | 128-d embedding, L2 norm 1.0000, 2.4–5.5 ms per embedding, load 0.08–0.09 s. |
| HUD snapshots | `faceauth hud-snapshots docs/hud` | 10 PNGs written. Reduce Motion check: no animations with it on; pulse and shake present with it off. |
| HUD live | `faceauth hud-demo` (4 runs) | First attempt hung: the window `animator()` frame animation never ran; replaced with `setFrame(animate:)`. On screen 0.088–0.105 s after process start on warm launches; 0.711 s on the first launch after a rebuild. Collapse 0.92–0.94 s after the result. Frontmost app unchanged. In `verify`, the HUD was fully expanded 0.424 s after process start. |
| Error paths | `FACEAUTH_STORE_DIR=… faceauth verify --no-hud` with a synthetic store | No config, wrong model, config 644, enrollment 644, directory 755 and a tampered config (threshold −0.99, motion off) each exit 2 with a fix-it message, before the camera opens. |

**Model mapping, abstractions and bounds.** See `formal/README.md`.
- One tick is 0.1 s, so the deadline is tick 50 (inclusive).
- Detectors are abstracted to monotone flags, and ghost variables record real liveness events since the last reset.
- The environment chooses one event per tick: valid / drop / reset / wrong turn / stall.
- There is no fairness assumption.
- Not modelled: camera start-up and errors.
- The real `VerifyKernel.decide` is additionally checked over every flag combination × a 0.1 s grid from 0 to 6 s, plus 4.9999999, 5.0 and 5.0000001 (`VerifyKernelTests.exhaustive`, 10,240 cases).

**Interpretations made during implementation.** These do not change the contract.
- **Deadline:** a frame that arrives after t0 + 5.0 s is not evaluated, so it cannot produce Success. The "same frame" ordering rule therefore applies only to a frame at exactly 5.0 s.
- **Motion check:** "inter-ocular-normalized" positions are centred on the eye midpoint and rotated to the eye line, so moving, tilting or zooming a flat photo produces no motion.
- **Calibration:** `calibrate` also measures the head-turn sign (`leftYawSign`) and the motion threshold. R13 allows calibration to tune numeric thresholds. The spec says a recorded fixture fixes the sign; that fixture test exists but is skipped until you record it.
- **Clock:** the code uses the CoreMedia host clock (`CMClockGetHostTimeClock`), not `ContinuousClock`. Both are monotonic, but the host clock matches the camera frame timestamps. That the frame timestamps really are on the host clock is assumed, not verified.
- **Decision vs. termination time:** the decision uses frame capture time; a frame captured after t0 + 5.0 s never counts. The fallback timer gives in-flight frames 0.3 s, so the process always reaches a decision by about t0 + 5.3 s of wall time.
- **Stored settings:** `config.json` values are range-checked on load (exit 2 if out of range), and the threshold must be in [0.2, 0.99]. This hardens the "invalid input behaviour" rule after the review.

| ID | Status | Exhaustive or bounded | Implementation evidence | Formal evidence | Outstanding gap |
|---|---|---|---|---|---|
| R1 | passed | — | `swift build` (debug and release) | — | — |
| R2 | partially verified | — | The code maps `.denied`/`.restricted` to exit 2 with a System Settings hint (`Camera.ensurePermission`) | — | Not run with permission actually denied: needs you |
| R3 | passed tests | bounded (synthetic) | `GateTests` (0 faces, 2 faces, quality, IoU, gap) | — | No recorded `two-faces` fixture yet |
| R4 | passed tests | — | `AlignmentTests` (eyes land within 1 px; inverse); model output parity | — | Not checked on a live face |
| R5 | passed | — | Conversion log, pinned SHA-256, parity 1.00000; README records source and license | — | — |
| R6 | partially verified | — | `StoreTests` and `HardeningTests` (0700/0600, round trip, only `enrollment.json` written, exactly 5 + mean, dimension must match the model) | — | Live `enroll` not run (needs your face) |
| R7 | passed tests (synthetic) | bounded | `BlinkTests` (incl. the rev-3 regression `constantLowEarNeverBlinks` and `slowDriftThroughMiddleBandIsNotABlink`) | — | Recorded `blink`/`open`/`photo` fixtures missing; a tilted photo may fake a blink (review finding 3, untested) |
| R8 | passed tests (synthetic) | bounded | `TurnTests` (left/right, 3-frame hold, wrong direction, sign) | Wrong turn modelled | Yaw sign on this camera not yet measured |
| R9 | passed tests (synthetic) | bounded | `MotionTests` (static, translated, zoomed photo rejected; live accepted) | — | Recorded `photo` fixture and live calibration missing |
| R10 | satisfied in model; passed tests | exhaustive (model, 3875 states); kernel grid | `VerifySessionTests`, `VerifyKernelTests.exhaustive` | `formal/verify_model.py` exit 0; `--faulty` gives a counterexample | Live end-to-end verify not run |
| R11 | satisfied in model; passed tests | exhaustive (model) | `tickFiresDeadlineWithoutFrames`, `frameAfterDeadlineIsNotEvaluated`; 3 s camera-start limit in `FramePipeline.first` | No non-final state past tick 50; no deadlock | 3 s camera limit not exercised at runtime |
| R12 | passed tests + runtime (error paths) | — | Exit-code tests; runtime exit 2 paths listed above; usage errors exit 2; Core ML and camera failures now throw → exit 2 (review finding 4) | — | Exit 0/1 not observed live; camera-failure path not exercised at runtime |
| R13 | unrun | — | `calibrate` implemented; it requires ≥ 20 frames per phase (review finding 12) | — | Needs you, live and with a phone photo; the README threshold row is empty |
| R14 | partially verified | — | `hud-demo`: notch frame 360×120 at top centre, focus unchanged, on screen in 0.09–0.11 s (warm); `verify` and `enroll` now show the HUD before loading the model (review finding 6) | — | First launch after a rebuild took 0.71 s (> 0.5 s). Over a full-screen app and on an external display: not tested. The frontmost app during the test was `loginwindow`, so the screen may have been locked. |
| R15 | passed | — | `docs/hud/*.png` for all states, notch and pill | — | — |
| R16 | passed tests | — | `VerifyControllerTests` (a throwing sink gives the same outcomes); `--no-hud` path; no-GUI fallback via `GUISession` | — | Not run over SSH |
| R17 | passed (demo) | — | `hud-demo`: collapse 0.92–0.94 s after the result (≤ 1.0 s) | — | Tight margin; not measured in a live verify |
| R18 | passed | — | `hud-snapshots` animation check | — | Not observed live with the setting on |
| R19 | passed tests | — | `make -C pam test` 16/16: exit 0 → SUCCESS; 1, 2, hang (2 s and default 10 s), world-writable, symlink, `/../`, missing or relative path → AUTH_ERR | — | Not loaded into the real `sudo`; the root-only parent-directory check is not testable without root |
| R20 | unrun | — | `pam/install.sh` (only `sudo_local`, prints the `/etc/pam.d/sudo` checksum before and after) and `uninstall.sh`; recovery in the README | — | Needs your OK to run with sudo |
| R21 | passed | — | Unit tests use synthetic and recorded landmark data, never the camera | — | Recorded fixtures still to be added |
| R22 | passed (review) | — | README sections: setup, usage, threshold table, model and license, limitations | — | Threshold value not filled in yet |

**Assumptions.**

| ID | Status |
|---|---|
| A1 | Confirmed by `hud-demo`. |
| A2 | Open. To be tested at install time. |
| A3 | Open. Needs a live run. |
| A4 | Partly false: `swift test` with only the Command Line Tools needs extra `-F`/rpath flags, which `scripts/test.sh` adds. Running it under Xcode needs `sudo xcodebuild -license`, which was not done. |
| A5 | Confirmed: `MLModel.compileModel` works without Xcode. |

**Reproduce.**

```bash
swift build -c release
./scripts/test.sh
python3 formal/verify_model.py
python3 formal/verify_model.py --faulty
make -C pam test
.build/release/faceauth self-test
.build/release/faceauth hud-snapshots docs/hud
.build/release/faceauth hud-demo
```

**Independent review.** A separate agent that did not write the code reviewed `git diff 8045213..HEAD` against this spec. It was given the spec and the diff, not my conclusions. I checked each of its 12 findings against the code.

| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | Security rests on user-writable files: config tunables, user model and cache, enrollment | high | **Fixed in rev 4.** Config is range-checked; `sudo` now uses a root-owned enrollment and config, and an installed root-owned compiled model (see the rev 4 report below). |
| 2 | Recorded fixtures absent; the yaw sign comes from calibrate, not a fixture | medium | **Open** (needs you): see Outstanding gaps. |
| 3 | A tilted static photo may fake a blink or turn | medium | **Open** (untested; spec gap). README corrected; it no longer claims tilting is cancelled. |
| 4 | Embedding and camera errors gave exit 1, not 2 | medium | **Fixed.** |
| 5 | Model output dimension not checked; not exactly 5 embeddings | low–medium | **Fixed** and tested. |
| 6 | HUD shown only after the model and camera load | medium | **Fixed.** |
| 7 | Ticker vs. in-flight frame near the deadline; clock type | low | **Fixed** with a 0.3 s grace; the clock is documented above. |
| 8 | Camera stop delayed the exit after the HUD collapse | low | **Fixed** (camera stops at the decision). |
| 9 | Stray backup and marker files in `/etc/pam.d`; uninstall could wipe user lines | low–medium | **Fixed** (state kept in `/usr/local/share/faceauth`; uninstall removes only our line). |
| 10 | PAM `stat` follows symlinks; parent directories not checked | low | **Fixed** and tested (unprivileged part). |
| 11 | Middle-band frames did not count toward the 8-frame blink limit | low | **Fixed** and tested. |
| 12 | `calibrate` did not enforce n ≥ 20 | low | **Fixed.** |

**Outstanding gaps.** These need you, the live camera or sudo, so I could not run them.
- **Live camera runs:** `enroll`, `calibrate` (choose and record the threshold) and `verify` (exit 0 for you; exit 1 for a phone photo).
- **Fixtures:** record the six fixtures in `Tests/FaceAuthCoreTests/Fixtures/README.md`, then rerun `./scripts/test.sh` so the skipped R3/R7/R8/R9 tests run. Add a tilted-photo recording.
- **R2:** deny camera permission once and check for exit 2.
- **R14:** check the HUD over a full-screen app and on an external display.
- **R20 / A2:** run `pam/install.sh` (asks for sudo) with a `sudo -s` shell open, then test `sudo -k; sudo true`.
- **Finding 1:** resolved by revision 4; see below.

### Revision 4 verification (2026-11-14)
Commits `9350d5c`, `3779283`, `a1ab722`, `723fe26` and `573a60e` on the same branch, all local.

| Check | Command | Result |
|---|---|---|
| Build | `swift build`, `swift build -c release` | Both complete with no errors. |
| Unit tests | `./scripts/test.sh` | 93 tests in 17 suites passed; 6 recorded-fixture tests skipped. One earlier run crashed with SIGPIPE (signal 13) in `readStopsAfterTheLimit`. That also exposed a real risk: a SIGPIPE in the PAM module would kill `sudo`. Fixed with `F_SETNOSIGPIPE` in both the test and the module. |
| Formal model | `python3 formal/verify_model.py` (and `--faulty`) | R10 and R11 still satisfied: 3875 states, exit 0. The seeded fault still gives exit 1. The decision logic did not change in rev 4. |
| PAM module | `make -C pam test` | 27/27 checks passed. They include the exact fd-3 bundle; a verifier that never reads a 60 KB store is killed at 2.01 s with no hang; and 8 invalid-store cases (missing, wrong modes, symlink, over 64 KiB, empty, store root mode 0755) each return AUTH_ERR **without starting the verifier**. |
| CLI preconditions | `faceauth enroll/calibrate --system` without sudo; `unenroll` without `--system`; `--system` on verify; `--store-fd` on enroll | All exit 2 with a message. |
| `--store-fd` | malformed, oversize (70 KB), wrong-model bundle on fd 3 | Exit 2 before the camera opens. |
| Installed-model rule | valid bundle on fd 3 from a non-installed binary; `capture-helper` run by the user; `install-model` without root | All exit 2 ("installed face model is missing or not root-owned" / "must run as root"). |
| Development path | `faceauth self-test` | Unchanged: 128-d, norm 1.0000, about 5 ms per frame. |

| ID | Status | Exhaustive or bounded | Implementation evidence | Formal evidence | Outstanding gap |
|---|---|---|---|---|---|
| R23 | passed tests + runtime (error paths) | — | C: fd 3 carries exactly `{enrollment, config}` from the root store; Swift `StoreBundleTests`; `--store-fd` never reads the user store or starts first-run enrollment (code path); sudo-side processes use only the installed model | — | Not run under real `sudo`. The runtime check (tamper with the user store, sudo result unchanged) needs install. |
| R24 | passed tests | bounded (8 constructed cases) | `make -C pam test` invalid-store cases; Swift `SystemStoreTests.symlinkedFileIsRefused` | — | The root:wheel owner check only runs as root, so it is untested here. |
| R25 | partially verified | — | Without sudo → exit 2; helper protocol and frame validation tests; root writes via the O_EXCL temp file then rename, then chown 0:0 | — | Live `sudo … enroll --system` not run (needs your OK, your face, and A6) |
| R26 | partially verified | — | Shared calibrate code with range checks (`HardeningTests`) | — | Live `calibrate --system` not run |
| R27 | passed tests | — | C: "no store for this user → AUTH_ERR, verifier not started" | — | Not under real `sudo` |
| R28 | passed tests + runtime | — | `StoreBundleTests` (oversize, malformed, ranges, model and dimension, non-unit vectors, pipe read limit); runtime exit 2 on fd 3 | — | — |
| R29 | partially verified | — | `SystemStoreTests.unenrollRemovesOnlyThatUser`; uninstall lists the store and asks y/N; EOF keeps the data | — | Live `unenroll --system` and uninstall not run |
| R30 | passed (review) | — | README "What the root-owned copy fixes" / "What it does not fix", including helper-computed embeddings and helper or verifier control | — | — |
| R31 | passed tests | — | `CameraSelectionTests` (external, virtual, Continuity, empty → none in strict mode); wired in `Camera.selectCamera` for `--store-fd` and the helper | — | Whether a legacy DAL virtual camera can report built-in transport is not verified |

**Interpretations made during implementation (rev 4).**
- **Model under sudo:** the verifier and the capture helper must use the installed model. `install.sh` compiles it once as root (`faceauth install-model`), and the result must be root-owned with root-owned parent directories. Under `sudo` there is no compile step and no user-writable cache. This follows from the rev 4 goal; the review showed that model files, not just data, could be swapped.
- **Helper limits:** the capture helper gets 10 s for its first frame (process start, model load and camera). After that, 3 s with no frame is an error. Q7's 3 s limit applies to `verify`, which is unchanged.

**Independent review (rev 4).** A separate agent reviewed `git diff 184a685..HEAD` against revision 4. It was given the spec and the diff, not my conclusions. I checked all 8 findings against the code.

| # | Finding | Severity | Disposition |
|---|---|---|---|
| 1 | Verifier and helper could fall back to user-writable models or caches if the installed model check failed; parent directories not checked | medium | **Fixed** (installed precompiled model only, full root chain; runtime exit 2 checks) |
| 2 | Compiling as the user in the user's temp directory: race to swap the compiled weights | medium (uncertain) | **Fixed** (no compile under sudo; root compiles at install) |
| 3 | Helper exited before showing the result HUD | low | **Fixed** |
| 4 | 3 s first-frame limit too short for helper start-up | low (uncertain) | **Fixed** (10 s for the helper) |
| 5 | Unbounded frame buffer; blocking command writes; no frame-gap timeout | low | **Fixed** |
| 6 | README overstated root's checks and the model's root chain | low | **Fixed** |
| 7 | `uninstall.sh` aborted on EOF at the y/N prompt | low | **Fixed** |
| 8 | PAM child closed descriptors only up to 255 | low | **Fixed** (`getdtablesize`) |

**Outstanding gaps (rev 4).** These all need sudo and your face; I have not run them.
1. Open a `sudo -s` shell first.
2. Run `sh pam/install.sh`. It must print no WARNING about parent directories.
3. Run `sudo /usr/local/libexec/faceauth enroll --system`, which also tests A6.
4. Run `sudo /usr/local/libexec/faceauth calibrate --system`.
5. Run `sudo -k; sudo true` (and try a phone photo).
6. Tamper with `~/Library/Application Support/faceauth/` and confirm `sudo` behaves the same (R23).
7. Run `sudo /usr/local/libexec/faceauth unenroll --system` and confirm `sudo` asks for the password (R27, R29).
