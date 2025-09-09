{
  config,
  pkgs,
  lib,
  ...
}:
{
  services.home-assistant = {
    enable = true;

    # Add extra Python packages for integrations that need them
    extraPackages =
      python3Packages: with python3Packages; [
        grpcio
        grpcio-status
        grpcio-reflection
        grpcio-tools
        gtts  # Google Text-to-Speech
        pyatv  # Apple TV integration
        pyheos  # HEOS (Denon/Marantz) integration
        wyoming  # Wyoming protocol for voice services (Piper TTS)
      ];

    # Custom components (like Nest Protect)
    customComponents = with pkgs.home-assistant-custom-components; [
      nest_protect
    ];
    
    # Custom Lovelace cards
    customLovelaceModules = with pkgs.home-assistant-custom-lovelace-modules; [
      card-mod  # CSS styling for cards
    ];

    extraComponents = [
      # Core functionality
      "default_config" # Includes most common integrations
      "met" # Weather (required for onboarding)
      "radio_browser" # Radio stations
      "application_credentials" # OAuth credential management for self-hosted
      "ffmpeg" # Media processing (required for Nest and cameras)

      # Smart devices
      "hue" # Philips Hue lights
      "homekit_controller" # Connect HomeKit devices locally (including ecobee)
      "zeroconf" # Network discovery for HomeKit and other devices
      "zwave_js" # Z-Wave via Z-Wave JS UI on bluedesert
      "miele" # Miele appliances (dishwasher)
      "lg_thinq" # LG ThinQ washer/dryer (requires LG account)
      "home_connect" # Bosch/Siemens Home Connect appliances
      "nest" # Nest Protect smoke/CO detectors and thermostats
      "sonos" # Sonos speakers and sound system
      "unifi" # UniFi network devices (access points, switches, controller)
      "spotify" # Spotify media playback and control
      "mqtt" # MQTT (if you add it later)

      # Local media integration
      "jellyfin" # Your Jellyfin server
      "webostv" # LG WebOS TV control
      "denonavr" # Denon/Marantz AVR receivers
      "radarr" # Movie collection manager
      "sonarr" # TV show collection manager
      "sabnzbd" # SABnzbd downloader (running in podman)

      # System monitoring
      "systemmonitor" # Monitor ultraviolet's resources
      "uptime"
      "command_line" # Run shell commands for monitoring

      # Network services
      "tailscale" # Tailscale VPN status and control

      # Additional services
      "todoist"
      
      # Voice and audio
      "piper"  # Local text-to-speech (supports custom voices like GlaDOS)
      "wyoming"  # Protocol for voice services integration

      # Mobile app support
      "mobile_app" # For Home Assistant companion app
      "webhook" # For app communications

      # Automation helpers
      "input_boolean"
      "input_button"
      "input_datetime"
      "input_number"
      "input_select"
      "input_text"
      "timer"
      "counter"
      "schedule"
    ];

    config = {
      # Basic configuration
      default_config = { };

      homeassistant = {
        name = "Home";
        # Location is loaded from secrets.yaml to keep it out of git
        latitude = "!secret latitude";
        longitude = "!secret longitude";
        elevation = "!secret elevation";
        unit_system = "us_customary"; # Use Fahrenheit, miles, etc.
        time_zone = "America/Los_Angeles";
        currency = "USD";
        country = "US";
        # External access via Cloudflare Tunnel
        external_url = "https://home.husbuddies.gay";
        internal_url = "http://localhost:8123";

        # Multi-factor authentication configuration
        auth_mfa_modules = [
          {
            # Primary MFA: Time-based One-Time Password (TOTP)
            # Use with Google Authenticator, Authy, 1Password, etc.
            type = "totp";
            name = "Authenticator app";
          }
        ];
      };

      # Define the home zone with a smaller radius (in meters)
      zone = [
        {
          name = "Home";
          latitude = "!secret latitude";
          longitude = "!secret longitude";
          radius = 50; # 50 meters (~164 feet) - adjust as needed
          icon = "mdi:home";
        }
      ];

      # Enable the web interface
      http = {
        server_host = "0.0.0.0"; # Listen on all interfaces (needed for proxies)
        trusted_proxies = [
          "::1"
          "127.0.0.1"
          "172.31.0.0/24" # Local network
        ];
        use_x_forwarded_for = true;
      };

      # Configure recorder for history (30 days default)
      recorder = {
        purge_keep_days = 30;
        exclude = {
          domains = [
            "automation"
            "updater"
          ];
          entity_globs = [
            "sensor.weather_*"
          ];
        };
      };

      # Z-Wave JS configuration to connect to bluedesert
      zwave_js = {
        # This will be configured through the UI
        # URL: ws://bluedesert:3000 or ws://172.31.0.201:3000
      };

      # Frontend themes
      frontend = {
        themes = "!include_dir_merge_named themes";
      };

      # Logging
      logger = {
        default = "warning";
        logs = {
          "homeassistant.components.zwave_js" = "info";
          "homeassistant.components.sonos" = "info"; # Debug Sonos discovery
          "homeassistant.components.ssdp" = "debug"; # Debug network discovery
        };
      };

      # Sonos configuration - Manual discovery for Sonos Move
      sonos = {
        media_player = {
          hosts = [
            "172.31.0.32" # Sonos Move
          ];
        };
      };

      # Miele configuration (for self-hosted OAuth)
      # You'll need to get client_id and client_secret from Miele developer portal
      # miele = {
      #   client_id = "!secret miele_client_id";
      #   client_secret = "!secret miele_client_secret";
      # };

      # Automation engine (keep automations in UI for easy editing)
      automation = "!include automations.yaml";
      script = "!include scripts.yaml";
      scene = "!include scenes.yaml";
    };

    # Make configuration writable so you can edit from the UI
    configWritable = true;

    # Configure directory for additional YAML files
    configDir = "/var/lib/hass";

    # Open firewall port (only localhost, Caddy handles external)
    openFirewall = false;
  };

  # Add Home Assistant to Caddy reverse proxy
  services.caddy.virtualHosts."homeassistant.home.husbuddies.gay" = {
    extraConfig = ''
      reverse_proxy localhost:8123 {
        header_up Host {host}
        header_up X-Real-IP {remote}
        header_up X-Forwarded-For {remote}
      }
      import cloudflare
    '';
  };

  # Create necessary directories and files
  systemd.tmpfiles.rules = [
    "d /var/lib/hass/themes 0755 hass hass -"
    "d /etc/homepage/keys 0755 root root -"
  ];

  # Create a secrets.yaml template for Home Assistant
  # This file can be edited after deployment to add your actual secrets
  environment.etc."hass-secrets.yaml" = {
    mode = "0600";
    user = "hass";
    text = ''
      # Home Assistant Secrets File
      # IMPORTANT: Edit this file at /var/lib/hass/secrets.yaml after deployment
      # with your actual location and API keys

      # Location data - MUST UPDATE with your actual location
      # Find your coordinates at https://www.latlong.net/
      latitude: 0.0
      longitude: 0.0  
      elevation: 0

      # Z-Wave JS WebSocket URL (update if using different host/port)
      zwave_js_url: ws://172.31.0.201:3000

      # API Keys (add as needed)
      # ecobee_api_key: your-ecobee-api-key
      # openweathermap_api_key: your-openweathermap-key

      # Notification servers
      ntfy_server: http://172.31.0.201:8093
      # Use random strings for topics for security
      ntfy_topic_alerts: home-alerts-CHANGEME
      ntfy_topic_water: water-sensors-CHANGEME
      ntfy_topic_security: door-sensors-CHANGEME
    '';
  };

  # Copy secrets file to Home Assistant directory on startup
  systemd.services.home-assistant.preStart = lib.mkAfter ''
    # Copy secrets file if it doesn't exist
    if [ ! -f /var/lib/hass/secrets.yaml ]; then
      cp /etc/hass-secrets.yaml /var/lib/hass/secrets.yaml
      chown hass:hass /var/lib/hass/secrets.yaml
      chmod 600 /var/lib/hass/secrets.yaml
      echo "Created secrets.yaml - please edit it with your actual values"
    fi
  '';

  # Backup service for Home Assistant
  systemd.services.home-assistant-backup = {
    description = "Backup Home Assistant configuration to NAS";
    after = [
      "home-assistant.service"
      "mnt-backups.mount"
    ];
    requires = [ "mnt-backups.mount" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /mnt/backups/home-assistant";
      ExecStart = pkgs.writeShellScript "ha-backup" ''
        set -e

        BACKUP_DIR="/mnt/backups/home-assistant"
        SOURCE_DIR="/var/lib/hass"
        DATE=$(date +%Y%m%d-%H%M%S)
        BACKUP_PATH="$BACKUP_DIR/backup-$DATE"

        # Call Home Assistant to purge old recorder entries for database consistency
        if [ -f /var/lib/hass/.secrets/backup-token ]; then
          ${pkgs.curl}/bin/curl -X POST \
            -H "Authorization: Bearer $(cat /var/lib/hass/.secrets/backup-token)" \
            -H "Content-Type: application/json" \
            http://localhost:8123/api/services/recorder/purge \
            -d '{"keep_days": 30, "repack": false}' \
            2>/dev/null || true
        fi

        # Wait a moment for any pending writes to complete
        sleep 5

        # Perform the backup using rsync (no ownership preservation for NFS)
        ${pkgs.rsync}/bin/rsync -rlptDv \
          --exclude='home-assistant_v2.db-shm' \
          --exclude='home-assistant_v2.db-wal' \
          --exclude='*.log' \
          --exclude='*.log.*' \
          --exclude='.cloud' \
          --exclude='deps' \
          --exclude='__pycache__' \
          "$SOURCE_DIR/" "$BACKUP_PATH/"

        # Keep only the last 14 days of backups
        find "$BACKUP_DIR" -maxdepth 1 -type d -name "backup-*" -mtime +14 -exec rm -rf {} \; || true

        # Create a "latest" symlink for easy access
        ln -sfn "$BACKUP_PATH" "$BACKUP_DIR/latest"

        echo "Backup completed successfully to $BACKUP_PATH"

        # Log backup size for monitoring
        ${pkgs.coreutils}/bin/du -sh "$BACKUP_PATH" | ${pkgs.util-linux}/bin/logger -t home-assistant-backup
      '';
    };
  };

  # Timer to run backup daily at 3 AM
  systemd.timers.home-assistant-backup = {
    description = "Daily Home Assistant backup timer";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 03:00:00"; # Daily at 3 AM
      Persistent = true; # Run backup if system was off at scheduled time
      RandomizedDelaySec = "10m"; # Add some randomness to prevent exact time conflicts
    };
  };

  # Restore service for Home Assistant
  systemd.services.home-assistant-restore = {
    description = "Restore Home Assistant configuration from NAS backup";
    after = [ "mnt-backups.mount" ];
    requires = [ "mnt-backups.mount" ];
    before = [ "home-assistant.service" ];

    serviceConfig = {
      Type = "oneshot";
      User = "root";
      RemainAfterExit = false;
      ExecStart = pkgs.writeShellScript "ha-restore" ''
        set -e

        BACKUP_DIR="/mnt/backups/home-assistant"
        RESTORE_DIR="/var/lib/hass"

        # Parse arguments
        BACKUP_NAME="''${1:-latest}"

        # Determine which backup to restore
        if [ "$BACKUP_NAME" = "latest" ]; then
          if [ -L "$BACKUP_DIR/latest" ]; then
            BACKUP_PATH="$BACKUP_DIR/latest"
            echo "Restoring from latest backup: $(readlink -f "$BACKUP_PATH")"
          else
            echo "Error: No 'latest' symlink found. Please specify a backup name."
            echo "Available backups:"
            ls -1d "$BACKUP_DIR"/backup-* 2>/dev/null | sed 's|.*/||' || echo "No backups found"
            exit 1
          fi
        elif [ -d "$BACKUP_DIR/$BACKUP_NAME" ]; then
          BACKUP_PATH="$BACKUP_DIR/$BACKUP_NAME"
          echo "Restoring from backup: $BACKUP_NAME"
        else
          echo "Error: Backup '$BACKUP_NAME' not found"
          echo "Available backups:"
          ls -1d "$BACKUP_DIR"/backup-* 2>/dev/null | sed 's|.*/||' || echo "No backups found"
          exit 1
        fi

        # Safety check - confirm if Home Assistant is running
        if systemctl is-active --quiet home-assistant.service; then
          echo "WARNING: Home Assistant is currently running!"
          echo "It's recommended to stop it before restoring:"
          echo "  sudo systemctl stop home-assistant.service"
          echo ""
          echo "Proceed anyway? This might cause issues. (y/N)"
          read -r response
          if [[ ! "$response" =~ ^[Yy]$ ]]; then
            echo "Restore cancelled"
            exit 0
          fi
        fi

        # Create backup of current config before restoring
        if [ -d "$RESTORE_DIR" ] && [ "$(ls -A "$RESTORE_DIR")" ]; then
          SAFETY_BACKUP="/var/lib/hass-backup-before-restore-$(date +%Y%m%d-%H%M%S)"
          echo "Creating safety backup of current config at $SAFETY_BACKUP"
          ${pkgs.rsync}/bin/rsync -rlptD "$RESTORE_DIR/" "$SAFETY_BACKUP/"
        fi

        # Ensure target directory exists
        mkdir -p "$RESTORE_DIR"

        # Perform the restore
        echo "Restoring configuration from $BACKUP_PATH..."
        ${pkgs.rsync}/bin/rsync -rlptDv --delete \
          --exclude='home-assistant_v2.db-shm' \
          --exclude='home-assistant_v2.db-wal' \
          --exclude='*.log' \
          --exclude='*.log.*' \
          "$BACKUP_PATH/" "$RESTORE_DIR/"

        # Fix ownership
        chown -R hass:hass "$RESTORE_DIR"

        echo ""
        echo "✅ Restore completed successfully!"
        echo ""
        echo "Next steps:"
        echo "1. Start Home Assistant: sudo systemctl start home-assistant.service"
        echo "2. Check the logs: sudo journalctl -fu home-assistant.service"
        echo "3. Access the UI at https://home.husbuddies.gay"
        echo ""
        if [ -n "$SAFETY_BACKUP" ]; then
          echo "Safety backup preserved at: $SAFETY_BACKUP"
          echo "You can remove it once everything is working: sudo rm -rf $SAFETY_BACKUP"
        fi
      '';
    };
  };

  # Create convenient restore command
  environment.systemPackages = with pkgs; [
    (writeShellScriptBin "ha-restore" ''
      # Home Assistant Restore Tool
      # Usage: ha-restore [backup-name|latest]
      #   latest (default) - Restore the most recent backup
      #   backup-20250902-225915 - Restore specific backup by name
      #   list - Show available backups

      set -e

      BACKUP_DIR="/mnt/backups/home-assistant"

      case "''${1:-latest}" in
        list|--list|-l)
          echo "Available Home Assistant backups:"
          echo ""
          if [ -L "$BACKUP_DIR/latest" ]; then
            echo "  latest -> $(basename "$(readlink -f "$BACKUP_DIR/latest")")"
            echo ""
          fi
          ls -1dt "$BACKUP_DIR"/backup-* 2>/dev/null | while read -r backup; do
            size=$(${pkgs.coreutils}/bin/du -sh "$backup" | cut -f1)
            date=$(basename "$backup" | sed 's/backup-//')
            echo "  $(basename "$backup") ($size)"
          done || echo "No backups found"
          ;;
        *)
          # Stop HA if running
          if systemctl is-active --quiet home-assistant.service; then
            echo "Stopping Home Assistant for restore..."
            sudo systemctl stop home-assistant.service
          fi
          
          # Run the restore
          sudo systemctl start home-assistant-restore.service "''${1:-latest}"
          
          # Follow the logs
          sudo journalctl -u home-assistant-restore.service -f --no-pager
          ;;
      esac
    '')
  ];

  # Note: After deploying, you'll need to:
  # 1. UPDATE LOCATION: Edit /var/lib/hass/secrets.yaml with your actual latitude/longitude
  # 2. Access Home Assistant at https://homeassistant.home.husbuddies.gay
  # 3. Complete the onboarding process
  # 4. Update location in UI: Settings -> System -> General
  # 5. Add integrations:
  #    - Z-Wave JS: URL ws://bluedesert:3000 or ws://172.31.0.201:3000
  #    - Philips Hue: Will auto-discover or add manually
  #    - Ecobee: Use the cloud integration with OAuth
  #    - Jellyfin: Server at http://localhost:8096
  # 6. Generate Long-Lived Access Token for Homepage:
  #    - Profile -> Security -> Long-Lived Access Tokens
  #    - Save to /etc/homepage/keys/homeassistant-api-key
  # 7. Install the companion app on your phone
  # 8. Set up ntfy in automations for push notifications
}

