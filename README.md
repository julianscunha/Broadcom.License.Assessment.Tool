
# Broadcom License Assessment Tool

Interactive PowerShell tool for Broadcom / VMware license assessments.

Key behaviors:
- `-Help` and `Get-Help` support
- Customer name stamped into exported file names
- `CollectLicenseAssignments` enabled by default
- Disconnects VIServer sessions at the end by default
- Executive HTML report with executive summary, key findings, recommendations, risk score, and a heuristic VCF versus VVF suitability section
- PDF export fallback order: Word COM, Edge headless, Chrome headless, `wkhtmltopdf`

Example:
```powershell
Get-Help .\BroadcomLicenseAssessmentTool.ps1 -Full
.\BroadcomLicenseAssessmentTool.ps1 -CustomerName "ACME Corp" -ExportPdf
```

See:
- `EXAMPLE-OUTPUT.html`
- `EXAMPLE-OUTPUT.md`
