
### 🚀 linux自动化安装

支持 `amd` 和 `arm` 架构，支持 `docker` 环境，程序运行目录为 `/root/nodetool`，安装完成后可使用 `nt` 命令打开快捷面板。

```bash
curl -fsSL https://raw.githubusercontent.com/sauciness666/node-tool/main/install.sh -o install.sh && chmod +x install.sh && ./install.sh
```
---

###  🚀 Docker化安装

- 注意不能直接使用   `本地文件夹:/app`  这种映射方式
- 必须一对一映射文件或文件夹
- 文件：`db_config.json` ， `app.db`
- 文件夹：`nodes` 

使用 `docker` 安装必须提前创建好文件或文件夹，可使用下面代码快速创建，将工作在 `/root/nodetool_data`
```bash 
mkdir -p /root/nodetool_data/nodes && touch /root/nodetool_data/{db_config.json,app.db}
```

```bash
docker run -d \
  --name nodetool \
  --restart always \
  -p 5000:5000 \
  -v /root/nodetool_data/db_config.json:/app/db_config.json \
  -v /root/nodetool_data/app.db:/app/app.db \
  -v /root/nodetool_data/nodes:/app/nodes \
  ghcr.io/hobin66/node-tool:latest
```

使用 docker-compose.yml (推荐)

```bash
version: '3.8'
services:
  nodetool:
    image: ghcr.io/hobin66/node-tool:latest
    container_name: nodetool
    restart: always
    ports:
      - "5000:5000"
    volumes:
      - ./data/db_config.json:/app/db_config.json
      - ./data/app.db:/app/app.db
      - ./data/nodes:/app/nodes
    environment:
      - TZ=Asia/Shanghai
```

---

### 🖥️ 访问应用

安装并启动成功后，请访问以下地址查看运行效果：

  * **访问地址：** `http://localhost:5000`

---

## ✨ 主要功能 (Features)

* **可视化**: 可视化的数据仪表盘，配合komari可实现节点流量消耗展示。
* **链接自动上报**: 内置的节点安装脚本支持主动上报到服务器，加入订阅列表。
* **Clash链式代理**: 无需复杂的中转设置，一键选择中转落地，完成修改只需更新订阅。
* **自定义规则列表**: 模板内置有mihomo官方分流规则，且添加直连和自定义代理节点分流规则。
* **部署简单**: 可直接二进制文件启动
* **多端支持**: 完美win、linux及多架构。
* **支持docker容器**: 甚至能在NAT小鸡运行哦
* **Docker**: 支持docker安装

---

## 🛠️ 技术栈 (Tech Stack)

* **后端**: Python (Flask)
* **前端**: HTML5
* **数据库**: SQLite / PostgreSQL

