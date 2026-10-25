# Stillmint 品牌设计

日期：2026-10-24。任务：brand_design。design_agent；不修改产品Swift代码。

## 最终名称

- 设备/App内品牌：**Stillmint**，发音 STILL-mint（/ˈstɪl.mɪnt/）。
- 美国App Store展示名：**Stillmint: Photo Cleanup**（24字符）。
- 英文副标题：**Keep the photos that matter**（27字符，已用JavaScript实测；主控最终统一版）。早期“Review first. Keep what matters”31字符已撤回；中间“See clearly. Keep what matters”30字符方案也被此最终版替代，禁止混用。
- 品牌主张：先看清，再决定；清掉多余，不把回忆当垃圾。Still指静态照片/从容，mint指整理后的清爽而非速度承诺。品牌不暗示自动安全删除、零误判或所有恢复均可靠。
- 不把Lifetime写入品牌名；一次性付费是商业规则，不需要靠品牌承诺掩盖尚未验收的交易路径。

## 公开重名初查（不是法律清查）

2026-10-24查询美国App Store公开索引/Apple iTunes软件搜索与网页精确词；没有App Store Connect名称占用数据库、USPTO全面商标检索、域名购买或商标法律意见。无检索命中不代表可注册或可上架。

| 候选 | 观察与决定 |
|---|---|
| FrameSift | [美国App Store同名照片审阅App](https://apps.apple.com/us/app/framesift/id6807047431)，同类别，淘汰。 |
| Stillwise | [美国App Store已有同名App](https://apps.apple.com/us/app/stillwise-mindful-drinking/id6790764020)，淘汰。 |
| Framewell | [摄影交付平台](https://framewell.app/)、[照片印刷业务](https://tryframewell.com/)，相关领域占用，淘汰。 |
| Framekind | [软件工作室](https://frame-kind.com/)等明显同名，淘汰。 |
| Stillmint（选定） | Apple美国software查询未发现精确同名清理App：返回1项无关Still River Wellness；网页精确词有下述同名他类使用，故仅“初查未见明显同类冲突”，不是全球唯一。 |

Apple查询入口：[US software search](https://itunes.apple.com/search?term=Stillmint&country=us&entity=software&limit=30)。搜索结果为模糊匹配，不能把resultCount=1误写成同名App存在。

同名风险透明记录：[Apple Music的Stillmint艺名](https://music.apple.com/us/album/thi%C3%AAn-h%C3%A0-th%E1%BB%A7y-b%C3%ADnh-ng%E1%BB%8D-bling-single/1879822394)、[Steam游戏开发者stillmint昵称](https://store.steampowered.com/app/3582850/)、[澳大利亚已注销ABN实体STILLMINT](https://abr.business.gov.au/ABN/View?abn=19070130817)。本次不是商标许可判断；正式上架前仍需实际ASC名称预检与适当商标/域名核查。选定Stillmint是此范围内的设计决定，不声称无任何权利冲突。

## 视觉方向与取舍

单一记忆点：**照片右上角的薄荷色保留书签**。相框/山丘/太阳让用户读成照片；书签表示“我选择留住”，强调主动判断。微微倾斜的照片比严肃数据库/保险箱更亲近，但不用扫帚、垃圾桶、火箭、通用渐变盾牌、对勾或AI闪光。

| Token | 色值 | 用途 |
|---|---|---|
| Deep tide | #152F3B | 深海蓝满版底色，稳定而不警报化 |
| Porcelain | #F4F7EF | 照片边框 |
| Mint keep | #66D6AD | 保留书签、品牌识别色 |
| Deep teal | #247F79 | 前景山丘 |
| Pale mint | #B6E4CC | 后景山丘 |

色值是生成brief目标，不保证栅格每个像素严格等值；生成图有细微材质/光影，非单色矢量。没有将界面全App颜色一并改动。App正文与操作仍用原生系统字体，品牌标识不用图片内文字，避免小尺寸不可读和伪字体。

视觉自检：原图和归一化1024图均实际view；另导出60px真缩略图实际view。相框与书签轮廓仍清楚；无拼写、水印、照片私有内容；深底满版至四角、没有预先做iOS外圆角，没有白色外围padding。内部照片框允许圆角，与图标画布预裁圆角不同。没有引用竞品图片或作为风格参考输入。

## 资源与生成

- 交付PNG：`docs/branding/stillmint-appicon-v1-2026-10-24.png`（仓库根相对路径）。
- 原始生成master：同目录`stillmint-appicon-master-v1-2026-10-24.png`。
- 60px检查件：同目录`stillmint-appicon-preview-60-v1.png`（只用于QA，不作为AppIcon输入）。
- 原始内置工具输出已归档为上述master；本仓库不包含本机工具缓存或个人目录路径。
- 工具：内置image_gen，generate新原创位图，transparent_background=false；未用CLI/API fallback，未索要API key。
- 原始工具图1254×1254，使用macOS sips仅机械缩放归一化为1024×1024；sips检测pixelWidth=1024、pixelHeight=1024、hasAlpha=no。旧图标未被设计Agent覆盖；集成所有者用新版本文件接入asset。
- 已使用imagegen SKILL与完整prompting指导，以及frontend-design的单一signature/去冗余原则：不将“安全”简单画成泛用盾牌，不把商业收费塞入图标。

## 完整生成Prompt

```text
Use case: logo-brand. Asset type: final iPhone App Store app icon, one 1024x1024 opaque square artwork, full bleed flat background. Brand: Stillmint, a careful photo and video library review app: see clearly, keep what matters. Create an original, confident, exceptionally legible miniature emblem, no text. Deep midnight ink navy background #152F3B extending exactly to all four square edges. Center one large warm porcelain photo frame #F4F7EF, a landscape-oriented soft square rectangle tilted about 5 degrees counterclockwise, with a thick crisp border and a very simple abstract two-plane landscape inside: one deep teal hill and one pale mint hill, a single small pale sun. The distinctive signature: a mint-green #66D6AD folded bookmark tab descends from the top right edge of the photograph, with a sharp swallowtail notch, integrated into the photo frame; this represents a photo deliberately kept, not a security shield. The tab is bold enough to survive at 60 pixels. Flat precise modern cut-paper geometry with at most a subtle tiny offset shadow for separation, not a photoreal object, not an illustration scene. Composition: emblem occupies about 72 percent of canvas, generous consistent space, single coherent silhouette, visually balanced. No checkmark, no shield, no broom, no rocket, no trash bin, no camera lens, no sparkle, no generic gradients, no lettering, no watermark. No outer rounded-square icon container, no pre-rounded canvas corners, no white outer padding, no mockup, no phone, no multiple variants. Deliver only the finished square app icon.
```

## 工程交接与边界

商业/工程Agent已收到名称及绝对路径；仅替换对外展示品牌和AppIcon资源引用，保留旧资源，不重命名Swift module、bundle ID、Keychain服务名、IAP product ID或用户持久化路径。设计交付不等于签名上架：StoreKit未通过的购买/恢复/退款验证不因改品牌消除。
