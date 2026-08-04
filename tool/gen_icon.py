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
        "App icon artwork, full-bleed square canvas with deep dark purple #1B1430 background "
        "covering every pixel to the corners. Centered composition: a large circle like a round face, "
        "slightly lighter purple #2A2045 fill. Inside the circle, as the 'face', three vertical "
        "rounded equalizer bars with violet-to-pink gradient (#7C4DFF to #EC407A), middle bar shorter. "
        "Over the circle, a THIN WHITE OUTLINE of over-ear headphones — only the outline stroke "
        "(headband arc over the top + two earcup outlines on the sides), NOT filled, NOT realistic, "
        "simple one-line contour in the style of the classic TTPlayer (千千静听) headphone logo. "
        "Flat minimal vector, generous negative space, no text."
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
