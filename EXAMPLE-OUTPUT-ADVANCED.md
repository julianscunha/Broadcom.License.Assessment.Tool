# Example Output - Advanced

## Executive summary

- Environments assessed: 2
- Compute required: 144 cores
- Included vSAN entitlement: 36 TiB
- Raw vSAN measured: 78.6 TiB
- Additional vSAN Add-on required: 67 TiB

## Applied formulas

- `compute_cores_per_host = cpu_sockets * max(actual_cores_per_cpu, 16)`
- `included_vsan_tib = compute_cores_required * entitlement_tib_per_core`
- `vsan_add_on_required = max(ceiling(raw_vsan_tib - floor(included_entitlement_tib)), 0)`

## Environment summary

| Environment | Model | Compute | Included vSAN | Raw vSAN | Add-on |
|---|---:|---:|---:|---:|---:|
| CLUSTER-VSAN-PROD | VVF | 48 | 12 TiB | 78.6 TiB | 67 TiB |
| CLUSTER-DR-SAUDALI | VVF | 96 | 24 TiB | 0 TiB | 0 TiB |
