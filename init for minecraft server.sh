
# app downloads
VELOCITY_URL=https://api.papermc.io/v2/projects/velocity/versions/3.3.0-SNAPSHOT/builds/371/downloads/velocity-3.3.0-SNAPSHOT-371.jar
PAPERMC_URL=https://api.papermc.io/v2/projects/paper/versions/1.20.4/builds/463/downloads/paper-1.20.4-463.jar

#update repo and upgrade apps
apt update -y && apt upgrade -y

#install common utilities
apt install zsh tmux htop glances curl python-is-python3 -y

#change default shell to zsh
chsh -s $(which zsh)

#install openjdk-17
apt install openjdk-17-jdk -y


mkdir -p ~/app/minecraft/velocity
cd ~/app/minecraft/velocity
curl -LO $VELOCITY_URL

cat << EOF >> start.sh
#!/bin/bash

java -Xmx1024M -Xms1024M -XX:+AlwaysPreTouch -XX:+ParallelRefProcEnabled -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:G1HeapRegionSize=4M -XX:MaxInlineLevel=15 -jar velocity.jar 
EOF

chmod +x ./start.sh


mkdir -p ~/app/minecraft/papermc
cd ~/app/minecraft/papermc
curl -LO $PAPERMC_URL

cat << EOF >> start.sh
#!/bin/bash

java -Xmx2048M -Xms2048M -XX:+AlwaysPreTouch -XX:+DisableExplicitGC -XX:+ParallelRefProcEnabled -XX:+PerfDisableSharedMem -XX:+UnlockExperimentalVMOptions -XX:+UseG1GC -XX:G1HeapRegionSize=8M -XX:G1HeapWastePercent=5 -XX:G1MaxNewSizePercent=40 -XX:G1MixedGCCountTarget=4 -XX:G1MixedGCLiveThresholdPercent=90 -XX:G1NewSizePercent=30 -XX:G1RSetUpdatingPauseTimePercent=5 -XX:G1ReservePercent=20 -XX:InitiatingHeapOccupancyPercent=15 -XX:MaxGCPauseMillis=200 -XX:MaxTenuringThreshold=1 -XX:SurvivorRatio=32 -Dusing.aikars.flags=https://mcflags.emc.gs -Daikars.new.flags=true -jar papermc.jar --nogui
EOF

chmod +x ./start.sh

echo "eula=true" >> eula.txt