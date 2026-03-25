# Advanced Example Output

## Executive Summary

- **Assessed environments:** 2
- **Total compute required:** 144 cores
- **Included vSAN entitlement:** 36.00 TiB
- **Measured vSAN raw:** 92.40 TiB
- **Additional vSAN Add-on:** 57 TiB
- **Objects without license:** 2

## Current rule set applied

- Compute cores per host = physical CPU sockets × max(actual cores per CPU, 16)
- Environment compute total = sum of licensed cores across all hosts
- VCF included vSAN entitlement = compute cores × 1.00 TiB
- VVF included vSAN entitlement = compute cores × 0.25 TiB
- vSAN Add-on required = max( ceil(raw vSAN TiB − floor(included entitlement TiB)), 0 )

## Environment: PROD

### Recommendation

- **Target model:** VVF + vSAN Add-on
- **Compute required:** 96 cores
- **Included entitlement:** 24.00 TiB
- **Measured raw vSAN:** 78.60 TiB
- **Additional vSAN Add-on:** 55 TiB

### Cluster walkthrough

| Cluster | Hosts | Total CPU Sockets | Actual Cores/CPU | Licensed Cores/CPU | Compute Formula | Compute Required | Included vSAN | Raw vSAN | Add-on |
|---|---:|---:|---:|---:|---|---:|---:|---:|---:|
| PROD-01 | 3 | 6 | 6 | 16 | 6 sockets × 16 licensed cores | 96 | 24.00 TiB | 78.60 TiB | 55 TiB |

## Environment: DR

### Recommendation

- **Target model:** VVF
- **Compute required:** 48 cores
- **Included entitlement:** 12.00 TiB
- **Measured raw vSAN:** 13.80 TiB
- **Additional vSAN Add-on:** 2 TiB

## Licensing health snapshot

| Metric | Value |
|---|---:|
| Current license keys | 5 |
| Expired licenses | 0 |
| Expiring in 30 days | 1 |
| Expiring in 90 days | 2 |
| Unlicensed objects | 2 |

## Notes

- vSAN raw capacity is based on physical claimed capacity, not usable VM storage.
- For vSphere / vSAN 8.0 U3 and newer, the updated KB 400416 path must be used.
