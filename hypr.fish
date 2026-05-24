# Dual-VM setup (hyperstack-vm1/vm2.toml -> hyperstack1/2.wg1)
abbr pi-hyperstack         pi --model hyperstack1/Qwen/Qwen3.6-27B-FP8
abbr pi-hyperstack-coder   pi --model hyperstack1/Qwen/Qwen3.6-27B-FP8
abbr pi-hyperstack-qwen36  pi --model hyperstack2/Qwen/Qwen3.6-27B-FP8
abbr pi-hyperstack-gemma4  pi --model hyperstack2/cyankiwi/gemma-4-31B-it-AWQ-4bit
abbr hyperstack-create      ruby ~/git/hyperstack/hyperstack.rb create
abbr hyperstack-create-vm2  ruby ~/git/hyperstack/hyperstack.rb create --vm 2
abbr hyperstack-create-both ruby ~/git/hyperstack/hyperstack.rb create --vm both
abbr hyperstack-delete-both ruby ~/git/hyperstack/hyperstack.rb delete --vm both

# Ollama (local endpoint pointing at cloud models)
abbr pi-ollama-kimi        pi --provider ollama --model kimi-k2.6:cloud
abbr pi-ollama-qwen        pi --provider ollama --model qwen3.5:cloud
abbr pi-ollama-glm          pi --provider ollama --model glm-5.1:cloud
abbr pi-ollama-minimax      pi --provider ollama --model minimax-m2.7:cloud
