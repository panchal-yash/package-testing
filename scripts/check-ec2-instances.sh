#!/bin/bash
#
## Calculate the threshold date (1 day ago)
threshold_date=$(date -d "$2 day ago" +%Y-%m-%d)
#
## Retrieve the list of EC2 instances
aws ec2 describe-instances     --filters "Name=instance-state-name,Values=running"     --query "Reservations[].Instances[?LaunchTime<='${threshold_date}'].[Tags[?Key=='Name'].Value[], InstanceId, LaunchTime]" --output yaml --region $1 | sed -e 's/\- \[\]//g' -e '/^$/d'
