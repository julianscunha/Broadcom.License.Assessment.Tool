# Example Output

This file shows a simplified example of the kind of executive summary the script can generate.

## Executive Summary

**Assessment Date:** 2026-03-25  
**Target Environment:** Production vCenter  
**Licensing Model:** VVF  
**Clusters Assessed:** 2  
**Assessment Result:** Completed with warnings

### Licensing Requirement Summary

| Item | Result |
|---|---:|
| Required VVF Compute | 144 cores |
| Included vSAN Entitlement | 36 TiB |
| Detected vSAN Raw Capacity | 78.6 TiB |
| Required vSAN Add-on | 43 TiB |

### Current License Health

| Check | Result |
|---|---|
| Expired licenses | 0 |
| Licenses expiring in 30 days | 0 |
| Licenses expiring in 90 days | 2 |
| Evaluation licenses detected | 0 |
| Unlicensed objects detected | 1 host |

### Warnings

- Cluster `CLUSTER-VSAN-PROD` reported a possible stale device condition.
- vSAN capacity was validated using current claimed raw capacity data.
- Environment includes hosts running vSphere 8.0 U3, so updated collection logic was applied.

## Sample Console Summary

```text
==============================================================
Developed by Juliano Cunha (GitHub: julianscunha)
Broadcom / VMware Licensing Assessment
==============================================================

[OK] PowerShell version check passed
[OK] VMware PowerCLI 13.3+ detected
[WARN] Session certificate trust was temporarily enabled
[OK] Connected to vcsa01.lab.local
[OK] Inventory collection completed
[OK] Licensing calculation completed
[WARN] 1 object without assigned license detected
[INFO] HTML report exported to .\output\assessment-report.html
[INFO] PDF report exported to .\output\assessment-report.pdf
```

## Sample JSON Excerpt

```json
{
  "assessmentDate": "2026-03-25T11:30:00",
  "environmentName": "Production vCenter",
  "licensingModel": "VVF",
  "requiredCoreLicenses": 144,
  "includedVsanTiB": 36,
  "detectedRawVsanTiB": 78.6,
  "requiredVsanAddonTiB": 43,
  "warnings": [
    "Possible stale vSAN device detected in cluster CLUSTER-VSAN-PROD"
  ]
}
```

## Notes

- Values above are examples only.
- Actual results depend on host CPU layout, vSAN raw capacity, current licenses, and cluster health.
- Final commercial quantities should always be validated before proposal issuance.
