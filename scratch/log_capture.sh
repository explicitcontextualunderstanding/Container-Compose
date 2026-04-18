#!/bin/bash
log show --last 5m --predicate 'subsystem == "com.apple.Virtualization" OR sender == "Virtualization"' --style syslog | tail -n 100
