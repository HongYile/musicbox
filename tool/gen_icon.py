#!/usr/bin/env python3
"""用第三方图像 API（gpt-image）生成 Unison 新图标。
从项目 .env 读 YUNWU_BASE_URL / YUNWU_API_KEY（不打印任何密钥）。
输出 /tmp/unison-icon-new.png（1024x1024，全出血方形，系统自行套圆角）。
"""
import base64
import json
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENV = os.path.join(ROOT, ".env")

def load_env(path):
    cfg = {}
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"').strip("'")
    return cfg

def main():
    cfg = load_env(ENV)
    base = cfg["YUNWU_BASE_URL"].rstrip("/")
    key = cfg["YUNWU_API_KEY"]
    prompt = (
        "Modern music app icon artwork, completely full-bleed edge-to-edge square image, "
        "the background gradient fills the ENTIRE canvas to every edge and corner with ZERO margins, "
        "ZERO white border, no rounded corners, no frame: "
        "smooth gradient from violet #7C4DFF (top-left) to magenta-pink #EC407A (bottom-right), "
        "a pair of minimalist white over-ear headphones centered, two soft concentric sound-wave arcs "
        "emanating from the ear cups, flat vector style, clean, no text. "
        "IMPORTANT: gradient covers 100% of the image, corners included."
    )
    body = json.dumps({
        "model": "gpt-image-2",
        "prompt": prompt,
        "size": "1024x1024",
        "n": 1,
    }).encode()
    req = urllib.request.Request(
        base + "/v1/images/generations",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": "Bearer " + key,
        },
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        data = json.load(resp)
    item = data["data"][0]
    out = "/tmp/unison-icon-new.png"
    if item.get("b64_json"):
        with open(out, "wb") as f:
            f.write(base64.b64decode(item["b64_json"]))
    else:
        urllib.request.urlretrieve(item["url"], out)
    print("saved:", out, os.path.getsize(out), "bytes")

if __name__ == "__main__":
    main()
