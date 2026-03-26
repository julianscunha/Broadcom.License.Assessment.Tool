
# EXAMPLE-OUTPUT

## Executive Summary

The environment requires additional vSAN licensing beyond included entitlement and should be evaluated commercially with a VCF-versus-VVF lens.

## Key Findings

- Customer: ACME Corp
- Required compute cores: 144
- Included vSAN entitlement: 36.00 TiB
- Measured raw vSAN: 92.40 TiB
- Required vSAN Add-on: 57 TiB
- Suggested direction: VCF

## Risk Score

- Score: 74 / 100
- Level: High

## Dashboard

- Compute required: 144
- Included entitlement TiB: 36.00
- Measured raw vSAN TiB: 92.40
- Required vSAN Add-on TiB: 57

## Cluster Calculations

| Server | Cluster | Hosts | Required cores | Included TiB | Raw vSAN TiB | Required Add-on TiB |
|---|---|---:|---:|---:|---:|---:|
| vcsa-prod.local | PROD-CLUSTER | 3 | 96 | 24.00 | 78.60 | 55 |
| vcsa-dr.local | DR-CLUSTER | 3 | 48 | 12.00 | 13.80 | 2 |
