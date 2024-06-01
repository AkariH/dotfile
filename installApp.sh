#add raw.githubusercontent.com to hosts
echo "185.199.108.133 raw.githubusercontent.com" >> /etc/hosts

#update repo and upgrade apps
apt update -y && apt upgrade -y

#install common utilities
apt install zsh tmux htop glances curl python-is-python3 p7zip-full ncdu -y

#change default shell to zsh
chsh -s $(which zsh)