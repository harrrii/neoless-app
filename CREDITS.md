# 致谢和出处

neoless 是照着几个现成的东西做的。这里写清楚学了谁的什么、到什么程度。

## Typeless

一个商业的语音输入产品，neoless 最初就是想做它的个人替代品。

- **整体的做法**：设备只录音，识别和整理在别处完成。neoless 把“别处”换成了自己的 Mac。
- **整理出来的样子**：说完的话不管有没有数“第一、第二”，都整理成分段、分条的文字。neoless 的提示词要的是这种效果。提示词本身的出处见下面“OpenLess”一节的最后一段。
- **录音浮层**：那个底部居中的小黑条（声波、× 和 ✓、识别和整理时的进度）的样子在精神上跟的是 Typeless 和 OpenLess 的浮层。代码是用 SwiftUI 自己写的（`Sources/NeolessCore/Capsule.swift`、`Sources/neoless/HUD.swift`、`Sources/neoless/DesignSystem.swift`）。仓库里没有 Typeless 的源文件、图片或其它素材。

neoless 和 Typeless 没有任何关系，也没有得到它的授权或认可。如果你是 Typeless 的权利人，认为这里有不妥的地方，请提 issue。

## OpenLess

开源的语音输入应用（<https://github.com/Open-Less/openless>，2.0 起为 AGPL-3.0-only）。neoless 参考了它的这些做法：

- **热词块**：提示词里有一段固定的说明，告诉模型逐字稿来自语音识别、会有同音错字，用户自己的热词在同音/形近时优先于“原样保留”。这个思路来自 OpenLess 的 `build_hotword_block`。neoless 这一段的文字和例子是重写的，另外加了“自动学到的词不享有这个优先”的区分。
- **实时字幕条**：浮层上方那条向左淡出的字幕。浮层本身的样子在精神上也跟了它。
- **剪贴板**：连续几次粘贴之间只保留用户最初的剪贴板、只有剪贴板还是自己写的内容时才恢复。
- 几个行为：**⌘Q 只关窗口**；整个听写期间 Esc 归 neoless，不会同时作用到下面的应用。

neoless 是 Swift 写的，没有包含 OpenLess 的代码；但上面这些地方跟得很近，所以 neoless 采用和它相同的许可（AGPL-3.0-only）。

**提示词的骨架**：neoless 的提示词是从一份社区里流传的 OpenLess 风格包起步的（一份给别的固定场景写的整理指令）。那份风格包的许可不明，也不在 OpenLess 的仓库里，所以公开的版本里没有它的原句：每一句都用自己的话重写了，示例也都换成了自己编的。但重写的是句子，不是骨架。章节的先后（任务、底线、什么时候分条、调整顺序、分段、版式、清掉杂音、照原样保留、输出、示例）、每一节里规则的分法、示例各自要说明的那一点，还有几个具体的设定（一段超过 80 个汉字左右就考虑拆开、列表的几种版式），仍然跟着那份风格包。它针对自己那个场景写的两节，在同样的位置换成了 neoless 的“常见场合”和“名称、术语和数字”；neoless 另外加的是热词那一节、最后的补充规则，以及在真实听写上试出来的那些规则（见 [docs/DESIGN.md](docs/DESIGN.md) 第 5 节）。那份风格包的作者这里没有具名；如果你是作者，希望署名、修改或撤下，请提 issue。

## 用到的软件和模型

- **Qwen3-ASR**（阿里的语音识别模型，Apache-2.0）的 MLX 版：[mlx-community/Qwen3-ASR-0.6B-4bit](https://huggingface.co/mlx-community/Qwen3-ASR-0.6B-4bit)。
- **MLX**（<https://github.com/ml-explore/mlx>，MIT）和 **mlx-audio**（<https://github.com/Blaizzy/mlx-audio>，MIT）：在 Apple 芯片上跑这个模型。
- **Hummingbird**（<https://github.com/hummingbird-project/hummingbird>，Apache-2.0）和它依赖的 SwiftNIO 等：处理中心的 HTTP 服务。
- **aiohttp、numpy、scipy、huggingface_hub**：语音识别 worker。
- **cloudflared / Cloudflare Tunnel / Cloudflare Access**：把家里的 Mac 安全地放到公网上。
- **Apple 的 Speech 框架**：本机识别和实时字幕。
- **整理用的模型**：用你自己的 AI 模型账号登录（目前支持 ChatGPT 账号）。登录的流程跟的是模型提供方开源的命令行客户端，仓库里没有它的代码。neoless 是非官方的个人项目，和模型提供方没有关系；用哪家的账号，就受哪家的使用条款约束。

这些软件都不在这个仓库里，构建或部署时才下载，各自按自己的许可。完整的清单在 [NOTICE](NOTICE)。

## 谁写的

代码主要由 AI 编程助手（Claude Code）按作者的要求写成，靠单元测试和作者的日常使用来把关。

---

## Credits (English)

- **Typeless** (a commercial dictation product): the overall split (the device records, recognition and tidying happen elsewhere), the way tidied text reads (paragraphs and numbered items whether or not the speaker counted them), and the look of the recording capsule, which follows the floating bars of Typeless and OpenLess in spirit. The capsule's code was written for neoless in SwiftUI; no Typeless source files or assets are in this repository. neoless is not affiliated with or endorsed by Typeless.
- **OpenLess** (<https://github.com/Open-Less/openless>, AGPL-3.0-only since 2.0): the hot-word block that outranks "keep as said" for near-homophones, the live transcript rail, how the clipboard is restored, and a few behaviours. No OpenLess code is included, but neoless follows it closely in those places, which is why it uses the same licence. The prompt started from a community style pack for OpenLess whose licence is unclear (it is not part of the OpenLess repository). None of its sentences is in the published prompt and every example is made up, but only the sentences were rewritten: the order of the sections, how the rules are grouped in them, what each example is there to show, and a few settings (the 80-character paragraph threshold, the list layouts) still follow that pack; its two sections for its own use case were replaced in place by neoless's own. Its authors are not named here; if it is yours and you want credit, a change or removal, please open an issue.
- **Software and model**: Qwen3-ASR (MLX conversion by mlx-community), MLX, mlx-audio, Hummingbird and SwiftNIO, aiohttp, numpy, scipy, huggingface_hub, cloudflared, Apple's Speech framework. Tidying uses your own AI model account (a ChatGPT account today); the sign-in follows the flow of the provider's open-source command-line client, none of whose code is included. neoless is an unofficial personal project, and using a provider's account is subject to that provider's terms.
- Most of the code was written by an AI coding assistant (Claude Code) at the author's direction.
