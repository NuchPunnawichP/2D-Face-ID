# Papers

The PDFs are downloaded here for reading. They are git-ignored because the
authors and publishers hold the copyright. To fetch them again:

```bash
curl -L -o docs/papers/arcface-1801.07698.pdf https://arxiv.org/pdf/1801.07698
curl -L -o docs/papers/mobilefacenets-1804.07573.pdf https://arxiv.org/pdf/1804.07573
curl -L -o docs/papers/soukupova-cech-2016-eye-blink-ear.pdf https://vision.fe.uni-lj.si/cvww2016/proceedings/papers/05.pdf
```

| File | Paper | Used for |
|---|---|---|
| `arcface-1801.07698.pdf` | Deng et al., *ArcFace: Additive Angular Margin Loss for Deep Face Recognition*, CVPR 2019 | The training loss of the embedding model, and the 112×112 alignment template |
| `mobilefacenets-1804.07573.pdf` | Chen et al., *MobileFaceNets: Efficient CNNs for Accurate Real-Time Face Verification on Mobile Devices*, 2018 | The embedding network |
| `soukupova-cech-2016-eye-blink-ear.pdf` | Soukupová & Čech, *Real-Time Eye Blink Detection using Facial Landmarks*, CVWW 2016 | The eye aspect ratio (EAR) used for blink detection |
