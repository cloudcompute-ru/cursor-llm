# cursor-llm

A reproducible, one-command setup that turns a single rented GPU into a private,
OpenAI-compatible inference endpoint you can paste into **[Cursor](https://cursor.com)**
(or any other tool that speaks the OpenAI API — Continue.dev, Cline, Aider,
`curl`, your own scripts) as a custom model.

It runs **[Qwen 2.5 Coder 32B Instruct](https://huggingface.co/Qwen/Qwen2.5-Coder-32B-Instruct-AWQ)**
(AWQ INT4 quantization, ~22 GB VRAM) behind **[vLLM](https://github.com/vllm-project/vllm)**
and exposes it through a free **Cloudflare quick tunnel** so Cursor can reach
it over HTTPS without any DNS or certificate setup on your side.

The whole pipeline — vLLM install, model download (~20 GB), server startup,
tunnel — takes 5-10 minutes on a fresh container and prints a Cloudflare URL +
generated API key + model name you paste straight into Cursor's **Settings →
Models → Add custom model** dialog.

## Hardware

Single NVIDIA GPU with **at least 24 GB VRAM** and a recent CUDA-capable
driver. Tested on:

- RTX 4090 (24 GB) — sweet spot, ~50 tok/s
- RTX A6000 (48 GB) — comfortable headroom
- A100 80 GB, H100 SXM — overkill but works

Less than 24 GB VRAM won't fit the AWQ INT4 weights + KV cache. If you only
have 12-16 GB, swap `MODEL_ID` to a smaller variant
(`Qwen/Qwen2.5-Coder-7B-Instruct-AWQ` fits 12 GB).

## Run it yourself

In any Linux container with an NVIDIA GPU and a CUDA-capable driver:

```bash
git clone https://github.com/cloudcompute-ru/cursor-llm.git
cd cursor-llm
bash provision.sh
```

When the script reports `provisioning complete` it prints three values:

```
[cc-provision] provisioning complete
[cc-provision]   tunnel: https://three-random-words.trycloudflare.com
[cc-provision]   api key: sk-cc-<32 hex chars>
[cc-provision]   model name: qwen-2.5-coder-32b
```

Paste them into Cursor's **Settings → Models → Add custom model**:

| Cursor field   | Paste                                                |
| -------------- | ---------------------------------------------------- |
| **Base URL**   | `<tunnel URL>/v1`  (e.g. `https://...trycloudflare.com/v1`) |
| **API Key**    | the `sk-cc-...` string                               |
| **Model**      | `qwen-2.5-coder-32b`                                 |

Then enable the model in Cursor and select it from the model picker. You're
now talking to your own GPU.

The tunnel URL stops working when the container stops (or when cloudflared
gets restarted) — every fresh launch generates a new URL and a new API key,
so re-paste them into Cursor each session. We may publish a follow-up
project with stable URLs if there's demand.

### Configurable environment

| Variable             | Default                                          | What it controls                                              |
| -------------------- | ------------------------------------------------ | ------------------------------------------------------------- |
| `MODEL_ID`           | `Qwen/Qwen2.5-Coder-32B-Instruct-AWQ`            | HuggingFace model id to download and serve.                   |
| `SERVED_MODEL_NAME`  | `qwen-2.5-coder-32b`                             | The name clients send in `model:` (decoupled from `MODEL_ID`).|
| `VLLM_PORT`          | `8000`                                           | Internal port vLLM binds. Tunnel always points at this.       |
| `WORKDIR`            | `/workspace`                                     | Where the HF cache and runtime state live.                    |
| `HF_HOME`            | `${WORKDIR}/hf-cache`                            | HuggingFace cache directory.                                  |

The two `CC_*` env vars referenced in `provision.sh` (`CC_PROVISION_URL`,
`CC_AGENT_TOKEN`) are used by the cloudcompute.ru launcher to receive
stage-progress updates and the tunnel URL / API key over HTTP. When they're
absent the script just logs the same values to stdout — running standalone
needs no extra setup.

## Why these choices

A few decisions worth surfacing:

- **AWQ INT4 instead of FP8/FP16.** Q2.5-Coder-32B in AWQ INT4 fits a single
  24 GB consumer card and costs ~$0.40-0.60/hr on Vast.ai, vs ~$1.50-3/hr for
  the FP8 variant on an A100/H100. Quality drop on real coding tasks is small
  but measurable; if you want the bigger GPU experience set `MODEL_ID` to
  `Qwen/Qwen2.5-Coder-32B-Instruct` (unquantized) and pick a 80 GB card.
- **Cloudflare quick tunnel instead of a stable subdomain.** No DNS setup, no
  account, no certificates. Trade-off: the URL rotates every launch. For
  production-style use you'd run a named tunnel through your own Cloudflare
  account instead — same `cloudflared` binary, different command.
- **vLLM instead of Ollama / llama.cpp / TGI.** vLLM has the most mature
  OpenAI-compatible API surface, the best tool/function-calling support for
  Qwen models, and continuous batching that matters when Cursor sends
  parallel autocomplete + chat requests. Other engines are fine for chat-
  only but worse for agent-style workloads.

## One-click launcher (cloudcompute.ru)

These artifacts also back the **["Свой LLM для Cursor"](https://cloudcompute.ru/tutorials/cursor-llm)**
tutorial on cloudcompute.ru. That launcher reads `manifest.yaml` directly from
this repo to pick a matching GPU offer, runs `provision.sh` on the freshly
created container, and surfaces the tunnel URL + API key + model name in the
dashboard as copy-buttons next to a "How to add to Cursor" mini-guide.

If you'd rather skip the manual container setup, click "Запустить" there and
you'll have copy-pasteable settings for Cursor in 5-10 minutes.

The tutorial article (Russian copy, walkthrough, screenshots, FAQ) lives in
the cloudcompute.ru marketing repo, not here — this repo is intentionally
script-only so it stays useful as a generic self-hosted-LLM launcher.

## Licenses

Scripts and configuration in this repo: **MIT** (see `LICENSE`).

The Qwen 2.5 Coder 32B model weights downloaded by `provision.sh` are
distributed by Alibaba under the **Qwen License**, which permits commercial
use up to 100M MAU. See the upstream model card on HuggingFace for details.

vLLM is Apache-2.0; cloudflared is Apache-2.0. This repo installs them at
runtime but does not redistribute or modify them.
