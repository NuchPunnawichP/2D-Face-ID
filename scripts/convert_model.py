"""Download MobileFaceNet (foamliu/MobileFaceNet, Apache-2.0) and convert it to Core ML.

Usage (from the repository root):
    python3 -m venv scripts/.venv
    scripts/.venv/bin/pip install -r scripts/requirements.txt
    scripts/.venv/bin/python -I scripts/convert_model.py

Output: models/MobileFaceNet.mlpackage. faceauth looks for it there, or in
~/Library/Application Support/faceauth/models/ once installed.

Source and license
  Repository: https://github.com/foamliu/MobileFaceNet (LICENSE: Apache-2.0)
  Weights:    the v1.0 release asset mobilefacenet_scripted.pt (TorchScript).
  We use the TorchScript file rather than mobilefacenet.pt because loading a
  TorchScript archive does not unpickle arbitrary Python objects.
  Training data: refined MS-Celeb-1M (see README, "Model").

The Core ML model:
  input  "face":      112x112 RGB image (pixel values 0-255), aligned with the
                      ArcFace 5-point template (eyes at (38.29, 51.70) and
                      (73.53, 51.50)).
  output "embedding": 128 floats, L2-normalized. The model embeds the face and
                      its mirror image and sums the two before normalizing,
                      as the repository's LFW evaluation does.
"""
import hashlib
import os
import sys
import urllib.request

WEIGHTS_URL = "https://github.com/foamliu/MobileFaceNet/releases/download/v1.0/mobilefacenet_scripted.pt"
# Pinned after the first download (2026-11-14). A different file is refused.
WEIGHTS_SHA256 = "780e31e7c2639a0d5fdebe843f5df3ff81fda79a090164df0ff40514d172853a"
MODEL_ID = "foamliu-mobilefacenet-v1.0-flipsum"

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DOWNLOAD_DIR = os.path.join(ROOT, "models", "download")
OUT = os.path.join(ROOT, "models", "MobileFaceNet.mlpackage")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download():
    os.makedirs(DOWNLOAD_DIR, exist_ok=True)
    path = os.path.join(DOWNLOAD_DIR, "mobilefacenet_scripted.pt")
    if not os.path.exists(path):
        print(f"Downloading {WEIGHTS_URL}")
        req = urllib.request.Request(WEIGHTS_URL, headers={"User-Agent": "faceauth-convert"})
        with urllib.request.urlopen(req) as r, open(path + ".part", "wb") as f:
            f.write(r.read())
        os.rename(path + ".part", path)
    digest = sha256(path)
    print(f"SHA-256 {digest}  {os.path.getsize(path)} bytes")
    if WEIGHTS_SHA256 == "PIN_ME":
        print("No checksum is pinned yet: record the value above in WEIGHTS_SHA256.")
    elif digest != WEIGHTS_SHA256:
        sys.exit(f"Checksum mismatch: expected {WEIGHTS_SHA256}. Refusing to convert.")
    return path


def convert(weights):
    import numpy as np
    import torch
    import coremltools as ct

    net = torch.jit.load(weights, map_location="cpu").eval()

    class Wrapped(torch.nn.Module):
        """Pixels 0..1 in, normalized 128-d embedding out."""

        def __init__(self, net):
            super().__init__()
            self.net = net
            self.register_buffer("mean", torch.tensor([0.485, 0.456, 0.406]).view(1, 3, 1, 1))
            self.register_buffer("std", torch.tensor([0.229, 0.224, 0.225]).view(1, 3, 1, 1))

        def forward(self, x):
            x = (x - self.mean) / self.std
            e = self.net(x) + self.net(torch.flip(x, dims=[3]))
            return e / torch.linalg.vector_norm(e, dim=1, keepdim=True).clamp_min(1e-12)

    # Script the wrapper around the scripted network, then freeze the whole
    # thing: freezing folds the train/eval branches baked into the TorchScript
    # file into constants, leaving a straight-line graph coremltools converts.
    model = torch.jit.freeze(torch.jit.script(Wrapped(net).eval()))
    example = torch.rand(1, 3, 112, 112)
    with torch.no_grad():
        ref = model(example).numpy()
    traced = model

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="face", shape=(1, 3, 112, 112), scale=1 / 255.0,
                             color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="embedding")],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS14,
        compute_precision=ct.precision.FLOAT32,
    )
    mlmodel.author = "foamliu/MobileFaceNet (Apache-2.0), converted by faceauth"
    mlmodel.license = "Apache-2.0"
    mlmodel.short_description = "MobileFaceNet face embedding (flip-sum, L2-normalized, 128-d)"
    mlmodel.user_defined_metadata["faceauth.model_id"] = MODEL_ID
    mlmodel.user_defined_metadata["faceauth.source"] = WEIGHTS_URL
    mlmodel.save(OUT)
    print(f"Saved {OUT}")

    # Check the Core ML model against PyTorch on the same input.
    try:
        from PIL import Image
        img = Image.fromarray((example[0].permute(1, 2, 0).numpy() * 255).round().astype(np.uint8))
        out = mlmodel.predict({"face": img})["embedding"].reshape(-1)
        cos = float(np.dot(out, ref.reshape(-1)) / np.linalg.norm(out) / np.linalg.norm(ref))
        print(f"Core ML vs PyTorch cosine on a random input: {cos:.5f} (expect > 0.999)")
        if cos < 0.999:
            sys.exit("Converted model does not match PyTorch.")
    except ImportError:
        print("Pillow is not installed; skipped the Core ML vs PyTorch check.")


if __name__ == "__main__":
    convert(download())
