## VMware Broadcom License Assessment Tool

Automated PowerShell-based assessment tool for VMware environments, designed to calculate licensing requirements under the Broadcom model (VCF, VVF, and vSAN).

Developed by Juliano Cunha

🚀 Overview
This tool connects to one or more vCenter environments, collects infrastructure data, validates prerequisites, and calculates licensing requirements based on Broadcom’s official rules.
It generates both technical and executive reports, enabling fast and standardized licensing assessments and proposal generation.

✨ Features
🔍 Automatic validation of prerequisites:
PowerShell version
VMware PowerCLI modules
Execution policy

🔐 Safe ExecutionPolicy handling (session-only, no permanent changes)
🔗 Multi-vCenter support in a single execution

🧮 Automated licensing calculation:
VMware Cloud Foundation (VCF)
vSphere Foundation (VVF)
vSAN Add-on (based on raw capacity)

📊 Environment inventory:
Hosts and clusters
CPU and core count (with 16-core minimum per CPU rule)
vSphere versions
vSAN capacity

📜 License analysis:
Current license assignments
Expired or expiring licenses
Evaluation mode detection
Unlicensed objects detection

⚠️ Environment health checks (e.g., vSAN inconsistencies like PDL/stale devices)
🧾 Report generation:
Console output
CSV / JSON (technical data)
HTML / PDF (executive report)

📈 Output
The script generates:
Required VCF/VVF core licenses
Required vSAN Add-on (TiB)
Comparison with current licensing
Consolidated multi-environment summary
Executive-ready report for customer delivery

🧠 Licensing Logic
The calculations follow Broadcom’s official rules:
Minimum 16 cores per physical CPU
vSAN licensing based on raw physical capacity
VCF includes 1 TiB per core
VVF includes 0.25 TiB per core

📦 Requirements
PowerShell 5.1 or higher
VMware PowerCLI 13.3 or higher
Access to vCenter with sufficient privileges

▶️ Usage
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Invoke-BroadcomLicenseAssessment.ps1

Optional parameters:
-TrustInvalidCertificates
-DisconnectWhenDone
-ExportPdf
-CollectLicenseAssignments

🔐 Security
No permanent changes are made to the system
ExecutionPolicy changes are session-only
PowerCLI certificate handling is temporary
No modifications are made to vCenter or ESXi

📁 Example Outputs
assessment.json
assessment.csv
assessment.html
assessment.pdf

🎯 Use Cases
Pre-sales assessments
License compliance validation
Migration planning to Broadcom model
Proposal generation support

🤝 Contributing
Contributions are welcome!

Feel free to:
open issues
submit pull requests
suggest improvements

⚠️ Disclaimer
This tool is not officially affiliated with Broadcom or VMware.
It is based on publicly available documentation and best practices.

📄 License
MIT License
