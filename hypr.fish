# Single-VM setup (hyperstack-vm.toml → hyperstack.wg1)
abbr pi-hyperstack-gpt-oss-120b pi --model hyperstack/openai/gpt-oss-120b
abbr hyperstack-create ruby ~/git/hyperstack/hyperstack.rb create
abbr hyperstack-delete ruby ~/git/hyperstack/hyperstack.rb delete
abbr hyperstack-test ruby ~/git/hyperstack/hyperstack.rb test

# Dual-VM setup (hyperstack-vm1/vm2.toml → hyperstack1/2.wg1)
abbr pi-hyperstack-nemotron pi --model hyperstack1/openai/gpt-oss-120b
abbr pi-hyperstack-coder pi --model hyperstack2/bullpoint/Qwen3-Coder-Next-AWQ-4bit
abbr hyperstack-create-both ruby ~/git/hyperstack/hyperstack.rb create-both
abbr hyperstack-delete-both ruby ~/git/hyperstack/hyperstack.rb delete-both
