# myHyprlandRice

My personal Hyprland rice configuration, built on top of [ML4W's dotfiles](https://github.com/mylinuxforwork/dotfiles).

## 🎨 Features

- **Window Manager**: Hyprland with custom keybindings and animations
- **Status Bar**: Waybar with custom styling
- **Terminal**: Kitty with optimized settings
- **Shell**: Fish/Zsh with Oh My Posh
- **Application Launcher**: Rofi
- **Notifications**: SwayNC
- **Theme Management**: GTK 3/4, Qt6ct
- **Editor**: Neovim with custom configuration

## 📦 Installation

### Prerequisites
```bash
# Install stow if not already installed
sudo pacman -S stow  # Arch/CachyOS
```

### Clone and Apply
```bash
# Clone the repository
git clone https://github.com/YOUR_USERNAME/myHyprlandRice.git
cd myHyprlandRice

# Backup your existing configs (optional but recommended)
cp -r ~/.config ~/.config.backup

# Use stow to create symlinks
stow -t ~ dotfiles
```

## 🔧 Configuration Structure

```
dotfiles/
├── .bashrc              # Bash configuration
├── .zshrc               # Zsh configuration
├── .gtkrc-2.0           # GTK 2 theme settings
├── .Xresources          # X resources
├── config.dotinst       # ML4W configuration
└── .config/
    ├── hypr/            # Hyprland configuration
    ├── waybar/          # Status bar
    ├── kitty/           # Terminal emulator
    ├── nvim/            # Neovim setup
    ├── rofi/            # Application launcher
    ├── fish/            # Fish shell
    └── ...              # Other app configs
```

## 🚀 Usage

After installation, your configs are symlinked to this repository. Any changes you make to your system configs will be automatically reflected here.

## 🙏 Credits

- Base configuration: [ML4W Dotfiles](https://github.com/mylinuxforwork/dotfiles)
- Hyprland: [hyprwm/Hyprland](https://github.com/hyprwm/Hyprland)

## 📝 License

Feel free to use and modify as needed!
