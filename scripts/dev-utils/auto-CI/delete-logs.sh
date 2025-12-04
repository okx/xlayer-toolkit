#!/bin/bash

# Script to delete logs in ci-logs directory
# Usage: ./delete-logs.sh

set -e  # Exit on error

# Define the logs directory
LOGS_DIR="ci-logs"

# Check if the directory exists
if [ ! -d "$LOGS_DIR" ]; then
    echo "Error: Directory '$LOGS_DIR' does not exist."
    exit 1
fi

# Count log files before deletion
LOG_COUNT=$(find "$LOGS_DIR" -type f -name "*.log" 2>/dev/null | wc -l)

if [ "$LOG_COUNT" -eq 0 ]; then
    echo "No log files found in '$LOGS_DIR'."
    exit 0
fi

# Delete log files
echo "Deleting $LOG_COUNT log file(s) from '$LOGS_DIR'..."
find "$LOGS_DIR" -type f -name "*.log" -delete

# Verify deletion
REMAINING=$(find "$LOGS_DIR" -type f -name "*.log" 2>/dev/null | wc -l)

if [ "$REMAINING" -eq 0 ]; then
    echo "Successfully deleted all log files from '$LOGS_DIR'."
else
    echo "Warning: $REMAINING log file(s) could not be deleted."
    exit 1
fi
