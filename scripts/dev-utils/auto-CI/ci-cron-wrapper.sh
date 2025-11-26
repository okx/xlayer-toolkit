#!/usr/bin/env bash

# Wrapper script for running CI from cron
# This ensures all environment variables and tools are properly loaded

# Set basic PATH
export PATH="/home/xlayer/.local/bin:/usr/local/bin:/usr/bin:/bin"

# Change to the working directory
cd /data1/brendon/ci || exit 1

# Activate mise to load Go and other tools
eval "$(/home/xlayer/.local/bin/mise activate bash)"

# Run the CI script
exec /data1/brendon/ci.sh