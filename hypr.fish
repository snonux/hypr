# Dual-VM setup (hyperstack-vm1/vm2.toml -> hyperstack1/2.wg1)
abbr pi-hyperstack-coder pi --model hyperstack1/bullpoint/Qwen3-Coder-Next-AWQ-4bit
abbr pi-hyperstack-qwen36 pi --model hyperstack2/Qwen/Qwen3.6-27B-FP8
abbr pi-hyperstack-gemma4 pi --model hyperstack2/cyankiwi/gemma-4-31B-it-AWQ-4bit
abbr hyperstack-create-both ruby ~/git/hyperstack/hyperstack.rb create-both
abbr hyperstack-delete-both ruby ~/git/hyperstack/hyperstack.rb delete-both
