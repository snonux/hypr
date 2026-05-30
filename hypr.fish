# Dual-VM setup (hyperstack-vm1/vm2.toml -> hyperstack1/2.wg1)
abbr pi-hyperstack pi --model hyperstack1/Qwen/Qwen3.6-27B-FP8
abbr pi-hyperstack-coder pi --model hyperstack1/Qwen/Qwen3.6-27B-FP8
abbr pi-hyperstack-qwen36 pi --model hyperstack1/Qwen/Qwen3.6-27B-FP8
abbr pi-hyperstack-gemma4 pi --model hyperstack2/cyankiwi/gemma-4-31B-it-AWQ-4bit
abbr hyperstack-create ruby ~/git/hypr/hyperstack.rb create

# Ollama cloud models (name-version-paramcount)
abbr pi-ollama-kimi-k26-1042b pi --provider ollama --model kimi-k2.6:cloud
abbr pik pi --provider ollama --model kimi-k2.6:cloud
abbr pi-ollama-qwen35-397b pi --provider ollama --model qwen3.5:cloud
abbr pi-ollama-glm51-756b pi --provider ollama --model glm-5.1:cloud
abbr pi-ollama-minimax-m27-229b pi --provider ollama --model minimax-m2.7:cloud
abbr pi-ollama-qwen3-coder-next-80b pi --provider ollama --model qwen3-coder-next:cloud
abbr pi-ollama-qwen3-coder-480b pi --provider ollama --model qwen3-coder:480b-cloud
abbr pi-ollama-gpt-oss-20b pi --provider ollama --model gpt-oss:20b-cloud
abbr pi-ollama-gpt-oss-120b pi --provider ollama --model gpt-oss:120b-cloud
abbr pi-ollama-deepseek-v31-671b pi --provider ollama --model deepseek-v3.1:671b-cloud
abbr pi-ollama-glm46-357b pi --provider ollama --model glm-4.6:cloud
abbr pi-ollama-minimax-m2-230b pi --provider ollama --model minimax-m2:cloud
