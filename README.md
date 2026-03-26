# Broadcom License Assessment Tool

Enterprise-grade PowerShell tool for assessing Broadcom / VMware licensing requirements.

## 🚀 Key Features
- Automated environment assessment via PowerCLI
- Multi-environment support
- Compute core calculation
- vSAN entitlement analysis
- Financial comparison VVF vs VCF
- Executive HTML report (Gartner-style)

## ⚙️ Parameters
- -CustomerName
- -EstimatedCurrency (BRL, USD, EUR)
- -EstimatedPricePerCoreVVF
- -EstimatedPricePerCoreVCF
- -EstimatedPricePerTiBAddon

## 📊 Financial Logic
VVF = 0.25 TiB/core  
VCF = 1.0 TiB/core  

## 🧪 Example
```powershell
.\BroadcomLicenseAssessmentTool.ps1 `
  -CustomerName "ACME" `
  -EstimatedCurrency BRL `
  -EstimatedPricePerCoreVVF 125 `
  -EstimatedPricePerCoreVCF 165 `
  -EstimatedPricePerTiBAddon 450
```

## ⚠️ Disclaimer
Estimates are indicative only.
