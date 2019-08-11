# SCCM Application Downloader

Modify contoso.com to whichever domain this script is being utilized. 

This tool was designed to bulk pull applications from a local SCCM distribution point which was part of an extremely large SCCM infrastructure which spanned multiple regions. 

Some modifications still needed to be made at the time, including: 
- Parallel downloads from the SCCM DP. 
- A better way to generate package information (with more in depth binary inspection / scraping MSI properties or resultant EXEs for info)
- Generalized cleanup of code flow (using different methods for random path/string generations, changing some string logic)

Unfortunately, since I don't have access to SCCM infrastructure, and the likelyhood of me being in the situation again where this type of workflow is needed is slim to none, so it will probably remain in this state forever. 
