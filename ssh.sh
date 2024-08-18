#!/bin/bash

echo "Chào mừng bạn đến với kho lữu trữ dạp của tôi"
if sudo grep -q "^PermitRootLogin yes$" /etc/ssh/sshd_config; then
  echo "SSH đăng nhập root đã được bật"
else
  echo "SSH đăng nhập root chưa được bật"
fi
read -p "Bạn có muốn bật SSH đăng nhập root không? (y/n)" choice
if [ ${choice} == y ] || [ ${choice} == Y ]; then
  if grep -qi "centos" /etc/*release; then
    sudo sed -i 's/#PermitRootLogin yes/PermitRootLogin yes/g' /etc/ssh/sshd_config
    sudo systemctl restart sshd.service
  elif grep -qi "ubuntu" /etc/*release; then
    sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config
    sudo systemctl restart ssh
  elif grep -qi "debian" /etc/*release; then
    sudo sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin yes/g' /etc/ssh/sshd_config
    sudo systemctl restart ssh
  else
    echo "Phân phối Linux không được hỗ trợ"
  fi
  sudo sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  sudo systemctl restart sshd.service
  echo "Vui lòng đặt mật khẩu cho người dùng root:"
  sudo passwd root
  sudo sed -i 's/PasswordAuthentication no/PasswordAuthentication yes/g' /etc/ssh/sshd_config
  sudo sed -i 's/PubkeyAuthentication yes/PubkeyAuthentication no/g' /etc/ssh/sshd_config
  sudo systemctl restart sshd.service

else
  echo "Đã hủy việc bật SSH đăng nhập root."
fi
