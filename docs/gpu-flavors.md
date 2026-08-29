# GPU flavor availability: A100 first, H100 fallback

The A100 80GB (`n3-A100x1`) is cheaper but sometimes sold out.
The H100 80GB (`n3-H100x1`) is the fallback.

**Manual fallback procedure:**

1. Edit the TOML and try A100 first:
   ```toml
   # hyperstack-vm2.toml
   flavor_name = "n3-A100x1"
   ```
2. Run `ruby hyperstack.rb --vm 2 create`.
3. If the API returns a flavor-not-available error, switch to H100:
   ```toml
   flavor_name = "n3-H100x1"
   ```
4. Re-run create. The state file is only written after the VM is successfully created,
   so a failed create leaves nothing to clean up.

Both GPUs have 80 GB VRAM and run all presets identically.
The TOML comment above `flavor_name` tracks the current choice.
