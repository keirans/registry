terraform {
  required_version = ">= 1.0"

  required_providers {
    coder = {
      source  = "coder/coder"
      version = ">= 2.5"
    }
  }
}

variable "agent_id" {
  type        = string
  description = "The ID of a Coder agent."
}

data "coder_workspace" "me" {}

data "coder_workspace_owner" "me" {}

variable "order" {
  type        = number
  description = "The order determines the position of app in the UI presentation. The lowest order is shown first and apps with equal order are sorted by name (ascending order)."
  default     = null
}

variable "group" {
  type        = string
  description = "The name of a group that this app belongs to."
  default     = null
}

variable "icon" {
  type        = string
  description = "The icon to use for the app."
  default     = "/icon/amazon-q.svg"
}

variable "folder" {
  type        = string
  description = "The folder to run Amazon Q in."
  default     = "/home/coder"
}

variable "install_amazon_q" {
  type        = bool
  description = "Whether to install Amazon Q."
  default     = true
}

variable "amazon_q_version" {
  type        = string
  description = "The version of Amazon Q to install."
  default     = "1.13.1"
}

variable "use_screen" {
  type        = bool
  description = "Whether to use screen for running Amazon Q in the background."
  default     = false
}

variable "use_tmux" {
  type        = bool
  description = "Whether to use tmux instead of screen for running Amazon Q in the background."
  default     = false
}

variable "report_tasks" {
  type        = bool
  description = "Whether to enable task reporting."
  default     = false
}

variable "pre_install_script" {
  type        = string
  description = "Custom script to run before installing Amazon Q."
  default     = null
}

variable "post_install_script" {
  type        = string
  description = "Custom script to run after installing Amazon Q."
  default     = null
}

variable "auth_tarball" {
  type        = string
  description = "Base64 encoded, zstd compressed tarball of a pre-authenticated ~/.local/share/amazon-q directory. After running `q login` on another machine, you may generate it with: `cd ~/.local/share/amazon-q && tar -c . | zstd | base64 -w 0`"
  default     = "tarball"
}

variable "system_prompt" {
  type        = string
  description = "The system prompt to use for Amazon Q. This should instruct the agent how to do task reporting."
  default     = <<-EOT
    You are a helpful Coding assistant. Aim to autonomously investigate
    and solve issues the user gives you and test your work, whenever possible.
    Avoid shortcuts like mocking tests. When you get stuck, you can ask the user
    but opt for autonomy.

    YOU MUST REPORT ALL TASKS TO CODER.
    When reporting tasks, you MUST follow these EXACT instructions:
    - IMMEDIATELY report status after receiving ANY user message.
    - Be granular. If you are investigating with multiple steps, report each step to coder.

    Task state MUST be one of the following:
    - Use "state": "working" when actively processing WITHOUT needing additional user input.
    - Use "state": "complete" only when finished with a task.
    - Use "state": "failure" when you need ANY user input, lack sufficient details, or encounter blockers.

    Task summaries MUST:
    - Include specifics about what you're doing.
    - Include clear and actionable steps for the user.
    - Be less than 160 characters in length.

    Your first task is:

  EOT
}

variable "ai_prompt" {
  type        = string
  description = "The initial task prompt to send to Amazon Q."
  default     = "Please help me with my coding tasks. I'll provide specific instructions as needed."
}

variable "install_agentapi" {
  type        = bool
  description = "Whether to install AgentAPI."
  default     = true
}

variable "agentapi_version" {
  type        = string
  description = "The version of AgentAPI to install."
  default     = "v0.3.3"
}

variable "agentapi_subdomain" {
  type        = bool
  description = "Whether to use a subdomain for AgentAPI."
  default     = true
}

