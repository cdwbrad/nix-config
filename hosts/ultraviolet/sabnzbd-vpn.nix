{ config, pkgs, ... }:

{
  # SABnzbd with Mullvad VPN using Gluetun container
  # Gluetun provides VPN with built-in killswitch
  
  virtualisation.oci-containers = {
    backend = "podman";
    
    containers = {
      # Gluetun VPN container - handles all VPN connectivity
      gluetun = {
        image = "qmcgaw/gluetun:v3.40.0";  # Pin to stable version
        
        environment = {
          VPN_SERVICE_PROVIDER = "mullvad";
          VPN_TYPE = "wireguard";
          # Mullvad WireGuard configuration - reads from secret files
          WIREGUARD_PRIVATE_KEY_SECRETFILE = "/gluetun/wireguard/privatekey";
          WIREGUARD_ADDRESSES_SECRETFILE = "/gluetun/wireguard/addresses";
          WIREGUARD_PRESHARED_KEY = "";  # Mullvad doesn't use preshared keys
          SERVER_CITIES = "Los Angeles CA";  # Choose your preferred city
          
          # Killswitch is enabled by default in Gluetun
          FIREWALL = "on";
          DOT = "on";  # DNS over TLS
          BLOCK_MALICIOUS = "on";
          BLOCK_ADS = "off";  # Set to "on" if you want ad blocking
          
          # Mullvad doesn't support port forwarding anymore
          VPN_PORT_FORWARDING = "off";
          
          # Health check
          HEALTH_VPN_DURATION_INITIAL = "30s";
          HEALTH_VPN_DURATION_ADDITION = "10s";
        };
        
        volumes = [
          "/etc/mullvad/gluetun:/gluetun"  # Mount directory with WireGuard config
        ];
        
        extraOptions = [
          "--cap-add=NET_ADMIN"
          "--device=/dev/net/tun"
          "--sysctl=net.ipv4.conf.all.src_valid_mark=1"
          "--sysctl=net.ipv6.conf.all.disable_ipv6=0"  # Enable IPv6 if Mullvad supports it
        ];
        
        ports = [
          "8080:8080"   # SABnzbd web interface
          "8888:8888"   # HTTP proxy (Gluetun)
          "8388:8388"   # Shadowsocks proxy (Gluetun)
        ];
        
        autoStart = true;
      };
      
      # SABnzbd container - routes through Gluetun
      sabnzbd = {
        image = "linuxserver/sabnzbd:latest";
        
        environment = {
          PUID = "1000";
          PGID = "1000";
          TZ = "America/Los_Angeles";
          # SABnzbd environment variables for aggressive cleanup
          SABNZBD_CLEANUP_LIST = "true";  # Clean up list files after download
          SABNZBD_SCRIPT_DIR = "/config/scripts";
        };
        
        volumes = [
          "/var/lib/sabnzbd:/config"                    # Config with secrets
          "/var/cache/sabnzbd:/downloads"               # Local SSD for temp files (fast!)
          "/mnt/video/sabnzbd/completed:/mnt/video/sabnzbd/completed"  # NFS mount path matches host
        ];
        
        # Use Gluetun's network stack - this is the key!
        dependsOn = [ "gluetun" ];
        extraOptions = [
          "--network=container:gluetun"  # Use Gluetun's network (VPN + killswitch)
          
          # Performance optimizations
          "--cpu-shares=2048"            # Higher CPU priority
          "--memory=6g"                   # Plenty of RAM for unpacking
          "--memory-swap=6g"              # No swap (use RAM only)
        ];
        
        autoStart = true;
      };
    };
  };

  # Ensure directories exist with proper permissions
  systemd.tmpfiles.rules = [
    # SABnzbd directories
    "d /var/lib/sabnzbd 0755 1000 1000 -"
    "d /var/lib/sabnzbd/admin 0755 1000 1000 -"
    "d /var/lib/sabnzbd/logs 0755 1000 1000 -"
    "d /var/lib/sabnzbd/scripts 0755 1000 1000 -"
    "d /var/cache/sabnzbd 0755 1000 1000 -"
    "d /var/cache/sabnzbd/incomplete 0755 1000 1000 -"
    
    # Mullvad config directory (only private key needed)
    "d /etc/mullvad 0700 root root -"
    "d /etc/mullvad/gluetun 0700 root root -"
    "d /etc/mullvad/gluetun/wireguard 0700 root root -"
    
    # Completed downloads on NFS
    "d /mnt/video/sabnzbd 0755 1000 1000 -"
    "d /mnt/video/sabnzbd/completed 0755 1000 1000 -"
  ];

  # Deploy post-processing script for SABnzbd
  systemd.services.sabnzbd-deploy-scripts = {
    description = "Deploy post-processing scripts to SABnzbd";
    wantedBy = [ "multi-user.target" ];
    after = [ "podman-sabnzbd.service" ];
    
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = let
        postCleanupScript = pkgs.writeScript "sabnzbd-post-cleanup.sh" ''
          #!${pkgs.bash}/bin/bash
          # SABnzbd post-processing script for aggressive cleanup
          # This script is called by SABnzbd after each download completes

          # SABnzbd passes these parameters:
          # $1 = Directory of the completed download
          # $2 = NZB name (without .nzb)
          # $3 = Clean NZB name
          # $4 = Indexer report number
          # $5 = Category
          # $6 = Group (0=alt.binaries, ...)
          # $7 = Status (0=OK, 1=failed verification, 2=failed unpack, 3=password, ...)

          DOWNLOAD_DIR="$1"
          STATUS="$7"

          echo "[$(${pkgs.coreutils}/bin/date)] Post-processing cleanup for: $DOWNLOAD_DIR"

          # Only run cleanup if download was successful
          if [ "$STATUS" = "0" ]; then
              echo "Download successful, cleaning up temp files..."
              
              # Clean up par2 files (already used for verification)
              ${pkgs.findutils}/bin/find "$DOWNLOAD_DIR" -name "*.par2" -delete 2>/dev/null || true
              
              # Clean up sample files (usually not needed)
              ${pkgs.findutils}/bin/find "$DOWNLOAD_DIR" -type f \( -iname "*sample*" -o -iname "*proof*" \) -size -100M -delete 2>/dev/null || true
              
              # Clean up .nfo, .sfv, .txt files (metadata)
              ${pkgs.findutils}/bin/find "$DOWNLOAD_DIR" -type f \( -iname "*.nfo" -o -iname "*.sfv" -o -iname "*.txt" \) -delete 2>/dev/null || true
              
              # Clean up empty directories
              ${pkgs.findutils}/bin/find "$DOWNLOAD_DIR" -type d -empty -delete 2>/dev/null || true
              
              echo "Cleanup complete for successful download"
          else
              echo "Download failed (status: $STATUS), keeping files for troubleshooting"
          fi

          # Always clean up old incomplete downloads from temp directory
          TEMP_DIR="/var/cache/sabnzbd/incomplete"
          if [ -d "$TEMP_DIR" ]; then
              # Remove incomplete downloads older than 2 hours
              ${pkgs.findutils}/bin/find "$TEMP_DIR" -maxdepth 1 -type d -mmin +120 -exec ${pkgs.coreutils}/bin/rm -rf {} + 2>/dev/null || true
              
              # Check disk usage and alert if high
              USAGE=$(${pkgs.coreutils}/bin/df "$TEMP_DIR" | ${pkgs.gawk}/bin/awk 'NR==2 {print int($5)}')
              if [ "$USAGE" -gt 75 ]; then
                  echo "WARNING: Temp directory usage at ''${USAGE}%"
                  # Remove even newer files if critically low on space
                  ${pkgs.findutils}/bin/find "$TEMP_DIR" -maxdepth 1 -type d -mmin +30 -exec ${pkgs.coreutils}/bin/rm -rf {} + 2>/dev/null || true
              fi
          fi

          # Exit with success so SABnzbd continues processing
          exit 0
        '';
      in pkgs.writeScript "deploy-scripts" ''
        #!${pkgs.bash}/bin/bash
        
        # Copy post-processing script to SABnzbd scripts directory
        ${pkgs.coreutils}/bin/cp ${postCleanupScript} /var/lib/sabnzbd/scripts/post-cleanup.sh
        ${pkgs.coreutils}/bin/chmod 755 /var/lib/sabnzbd/scripts/post-cleanup.sh
        ${pkgs.coreutils}/bin/chown 1000:1000 /var/lib/sabnzbd/scripts/post-cleanup.sh
        
        echo "Post-processing scripts deployed"
        echo "Configure in SABnzbd: Settings -> Categories -> Default -> Script: post-cleanup.sh"
      '';
    };
  };

  # Setup script to prepare Mullvad configuration
  environment.systemPackages = [ 
    (pkgs.writeScriptBin "setup-mullvad-sabnzbd" ''
      #!${pkgs.bash}/bin/bash
      set -e
      
      echo "=== Mullvad WireGuard Setup for SABnzbd ==="
      echo ""
      echo "Option 1: Get from Mullvad website:"
      echo "   1. Go to: https://mullvad.net/en/account#/wireguard-config"
      echo "   2. Generate a new WireGuard configuration"
      echo "   3. Copy the PrivateKey value"
      echo ""
      echo "Option 2: Or if you have mullvad CLI installed:"
      echo "   mullvad account login"
      echo "   mullvad relay set location us lax"
      echo "   mullvad tunnel wireguard key regenerate"
      echo ""
      read -sp "Enter your WireGuard Private Key: " private_key
      echo ""
      
      # Save to file that Gluetun will read (only private key needed for Mullvad)
      echo "$private_key" | sudo tee /etc/mullvad/gluetun/wireguard/privatekey > /dev/null
      
      sudo chmod 600 /etc/mullvad/gluetun/wireguard/privatekey
      
      echo ""
      echo "✅ Configuration saved!"
      echo "   Run 'systemctl restart podman-gluetun' to apply"
    '')
  ];

  # Aggressive cleanup service for SABnzbd temp files
  systemd.services.sabnzbd-temp-cleanup = {
    description = "Clean up SABnzbd temporary files aggressively";
    
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "cleanup-sabnzbd-temp" ''
        #!${pkgs.bash}/bin/bash
        set -euo pipefail
        
        TEMP_DIR="/var/cache/sabnzbd"
        INCOMPLETE_DIR="$TEMP_DIR/incomplete"
        
        echo "[$(date)] Starting SABnzbd temp cleanup"
        
        # Get filesystem usage percentage
        USAGE=$(${pkgs.coreutils}/bin/df "$TEMP_DIR" | ${pkgs.gawk}/bin/awk 'NR==2 {print int($5)}')
        echo "Filesystem usage: $USAGE%"
        
        # Clean based on filesystem usage
        if [ "$USAGE" -gt 80 ]; then
            echo "⚠️  Critical: Filesystem over 80% full, aggressive cleanup"
            
            # Remove all files older than 1 hour
            ${pkgs.findutils}/bin/find "$INCOMPLETE_DIR" -type f -mmin +60 -delete 2>/dev/null || true
            
            # Remove empty directories
            ${pkgs.findutils}/bin/find "$INCOMPLETE_DIR" -type d -empty -delete 2>/dev/null || true
            
            # If still over 80%, remove orphaned files (not being written to)
            USAGE=$(${pkgs.coreutils}/bin/df "$TEMP_DIR" | ${pkgs.gawk}/bin/awk 'NR==2 {print int($5)}')
            if [ "$USAGE" -gt 80 ]; then
                echo "Still critical, removing orphaned files..."
                ${pkgs.findutils}/bin/find "$INCOMPLETE_DIR" -type f -mmin +30 ! -exec ${pkgs.lsof}/bin/lsof {} \; -delete 2>/dev/null || true
            fi
            
        elif [ "$USAGE" -gt 60 ]; then
            echo "⚠️  Warning: Filesystem over 60% full, moderate cleanup"
            
            # Remove files older than 6 hours
            ${pkgs.findutils}/bin/find "$INCOMPLETE_DIR" -type f -mmin +360 -delete 2>/dev/null || true
            
            # Remove empty directories
            ${pkgs.findutils}/bin/find "$INCOMPLETE_DIR" -type d -empty -delete 2>/dev/null || true
            
        else
            echo "✅ Filesystem usage normal, routine cleanup"
            
            # Remove files older than 24 hours (likely abandoned)
            ${pkgs.findutils}/bin/find "$INCOMPLETE_DIR" -type f -mtime +1 -delete 2>/dev/null || true
            
            # Remove empty directories
            ${pkgs.findutils}/bin/find "$INCOMPLETE_DIR" -type d -empty -delete 2>/dev/null || true
        fi
        
        # Always clean up SABnzbd's admin/history if it gets too large
        ADMIN_DIR="/var/lib/sabnzbd/admin"
        if [ -d "$ADMIN_DIR" ]; then
            # Remove old SABnzbd logs (keep last 7 days)
            ${pkgs.findutils}/bin/find "$ADMIN_DIR" -name "*.log*" -mtime +7 -delete 2>/dev/null || true
            ${pkgs.findutils}/bin/find "/var/lib/sabnzbd/logs" -name "*.log*" -mtime +7 -delete 2>/dev/null || true
        fi
        
        # Report final usage
        FINAL_USAGE=$(${pkgs.coreutils}/bin/df "$TEMP_DIR" | ${pkgs.gawk}/bin/awk 'NR==2 {print int($5)}')
        echo "Cleanup complete. Final filesystem usage: $FINAL_USAGE%"
        
        # Alert if still critical
        if [ "$FINAL_USAGE" -gt 85 ]; then
            echo "❌ CRITICAL: Filesystem still over 85% after cleanup!"
            echo "   Manual intervention may be required"
            echo "   Check: du -sh $TEMP_DIR/* | sort -h"
        fi
      '';
    };
  };
  
  # Run cleanup every 15 minutes
  systemd.timers.sabnzbd-temp-cleanup = {
    description = "Run SABnzbd temp cleanup every 15 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "5min";
      OnUnitActiveSec = "15min";
      Persistent = true;
    };
  };

  # Emergency cleanup service (triggered when disk is nearly full)
  systemd.services.sabnzbd-emergency-cleanup = {
    description = "Emergency cleanup when disk space is critical";
    
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "emergency-cleanup" ''
        #!${pkgs.bash}/bin/bash
        
        TEMP_DIR="/var/cache/sabnzbd"
        
        echo "🚨 EMERGENCY CLEANUP TRIGGERED"
        
        # Pause SABnzbd to prevent new downloads
        ${pkgs.curl}/bin/curl -s "http://localhost:8080/api?mode=pause" || true
        
        # Remove ALL temp files not currently being written
        ${pkgs.findutils}/bin/find "$TEMP_DIR/incomplete" -type f ! -exec ${pkgs.lsof}/bin/lsof {} \; -delete 2>/dev/null || true
        
        # Clear SABnzbd's article cache
        rm -rf "$TEMP_DIR/incomplete/"*.sab 2>/dev/null || true
        
        # Resume SABnzbd
        sleep 5
        ${pkgs.curl}/bin/curl -s "http://localhost:8080/api?mode=resume" || true
        
        echo "Emergency cleanup complete"
      '';
    };
  };

  # Monitor disk space and trigger emergency cleanup if needed
  systemd.paths.sabnzbd-disk-monitor = {
    description = "Monitor disk space for SABnzbd temp directory";
    pathConfig = {
      PathModified = "/var/cache/sabnzbd";
      Unit = "sabnzbd-disk-check.service";
    };
    wantedBy = [ "multi-user.target" ];
  };

  systemd.services.sabnzbd-disk-check = {
    description = "Check if emergency cleanup is needed";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "check-disk" ''
        #!${pkgs.bash}/bin/bash
        
        USAGE=$(${pkgs.coreutils}/bin/df /var/cache/sabnzbd | ${pkgs.gawk}/bin/awk 'NR==2 {print int($5)}')
        
        if [ "$USAGE" -gt 90 ]; then
            echo "Disk usage critical ($USAGE%), triggering emergency cleanup"
            ${pkgs.systemd}/bin/systemctl start sabnzbd-emergency-cleanup
        fi
      '';
    };
  };

  # Health check service
  systemd.services.sabnzbd-vpn-health = {
    description = "Check SABnzbd VPN connection health";
    after = [ "podman-gluetun.service" "podman-sabnzbd.service" ];
    
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeScript "check-vpn-health" ''
        #!${pkgs.bash}/bin/bash
        
        echo "Checking SABnzbd VPN connection..."
        
        # Check if Gluetun is healthy
        if ! ${pkgs.podman}/bin/podman healthcheck run gluetun 2>/dev/null; then
          echo "❌ Gluetun VPN is not healthy!"
          exit 1
        fi
        
        # Check external IP through Gluetun
        VPN_IP=$(${pkgs.curl}/bin/curl -s --proxy http://localhost:8888 https://ipinfo.io/ip 2>/dev/null || echo "FAILED")
        
        if [ "$VPN_IP" = "FAILED" ]; then
          echo "❌ Cannot reach internet through VPN!"
          echo "   Killswitch is active - no VPN, no internet."
          exit 1
        fi
        
        # Verify it's Mullvad
        VPN_ORG=$(${pkgs.curl}/bin/curl -s --proxy http://localhost:8888 https://ipinfo.io/org 2>/dev/null || echo "")
        
        if echo "$VPN_ORG" | grep -qi mullvad; then
          echo "✅ SABnzbd is using Mullvad VPN"
          echo "   External IP: $VPN_IP"
          echo "   Organization: $VPN_ORG"
        else
          echo "⚠️  WARNING: May not be using Mullvad"
          echo "   IP: $VPN_IP"
          echo "   Org: $VPN_ORG"
        fi
        
        # Check if SABnzbd is accessible
        if ${pkgs.curl}/bin/curl -s http://localhost:8080 >/dev/null 2>&1; then
          echo "✅ SABnzbd web interface is accessible"
        else
          echo "❌ SABnzbd web interface is not responding"
        fi
      '';
    };
    
    # Run health check every 30 minutes
    startAt = "*:0/30";
  };
}