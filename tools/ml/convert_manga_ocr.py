#!/usr/bin/env python3
"""manga-ocr (kha-white/manga-ocr-base) -> two CoreML packages.

  MangaOCREncoder.mlpackage : image (224x224 grayscale) -> encoder_hidden_states [1,197,768]
  MangaOCRDecoder.mlpackage : input_ids [1,T] + encoder_hidden_states -> logits [1,T,6144]
                              (T flexible 1..MAX_LEN; greedy loop is done in Swift)

Preprocessing baked into the encoder input: gray -> 3 channels, x/127.5 - 1
(manga-ocr converts to L then RGB and normalizes mean=std=0.5).
"""
import sys, os, json, time, numpy as np, torch, torch.nn as nn, coremltools as ct
from transformers import VisionEncoderDecoderModel
from PIL import Image, ImageDraw, ImageFont

SRC = sys.argv[1]; OUT = sys.argv[2]; MAX_LEN = 128
os.makedirs(OUT, exist_ok=True)
m = VisionEncoderDecoderModel.from_pretrained(SRC).eval()
V = m.config.decoder.vocab_size

class Enc(nn.Module):
    def __init__(s, e): super().__init__(); s.e = e
    def forward(s, gray):                       # [1,1,224,224] already scaled to [-1,1]
        return s.e(pixel_values=gray.repeat(1, 3, 1, 1)).last_hidden_state

class Dec(nn.Module):
    def __init__(s, d): super().__init__(); s.d = d
    def forward(s, input_ids, enc):
        return s.d(input_ids=input_ids, encoder_hidden_states=enc).logits

enc, dec = Enc(m.encoder).eval(), Dec(m.decoder).eval()
gray = torch.zeros(1, 1, 224, 224)
ids = torch.tensor([[2, 100, 200, 300]], dtype=torch.int32)
with torch.no_grad():
    hs = enc(gray)
    t_enc = torch.jit.trace(enc, gray)
    t_dec = torch.jit.trace(dec, (ids, hs))

t0 = time.time()
enc_ml = ct.convert(t_enc,
    inputs=[ct.ImageType(name="image", shape=(1, 1, 224, 224), color_layout=ct.colorlayout.GRAYSCALE, scale=1/127.5, bias=[-1.0])],
    outputs=[ct.TensorType(name="encoder_hidden_states")],
    minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
enc_ml.save(os.path.join(OUT, "MangaOCREncoder.mlpackage"))
print(f"encoder converted {time.time()-t0:.0f}s", flush=True)

t0 = time.time()
dec_ml = ct.convert(t_dec,
    inputs=[ct.TensorType(name="input_ids", shape=(1, ct.RangeDim(1, MAX_LEN, default=8)), dtype=np.int32),
            ct.TensorType(name="encoder_hidden_states", shape=(1, 197, 768))],
    outputs=[ct.TensorType(name="logits")],
    minimum_deployment_target=ct.target.iOS17, compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
dec_ml.save(os.path.join(OUT, "MangaOCRDecoder.mlpackage"))
print(f"decoder converted {time.time()-t0:.0f}s", flush=True)

# ---- parity check: synthetic vertical Japanese text, PyTorch generate vs CoreML greedy ----
vocab = [l.rstrip("\n") for l in open(os.path.join(SRC, "vocab.txt"), encoding="utf-8")]
def render(text):
    img = Image.new("L", (224, 224), 255); d = ImageDraw.Draw(img)
    font = None
    for f in ["/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc", "/System/Library/Fonts/Hiragino Sans GB.ttc", "/System/Library/Fonts/Supplemental/Arial Unicode.ttf"]:
        if os.path.exists(f):
            try: font = ImageFont.truetype(f, 34); break
            except Exception: pass
    y = 20
    for ch in text: d.text((95, y), ch, fill=0, font=font); y += 36
    return img
img = render("今日は")
x = torch.from_numpy((np.asarray(img, dtype=np.float32) / 127.5 - 1.0)[None, None])
with torch.no_grad():
    ref = m.generate(pixel_values=x.repeat(1, 3, 1, 1), max_length=MAX_LEN)[0].tolist()
def decode(ids): return "".join(vocab[i] for i in ids if i > 4)
enc_out = enc_ml.predict({"image": img})["encoder_hidden_states"]
seq = [2]
for _ in range(MAX_LEN - 1):
    lg = dec_ml.predict({"input_ids": np.array([seq], dtype=np.int32), "encoder_hidden_states": enc_out})["logits"]
    nxt = int(np.argmax(lg[0, -1])); seq.append(nxt)
    if nxt == 3: break
print("pytorch:", decode(ref), ref[:12]); print("coreml :", decode(seq), seq[:12])
print("PARITY", "OK" if decode(ref) == decode(seq) else "MISMATCH")
json.dump({"max_len": MAX_LEN, "vocab": len(vocab), "cls": 2, "sep": 3, "pad": 0}, open(os.path.join(OUT, "manga-ocr.json"), "w"))
for name in ["MangaOCREncoder", "MangaOCRDecoder"]:
    p = os.path.join(OUT, name + ".mlpackage"); size = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs)
    print(f"{name}: {size/2**20:.0f} MB")