locals {
  workdir                            = trimsuffix(var.folder, "/")
  encoded_pre_install_script         = var.pre_install_script != null ? base64encode(var.pre_install_script) : ""
  encoded_post_install_script        = var.post_install_script != null ? base64encode(var.post_install_script) : ""
  agentapi_start_script_b64          = base64encode(file("${path.module}/scripts/agentapi-start.sh"))
  agentapi_wait_for_start_script_b64 = base64encode(file("${path.module}/scripts/agentapi-wait-for-start.sh"))
  remove_last_session_id_script_b64  = base64encode(file("${path.module}/scripts/remove-last-session-id.js"))
  agentapi_chat_base_path            = var.agentapi_subdomain ? "" : "/@${data.coder_workspace_owner.me.name}/${data.coder_workspace.me.name}.${var.agent_id}/apps/qapi/chat"

  full_prompt = <<-EOT
    ${var.system_prompt}

    ${var.ai_prompt}
  EOT
}

resource "coder_script" "amazon_q" {
  agent_id     = var.agent_id
  display_name = "Amazon Q"
  icon         = var.icon
  script       = <<-EOT
    #!/bin/bash
    set -o errexit
    set -o pipefail

    command_exists() {
      command -v "$1" >/dev/null 2>&1
    }

    if [ -n "${local.encoded_pre_install_script}" ]; then
      echo "Running pre-install script..."
      echo "${local.encoded_pre_install_script}" | base64 -d > /tmp/pre_install.sh
      chmod +x /tmp/pre_install.sh
      /tmp/pre_install.sh
    fi

    if [ "${var.install_amazon_q}" = "true" ]; then
      echo "Installing Amazon Q..."
      PREV_DIR="$PWD"
      TMP_DIR="$(mktemp -d)"
      cd "$TMP_DIR"

      ARCH="$(uname -m)"
      case "$ARCH" in
        "x86_64")
          Q_URL="https://desktop-release.q.us-east-1.amazonaws.com/${var.amazon_q_version}/q-x86_64-linux.zip"
          ;;
        "aarch64"|"arm64")
          Q_URL="https://desktop-release.codewhisperer.us-east-1.amazonaws.com/${var.amazon_q_version}/q-aarch64-linux.zip"
          ;;
        *)
          echo "Error: Unsupported architecture: $ARCH. Amazon Q only supports x86_64 and arm64."
          exit 1
          ;;
      esac

      echo "Downloading Amazon Q for $ARCH..."
      curl --proto '=https' --tlsv1.2 -sSf "$Q_URL" -o "q.zip"
      unzip q.zip
      ./q/install.sh --no-confirm
      cd "$PREV_DIR"
      export PATH="$PATH:$HOME/.local/bin"
      echo "Installed Amazon Q version: $(q --version)"
    fi

    echo "Extracting auth tarball..."
    PREV_DIR="$PWD"
    echo "${var.auth_tarball}" | base64 -d > /tmp/auth.tar.zst
    rm -rf ~/.local/share/amazon-q
    mkdir -p ~/.local/share/amazon-q
    cd ~/.local/share/amazon-q
    tar -I zstd -xf /tmp/auth.tar.zst
    rm /tmp/auth.tar.zst
    cd "$PREV_DIR"
    echo "Extracted auth tarball"

    # Ensuring the Amazon Q Environment is sane given new 'features' in the recently releases.
    # Installing SSH Server
    sudo apt-get update 
    sudo apt-get install -y openssh-server

    #The following values need to be in the SSH Configuration
    echo "AcceptEnv Q_SET_PARENT" | sudo tee -a  /etc/ssh/sshd_config.d/amazonq.conf
    echo "AllowStreamLocalForwarding yes" | sudo tee -a /etc/ssh/sshd_config.d/amazonq.conf

    # QTerm must be running for some reason
    #qterm

    # Ensure the shell directory exists (TODO - Remove hard coded values)
    mkdir -p /home/coder/.local/share/amazon-q/shell
    chmod -R 755 /home/coder/.local/share/amazon-q

    # If Report tasks is true and Install AgentAPI is false, we need to ensure that the Coder MCP server is configured
    # without the AgentAPI URL
    if [ "${var.report_tasks}" = "true" ] && [ "${var.install_agentapi}" = "false" ] ; then
      echo "Configuring Amazon Q to report tasks via Coder MCP WITHOUT AgentAPI Configuration..."
      q mcp add --name coder --command "coder" --args "exp,mcp,server,--allowed-tools,coder_report_task" --env "CODER_MCP_APP_STATUS_SLUG=amazon-q" --force
      echo "Added Coder MCP server to Amazon Q configuration"
    fi

    # If Report tasks is true and Install AgentAPI is true, we need to ensure that the Coder MCP server is configured
    # WITH  the AgentAPI URL
    if [ "${var.report_tasks}" = "true" ] && [ "${var.install_agentapi}" = "true" ] ; then
      echo "Configuring Amazon Q to report tasks via Coder MCP WITH AgentAPI Configuration..."
      q mcp add --name coder --command "coder" --args "exp,mcp,server,--allowed-tools,coder_report_task" --env "CODER_MCP_APP_STATUS_SLUG=qapi, CODER_MCP_AI_AGENTAPI_URL=http://localhost:3284" --force
      echo "Added Coder MCP server to Amazon Q configuration"
    fi

    # Install AgentAPI if enabled
    if [ "${var.install_agentapi}" = "true" ]; then
      echo "Installing AgentAPI..."
      arch=$(uname -m)
      if [ "$arch" = "x86_64" ]; then
        binary_name="agentapi-linux-amd64"
      elif [ "$arch" = "aarch64" ]; then
        binary_name="agentapi-linux-arm64"
      else
        echo "Error: Unsupported architecture: $arch"
        exit 1
      fi
      curl \
        --retry 5 \
        --retry-delay 5 \
        --fail \
        --retry-all-errors \
        -L \
        -C - \
        -o agentapi \
        "https://github.com/coder/agentapi/releases/download/${var.agentapi_version}/$binary_name"
      chmod +x agentapi
      sudo mv agentapi /usr/local/bin/agentapi
    fi
    if ! command_exists agentapi; then
      echo "Error: AgentAPI is not installed. Please enable install_agentapi or install it manually."
      exit 1
    fi

    # this must be kept in sync with the agentapi-start.sh script
    module_path="$HOME/.amazonq-module"
    mkdir -p "$module_path/scripts"

    # We now decode the base64 encoded scripts and save them to the module path
    echo -n "${local.agentapi_start_script_b64}" | base64 -d > "$module_path/scripts/agentapi-start.sh"
    echo -n "${local.agentapi_wait_for_start_script_b64}" | base64 -d > "$module_path/scripts/agentapi-wait-for-start.sh"
    echo -n "${local.remove_last_session_id_script_b64}" | base64 -d > "$module_path/scripts/remove-last-session-id.js"
    chmod +x "$module_path/scripts/agentapi-start.sh"
    chmod +x "$module_path/scripts/agentapi-wait-for-start.sh"


    if [ -n "${local.encoded_post_install_script}" ]; then
      echo "Running post-install script..."
      echo "${local.encoded_post_install_script}" | base64 -d > /tmp/post_install.sh
      chmod +x /tmp/post_install.sh
      /tmp/post_install.sh
    fi

    if [ "${var.use_tmux}" = "true" ] && [ "${var.use_screen}" = "true" ]; then
      echo "Error: Both use_tmux and use_screen cannot be true simultaneously."
      echo "Please set only one of them to true."
      exit 1
    fi

    if [ "${var.use_tmux}" = "true" ]; then
      echo "Running Amazon Q in the background with tmux..."

      if ! command_exists tmux; then
        echo "Error: tmux is not installed. Please install tmux manually."
        exit 1
      fi

      touch "$HOME/.amazon-q.log"

      export LANG=en_US.UTF-8
      export LC_ALL=en_US.UTF-8

      tmux new-session -d -s amazon-q -c "${var.folder}" "q chat --trust-all-tools | tee -a "$HOME/.amazon-q.log" && exec bash"

      tmux send-keys -t amazon-q "${local.full_prompt}"
      sleep 5
      tmux send-keys -t amazon-q Enter
    fi

    if [ "${var.use_screen}" = "true" ]; then
      echo "Running Amazon Q in the background..."

      if ! command_exists screen; then
        echo "Error: screen is not installed. Please install screen manually."
        exit 1
      fi

      touch "$HOME/.amazon-q.log"

      if [ ! -f "$HOME/.screenrc" ]; then
        echo "Creating ~/.screenrc and adding multiuser settings..." | tee -a "$HOME/.amazon-q.log"
        echo -e "multiuser on\nacladd $(whoami)" > "$HOME/.screenrc"
      fi

      if ! grep -q "^multiuser on$" "$HOME/.screenrc"; then
        echo "Adding 'multiuser on' to ~/.screenrc..." | tee -a "$HOME/.amazon-q.log"
        echo "multiuser on" >> "$HOME/.screenrc"
      fi

      if ! grep -q "^acladd $(whoami)$" "$HOME/.screenrc"; then
        echo "Adding 'acladd $(whoami)' to ~/.screenrc..." | tee -a "$HOME/.amazon-q.log"
        echo "acladd $(whoami)" >> "$HOME/.screenrc"
      fi
      export LANG=en_US.UTF-8
      export LC_ALL=en_US.UTF-8

      screen -U -dmS amazon-q bash -c '
        cd ${var.folder}
        q chat --trust-all-tools | tee -a "$HOME/.amazon-q.log
        exec bash
      '
      # Extremely hacky way to send the prompt to the screen session
      # This will be fixed in the future, but `amazon-q` was not sending MCP
      # tasks when an initial prompt is provided.
      screen -S amazon-q -X stuff "${local.full_prompt}"
      sleep 5
      screen -S amazon-q -X stuff "^M"
    else
      if ! command_exists q; then
        echo "Error: Amazon Q is not installed. Please enable install_amazon_q or install it manually."
        exit 1
      fi
    fi

    # When all this is done, lets start the AgentAPI server in a very basic form and see what happens.
    # This changes to the working directory and then starts Amazon Q with resume mode enabled
    cd "${local.workdir}"
    export ARG_AGENTAPI_CHAT_BASE_PATH='${local.agentapi_chat_base_path}'
    nohup "$module_path/scripts/agentapi-start.sh" &> "$module_path/agentapi-start.log" &
    "$module_path/scripts/agentapi-wait-for-start.sh"

    EOT
  run_on_start = true
}

