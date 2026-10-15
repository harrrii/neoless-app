import Foundation
import NeolessCloud
import NeolessCore

/// Runs one `neoless-hub` command. Returns the exit status.
@MainActor
public enum HubCommands {
    public static func main(_ arguments: [String]) async -> Int32 {
        let line: HubCommandLine
        do {
            line = try HubCommandLine.parse(arguments)
        } catch {
            printError((error as? LocalizedError)?.errorDescription ?? "\(error)")
            printError(HubCommandLine.usage)
            return 2
        }
        do {
            return try await run(line)
        } catch {
            printError((error as? LocalizedError)?.errorDescription ?? "\(error)")
            return 1
        }
    }

    public static func run(_ line: HubCommandLine) async throws -> Int32 {
        if line.command == .help {
            print(HubCommandLine.usage)
            return 0
        }
        // Needs no data folder.
        if case .eval(.printInstructions(let mode)) = line.command {
            print(PolishPrompt.staticInstructions(for: mode))
            return 0
        }
        let folder = try line.dataDirectory.map { try HubDataFolder.at(URL(fileURLWithPath: $0, isDirectory: true)) }
            ?? HubDataFolder.standard()
        switch line.command {
        case .help:
            return 0
        case .serve(let port):
            return try await serve(folder: folder, port: port, worker: line.workerURL ?? ASRWorker.defaultURL)
        case .pair(let name, let server, let qr):
            return try pair(folder: folder, name: name, server: try pairingServer(given: server, folder: folder), qr: qr)
        case .server(let address):
            return try server(address, folder: folder)
        case .devices:
            return devices(folder: folder)
        case .revoke(let name):
            let count = try DeviceRegistry(folder: folder).revoke(name: name)
            print(count > 1 ? "已移除 \(count) 台叫“\(name)”的设备" : "已移除“\(name)”，它的密钥已失效")
            return 0
        case .login:
            return await login(folder: folder)
        case .status(let port):
            return await status(folder: folder, port: port, worker: line.workerURL ?? ASRWorker.defaultURL)
        case .access(let action):
            return try access(action, folder: folder)
        case .importSamples(let files):
            return try await importSamples(files, folder: folder)
        case .eval(.run(let run)):
            return try await eval(run, folder: folder)
        case .eval(.printInstructions):
            return 0
        case .transcribe(let files, let json):
            return try await transcribe(files, json: json, folder: folder, worker: line.workerURL ?? ASRWorker.defaultURL)
        }
    }

    // MARK: serve

    static func serve(folder: HubDataFolder, port: Int, worker: URL) async throws -> Int32 {
        let secret = WorkerSecretSource(folder: folder.url)
        // Made now if missing, so the worker finds the same one whichever starts first.
        _ = try secret.value()
        let service = HubService(folder: folder, asr: ASRWorkerClient(baseURL: worker, secret: secret))
        // ASCII: pmset and Activity Monitor show other names as empty.
        let assertion = PowerAssertion(reason: "neoless-hub is serving dictation for the Mac and the iPhone")
        defer { assertion?.release() }
        if assertion == nil { HubLog.write("没能阻止闲置睡眠，Neo 闲置时可能会睡着") }
        let app = HubServer.application(service: service, port: port) {
            HubLog.write("neoless-hub \(HubService.version) 在 127.0.0.1:\(port) 等待请求（数据：\(folder.url.path)）")
        }
        var failure: Error?
        do {
            try await app.runService()
        } catch {
            failure = error
        }
        // A polish that timed out leaves its login refresh running: let it save the rotated token before exiting.
        await service.waitForRefresh()
        QuietRequests.shared.flush()
        if let failure { throw failure }
        HubLog.write("neoless-hub 已停止")
        return 0
    }

    // MARK: pair, devices

