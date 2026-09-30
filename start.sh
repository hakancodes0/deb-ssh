Bu sh dosyasını sıfır taze debian sunucuda çalıştırınca ne olur güzel bence?

#!/usr/bin/env bash
set -euo pipefail

echo "===================================="
echo " Yeni Sunucu Otomatik Kurulum Scripti"
echo " Debian / Ubuntu"
echo "===================================="

if [ "$EUID" -ne 0 ]; then
  echo "Bu script root olarak çalıştırılmalı."
  echo "Örnek: bash setup-server.sh"
  exit 1
fi

read -rp "Yeni sudo kullanıcı adı: " NEW_USER

if [ -z "$NEW_USER" ]; then
  echo "Kullanıcı adı boş olamaz."
  exit 1
fi

read -rp "SSH public key yapıştır: " SSH_PUBLIC_KEY

if [ -z "$SSH_PUBLIC_KEY" ]; then
  echo "SSH public key boş olamaz."
  exit 1
fi

read -rp "SSH portu ne olsun? [22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

read -rp "Swap boyutu GB olarak? [2]: " SWAP_SIZE_GB
SWAP_SIZE_GB=${SWAP_SIZE_GB:-2}

echo ""
echo "Kurulum başlıyor..."
sleep 1

echo ""
echo "1) Sistem güncelleniyor..."
apt update
DEBIAN_FRONTEND=noninteractive apt upgrade -y

echo ""
echo "2) Temel paketler kuruluyor..."

apt install -y \
  sudo \
  curl \
  wget \
  git \
  nano \
  vim \
  ufw \
  fail2ban \
  htop \
  unzip \
  ca-certificates \
  gnupg \
  lsb-release

echo ""
echo "3) Yeni kullanıcı hazırlanıyor..."

if id "$NEW_USER" &>/dev/null; then
  echo "$NEW_USER zaten var, kullanıcı oluşturma atlandı."
  echo "Mevcut kullanıcının şifresini değiştirmek istersen:"
  echo "  passwd $NEW_USER"
else
  echo ""
  echo "Şimdi $NEW_USER kullanıcısı için şifre belirleyeceksin."
  echo "Bu şifre SSH için değil, sudo komutları için kullanılacak."
  echo ""

  adduser "$NEW_USER"
fi

usermod -aG sudo "$NEW_USER"

echo ""
echo "4) SSH key ekleniyor..."

USER_HOME="/home/$NEW_USER"
mkdir -p "$USER_HOME/.ssh"
chmod 700 "$USER_HOME/.ssh"

echo "$SSH_PUBLIC_KEY" > "$USER_HOME/.ssh/authorized_keys"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

chown -R "$NEW_USER:$NEW_USER" "$USER_HOME/.ssh"

echo ""
echo "5) SSH ayarları yedekleniyor ve güvenli hale getiriliyor..."

SSHD_CONFIG="/etc/ssh/sshd_config"
BACKUP_FILE="/etc/ssh/sshd_config.backup.$(date +%Y%m%d-%H%M%S)"

cp "$SSHD_CONFIG" "$BACKUP_FILE"

echo "SSH config backup: $BACKUP_FILE"

set_sshd_config() {
  local key="$1"
  local value="$2"

  if grep -qE "^[#[:space:]]*$key[[:space:]]+" "$SSHD_CONFIG"; then
    sed -i "s|^[#[:space:]]*$key[[:space:]].*|$key $value|" "$SSHD_CONFIG"
  else
    echo "$key $value" >> "$SSHD_CONFIG"
  fi
}

set_sshd_config "Port" "$SSH_PORT"
set_sshd_config "PermitRootLogin" "no"
set_sshd_config "PasswordAuthentication" "no"
set_sshd_config "PubkeyAuthentication" "yes"
set_sshd_config "ChallengeResponseAuthentication" "no"
set_sshd_config "KbdInteractiveAuthentication" "no"
set_sshd_config "UsePAM" "yes"

if grep -qE "^AllowUsers " "$SSHD_CONFIG"; then
  sed -i "s/^AllowUsers .*/AllowUsers $NEW_USER/" "$SSHD_CONFIG"
else
  echo "AllowUsers $NEW_USER" >> "$SSHD_CONFIG"
fi

echo ""
echo "6) SSH config test ediliyor..."

sshd -t

echo ""
echo "7) Firewall ayarlanıyor..."

ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp
ufw --force enable

echo ""
echo "8) Fail2ban ayarlanıyor..."

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = %(sshd_log)s
maxretry = 5
EOF

systemctl enable fail2ban
systemctl restart fail2ban

echo ""
echo "9) Swap ayarlanıyor..."

if swapon --show | grep -q "/swapfile"; then
  echo "Swap zaten var, atlandı."
else
  fallocate -l "${SWAP_SIZE_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$((SWAP_SIZE_GB * 1024))"
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  if ! grep -q "/swapfile" /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
fi

echo ""
echo "10) Kernel/network temel ayarları ekleniyor..."

cat > /etc/sysctl.d/99-server-hardening.conf <<EOF
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
kernel.randomize_va_space = 2
EOF

sysctl --system >/dev/null

echo ""
echo "11) Otomatik güvenlik güncellemeleri kuruluyor..."

apt install -y unattended-upgrades

cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

systemctl enable unattended-upgrades || true
systemctl restart unattended-upgrades || true

echo ""
echo "12) SSH servisi yeniden başlatılıyor..."

if systemctl list-unit-files | grep -q "^ssh.service"; then
  systemctl restart ssh
elif systemctl list-unit-files | grep -q "^sshd.service"; then
  systemctl restart sshd
else
  service ssh restart || service sshd restart
fi

echo ""
echo "===================================="
echo " Kurulum tamamlandı."
echo "===================================="
echo ""
echo "Yeni kullanıcı:"
echo "  $NEW_USER"
echo ""
echo "SSH port:"
echo "  $SSH_PORT"
echo ""
echo "Bağlanma komudu:"
echo "  ssh -p $SSH_PORT $NEW_USER@SUNUCU_IP"
echo ""
echo "Private key dosyan farklıysa:"
echo "  ssh -i ~/.ssh/KEY_DOSYAN -p $SSH_PORT $NEW_USER@SUNUCU_IP"
echo ""
echo "ÖNEMLİ:"
echo "Bu root terminalini hemen kapatma."
echo ""
echo "Önce yeni bir terminalden bağlantıyı test et:"
echo "  ssh -p $SSH_PORT $NEW_USER@SUNUCU_IP"
echo ""
echo "Sonra sudo test et:"
echo "  sudo whoami"
echo ""
echo "sudo whoami komutu root yazıyorsa her şey tamamdır."
echo ""