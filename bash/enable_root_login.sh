#!/bin/bash
# Universal Debian Root Login Enable Script
# Compatible with Debian 11, 12, 13 and derivatives
# Usage: sudo bash enable_root_login.sh

set -e

echo "=== Debian Universal Root Login Enable Script ==="
echo

# Check if running with root privileges
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script with sudo privileges"
    echo "Usage: sudo bash $0"
    exit 1
fi

# Detect Debian version
DEBIAN_VERSION=$(lsb_release -rs 2>/dev/null || cat /etc/debian_version 2>/dev/null || echo "unknown")
echo "Detected Debian version: $DEBIAN_VERSION"
echo

# Backup original SSH configuration file
echo "1. Backing up SSH configuration file..."
BACKUP_FILE="/etc/ssh/sshd_config.bak.$(date +%Y%m%d_%H%M%S)"
cp /etc/ssh/sshd_config "$BACKUP_FILE"
echo "   Backed up to: $BACKUP_FILE"

# Configure SSH to allow root login
echo "2. Modifying SSH configuration..."
if grep -q "^#PermitRootLogin" /etc/ssh/sshd_config; then
    # If commented PermitRootLogin exists, uncomment and set to yes
    sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    echo "   Uncommented and set PermitRootLogin to yes"
elif grep -q "^PermitRootLogin" /etc/ssh/sshd_config; then
    # If uncommented PermitRootLogin exists, modify directly
    sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    echo "   Modified PermitRootLogin to yes"
else
    # If no PermitRootLogin configuration exists, add it
    echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    echo "   Added PermitRootLogin yes configuration"
fi

# Check and enable password authentication
echo "3. Checking password authentication settings..."
if grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config; then
    echo "   Found password authentication disabled, enabling..."
    sed -i 's/^PasswordAuthentication no/PasswordAuthentication yes/' /etc/ssh/sshd_config
    echo "   Password authentication enabled"
elif grep -q "^#PasswordAuthentication" /etc/ssh/sshd_config; then
    # Uncomment and set to yes
    sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
    echo "   Uncommented and enabled password authentication"
elif ! grep -q "^PasswordAuthentication" /etc/ssh/sshd_config; then
    # If no related configuration exists, add it
    echo "PasswordAuthentication yes" >> /etc/ssh/sshd_config
    echo "   Added password authentication configuration"
else
    echo "   Password authentication already enabled"
fi

# Ensure PubkeyAuthentication is also enabled (maintain compatibility)
echo "4. Ensuring public key authentication is enabled..."
if ! grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config; then
    if grep -q "^PubkeyAuthentication no" /etc/ssh/sshd_config; then
        sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        echo "   Enabled public key authentication"
    elif grep -q "^#PubkeyAuthentication" /etc/ssh/sshd_config; then
        sed -i 's/^#PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        echo "   Uncommented and enabled public key authentication"
    else
        echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
        echo "   Added public key authentication configuration"
    fi
else
    echo "   Public key authentication already enabled"
fi

# Check root user password status
echo "5. Checking root user password status..."
if passwd -S root 2>/dev/null | grep -q "L"; then
    echo "   Root user password is locked, setting new password..."
    echo "   Please enter a new password for the root user:"
    passwd root
elif ! passwd -S root &>/dev/null; then
    echo "   Root user password not set, setting new password..."
    echo "   Please enter a new password for the root user:"
    passwd root
else
    echo "   Root user password is already set"
    echo "   To change root password, run: passwd root"
fi

# Validate SSH configuration syntax
echo "6. Validating SSH configuration syntax..."
if sshd -t 2>/dev/null; then
    echo "   SSH configuration syntax is correct"
else
    echo "   Error: SSH configuration syntax is invalid, restoring backup..."
    cp "$BACKUP_FILE" /etc/ssh/sshd_config
    echo "   Original configuration restored"
    exit 1
fi

# Restart SSH service
echo "7. Restarting SSH service..."
if command -v systemctl &> /dev/null; then
    # SystemD-based systems
    systemctl restart ssh sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
    if systemctl is-active --quiet ssh 2>/dev/null || systemctl is-active --quiet sshd 2>/dev/null; then
        echo "   SSH service restarted successfully"
    else
        echo "   Error: SSH service restart failed"
        exit 1
    fi
elif command -v service &> /dev/null; then
    # SysV init systems
    service ssh restart || service sshd restart
    echo "   SSH service restarted successfully"
else
    echo "   Warning: Unable to restart SSH service automatically"
    echo "   Please restart SSH service manually"
fi

# Display SSH service status
echo "8. SSH service status:"
if command -v systemctl &> /dev/null; then
    systemctl status ssh sshd --no-pager -l 2>/dev/null || systemctl status ssh --no-pager -l 2>/dev/null || systemctl status sshd --no-pager -l 2>/dev/null || echo "   Unable to display service status"
elif command -v service &> /dev/null; then
    service ssh status || service sshd status || echo "   Unable to display service status"
fi

echo
echo "=== Configuration Complete ==="
echo "Root login has been enabled!"
echo
echo "Important Reminders:"
echo "1. Original configuration has been backed up to: $BACKUP_FILE"
echo "2. Ensure root password is strong enough"
echo "3. Consider configuring firewall to restrict SSH access"
echo "4. Consider using key-based authentication instead of password authentication"
echo "5. Regularly update your system for security patches"
echo
echo "Test connection: ssh root@$(hostname -I 2>/dev/null | awk '{print $1}' || echo 'YOUR_SERVER_IP')"
echo
echo "Current SSH configuration relevant lines:"
grep -E "^(PermitRootLogin|PasswordAuthentication|PubkeyAuthentication)" /etc/ssh/sshd_config
echo
