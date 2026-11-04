# VM requests

One file per VM, written by the self-service portal (`vms/<name>.yaml`) and
applied by the `vm-provision` workflow after the pull request is merged.
Schema: `schemas/vm-request.schema.json`; choices: `catalog/vm.yaml`.

- To change a VM, submit the portal form again with the same name.
- To remove one, use **Decommission** (`state: absent`). Deleting the file
  does *not* delete the VM.
