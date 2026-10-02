# R-Tavotto Web 发布汇总 · 2026-10-03

本报告区分实现、模块验证、浏览器验收和公网发布。功能测试使用人工数据；用户的真实科研文件不随公开源码或网站发布。

## 产品和本次交付

这是 Tavotto 的非官方 R/ggplot2 衍生编辑器。使用浏览器的文件选择器导入脚本与数据，由 WebR 在浏览器运行 R；在画布上选对象、调整属性，得到图形和可重放的 R 修改代码。导入文件不提交到 GitHub，也不依赖另起本机 R/Node 服务。

本轮在独立发布目录开发，保留原本机项目作为回滚参照；土样、财务和科研数据库没有被改写。

| 交付项 | 当前状态 |
| --- | --- |
| GitHub 源码地址 | [hongzhongDaLv/r-tavotto-web](https://github.com/hongzhongDaLv/r-tavotto-web)；main 保存源码 |
| 公网网站地址 | [打开 R-Tavotto Web](https://hongzhongdalv.github.io/r-tavotto-web/)；实际 HTTP 200，公网浏览器流程通过 |
| 发布源提交 | [`a298a7e7d3cc3634055404465043c7207865f22d`](https://github.com/hongzhongDaLv/r-tavotto-web/commit/a298a7e7d3cc3634055404465043c7207865f22d) |
| 静态产物提交 | gh-pages [`2cd734eae39d8b2bdfa10936311482fdb81792b7`](https://github.com/hongzhongDaLv/r-tavotto-web/commit/2cd734eae39d8b2bdfa10936311482fdb81792b7) |
| 已推送回滚标签 | [源码 web-v0.1.0](https://github.com/hongzhongDaLv/r-tavotto-web/tree/web-v0.1.0)、[网站 pages-v0.1.0](https://github.com/hongzhongDaLv/r-tavotto-web/tree/pages-v0.1.0)，分别指向上面两个已验证提交 |
| 公网来源核对 | [build-info.json](https://hongzhongdalv.github.io/r-tavotto-web/build-info.json) 的 `revision` 为上述 `a298a7…` 源提交 |
| Pages 系统部署 | [Pages build and deployment / 37042783021](https://github.com/hongzhongDaLv/r-tavotto-web/actions/runs/37042783021)：completed / success；部署 ID `6814586634` |
| Pages 构建时间 | 2026-10-03 01:45:04 北京时间（2026-10-02T17:45:04Z） |
| 发布方式 | Pages 使用 gh-pages 分支的 `/ (root)`；本次不运行自定义 Actions 工作流 |
| Node / pnpm | 固定为 24.19.0 / 11.19.0 |
| 浏览器 R | WebR 0.6.0，PostMessage Worker 通道 |
| 源码许可证 | AGPL-3.0-only；上游版权和商标说明保留 |

## 功能模块

| 模块 | 源码入口 | 用途 |
| --- | --- | --- |
| 导入与应用入口 | `web/src/r/browser.tsx`、`browserFiles.ts` | 用户主动选择脚本、依赖文件、项目文件夹或已保存项目；选择入口脚本及图对象；展示运行和错误状态 |
| 浏览器 R 驱动 | `web/src/r/browserRuntime.ts` | 初始化 WebR、准备可用 R 包、建立虚拟工作区、执行脚本、传回权威图形结构；停止运行时终止 Worker |
| R 绘图引擎 | `r-adapter/engine.R`、`visual-properties.R` | ggplot/grid 结构提取、真实图元与命中几何、原生参数修改、页面和图框布局、图形及 R 代码导出 |
| Tavotto 交互复用 | `web/src/canvas/`、`components/left/ElementTree.tsx`、`components/inspector/` | 对象树、图上点选、属性检查器、拖动、CAD 框选/窗交；使用共同文档和修改记录 |
| 保存与恢复 | `browserRuntime.ts`、`browserFiles.ts` | 下载包含已选脚本/数据/修改和文件哈希的项目；当前浏览器 IndexedDB 保存最近一个项目 |
| 发布工程 | `scripts/`、`docs/templates/pages.yml` | 本次本机受检查构建，main 对应源码、gh-pages 对应静态产物；Actions 文件仅为未来可选模板 |

复制保留的上游架构文档用于追溯其交互与系统约束。它们不能作为本浏览器版已实现 Python 引擎、桌面壳、Codex MCP 或完整出版预检的证明。

## 画布与图框契约

1. **画布**是白色方格输出页面。初始大小取自目标图在 R 脚本中实际使用的导出设备/`ggsave()` 参数；没有尺寸或存在多个冲突尺寸时，要求用户明确选择，避免猜预设值。
2. **图框**是坐标轴围出的数据绘图区，初始布局来自实际 R 渲染测量。编辑器位置/尺寸统一 px；R 原生字号、点径和线宽保留代码原有单位。
3. 调整画布仅改变页面边界；调整图框改变数据绘图区宽高。后者携带相关图元的位置，文字字号、点径和线宽不按比例放大。
4. 图框可以移出白纸；编辑视图允许查看并选择页面外图元。PNG/PDF 的有限输出页面仍会裁到页面边界，不能把编辑视图的无限灰区当作导出范围。
5. 图框和画布没有第三套用户尺寸。视口缩放只是看图比例，不写入 R 图的物理大小。

## 选择与修改契约

画布选择使用真实图元的墨迹路径，检查器只显示当前对象适用属性。仅在确实生成可独立编辑子对象后，才禁用父图层在画布上的选择；父图层仍可在左侧树中选择。不能安全拆分的图层维持图层级选择，不能伪造逐点编辑能力。

灰区、白纸和图内空白共用框选链路：左→右只选全包含对象；右→左选真实几何相交对象；Shift 加选。框选不更改文档、历史或 R 渲染结果。图框/页面等容器不混入叶子对象选区。

修改保存在覆盖记录中，原始脚本保持不变。“查看 R 代码”和下载图形使用同一修改记录；项目文件保存选定原始文件及修改。单独下载修改代码时，用户仍需保留相应源脚本、数据与依赖。

## 已取得的工程证据

| 验证 | 判据和结果 | 边界 |
| --- | --- | --- |
| 锁文件 | 将 web 的 manifest/lock/workspace 复制到隔离临时目录，运行 pnpm 11.19.0 `install --lockfile-only --frozen-lockfile --ignore-scripts --offline`，退出码 0 | 未触碰既有 `node_modules` Junction；证明 manifest 与锁相容，不等于已在 GitHub runner 安装依赖 |
| 公开源码边界 | `scripts/check-public-source.mjs` 检查候选 Git 文件列表，通过；新生成的浏览器/原生验证截图、报告、输出全部排除 | 防线按明确路径和扩展名检查；仍需人工审核新增内容 |
| 公开包失败反例 | 清洁包通过；私有数据文件、已知本机路径、绝对 localhost 后端地址、历史文档截图被实际检查器拒绝；本机生成验证证据路径也被拒绝 | 检查的是实际静态发布目录，不能代替功能验收 |
| 原生 R 图元选择 | 真实 R 4.5.2 / ggplot2 4.0.2 的 10 类 fixture：普通 point/col/line/vline/errorbar、分组对象及不可安全拆分误差棒，通过 | 人工数据的图元提取/选择测试；不是 WebR 完整入口测试 |
| 真实浏览器 CAD | 真鼠标测试：灰区 LTR、灰区 RTL、白纸外选择、误差棒路径、斜线 bbox 空白角拒绝、页面外文字单击，通过 | 使用产品真实 CanvasStage 和权威测试 manifest；不启动 WebR |
| 选择副作用 | 框选前后文档逐字相同、历史长度 0、未选 carrier；SVG overflow 可见，通过 | 对应人工 CAD fixture |
| WebR 运行与独立 R 重放 | 实际 WebR 测试及独立 Rscript 重放通过；保留图元结构、修改和导出链路 | 使用人工 fixture，不能推广为所有 R 包或科研脚本均兼容 |
| 全浏览器入口与导出 | 公网入口打开示例、调整页面/图框、保存项目、重开、查看 R 代码和 SVG/PDF/PNG 导出通过 | 使用下表的具体尺寸和人工示例；不是任意参数的完整覆盖证明 |
| 真实文件选择与依赖导入 | 公网真实 filechooser 一次选择 `upload.R` 与 `data.csv`，通过相对路径 `read.csv()` 运行；项目保存原始文件字节和 SHA 一致 | 测试的是用户明确选择的两份人工文件，未查询本机目录 |
| 存储失败兜底 | 模拟 IndexedDB `QuotaExceeded` 后仍下载完整项目，通过 | 自动恢复可能不可用，正式存档仍使用下载文件 |
| 分支发布与公网 | main 源码、gh-pages 静态产物和 Pages 系统分支部署完成；公网 HTTP 200 及核心流程通过 | 系统 Pages 部署成功不等于自定义 Actions CI 已运行；本次未安装后者 |

## 模块数值与公网流程验收

公网测试使用真实部署地址，未以 localhost 站点冒充在线结果。几何值按编辑器 96 px/in 的换算显示；下表的图框值保留一位小数。

| 操作 / 模块 | 实际结果 | 判定 |
| --- | --- | --- |
| 示例初次打开：画布 | 白色方格页面 `900 × 600 px`，取自源脚本的 `ggsave()` | PASS |
| 示例初次打开：图框 | `x=80.9, y=81.2, w=787.3, h=426.2 px` | PASS；与原生 R 尺寸验证一致 |
| 仅改画布 | 页面改为 `1000 × 700 px`；图框仍为 `80.9 / 81.2 / 787.3 / 426.2 px` | PASS；页面尺寸不拉伸图框 |
| 仅改图框宽度 | 图框宽改为 `727 px`，画布保持 `1000 × 700 px` | PASS；两类尺寸独立 |
| 项目下载与重开 | 便携项目重开后仍为上述修改后的画布与图框尺寸 | PASS |
| SVG / PDF 页面 | 页面为 `750 × 525 pt`，对应 `1000 × 700 px`（96 px/in、72 pt/in） | PASS |
| PNG 导出 | `6250 × 4375` 像素，600 dpi；对应同一物理页面 | PASS；PNG 分辨率不改变编辑器图框尺寸 |
| 上传人工脚本与 CSV | 真实 filechooser 选择 `upload.R + data.csv`；基础 `read.csv()` 相对读取；白纸 `480 × 320 px` | PASS |
| 上传文件重放代码 | R 修改代码正确引用源脚本；便携项目保留所选文件的原始字节和 SHA | PASS |
| 空文件选择结果 | 空 `FileList` 不进入卡住的加载状态 | PASS；原生系统文件对话框 Cancel 尚未实测 |
| IndexedDB 配额错误 | 自动保存失败时仍能下载完整项目 | PASS |
| 公网浏览器健康 | 零页面错误、零失败请求 | PASS |
| 公网文件与网络边界 | 测试期间无 POST、API、本机 localhost 或产品遥测请求；仅加载网站、运行时和依赖资源 | PASS；不承诺用户任意联网 R 脚本也无网络请求 |

可重跑的测试源码：[公网编辑/尺寸/导出](../tests/browser-ui-smoke.mjs)、[公网真实文件导入](../tests/browser-upload-smoke.mjs)、[CAD 选择](../tests/browser-cad-smoke.mjs)、[WebR 引擎](../r-adapter/browser-smoke.mjs)、[原生 R 图元选择](../tests/verify-native-selection.R)。对应运行结果和截图保留在本机被忽略目录，未提交为公开附件。

本机生成证据保留在被忽略的验证目录。公开仓库保留测试脚本和人工 fixture，使测试可以重跑，不附带真实科研图或本机路径截图。

## 当前兼容边界

本次优先单个笛卡尔坐标 ggplot2 绘图区；多个候选 ggplot 对象可以选目标。复杂分面、patchwork/cowplot 拼图、任意第三方 geom 和任意 R 包并未获得全覆盖验收，不宣称“所有 R 代码参数均已交互化”。WebR 依赖 WebAssembly 包构建，电脑的 Windows R 包/DLL 不能直接使用。

统计模型、数据过滤和显著性计算仍由用户脚本负责。软件的图形和重放测试不证明科研数据或统计结论正确。字体和图形设备与本机 R 可能不同，具体论文图需逐一核对。

当前没有取得完整验收的内容：

- 任意 ggplot 参数逐条交互覆盖、所有第三方 geom 和每个数据点的独立编辑。
- 复杂 facet、patchwork/cowplot 多面板组合、base R、plotly、Shiny 和 R Markdown 全流程。
- 任意 R 包安装与 Windows DLL；脚本里的本机绝对路径和未选择文件无法自动读取。
- 原生系统文件选择对话框 Cancel、各浏览器/移动端和私有模式的完整兼容矩阵；空 FileList 与 IndexedDB 配额失败已经单独测试。
- 用户真实 PSR/野火等项目的全部脚本、数据与包组合；本次公网证据使用人工 fixture，不把单例通过扩大为真实项目全覆盖。
- 桌面打包、Codex MCP 深度集成、云端 Agent 服务和上游完整出版预检。这些不是本次网页发行的已完成模块。

## 保存、隐私和回滚

IndexedDB 自动保存只保留最近一个项目。清理站点数据、隐私模式和配额限制会影响恢复；请下载项目作为正式存档。已验证配额失败不会阻止下载项目。项目 JSON 含用户已选择的脚本和数据，分享它意味着分享这些文件。

站点没有文件上传服务器；运行时、R 包、字体和普通站点资源仍需网络请求，用户脚本自身也可能联网。浏览器入口没有初始化上游产品遥测。完整说明见 [WEB_PRIVACY.md](WEB_PRIVACY.md)。

发布前记录 main 源 SHA、gh-pages 产物 SHA 和 Pages 部署记录，验证通过后建立版本标记。网站回滚以 gh-pages 新提交恢复已验证静态产物，保留对应源 SHA；源码修正另在 main 完成并重新构建发布。回滚后做核心浏览器验收和公网版本核对；不强推、不删除用户科研文件。操作清单见 [RELEASE_AND_ROLLBACK.md](RELEASE_AND_ROLLBACK.md)。

## 本次交付状态

本次对应源码、受检查静态包、GitHub Pages 系统部署和上述公网核心流程均完成。后续功能扩展与兼容性工作按“当前兼容边界”逐项验收；本报告不宣称全部 R 参数、所有科研脚本、桌面版本或 Codex MCP 已完成。

回滚以本报告记录的源提交与 gh-pages 产物提交作为已验证基线；上述两个版本标签已推送成功，提交 SHA 也可独立精确追溯。
