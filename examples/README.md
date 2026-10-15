# 文件格式的例子

这里的内容都是编的，只为了说明 `neoless-hub` 几个命令读的文件长什么样（命令见 [docs/hub.md](../docs/hub.md)）。

- `vocabulary.example.json`、`corrections.example.json`：`neoless-hub import-samples --vocabulary … --corrections …` 读的词表和纠正表。比如你想把别的听写软件里攒下的词和纠正搬过来，就整理成这两个文件。只读这里出现的字段，多出来的字段会被忽略。
  - 词表：`tier` 越小越重要，5 及以上不导入；同一档里按 `rank` 排。
  - 纠正表：`wrong` 可以写几个错写，用 `/` 隔开；只导入 `confidence` 是 `high` 的；`records` 是这条纠正发生的时间（可省略）。
- `polish-eval.example.json`：`neoless-hub eval --samples …` 读的逐字稿。`mode_hint` 是 `light`（自然整理）、`structured`（结构化）或 `raw`（原样转写，不调 ChatGPT）；`app` 是当时所在的应用，可以是 `null`。

真正有用的是你自己的词和你自己说过的话。那些文件里是你的隐私，放在仓库外面（或 `local/` 里），别提交。

*Made-up examples of the files `neoless-hub import-samples` and `neoless-hub eval` read. Your real word lists and transcripts are private: keep them out of the repository.*
