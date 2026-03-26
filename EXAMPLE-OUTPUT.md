# Example Output - Executive License Assessment

## Environment summary

| Metric | Value |
|---|---:|
| Environments assessed | 2 |
| Clusters assessed | 2 |
| Hosts assessed | 6 |
| Required VVF compute | 144 cores |
| Included vSAN entitlement | 36 TiB |
| Measured raw vSAN | 92.4 TiB |
| Required vSAN Add-on | 57 TiB |

## Applied formulas

- Adjusted host cores = max(actual host cores, 16 x physical CPU count)
- Included vSAN entitlement = adjusted cores x 0.25 for VVF, or adjusted cores x 1.0 for VCF
- Required vSAN Add-on = max(ceil(raw vSAN TiB - floor(included entitlement TiB)), 0)

## Cluster breakdown

| Server | Cluster | Model | Required compute | Included vSAN | Raw vSAN | Required Add-on | Method |
|---|---|---|---:|---:|---:|---:|---|
| vcsa-prod.company.local | PROD-CLUSTER | VVF | 48 | 12.0 | 78.6 | 67 | Get-VsanSpaceUsage |
| vcsa-dr.company.local | DR-CLUSTER | VVF | 96 | 24.0 | 13.8 | 0 | Get-VsanSpaceUsage |

## Executive takeaway

The assessed environments require 144 cores of VVF and 57 TiB of additional vSAN Add-on licensing. The current standard used in the calculation is the Broadcom minimum of 16 cores per physical CPU, with vSAN entitlement derived from adjusted core count.
