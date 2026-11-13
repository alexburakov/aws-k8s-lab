#!/usr/bin/env bash
WORKER_IPS=${WORKER_IPS:-"10.42.1.11 10.42.1.12 10.42.1.13"}
while :; do
  for ip in $WORKER_IPS; do
    code=$(curl -sk -o /dev/null -m 2 -w '%{http_code}' --resolve "podinfo.lab:443:$ip" https://podinfo.lab/)
    echo "$(date +%F' '%T) $ip $code"
  done
  sleep 1
done >> "$HOME/lab/probe.log"
