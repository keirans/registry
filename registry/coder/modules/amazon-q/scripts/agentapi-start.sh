#!/bin/bash
set -o errexit
set -o pipefail

# this must be kept in sync with the main.tf file
module_path="$HOME/.amazonq-module"
scripts_dir="$module_path/scripts"
log_file_path="$module_path/agentapi.log"

# if the log file already exists, archive it
if [ -f "$log_file_path" ]; then
    mv "$log_file_path" "$log_file_path"".$(date +%s)"
fi

# use low width to fit in the tasks UI sidebar. height is adjusted so that width x height ~= 80x1000 characters
# visible in the terminal screen by default.
echo "Changing to /home/coder directory to start AgentAPI server."
cd /home/coder # TODO: this shouldnt be hard coded - fix before release
echo "Starting AgentAPI server"
agentapi server --term-width 67 --term-height 1190 -- \
    bash -c "q chat --resume --trust-all-tools" \
    > "$log_file_path" 2>&1

if [ $exit_code -eq 0 ]; then
    echo "Caught exit code 0, AgentAPI started successfully."
    exit 0
else
    echo "Caught exit code $exit_code, AgentAPI failed to start."
fi

