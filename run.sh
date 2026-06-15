#!/usr/bin/env bash
# Quick launcher. Pass your PS5 IP as the first arg for live capture.
set -e
[ -n "$1" ] && export GT7_IP="$1"
python -m app.server
