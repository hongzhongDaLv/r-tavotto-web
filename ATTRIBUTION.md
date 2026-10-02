# 来源、版权与衍生改动

## 上游

- 项目：[Tavotto](https://github.com/Tavotto/Tavotto)
- 固定源提交：`13886a0b7ebf9073c31023a923833a74e7eebbe5`
- 源码许可证：**AGPL-3.0-only**，全文保留于根目录 `LICENSE`。
- Tavotto 名称和标志的说明保留于 `TRADEMARKS.md`。上游商标说明记载 Tavotto 标识由 Jiaqi Wan 持有；源码许可与商标政策是不同事项。
- 上游文件原有版权、作者与许可注释应随对应文件保留，不替换成衍生项目的单独声明。

R-Tavotto Web 是第三方衍生项目，不是 Tavotto 官方发行渠道。不声明官方授权、合作或认证；不以 Tavotto 官方 logo 作为衍生项目自己的身份标志。

## 复用部分

复用 Tavotto 的 React/TypeScript 画布、图元选择、对象树、检查器、撤销/重做、几何命中、共同 UI 控件及相关测试和规则文档。复用不意味着 Python/Matplotlib 的全部引擎能力已经在 R 版本实现。

## 衍生改动

- 2026-09：加入 R/ggplot2 与 grid 适配引擎、图元结构提取、交互修改重放和 R 代码导出。源码为 `r-adapter/engine.R` 与 `r-adapter/visual-properties.R`。
- 2026-09：为 R 对象、绘图属性和独立画布/图框几何增加适配；这些改动保留在相应源文件及测试中。
- 2026-10：建立独立浏览器发布目录，增加 WebR 执行驱动、浏览器文件导入、网页构建入口与 GitHub Pages 分支发布流程。保留本机版本的原始工作目录，网页版本不依赖其 localhost 服务。
- 根目录发布脚本、隐私说明和回滚文档属于衍生项目的发布工程改动。

衍生源码继续按 AGPL-3.0-only 发布。实际发行的对应源码应与网站 `build-info.json` 的提交一致；发布时在网站提供对应仓库/提交入口，不仅提供打包后的 JavaScript。

## 运行时与其他依赖

[WebR](https://github.com/r-wasm/webr) 及通过 WebR 提供的 R 包保持各自许可证。它们的下载入口、版本和字体配置以浏览器运行时源码为准。复用的 npm 包和其他第三方资源也保持各自许可证；本项目的 AGPL 声明不替换第三方版权通知。
