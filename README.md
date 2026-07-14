<div align="center">

<img src="client/assets/icon.png" width="96" alt="Sena Repo" />

# Sena Repo

![Release](https://img.shields.io/github/v/release/404-GCross/Sena-Repo)
![Downloads](https://img.shields.io/github/downloads/404-GCross/Sena-Repo/total)
![License](https://img.shields.io/github/license/404-GCross/Sena-Repo)
![Platform](https://img.shields.io/badge/platform-Windows%20%7C%20Android%20%7C%20Linux-blue)

项目名称中的**Sena**来源于游戏[想要传达给你的爱恋](https://mzh.moegirl.org.cn/%E6%83%B3%E8%A6%81%E4%BC%A0%E8%BE%BE%E7%BB%99%E4%BD%A0%E7%9A%84%E7%88%B1%E6%81%8B)中的女主角[姬野星奏](https://mzh.moegirl.org.cn/%E5%A7%AC%E9%87%8E%E6%98%9F%E5%A5%8F)

</div>

---
## 简介
**Sena Repo** 是一款面向多平台的视觉小说私有库管理器，适合管理部署在远程服务器（如 NAS）上的游戏，让使用者能方便地浏览、搜索、下载与安装自己的游戏收藏。

服务端（Docker / Python）负责扫描目录、清洗文件名、刮削元数据<br>客户端（Windows / Android / Linux）通过 HTTP/HTTPS 连接服务端，提供一体化的游戏库浏览和下载安装体验。

Sena-Repo并非本地游戏管理器，而更像是由您自己完全掌控的站点

## 主要功能

- 🖼️ **更直接美观的资源库** — 扫描刮削分类您的视觉小说游戏文件，并在客户端排列显示
- 🌐 **方便的下载安装** — 客户端能自动下载并解压到指定目录，并提供导入为steam第三方游戏与生成快捷方式的功能
- 🎮**Steam补丁注入** — 扫描刮削匹配补丁文件，为您在steam上购买的视觉小说游戏注入补丁


---

## 截图

<table align="center">
  <tr valign="top">
    <td align="center" width="50%">
      <b>游戏库</b><br>
      <i>网格 / 列表双视图，按会社、标签、平台筛选</i><br>
      <img src="Documentation/gallery/library.png" width="95%">
    </td>
    <td align="center" width="50%">
      <b>游戏详情页</b><br>
      <i>封面、背景、简介、标签、版本列表与下载</i><br>
      <img src="Documentation/gallery/detail-1.png" width="95%">
    </td>
  </tr>
  <tr valign="top">
    <td align="center" width="50%">
      <b>Steam 补丁管理</b><br>
      <i>客户端 / 服务端双 Tab，自动匹配与注入</i><br>
      <img src="Documentation/gallery/steam-patch.png" width="95%">
    </td>
    <td align="center" width="50%">
      <b>元数据编辑</b><br>
      <i>多源刮削结果逐字段对比勾选</i><br>
      <img src="Documentation/gallery/edit.png" width="95%">
    </td>
  </tr>
  <tr valign="top">
    <td align="center" width="50%">
      <b>我的</b><br>
      <i>个人信息、用户管理与设置</i><br>
      <img src="Documentation/gallery/profile.png" width="95%">
    </td>
    <td align="center" width="50%">
    </td>
  </tr>

  
</table>




---

## 快速开始

| 文档 | 说明 |
|------|------|
| **[服务端部署说明书](Documentation/zh-CN/server-guide.md)** | Docker 部署（GHCR / Tarball / 直接部署）、配置参考、游戏目录结构、Steam 补丁服务端配置 |
| **[客户端使用说明书](Documentation/zh-CN/client-guide.md)** | 安装（Windows / Android / Linux）、首次设置、游戏库浏览、下载解压、Steam 补丁注入操作 |

附加文档：[技术文档](Documentation/zh-CN/technical.md) · [疑难杂症](Documentation/zh-CN/troubleshooting.md)

---

## 贡献

欢迎任何形式的贡献！请查看 [CONTRIBUTING.md](./CONTRIBUTING.md) 了解如何开始。

---

## 特别鸣谢

本项目在开发过程中参考与学习了以下优秀开源项目（排名不分先后）：
- [7-zip](https://www.7-zip.org)
- [xm486/YukiHub](https://github.com/xm486/YukiHub)
- [INK666/myGal](https://github.com/INK666/myGal)
- [JosefNemec/Playnite](https://github.com/JosefNemec/Playnite)
- [huoshen80/ReinaManager](https://github.com/huoshen80/ReinaManager)
- [Saramanda9988/LunaBox](https://github.com/Saramanda9988/LunaBox)
- [bggRGjQaUbCoE/PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)
- [moraroy/NonSteamLaunchers-On-Steam-Deck](https://github.com/moraroy/NonSteamLaunchers-On-Steam-Deck)

感谢以上项目作者以及贡献者的付出。

---

## 免责声明

- 本项目为开源项目，仅用于合法用途，管理您有权使用的游戏/应用，如有侵权请告知。
- 您需要自行确认资源与第三方组件的合法性。
- 本项目不提供游戏本体、破解资源、绕过授权的能力或任何违规用途的支持。
- 本项目由 AI 辅助开发，安全性未经审计，服务端部署至公网前请自行加固。
- 本项目在后续更新中可能涉及服务端变动，可能存在无法保留数据更新的可能。


## 开源协议

本项目采用 **GNU Affero General Public License v3.0 (AGPL-3.0)**。

**你可以：**
- 自由使用、复制、修改、分发本项目
- 将本项目用于商业或非商业用途
- 将修改后的版本作为网络服务运行

**你需要：**
- 分发或公开部署修改后的版本时，开源你的修改
- 即使只通过网络提供服务（不分发二进制），也要提供源代码
- 保留原始版权声明和许可声明
- 使用相同的 AGPL-3.0 许可证

**简单来说：** 自己用随便改；如果把修改版给别人用或部署成公共服务，代码也要开源。