    /// Pairs a device: a new token for `name` (replacing an older one of the same name), in a link with the saved
    /// Cloudflare Access credentials when there are some (双重锁).
    static func makePairing(folder: HubDataFolder, name: String, server: URL) throws -> (pairing: HubPairing, replaced: Bool) {
        // Check the server, and that the Access credentials can be read, before a token is made and saved.
        _ = try HubPairing(server: server, token: HubToken.generate(), name: name)
        let access = try AccessCredentials(folder: folder).load()?.access
        let registry = DeviceRegistry(folder: folder)
        let (token, replaced) = try registry.pair(name: name)
        return (try HubPairing(server: server, token: token, name: name, access: access), replaced)
    }

    /// What the hub says when it has no address to put into a pairing link.
    static let noServer = "还不知道这台 Hub 对外的地址（Cloudflare 隧道的域名）。写一次就记住：neoless-hub pair --name <设备名> --server https://你的域名"

    /// The address a pairing link carries: `given` (`--server`), remembered in settings.json for the next time, or
    /// the remembered one. There is no default: the hub listens on 127.0.0.1 and cannot know its tunnel's hostname.
    static func pairingServer(given: URL?, folder: HubDataFolder) throws -> URL {
        let config = WatchedFile(store: folder.store, name: HubDataFolder.File.settings, fallback: HubConfig())
        guard let given else {
            guard let saved = config.value.server, let server = HubPairing.server(from: saved) else {
                throw HubSetupError(noServer)
            }
            return server
        }
        // Checked as a pairing checks it (https, or http for this Mac itself), and kept as a pairing keeps it.
        let server = try HubPairing(server: given, token: HubToken.generate(), name: "").server
        if config.value.server != server.absoluteString {
            var next = config.value
            next.server = server.absoluteString
            guard config.write(next) else { throw HubSetupError("没能保存设置（settings.json）") }
        }
        return server
    }

    /// `neoless-hub server [地址]`: remembers the hub's public address, or shows the remembered one.
    static func server(_ address: URL?, folder: HubDataFolder) throws -> Int32 {
        if let address {
            let server: URL
            do {
                server = try pairingServer(given: address, folder: folder)
            } catch HubProtocolError.badServer {
                throw HubSetupError("地址要用 https（只有这台 Mac 自己的 127.0.0.1 / localhost 可以用 http）：\(address.absoluteString)")
            }
            print("已记下 Hub 对外的地址：\(server.absoluteString)。之后 neoless-hub pair 生成的配对链接都用它。")
            return 0
        }
        let config = WatchedFile(store: folder.store, name: HubDataFolder.File.settings, fallback: HubConfig())
        guard let saved = config.value.server, let server = HubPairing.server(from: saved) else {
            print(noServer)
            return 1
        }
        print(server.absoluteString)
        return 0
    }

    static func pair(folder: HubDataFolder, name: String, server: URL, qr: String?) throws -> Int32 {
        let (pairing, replaced) = try makePairing(folder: folder, name: name, server: server)
        let link = pairing.url.absoluteString
        if replaced { print("“\(pairing.name)”之前配对过：旧的密钥已失效。") }
        print("已配对“\(pairing.name)”。在 iPhone 上扫描二维码，或在 Mac 上粘贴这个链接：")
        print(link)
        if pairing.access != nil { print("链接里带了 Cloudflare 门禁凭据（双重锁），这台设备的请求能过 Cloudflare 门禁。") }
        if let qr {
            let url = URL(fileURLWithPath: qr)
            try PairingQR.writePNG(for: link, to: url)
            print("二维码已保存到 \(url.path)（只有你能读）。配对后删掉它。")
        }
        if isatty(STDOUT_FILENO) == 1, let code = try? PairingQR.terminal(for: link) {
            print(code)
        }
        print(pairing.access == nil
              ? "链接里有这台设备的密钥，只显示这一次，别发给别人。"
              : "链接里有这台设备的密钥和门禁凭据（所有设备共用），只显示这一次，别发给别人。")
        print(Self.handOver)
        return 0
    }

