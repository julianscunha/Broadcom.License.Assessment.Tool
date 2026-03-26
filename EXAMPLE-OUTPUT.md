# EXAMPLE-OUTPUT

This example shows the Gartner-style executive dashboard with automatic light/dark theme support.

## Headline figures

- Total VVF cores required: **144**
- Included vSAN entitlement: **36 TiB**
- Raw vSAN measured: **78.6 TiB**
- vSAN Add-on required: **67 TiB**

## Formulas used

- Adjusted cores per host = `CPU sockets x max(actual cores per CPU, 16)`
- Included vSAN entitlement (VVF) = `Total required cores x 0.25 TiB`
- Required vSAN Add-on = `max(ceil(raw vSAN TiB) - floor(included entitlement TiB), 0)`

## Dashboard sections

- Executive summary
- Assessment health
- Consumption dashboard
- Per-environment calculation walkthrough
- Cluster detail
