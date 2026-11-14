# Recorded landmark fixtures

These JSON files are landmark sequences recorded from the real camera. They hold
landmark coordinates, yaw, pitch and quality only, never images.

Record each one with:

```bash
swift run faceauth record-landmarks Tests/FaceAuthCoreTests/Fixtures/<name>.json --label <label> --seconds 4
```

| Label | What to do while recording | The tests expect |
|---|---|---|
| `blink` | Look at the camera and blink once or twice | a blink, and motion |
| `open` | Look at the camera and keep your eyes open, without blinking | no blink |
| `photo` | Hold a phone showing a photo of your face in front of the camera, and move it around a little | no blink, no motion |
| `turn-left` | Turn your head to *your* left and hold it there | the turn passes "left" and fails "right"; this also fixes the yaw sign |
| `turn-right` | Turn your head to *your* right and hold it there | the opposite of `turn-left` |
| `two-faces` | Have a second face, or a photo of one, in the frame | at least one 2-face frame, never valid |

Tests for a label that has no fixture yet are skipped, and the skip is reported in the test output.