    /// How to get a pairing link to the device without leaving a copy behind.
    static let handOver = "用 AirDrop、通用剪贴板或扫二维码传过去，别用备忘录和信息：它们会同步到 iCloud，删掉的备忘录还会在“最近删除”里留 30 天。传完删掉二维码文件。"

    // MARK: access

    static func access(_ action: HubCommandLine.Access, folder: HubDataFolder, input: SecretInput.Reader = SecretInput.standard) throws -> Int32 {
        let credentials = AccessCredentials(folder: folder)
        let config = WatchedFile(store: folder.store, name: HubDataFolder.File.settings, fallback: HubConfig())
        switch action {
        case .set(let givenID):
            let access = try readAccess(clientID: givenID, input: input)
            let had = try? credentials.load()
            try credentials.save(access)
            print("已\(had == nil ? "存入" : "替换") Cloudflare 门禁凭据（Client ID \(access.maskedID)），只有你能读：\(credentials.url.path)")
            if !access.clientID.hasSuffix(".access") {
                print("注意：Cloudflare 的 Client ID 一般以 .access 结尾，确认没有复制错。")
            }
            print("之后 neoless-hub pair 生成的配对链接会带上它们。已经配对的设备要重新配对：在 Neo 上运行 neoless-hub pair --name <设备名>，把新链接粘贴到设备上。")
            return 0
        case .status:
            AccessText.status(saved: try credentials.load(), requireAccess: config.value.requireAccess).forEach { print($0) }
            return 0
        case .clear:
            if try credentials.clear() {
                print("已删除 Cloudflare 门禁凭据。之后的配对链接不再带上它们。")
                print("已经配对的设备手里还有一份：要让它彻底失效，在 Cloudflare 上删除（或轮换）这个服务令牌。")
            } else {
                print("没有存过 Cloudflare 门禁凭据。")
            }
            return 0
        case .require(let on):
            var next = config.value
            next.requireAccess = on
            guard config.write(next) else {
                printError("没能保存设置（settings.json）")
                return 1
            }
            if on {
                print("已打开：Hub 只收带 Cloudflare 门禁标记的请求（/v1/ping 除外），正在运行的 Hub 立刻生效。")
                print("它只看标记在不在、不验签名，谁都能伪造：用来让设备及时发现门禁没设好，挡不住有意绕过的人。")
                if (try? credentials.load()) == nil {
                    print("注意：还没存门禁凭据（neoless-hub access set），新配对的设备过不了 Cloudflare 门禁。")
                }
            } else {
                print("已关闭：Hub 不再自己核对门禁（Cloudflare 上的 Access 照样起作用）。")
            }
            return 0
        }
    }

