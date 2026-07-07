@echo off
cd \ProgramData\VMware
net stop "TP AutoConnect Service"
net stop "tsdrvdisvc"
net stop "VMware Alias Manager and Ticket Service"
net stop "VMware Blast"
net stop "VMware DEM Service"
net stop "VMware Horizon View Agent"
net stop "VMware Horizon View Logon Monitor"
net stop "VMware vRealize Operations for Horizon Desktop Agent"
del *.log /s
del *.txt /s
cd "\Program Files (x86)\CloudVolumes\Agent\Logs"
del *.log /s
del *.txt /s
