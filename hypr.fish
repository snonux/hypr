# Dual-VM setup (hyperstack-vm1/vm2.toml -> hyperstack1/2.wg1)
# VM1 default model: Qwen3.8 27B FP8 (vLLM); VM2 default: Gemma 4 31B.
abbr pi-hyperstack pi --model hyperstack1/Qwen/Qwen3.8-27B-FP8
abbr pi-hyperstack-coder pi --model hyperstack1/Qwen/Qwen3.8-27B-FP8
abbr pi-hyperstack-qwen38 pi --model hyperstack1/Qwen/Qwen3.8-27B-FP8
abbr pi-hyperstack-qwen36 pi --model hyperstack1/Qwen/Qwen3.6-27B-FP8
abbr pi-hyperstack-gemma4 pi --model hyperstack2/cyankiwi/gemma-4-31B-it-AWQ-4bit
abbr hyperstack-create ruby ~/git/hypr/hyperstack.rb create

# Local Ollama models (this laptop, CPU inference)
abbr pi-ollama-bonsai-ternary-27b pi --provider ollama --model hf.co/prism-ml/Ternary-Bonsai-27B-gguf:Q2_0
abbr pibonsai pi --provider ollama --model hf.co/prism-ml/Ternary-Bonsai-27B-gguf:Q2_0
abbr pibt pi --provider ollama --model hf.co/prism-ml/Ternary-Bonsai-27B-gguf:Q2_0
abbr pi-ollama-bonsai-1bit-27b pi --provider ollama --model hf.co/prism-ml/Bonsai-27B-gguf:Q1_0
abbr pibonsai1b pi --provider ollama --model hf.co/prism-ml/Bonsai-27B-gguf:Q1_0

# Qwen3.8 27B (local Ollama, CPU inference). Registered on the Ollama registry but
# needs a current Ollama client (pull 412s on older builds) and ~18 GB to pull.
# NOTE: qwen3.8 is NOT yet published on Ollama Cloud (no qwen3.8:cloud tag — qwen3.5:cloud
# is the closest available), so there is intentionally no --provider ollama-cloud alias for it.
abbr pi-ollama-qwen38-27b pi --provider ollama --model qwen3.8:27b
abbr piq38 pi --provider ollama --model qwen3.8:27b

# Ollama cloud models (name-version-paramcount)
abbr pi-ollama-kimi-k26-1042b pi --provider ollama-cloud --model kimi-k2.6:cloud
abbr pik6 pi --provider ollama-cloud --model kimi-k2.6:cloud
abbr pi-ollama-kimi-k27-1042b pi --provider ollama-cloud --model kimi-k2.7-code:cloud
abbr pi-ollama-kimi-k3-28t pi --provider ollama-cloud --model kimi-k3:cloud
abbr pi-ollama-kimi pi --provider ollama-cloud --model kimi-k2.7-code:cloud
abbr pik pi --provider ollama-cloud --model kimi-k2.7-code:cloud
abbr pik-code pi --provider ollama-cloud --model kimi-k2.7-code:cloud
abbr pik7 pi --provider ollama-cloud --model kimi-k2.7-code:cloud
abbr pik3 pi --provider ollama-cloud --model kimi-k3:cloud
abbr kimi pi --provider ollama-cloud --model kimi-k2.7-code:cloud
abbr pi-ollama-qwen35-397b pi --provider ollama-cloud --model qwen3.5:cloud
abbr pi-ollama-glm51-756b pi --provider ollama-cloud --model glm-5.1:cloud
abbr pi-ollama-glm52-756b pi --provider ollama-cloud --model glm-5.2:cloud
abbr pi-ollama-glm53-756b pi --provider ollama-cloud --model glm-5.3:cloud
abbr pi-ollama-glm53-flash pi --provider ollama-cloud --model glm-5.3-flash:cloud
abbr glm pi --provider ollama-cloud --model glm-5.3:cloud
abbr glm-flash pi --provider ollama-cloud --model glm-5.3-flash:cloud
abbr pi-ollama-minimax-m27-229b pi --provider ollama-cloud --model minimax-m2.7:cloud
abbr pi-ollama-qwen3-coder-next-80b pi --provider ollama-cloud --model qwen3-coder-next:cloud
abbr pi-ollama-qwen3-coder-480b pi --provider ollama-cloud --model qwen3-coder:480b-cloud
abbr pi-ollama-gpt-oss-20b pi --provider ollama-cloud --model gpt-oss:20b-cloud
abbr pi-ollama-gpt-oss-120b pi --provider ollama-cloud --model gpt-oss:120b-cloud
abbr pi-ollama-deepseek-v31-671b pi --provider ollama-cloud --model deepseek-v3.1:671b-cloud
abbr pi-ollama-minimax-m2-230b pi --provider ollama-cloud --model minimax-m2:cloud
abbr pi-ollama-minimax-m3 pi --provider ollama-cloud --model minimax-m3:cloud
abbr pi-ollama-gemma4-31b pi --provider ollama-cloud --model gemma4:31b-cloud

# OpenRouter cloud models (OPENROUTER_API_KEY required)
abbr pi-openrouter-qwen38-27b pi --provider openrouter --model qwen/qwen3.8-27b
abbr pior38 pi --provider openrouter --model qwen/qwen3.8-27b
abbr pi-openrouter-qwen36-27b pi --provider openrouter --model qwen/qwen3.6-27b
abbr pior36 pi --provider openrouter --model qwen/qwen3.6-27b
abbr pi-openrouter-qwen36-35b pi --provider openrouter --model qwen/qwen3.6-35b-a3b
abbr pior36moe pi --provider openrouter --model qwen/qwen3.6-35b-a3b
