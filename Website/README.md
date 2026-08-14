# 拾响产品站

这是拾响的独立静态产品介绍与下载站。它不需要 Node、数据库或构建工具，可以直接部署到 nginx 静态目录。

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

## 部署

域名确定后，将 `Website/` 中的文件同步到对应 nginx 站点根目录。部署前应先在服务器创建回滚副本并验证 nginx 配置。
