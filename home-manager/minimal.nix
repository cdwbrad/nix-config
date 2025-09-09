# Minimal configuration for resource-constrained bridge devices
# Only includes essentials for remote management and basic operations
{ inputs, lib, config, pkgs, ... }: {
  imports = [
    ./git
    ./ssh-config   # SSH configuration
    ./starship     # Keep starship for nice prompt
    ./tmux         # Keep tmux for persistent sessions
  ];

  home = {
    username = "joshsymonds";
    homeDirectory = "/home/joshsymonds";
    stateVersion = "25.05";

    packages = with pkgs; [
      # Absolute essentials only
      coreutils-full
      curl
      jq        # For parsing JSON from APIs
      htop      # Lightweight monitoring
      nano      # Simple text editor (not vim/neovim)
      ncdu      # Disk usage analyzer (useful given storage issues)
    ];

    sessionVariables = {
      EDITOR = "nano";  # Not nvim on this box
    };
  };

  # Minimal zsh config - light plugins only
  programs.zsh = {
    enable = true;
    enableCompletion = true;  # Keep completions, they're helpful
    autosuggestion.enable = false;  # Save resources
    syntaxHighlighting.enable = false;  # Save resources
    
    shellAliases = {
      update = "sudo nixos-rebuild switch --fast --flake \".#$(hostname)\"";
      ll = "ls -la";
      l = "ls -l";
      # Monitoring aliases for this box
      diskspace = "df -h / && du -sh /nix/store";
      zwave-logs = "sudo podman logs zwave-js-ui";
      ntfy-status = "systemctl status ntfy-sh";
    };
  };

  # Disable heavy services
  programs.neovim.enable = false;
  programs.direnv.enable = false;

  systemd.user.startServices = "sd-switch";
}