    /// The Client ID (given, or the first thing read) and the Client Secret (read, never an argument).
    static func readAccess(clientID givenID: String?, input: SecretInput.Reader) throws -> HubAccess {
        func clean(_ text: String?) -> String? {
            text.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        let terminal = isatty(STDIN_FILENO) == 1
        if terminal && givenID == nil {
            print("在 Cloudflare Zero Trust › Access controls › Service credentials › Service Tokens 创建服务令牌时，会显示 Client ID 和 Client Secret。")
        }
        guard let id = clean(givenID) ?? clean(input("Client ID：", false)) else {
            throw HubSetupError("没读到 Client ID（从标准输入读时，第一行 Client ID，第二行 Client Secret）")
        }
        guard let secret = clean(input("Client Secret（输入时不显示）：", true)) else {
            throw HubSetupError("没读到 Client Secret")
        }
        let access: HubAccess
        do {
            access = try HubAccess(clientID: id, clientSecret: secret)
        } catch {
            throw HubSetupError(id == secret ? "Client ID 和 Client Secret 不能一样"
                                : "Client ID 或 Client Secret 不对：各 8–512 个字符，不能有空格或中文")
        }
        guard !access.looksSwapped else { throw HubSetupError("看起来 Client ID 和 Client Secret 填反了：Client ID 以 .access 结尾") }
        return access
    }

    static func devices(folder: HubDataFolder) -> Int32 {
        let list = DeviceRegistry(folder: folder).all
        guard !list.isEmpty else {
            print("还没有配对的设备。用 neoless-hub pair --name <设备名> 配对。")
            return 0
        }
        for device in list {
            var parts = ["配对于 \(stamp(device.createdAt))"]
            parts.append(device.lastSeenAt.map { "最近使用 \(stamp($0))" } ?? "还没用过")
            if let revoked = device.revokedAt { parts.append("已移除 \(stamp(revoked))") }
            print("\(device.name)  " + parts.joined(separator: "  "))
        }
        return 0
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    // MARK: login

    static func login(folder: HubDataFolder) async -> Int32 {
        let account = ChatGPTAccount(store: folder.store, openURL: { url in
            print("在浏览器里登录 ChatGPT（没有自动打开就复制这个地址）：")
            print(url.absoluteString)
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = [url.absoluteString]
            try? open.run()
        })
        await account.signIn()
        // Only a login saved in the data folder reaches the running hub.
        let stored = folder.store.read(ChatGPTTokens.self, from: ChatGPTAccount.fileName)
        let saved = account.tokens != nil && stored?.refreshToken == account.tokens?.refreshToken
        print(account.message ?? (saved ? "登录成功" : "登录没有完成"))
        if saved { print("已登录：\(account.maskedEmail ?? "ChatGPT")。正在运行的 Hub 会自动用上新的登录。") }
        return saved ? 0 : 1
    }

    // MARK: import-samples

    /// A word list and a list of fixes into the dictionary and the learning book. Not while the hub serves this folder:
    /// it keeps both in memory and its next save would undo the import. A dry run changes nothing, so it always runs.
    /// - Parameter hubAnswers: whether a hub answers on a port (tests stub it).
    static func importSamples(_ files: HubCommandLine.SampleFiles, folder: HubDataFolder,
                              hubAnswers: (Int) async -> Bool = { await ping(port: $0) }) async throws -> Int32 {
        if !files.dryRun, !files.forceOffline, await hubAnswers(files.port) {
            throw HubSetupError("Hub 正在 127.0.0.1:\(files.port) 上运行：先停掉它再导入（它把词典和纠正放在内存里，下次保存会盖掉导入的内容）。"
                                + "确定它用的不是这个数据文件夹时，加 --force-offline。")
        }
        let plan = try SampleImport.plan(vocabulary: URL(fileURLWithPath: files.vocabulary),
                                         corrections: URL(fileURLWithPath: files.corrections))
        let words = WordStore(store: folder.store)
        let result = words.importSamples(words: plan.words, corrections: plan.corrections, dryRun: files.dryRun)
        SampleImport.summary(plan: plan, result: result, dryRun: files.dryRun, folder: folder.url).forEach { print($0) }
        return 0
    }

    // MARK: eval

    /// The polish eval: every chosen sample through the hub's own polish, written as JSON to `--out` (or standard
    /// output); progress goes to standard error. Stops at the first login or quota failure, or on Ctrl-C after the
    /// sample being polished, and still writes what it has. Waits for a login refresh before it returns.
    static func eval(_ run: HubCommandLine.EvalRun, folder: HubDataFolder) async throws -> Int32 {
        var overrides: [DictationMode: String] = [:]
        if let file = run.naturalFile { overrides[.natural] = try HubEval.staticText(from: URL(fileURLWithPath: file)) }
        if let file = run.structuredFile { overrides[.structured] = try HubEval.staticText(from: URL(fileURLWithPath: file)) }
        // Without a variant file a mode gets what a dictation gets: the data folder's own instruction file, if any.
        let own = PolishOverrides(store: folder.store)
        var ownFiles: [String] = []
        for mode in [DictationMode.natural, .structured] where overrides[mode] == nil {
            if let text = own.staticText(for: mode) {
                overrides[mode] = text
                ownFiles.append("\(mode.title)用数据文件夹里的 \(PolishOverrides.fileName(for: mode))")
            }
        }
        let samples = try HubEval.select(try HubEval.load(samples: URL(fileURLWithPath: run.samples)),
                                         only: run.only, limit: run.limit)
        let out = run.out.map { URL(fileURLWithPath: $0) }
        if let out {
            // Checked before anything is sent to ChatGPT.
            guard FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path) else {
                throw HubSetupError("--out 的文件夹不存在：\(out.deletingLastPathComponent().path)")
            }
        }
        let config = WatchedFile(store: folder.store, name: HubDataFolder.File.settings, fallback: HubConfig())
        let polisher = ChatGPTPolisher(store: folder.store, config: { config.value })
        let health = polisher.health
        guard health.ready else {
            throw HubSetupError("\(health.problem ?? HubLoginText.notSignedIn)：先运行 neoless-hub login")
        }
        let words = WordStore(store: folder.store)
        let options = config.value.polishOptions
        let variants = [run.naturalFile.map { "自然整理换成 \($0)" },
                        run.structuredFile.map { "结构化换成 \($0)" }].compactMap { $0 } + ownFiles
        printError("整理测试：\(samples.count) 条，提示词 \(PolishPrompt.version)"
                   + (variants.isEmpty ? "" : "（\(variants.joined(separator: "，"))）")
                   + "，模型 \(options.model)，快速模式\(options.fastTier ? "开" : "关")，"
                   + "词典 \(words.promptWords.own.count) 个词，自动学到的词 \(words.promptWords.learned.count) 个，学到的纠正 \(words.book.items.count) 条")

        let stop = InterruptFlag.install()
        defer { InterruptFlag.uninstall() }
        let (results, stopped) = await HubEval.run(samples, words: words, polisher: polisher, options: options,
                                                   overrides: overrides, progress: { printError($0) },
                                                   interrupted: { stop.isSet })
        // A polish that timed out leaves its refresh running: let it save the rotated token first.
        await polisher.waitForRefresh()

        let data = try HubEval.encode(results)
        if let out {
            // The user's own words: only they may read the file, as the hub's data files.
            guard (try? data.write(to: out, options: .atomic)) != nil else { throw HubSetupError("没能写入 \(out.path)") }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: out.path)
        } else {
            FileHandle.standardOutput.write(data + Data("\n".utf8))
        }
        let polished = results.filter(\.polished)
        let average = polished.isEmpty ? 0 : polished.map(\.ms).reduce(0, +) / polished.count
        printError("完成 \(results.count)/\(samples.count) 条：整理了 \(polished.count) 条，"
                   + "没整理成 \(results.filter { $0.fallback != nil }.count) 条，平均 \(average) ms"
                   + (out.map { "，结果在 \($0.path)" } ?? ""))
        switch stopped {
        case .login(let why)?:
            printError("停止：\(why)。先运行 neoless-hub login（或等额度恢复）再试")
            return 1
        case .interrupted?:
            printError("已中断")
            return 130
        case nil:
            return 0
        }
    }

