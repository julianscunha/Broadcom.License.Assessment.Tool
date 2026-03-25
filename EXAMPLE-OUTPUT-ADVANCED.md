# Example Output - Broadcom License Assessment Dashboard

## Executive summary

**Assessment date:** 2026-03-25  
**Assessment scope:** 2 environments / 2 vCenters / 5 clusters / 9 hosts  
**Target model:** VVF with optional vSAN Add-on

### KPI snapshot

- **Total compute required:** 144 cores
- **Included vSAN entitlement:** 36 TiB
- **Measured vSAN raw capacity:** 78.6 TiB
- **Required vSAN Add-on:** 67 TiB
- **Objects without license assignment:** 2
- **Licenses expiring in 90 days:** 1

## Current licensing standard and formulas

### Compute
Licensed cores per host = `CPU sockets x max(actual cores per CPU, 16)`

### Included vSAN entitlement
- **VCF:** `licensed cores x 1.0 TiB`
- **VVF:** `licensed cores x 0.25 TiB`

### vSAN Add-on
`max( ceil(raw vSAN TiB) - floor(included entitlement TiB), 0 )`

## Cluster calculation walkthrough

### Environment A - CLUSTER-VSAN-PROD
- Hosts: 3
- CPU sockets per host: 1
- Actual cores per CPU: 16
- Licensed cores per host: `1 x max(16,16) = 16`
- Total cluster compute: `3 x 16 = 48 cores`
- Included vSAN entitlement under VVF: `48 x 0.25 = 12 TiB`
- Measured vSAN raw capacity: `78.6 TiB`
- Required vSAN Add-on: `ceil(78.6) - floor(12) = 79 - 12 = 67 TiB`

### Environment B - CLUSTER-DR-SAUDALI
- Hosts: 3
- CPU sockets per host: 2
- Actual cores per CPU: 6
- Licensed cores per host: `2 x max(6,16) = 32`
- Total cluster compute: `3 x 32 = 96 cores`
- Included vSAN entitlement under VVF: `96 x 0.25 = 24 TiB`
- Measured vSAN raw capacity: `0 TiB`
- Required vSAN Add-on: `max(ceil(0) - floor(24), 0) = 0`

## Consolidated result

| Metric | Value |
|---|---:|
| Total VVF compute required | 144 cores |
| Total vSAN entitlement | 36 TiB |
| Total measured vSAN raw capacity | 78.6 TiB |
| Total required vSAN Add-on | 67 TiB |

## License health findings

| Finding | Quantity |
|---|---:|
| Expired licenses | 0 |
| Expiring in 30 days | 0 |
| Expiring in 90 days | 1 |
| Evaluation mode objects | 0 |
| Objects without license assignment | 2 |

## Recommendation

Procure:
- **144 VVF cores**
- **67 TiB of vSAN Add-on**

Also review:
- license assignment gaps
- vSAN health inconsistencies before final commercial proposal