resource "coder_app" "amazonq_code_web" {
  # use a short slug to mitigate https://github.com/coder/coder/issues/15178
  slug         = "qapi"
  display_name = "Q AgentAPI"
  agent_id     = var.agent_id
  url          = "http://localhost:3284/"
  icon         = var.icon
  order        = var.order
  group        = var.group
  subdomain    = false
  healthcheck {
    url       = "http://localhost:3284/status"
    interval  = 5
    threshold = 20
  }
}


resource "coder_app" "amazon_q" {
  slug         = "qcli"
  display_name = "Q CLI"
  agent_id     = var.agent_id
  command      = <<-EOT
    #!/bin/bash
    set -e

    export LANG=en_US.UTF-8
    export LC_ALL=en_US.UTF-8

    if [ "${var.use_tmux}" = "true" ]; then
      if tmux has-session -t amazon-q 2>/dev/null; then
        echo "Attaching to existing Amazon Q tmux session." | tee -a "$HOME/.amazon-q.log"
        tmux attach-session -t amazon-q
      else
        echo "Starting a new Amazon Q tmux session." | tee -a "$HOME/.amazon-q.log"
        tmux new-session -s amazon-q -c ${var.folder} "q chat --trust-all-tools | tee -a \"$HOME/.amazon-q.log\"; exec bash"
      fi
    elif [ "${var.use_screen}" = "true" ]; then
      if screen -list | grep -q "amazon-q"; then
        echo "Attaching to existing Amazon Q screen session." | tee -a "$HOME/.amazon-q.log"
        screen -xRR amazon-q
      else
        echo "Starting a new Amazon Q screen session." | tee -a "$HOME/.amazon-q.log"
        screen -S amazon-q bash -c 'q chat --trust-all-tools | tee -a "$HOME/.amazon-q.log"; exec bash'
      fi
    else
      cd ${var.folder}
      q chat --trust-all-tools
    fi
    EOT
  icon         = var.icon
  order        = var.order
  group        = var.group
}