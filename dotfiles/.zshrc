#            _
#    _______| |__  _ __ ___
#   |_  / __| '_ \| '__/ __|
#  _ / /\__ \ | | | | | (__
# (_)___|___/_| |_|_|  \___|
#
# -----------------------------------------------------
# ML4W zshrc loader
# -----------------------------------------------------

# DON'T CHANGE THIS FILE

# You can define your custom configuration by adding
# files in ~/.config/zshrc
# or by creating a folder ~/.config/zshrc/custom
# with copies of files from ~/.config/zshrc
# -----------------------------------------------------

# -----------------------------------------------------
# Load modular configuration
# -----------------------------------------------------
export PATH=$(printf '%s\n' "$PATH" | tr ':' '\n' | grep -vx '/home/username/anaconda3/bin' | grep -vx '/home/username/anaconda3/condabin' | paste -sd:)
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:$PATH"
hash -r
for f in ~/.config/zshrc/*; do
    if [ ! -d $f ]; then
        c=`echo $f | sed -e "s=.config/zshrc=.config/zshrc/custom="`
        [[ -f $c ]] && source $c || source $f
    fi
done

# -----------------------------------------------------
# Load single customization file (if exists)
# -----------------------------------------------------

if [ -f ~/.zshrc_custom ]; then
    source ~/.zshrc_custom
fi

# Load Conda only when requested
alias conda-on='source /home/username/anaconda3/etc/profile.d/conda.sh && conda activate base'
# GPU modes
alias gpu-eco='sudo envycontrol -s integrated && sudo reboot'
alias gpu-balanced='sudo envycontrol -s hybrid --rtd3 && sudo reboot'
alias gpu-mode='sudo envycontrol --query'
# export ANTHROPIC_API_KEY="put-your-key-in-a-local-untracked-file"
export CYBENCH_RISK_FLAG_REMOVED=1
alias ctf='python3 /home/username/tools/ctf-agent/files/ctf_agent.py'
alias ctf-swarm='python3 /home/username/tools/ctf-agent/files/ctf_swarm.py'
source /usr/share/nvm/init-nvm.sh
export PATH="$(npm config get prefix)/bin:$PATH"


# Added by Antigravity CLI installer
export PATH="/home/username/.local/bin:$PATH"

# OpenClaw Completion
source "/home/username/.openclaw/completions/openclaw.zsh"
