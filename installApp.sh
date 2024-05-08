#update repo and upgrade apps
apt update -y && apt upgrade -y

#install common utilities
apt install zsh tmux htop glances curl python-is-python3 p7zip-full -y

#change default shell to zsh
chsh -s $(which zsh)