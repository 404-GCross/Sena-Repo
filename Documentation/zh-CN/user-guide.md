# 快速开始
Sena-Repo 的使用思路是：服务端只需要部署以及文件挂载，剩下的设置以及使用统统交给客户端。
## 服务端部署
### 选择你的游戏库与steam补丁目录的来源
在服务端部署前先确定你的游戏库文件来源，Sena-Repo支持常规文件目录挂载以及openlist挂载。<br>
如果您是使用常规文件目录，请将对应游戏库目录映射至docker容器的/games目录，steam补丁映射至/steam_patch目录<br>
范例：
```
sudo docker pull 404gcross/sena-repo:latest
sudo docker run -d \
  --name sena-repo \
  -p 11451:11451 \
  -v /root/docker/Sena-Repo/data:/data \
  -v /mnt/openlist/115/Games/GalGame/Library:/games \
  -v /mnt/openlist/115/Games/GalGame/Steam_Patch:/steam_patch \
  404gcross/sena-repo:latest
```
