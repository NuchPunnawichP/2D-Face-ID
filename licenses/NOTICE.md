# Third-party components in the faceauth DMG

| Component | Source | License |
|---|---|---|
| MobileFaceNet weights (converted to Core ML as `MobileFaceNet.mlpackage`) | https://github.com/foamliu/MobileFaceNet, release v1.0, `mobilefacenet_scripted.pt` (SHA-256 `780e31e7c2639a0d5fdebe843f5df3ff81fda79a090164df0ff40514d172853a`) | Apache-2.0, see `MobileFaceNet-LICENSE` |

The weights were converted by `scripts/convert_model.py`. The conversion freezes
the TorchScript graph, adds ImageNet normalisation, embeds the face and its
mirror image and sums the two, L2-normalises the result, and converts it with
coremltools. That is a modification of the original model.

The model was trained on refined MS-Celeb-1M, a research dataset that Microsoft
withdrew in 2019. See the README.