    // MARK: transcribe

    /// Audio files through what `/v1/dictations` does before polishing: the hub's decoding (`AudioPrep`) and the ASR
    /// worker with the dictionary's hints. Prints each file's length, transcript and recognition time.
    static func transcribe(_ files: [String], json: Bool, folder: HubDataFolder, worker: URL) async throws -> Int32 {
        let client = ASRWorkerClient(baseURL: worker, secret: WorkerSecretSource(folder: folder.url))
        guard await client.health() != nil else {
            throw HubSetupError("语音识别 worker \(worker.absoluteString) 没有响应")
        }
        let hints = WordStore(store: folder.store).recognizerHints
        var results: [Transcription] = []
        for file in files {
            let result = await transcribe(file: file, asr: client, hints: hints)
            results.append(result)
            if !json { result.lines.forEach { print($0) } }
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            FileHandle.standardOutput.write(try encoder.encode(results) + Data("\n".utf8))
        }
        return results.contains { $0.error != nil } ? 1 : 0
    }

    /// One file's transcription (`neoless-hub transcribe`).
    struct Transcription: Codable, Equatable {
        var file: String
        var seconds: Double?
        var transcript: String?
        var status: String?
        var asrMs: Int?
        var loadMs: Int?
        var queueMs: Int?
        var error: String?

