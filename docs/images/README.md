# CertHub Logo Assets

这个目录包含 CertHub 项目的所有 LOGO 资源文件。

## 📁 文件列表

### 1. certhub-logo.svg
**主 LOGO** - 用于 README.md 头部展示

- **尺寸**: 600×200 px
- **用途**: GitHub 仓库主页、文档头部
- **特点**: 包含完整的品牌标识和作者信息

![CertHub Logo](certhub-logo.svg)

---

### 2. certhub-icon.svg
**图标版 LOGO** - 用于应用图标、Favicon

- **尺寸**: 256×256 px
- **用途**: 网站 Favicon、应用图标、Docker Hub 图标
- **特点**: 简化设计，适合小尺寸显示

![CertHub Icon](certhub-icon.svg)

---

### 3. certhub-banner.svg
**横幅版 LOGO** - 用于社交媒体分享

- **尺寸**: 1200×630 px
- **用途**: GitHub 社交媒体预览、Twitter/LinkedIn 分享
- **特点**: 渐变背景，完整品牌信息

![CertHub Banner](certhub-banner.svg)

---

## 🎨 设计说明

### 设计理念

CertHub LOGO 的设计融合了以下元素：

1. **六边形背景**
   - 象征稳固和安全
   - 代表蜂巢式的集中管理
   - 体现系统化和结构化

2. **证书文档图标**
   - 核心业务：SSL 证书管理
   - 白色背景代表信任和纯净
   - 蓝绿渐变线条代表技术和创新

3. **锁图标**
   - 安全性的直观表达
   - 橙红渐变代表警戒和保护
   - 与 Let's Encrypt 品牌色呼应

4. **循环箭头**
   - 代表自动化和持续更新
   - 绿色象征生命周期管理
   - 体现证书的自动续期功能

### 配色方案

| 颜色 | 十六进制 | 用途 | 象征 |
|------|---------|------|------|
| 蓝色 | `#2196F3` | 主色调 | 信任、技术、专业 |
| 绿色 | `#4CAF50` | 辅助色 | 安全、自动化、生命力 |
| 橙色 | `#FF9800` | 强调色 | 警戒、Let's Encrypt |
| 红色 | `#FF5722` | 强调色 | 保护、重要性 |
| 白色 | `#FFFFFF` | 背景色 | 纯净、信任 |

### 字体

- **主标题**: Arial Black（加粗）
- **副标题**: Arial（半粗）
- **作者信息**: Arial（常规/半粗）

---

## 📝 使用指南

### Markdown 中使用

#### 在 README.md 中使用主 LOGO
```markdown
![CertHub Logo](docs/images/certhub-logo.svg)
```

#### 在文档中使用图标
```markdown
![CertHub](docs/images/certhub-icon.svg)
```

#### 作为链接使用
```markdown
[![CertHub](docs/images/certhub-logo.svg)](https://github.com/huiyonghkw/CertHub)
```

### HTML 中使用

```html
<!-- 主 LOGO -->
<img src="docs/images/certhub-logo.svg" alt="CertHub Logo" width="600">

<!-- 图标 -->
<img src="docs/images/certhub-icon.svg" alt="CertHub" width="256">

<!-- 横幅 -->
<img src="docs/images/certhub-banner.svg" alt="CertHub Banner" width="1200">
```

### 作为 Favicon

将 `certhub-icon.svg` 转换为 PNG/ICO 格式：

```bash
# 使用 ImageMagick 转换
convert certhub-icon.svg -resize 32x32 favicon-32x32.png
convert certhub-icon.svg -resize 16x16 favicon-16x16.png
convert certhub-icon.svg -resize 256x256 favicon.ico
```

### Docker Hub

使用 `certhub-icon.svg` 作为 Docker Hub 仓库图标。

---

## 🔧 自定义和修改

所有 LOGO 文件都是 SVG 格式，可以使用以下工具编辑：

- **在线编辑器**: [Figma](https://figma.com), [Canva](https://canva.com)
- **专业软件**: Adobe Illustrator, Inkscape
- **代码编辑**: 任何文本编辑器（SVG 是 XML 格式）

### 修改颜色

在 SVG 文件中找到 `<linearGradient>` 定义，修改颜色值：

```xml
<linearGradient id="mainGradient">
  <stop offset="0%" style="stop-color:#YOUR_COLOR_1"/>
  <stop offset="100%" style="stop-color:#YOUR_COLOR_2"/>
</linearGradient>
```

---

## 📄 版权和使用条款

**CertHub™** 及其 LOGO 设计版权归属：

```
Copyright © 2025 会勇 (Huiyong Wang). All rights reserved.
Author: 会勇禾口王 (Huiyong Wang)
GitHub: @huiyonghkw
```

### 使用许可

- ✅ **允许**: 在遵循 MIT License 的前提下，用于项目宣传、文档、演示
- ✅ **允许**: 修改颜色和尺寸以适应不同场景
- ✅ **允许**: 在派生项目中使用（需保留版权声明）
- ⚠️ **限制**: 不得用于商业性质的商标注册
- ⚠️ **限制**: 不得移除或修改作者信息

### 商标声明

**CertHub™** 是会勇 (Huiyong Wang) 的商标。使用 LOGO 时请保留原始设计元素和版权信息。

---

## 🎯 品牌使用建议

### 正确使用 ✅

1. 保持 LOGO 的原始比例
2. 在纯色背景上使用
3. 保持足够的留白空间
4. 使用高清晰度的 SVG 格式

### 错误使用 ❌

1. 不要拉伸或压缩 LOGO
2. 不要改变 LOGO 的颜色方案（除非必要）
3. 不要在复杂背景上使用
4. 不要移除作者信息和版权声明

---

## 📞 联系方式

如有 LOGO 使用相关问题，请联系：

- **作者**: 会勇 (Huiyong Wang)
- **GitHub**: [@huiyonghkw](https://github.com/huiyonghkw)
- **项目**: [CertHub](https://github.com/huiyonghkw/CertHub)

---

<div align="center">

**CertHub™** - Enterprise SSL Certificate Automation Platform

Made with ❤️ by 会勇 (Huiyong Wang)

Copyright © 2025 Huiyong Wang. All rights reserved.

</div>
