#!/usr/bin/env python3
# 把 p208p2002/zh-wiki-punctuation-restore (BertForTokenClassification, bert-base-chinese)
# 转成 CoreML int8，并在 PyTorch / CoreML 两端各验证一遍补标点是否正确。
import os, sys, json
import numpy as np
import torch
from transformers import AutoTokenizer, AutoModelForTokenClassification

REPO = "p208p2002/zh-wiki-punctuation-restore"
SEQ = 256
OUT = "/tmp/punct_build"
os.makedirs(OUT, exist_ok=True)

ID2P = {0: "", 1: "，", 2: "、", 3: "。", 4: "？", 5: "！", 6: "；"}

TESTS = [
    "你好今天天气不错我们一起去公园散步吧这是一段用来测试语音识别的中文录音",
    "请问现在几点了我有点饿了我们去吃饭好不好",
    "这个方案我觉得可行但是还要再确认一下细节",
]

print("== 加载模型/分词器 ==", flush=True)
tok = AutoTokenizer.from_pretrained(REPO)
# eager 注意力 + 旧版 transformers：避免 sdpa/masking_utils 产生 coremltools 不认的 new_ones 算子。
model = AutoModelForTokenClassification.from_pretrained(REPO, attn_implementation="eager").eval()
print("labels:", model.config.id2label, flush=True)

def restore_torch(text):
    enc = tok(text, return_offsets_mapping=True, return_tensors="pt",
              truncation=True, max_length=SEQ)
    offs = enc.pop("offset_mapping")[0].tolist()
    with torch.no_grad():
        logits = model(**enc).logits[0]          # [seq,7]
    labels = logits.argmax(-1).tolist()
    return _reinsert(text, offs, labels)

def _reinsert(text, offs, labels):
    # 在每个 token 的 end 偏移处插入其预测标点（跳过 special token：offset==(0,0)）。
    inserts = {}
    for (s, e), lab in zip(offs, labels):
        if e == 0 and s == 0:      # [CLS]/[SEP]/pad
            continue
        p = ID2P.get(lab, "")
        if p:
            inserts[e] = p
    out = []
    for i, ch in enumerate(text):
        out.append(ch)
        if (i + 1) in inserts:
            out.append(inserts[i + 1])
    return "".join(out)

print("\n== PyTorch 验证 ==", flush=True)
for t in TESTS:
    print(f"  in : {t}\n  out: {restore_torch(t)}", flush=True)

# ---- 转 CoreML ----
print("\n== 转 CoreML（trace, seq=%d） ==" % SEQ, flush=True)
import coremltools as ct

class Wrap(torch.nn.Module):
    def __init__(self, m): super().__init__(); self.m = m
    def forward(self, input_ids, attention_mask, token_type_ids):
        return self.m(input_ids=input_ids, attention_mask=attention_mask,
                      token_type_ids=token_type_ids).logits

wrap = Wrap(model).eval()
ex = (torch.zeros(1, SEQ, dtype=torch.long),
      torch.ones(1, SEQ, dtype=torch.long),
      torch.zeros(1, SEQ, dtype=torch.long))
traced = torch.jit.trace(wrap, ex, strict=False)

mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="input_ids", shape=(1, SEQ), dtype=np.int32),
        ct.TensorType(name="attention_mask", shape=(1, SEQ), dtype=np.int32),
        ct.TensorType(name="token_type_ids", shape=(1, SEQ), dtype=np.int32),
    ],
    outputs=[ct.TensorType(name="logits")],
    convert_to="mlprogram",
    minimum_deployment_target=ct.target.macOS13,
    compute_units=ct.ComputeUnit.ALL,
)

print("== int8 量化 ==", flush=True)
try:
    from coremltools.optimize.coreml import linear_quantize_weights, OpLinearQuantizerConfig, OptimizationConfig
    cfg = OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric", weight_threshold=512))
    mlmodel = linear_quantize_weights(mlmodel, config=cfg)
except Exception as e:
    print("  量化失败，保留 fp16:", e, flush=True)

pkg = os.path.join(OUT, "PunctZh.mlpackage")
mlmodel.save(pkg)
sz = sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fs in os.walk(pkg) for f in fs)
print(f"已保存 {pkg}  ({sz/1e6:.1f} MB)", flush=True)

# 导出 vocab + 标签，供 Swift 端用
tok.save_pretrained(os.path.join(OUT, "tok"))
with open(os.path.join(OUT, "labels.json"), "w") as f:
    json.dump(ID2P, f, ensure_ascii=False)

# ---- CoreML 复验 ----
print("\n== CoreML 验证 ==", flush=True)
def restore_coreml(text):
    enc = tok(text, return_offsets_mapping=True, truncation=True, max_length=SEQ)
    offs = enc["offset_mapping"]
    ids = enc["input_ids"]; mask = enc["attention_mask"]
    n = len(ids)
    def pad(a): return np.array(a + [0]*(SEQ-n), dtype=np.int32).reshape(1, SEQ)
    out = mlmodel.predict({
        "input_ids": pad(ids),
        "attention_mask": pad(mask),
        "token_type_ids": np.zeros((1, SEQ), dtype=np.int32),
    })
    logits = out["logits"][0][:n]
    labels = np.argmax(logits, axis=-1).tolist()
    return _reinsert(text, offs, labels)

ok = True
for t in TESTS:
    rt, rc = restore_torch(t), restore_coreml(t)
    same = "✅" if rt == rc else "❌不一致"
    if rt != rc: ok = False
    print(f"  {same}\n   torch : {rt}\n   coreml: {rc}", flush=True)

print("\nDONE ok=%s" % ok, flush=True)
