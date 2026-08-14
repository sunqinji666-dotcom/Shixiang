#!/usr/bin/env python3
"""Turn one local sound-search request into controlled keywords with Qwen3 1.7B."""

import argparse
import json
import sys

from mlx_lm import generate, load
from mlx_lm.sample_utils import make_sampler


SYSTEM_PROMPT = """You convert a search sentence for a local sound-effects library into concise retrieval keywords.
Return exactly one JSON object and nothing else: {\"keywords\":[\"...\"]}.
Use 2 to 8 useful Chinese or English sound-search terms. Preserve only sound type, material, mood,
movement, scene, and duration words that are explicit in the request or are a direct translation.
Never infer extra mood, tempo, genre, use-case, or a broader sound category. Never output generic
library words such as "sound", "sounds", "sound effect", "effects", "audio", "soundtrack", "SFX",
"音效", "声音", "音频", or "素材". Do not invent file names. Do not explain your answer.
Example: for "风" return only direct equivalents such as ["风", "wind"], never "sound" or "nature"."""


def extract_json(value: str) -> dict:
    start = value.find("{")
    end = value.rfind("}")
    if start < 0 or end < start:
        raise ValueError("model response did not contain JSON")
    payload = json.loads(value[start : end + 1])
    keywords = payload.get("keywords")
    if not isinstance(keywords, list):
        raise ValueError("model response did not contain keywords")
    return {"keywords": [item.strip() for item in keywords if isinstance(item, str) and item.strip()]}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--query", required=True)
    args = parser.parse_args()

    model, tokenizer = load(args.model)
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": args.query},
    ]
    try:
        prompt = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
            enable_thinking=False,
        )
    except TypeError:
        prompt = tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True) + "/no_think"
    response = generate(
        model,
        tokenizer,
        prompt=prompt,
        max_tokens=110,
        sampler=make_sampler(temp=0.0, top_p=1.0, min_p=0.0, min_tokens_to_keep=1),
    )
    print(json.dumps(extract_json(response), ensure_ascii=False, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