        var lines: [String] {
            var out = ["文件：\(file)"]
            if let seconds { out.append(String(format: "时长：%.2f 秒", seconds)) }
            if let error {
                out.append("失败：\(error)")
            } else {
                var timing = "识别 \(asrMs ?? 0) ms"
                if let loadMs, loadMs > 0 { timing += "，加载模型 \(loadMs) ms" }
                if let queueMs, queueMs > 0 { timing += "，排队 \(queueMs) ms" }
                let text = transcript ?? ""
                out.append("转写（\(timing)）：" + (text.isEmpty ? "（没听到话）" : text))
            }
            out.append("")
            return out
        }
    }

    static func transcribe(file: String, asr: ASRRecognizing, hints: [String]) async -> Transcription {
        var result = Transcription(file: file)
        let url = URL(fileURLWithPath: file)
        guard let type = audioType(of: url) else {
            result.error = "只认 .wav、.m4a 和 .caf"
            return result
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
        guard let size else {
            result.error = "读不了这个文件"
            return result
        }
        guard size <= Hub.maxAudioBytes else {
            result.error = HubFailure.audioTooLarge.body.error
            return result
        }
        guard let data = try? Data(contentsOf: url) else {
            result.error = "读不了这个文件"
            return result
        }
        let prepared: AudioPrep.Prepared
        do {
            prepared = try await AudioPrep.workerWAV(from: data, type: type)
        } catch AudioPrep.Failure.tooLong {
            result.error = HubFailure.audioTooLong.body.error
            return result
        } catch {
            result.error = HubFailure.decodeFailed.body.error
            return result
        }
        result.seconds = prepared.seconds
        guard prepared.seconds > 0 else {
            result.transcript = ""
            result.status = ASRWorkerResult.Status.noSpeech.rawValue
            result.asrMs = 0
            return result
        }
        do {
            let heard = try await asr.recognize(wav: prepared.wav, hints: hints, audioSeconds: prepared.seconds)
            result.transcript = heard.raw.trimmingCharacters(in: .whitespacesAndNewlines)
            result.status = heard.status.rawValue
            result.asrMs = heard.asrMs
            result.loadMs = heard.loadMs
            result.queueMs = heard.queueMs
        } catch {
            result.error = HubService.describe(error)
        }
        return result
    }

    static func audioType(of url: URL) -> HubAudioType? {
        switch url.pathExtension.lowercased() {
        case "wav", "wave": return .wav
        case "m4a", "mp4", "aac": return .m4a
        case "caf": return .caf
        default: return nil
        }
    }

    // MARK: status

    static func status(folder: HubDataFolder, port: Int, worker: URL) async -> Int32 {
        print("数据文件夹：\(folder.url.path)")
        let list = DeviceRegistry(folder: folder).all
        let active = list.filter { !$0.isRevoked }
        print("设备：\(active.count) 台" + (active.isEmpty ? "" : "（\(active.map(\.name).joined(separator: "、"))）"))

        let running = await ping(port: port)
        print(running ? "Hub：在 127.0.0.1:\(port) 运行中" : "Hub：127.0.0.1:\(port) 没有响应")
        let address = WatchedFile(store: folder.store, name: HubDataFolder.File.settings, fallback: HubConfig()).value.server
        print("对外地址：" + (address.flatMap { HubPairing.server(from: $0)?.absoluteString }
                              ?? "还没记下（neoless-hub server https://你的域名）"))

        let client = ASRWorkerClient(baseURL: worker, secret: WorkerSecretSource(folder: folder.url))
        if let health = await client.health() {
            print(workerLine(health))
        } else {
            print("语音识别：\(worker.absoluteString) 没有响应")
        }

        let config = WatchedFile(store: folder.store, name: HubDataFolder.File.settings, fallback: HubConfig())
        let chatgpt = ChatGPTPolisher.health(of: ChatGPTPolisher.makeAccount(store: folder.store))
        if chatgpt.ready {
            print("ChatGPT：可以整理" + (chatgpt.account.map { "（\($0)）" } ?? ""))
        } else {
            print("ChatGPT：\(chatgpt.problem ?? HubLoginText.notSignedIn)，现在只输入原文。运行 neoless-hub login 登录。")
        }

        let words = WordStore(store: folder.store)
        let history = HubHistory(store: folder.store)
        let unused = words.unusedCorrections
        print("历史：\(history.entries.count) 条；词典：\(words.words.count) 个词；学到的纠正：\(words.book.items.count) 条"
              + (unused > 0 ? "（其中 \(unused) 条按现在的规则不像听错的词，已停用）" : "")
              + (words.habits.isEmpty ? "" : "；我的习惯：\(words.habits.items.count) 条"))

        print(PolishOverrides(store: folder.store).summary)

        do {
            AccessText.status(saved: try AccessCredentials(folder: folder).load(), requireAccess: config.value.requireAccess)
                .forEach { print($0) }
        } catch {
            print("双重锁：\((error as? LocalizedError)?.errorDescription ?? "门禁凭据读不出来")")
        }
        return 0
    }

    /// What `status` says about a worker that answers: its model, and both when it has a large and a small one.
    nonisolated static func workerLine(_ health: ASRWorkerHealth) -> String {
        let state = health.ok ? (health.loaded ? "模型已加载" : "模型未加载，下次请求时加载") : (health.problem ?? "模型加载失败")
        guard let large = health.largeModel, let small = health.smallModel else {
            return "语音识别：在线（\(health.model)，\(state)）"
        }
        let auto = health.autoUses == HubASRModel.small.rawValue ? "小模型（Neo 忙，大模型先歇着）" : "大模型"
        return "语音识别：在线（大模型 \(large)，小模型 \(small)，自动现在用\(auto)；\(state)）"
    }

    static func ping(port: Int) async -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(HubPath.ping)")!)
        request.timeoutInterval = 2
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        return (try? HubJSON.decode(HubOK.self, from: data))?.ok == true
    }

    static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

/// Ctrl-C (or SIGTERM) during `eval`: the run stops after the sample being polished, still waits for a login
/// refresh and writes its results. A second one ends the process at once.
final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    private var sources: [DispatchSourceSignal] = []
    nonisolated(unsafe) private static var current: InterruptFlag?

    var isSet: Bool { lock.withLock { set } }

    func raise() -> Bool {
        lock.withLock {
            defer { set = true }
            return set
        }
    }

    static func install() -> InterruptFlag {
        let flag = InterruptFlag()
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                if flag.raise() {
                    signal(number, SIG_DFL)
                    kill(getpid(), number)
                } else {
                    FileHandle.standardError.write(Data("收到中断：这一条做完就停（再按一次立即退出）\n".utf8))
                }
            }
            source.resume()
            flag.sources.append(source)
        }
        current = flag
        return flag
    }

    static func uninstall() {
        current?.sources.forEach { $0.cancel() }
        current = nil
        signal(SIGINT, SIG_DFL)
        signal(SIGTERM, SIG_DFL)
    }
}
