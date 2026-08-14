# 拾响产品站

这是拾响的独立产品介绍与下载站。产品页面不需要 Node 或构建工具；可选的第一方访问统计使用 PHP 8.3 + SQLite，不需要常驻服务。

`guide/` 是与 Build 109 对应的完整使用说明，包含最新实机截图、局部特写、AI 搜索专章、系统兼容表、快捷键与故障排查。

## 本地预览

```bash
cd Website
python3 -m http.server 4173
```

浏览器打开 `http://127.0.0.1:4173/`。

## 接入正式域名与百度网盘

编辑 `site-config.js`：

```js
window.SHIXIANG_SITE = {
  productUrl: "https://shixiang.jack-sun.com",
  githubUrl: "https://github.com/sunqinji666-dotcom/Shixiang",
  baiduPanUrl: "https://pan.baidu.com/s/1f4qAICdwC1CJRkeNijwdqw?pwd=jack",
  baiduPanCode: "jack",
  downloadLabel: "百度网盘下载拾响 1.0"
};
```

如果百度网盘链接不需要提取码，将 `baiduPanCode` 保持为空字符串。

## 内容边界

- `app-*.png` 是拾响真实运行界面，用于证明功能。
- `concept-*.png` 是概念示意，用于表达产品理念，页面中已明确标注。
- App 安装包本身不内置音效；同一网盘另行赠送作者多年积累、筛选和整理的 5 万+ 附加音效库，来源包括公开互联网资源与作者自行购买素材，具体使用授权以附加包内说明为准。用户也可以直接导入自己的音效文件夹。
- 当前系统要求为 Apple Silicon Mac 与 macOS 14.0 或更高版本；本地 AI 自然语言搜索需要 macOS 26.2 或更高版本。

## GitHub 源码入口

顶部导航与页脚的 GitHub 入口指向公开仓库：

`https://github.com/sunqinji666-dotcom/Shixiang`

## SEO 专题页

- `mac-sound-effect-manager/`：Mac 音效管理软件
- `local-ai-sound-search/`：本地 AI 音效搜索
- `final-cut-pro-workflow/`：Final Cut Pro 音效工作流
- `sound-library-management/`：大型音效库整理
- `free-sound-library/`：附加音效库与授权说明
- `privacy/`：官网访问统计隐私说明

所有公开页面都使用独立标题、描述、Canonical、结构化数据与内部链接；新增页面必须同步更新 `sitemap.xml`。

## 第一方访问统计

- 浏览器脚本：`analytics/track.js`
- 公共写入接口：`analytics/collect.php`，只接受同源 POST
- 私有读取接口：`analytics/admin-api.php`
- 可视化后台：`analytics/admin/`
- 数据库默认位于站点根目录外：`/www/wwwroot/shixiang.jack-sun.com-data/analytics.sqlite`

统计记录匿名访客 ID、访问页面、活跃秒数、来源、设备环境和网络 IP。它不采集姓名、账号或 App 内声音数据，尊重浏览器 Do Not Track，原始会话默认保留 180 天。后台与读取接口必须由 nginx `auth_basic` 保护，密码文件不得进入 Git。

## 部署

将 `Website/` 中的公开文件同步到 nginx 站点根目录。部署统计接口时还需要：

1. 确认 PHP 8.3 已启用 PDO SQLite。
2. 创建站外数据目录并授权 PHP-FPM 用户读写。
3. 在 nginx 中只允许执行 `collect.php` 与受认证保护的 `admin-api.php`，其他 PHP 一律返回 404。
4. 把后台认证文件保存在 `/www/secure/`，不要放进站点目录或仓库。
5. 部署前创建站点、数据目录和 nginx 配置回滚副本，执行实际 BT nginx 配置测试后再重载。
