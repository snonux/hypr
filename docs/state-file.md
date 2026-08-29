# Checking the state file

The JSON state file (`.hyperstack-vm2-state.json` for VM2) is the source of truth
for provisioning state. Key fields:

```bash
python3 -c "
import json
d = json.load(open('.hyperstack-vm2-state.json'))
print('vm_id:          ', d.get('vm_id'))
print('public_ip:      ', d.get('public_ip'))
print('bootstrapped_at:', d.get('bootstrapped_at'))
print('vllm_setup_at:  ', d.get('vllm_setup_at'))
print('vllm_model:     ', d.get('vllm_model'))
"
```

If `vllm_setup_at` is `None` but the container is running, the provisioner did not
mark setup as complete (likely a transient error at the end of `create`). Re-running
`create` will redo the vLLM step.
