import Foundation
import NeolessCloud
import NeolessCore

/// `neoless-hub` command line: what to do, parsed from the arguments.
public struct HubCommandLine: Equatable, Sendable {
    public enum Command: Equatable, Sendable {
        case serve(port: Int)
        /// `server`: the address the link carries (`--server`), nil for the one remembered in settings.json.
        case pair(name: String, server: URL?, qr: String?)
        /// The hub's public address, as pairing links carry it: remember `address`, or show the remembered one.
        case server(address: URL?)
        case devices
        case revoke(name: String)
        case login
        case status(port: Int)
        /// 双重锁: the Cloudflare Access service token pairing links carry.
        case access(Access)
        /// A word list and a list of fixes (two JSON files the user brings) into the dictionary and the learning book
        /// (refused while the hub on `port` answers, unless `forceOffline`).
        case importSamples(SampleFiles)
        /// The polish eval over a file of transcripts, or the static instructions to start a variant from.
        case eval(Eval)
        /// Audio files through the hub's decoding and the ASR worker, as `/v1/dictations` does.
        case transcribe(files: [String], json: Bool)
        case help
    }

    public struct SampleFiles: Equatable, Sendable {
        public var vocabulary: String
        public var corrections: String
        public var dryRun: Bool
        public var forceOffline: Bool
        /// Where the hub would answer if it ran.
        public var port: Int

        public init(vocabulary: String, corrections: String, dryRun: Bool = false, forceOffline: Bool = false,
                    port: Int = Hub.port) {
            self.vocabulary = vocabulary; self.corrections = corrections; self.dryRun = dryRun
            self.forceOffline = forceOffline; self.port = port
        }
    }

    public enum Eval: Equatable, Sendable {
        case run(EvalRun)
        /// The static text of 自然整理 or 结构化.
        case printInstructions(DictationMode)
    }

    public struct EvalRun: Equatable, Sendable {
        public var samples: String
        public var naturalFile: String?
        public var structuredFile: String?
        public var out: String?
        public var limit: Int?
        public var only: [String]?

        public init(samples: String, naturalFile: String? = nil, structuredFile: String? = nil, out: String? = nil,
                    limit: Int? = nil, only: [String]? = nil) {
            self.samples = samples; self.naturalFile = naturalFile; self.structuredFile = structuredFile
            self.out = out; self.limit = limit; self.only = only
        }
    }

    public enum Access: Equatable, Sendable {
        /// Save the Client ID (`--id`, or asked for) and the Client Secret (always asked for, or read from stdin).
        case set(clientID: String?)
        case status
        case clear
        /// settings.json `requireAccess`: the hub refuses requests without the header Cloudflare Access adds (only
        /// whether it is there: a check for a misconfigured Access, not a lock).
        case require(Bool)
    }

    public var command: Command
    /// `--data-dir`: another data folder (a trial run on a spare port); default ~/Library/Application Support/neoless-hub.
    public var dataDirectory: String?
    /// `--worker`: the ASR worker's address; default http://127.0.0.1:18801.
    public var workerURL: URL?

    public init(command: Command, dataDirectory: String? = nil, workerURL: URL? = nil) {
        self.command = command; self.dataDirectory = dataDirectory; self.workerURL = workerURL
    }

    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public var errorDescription: String? { message }
    }

    public static let usage = """
    用法：
      neoless-hub serve [--port 18800]          在 127.0.0.1 上提供服务（同时阻止 Neo 闲置睡眠）
      neoless-hub server [https://你的域名]     记下 Hub 对外的地址（配对链接里写的就是它）；不写地址时显示记下的
      neoless-hub pair --name <设备名> [--server https://你的域名] [--qr <图片.png>]
                                                配对一台设备：打印配对链接和二维码（--server 写过一次就记住了）
      neoless-hub devices                       列出已配对的设备
      neoless-hub revoke <设备名>               移除一台设备（它的密钥立即失效）
      neoless-hub login                         在浏览器里登录 ChatGPT（用于整理）
      neoless-hub status [--port 18800]         查看 Hub、语音识别、ChatGPT 和双重锁的状态
      neoless-hub access set [--id <Client ID>] 存入 Cloudflare 门禁凭据（双重锁）；Client Secret 在提示时输入（不显示），
                                                或从标准输入读：第一行 Client ID，第二行 Client Secret
      neoless-hub access status                 双重锁开没开（不显示密钥）
      neoless-hub access clear                  删掉存的门禁凭据（之后的配对链接不再带上）
      neoless-hub access require on|off         Hub 只收带 Cloudflare 门禁标记的请求（默认关；只看标记在不在，
                                                谁都能伪造：用来发现门禁没设好，不算第三道锁）
      neoless-hub import-samples --vocabulary <vocabulary.json> --corrections <corrections.json>
                                 [--dry-run] [--force-offline] [--port 18800]
                                                把你自己准备的词表加进词典、纠正表里高把握的纠正加进学习簿（先停掉 Hub；
                                                Hub 在 --port 上回应时不导入，除非加 --force-offline）
      neoless-hub eval --samples <polish-eval.json> [--natural-file <文件>] [--structured-file <文件>]
                       [--out <results.json>] [--limit <条数>] [--only <id,id…>]
                                                用 Neo 的 ChatGPT 登录、词典和纠正，把你准备的逐字稿逐条整理一遍（不存历史）；
                                                --natural-file / --structured-file 换掉自然整理 / 结构化的固定指令
      neoless-hub eval --print-instructions natural|structured
                                                打印内置的固定指令（想改指令时从它开始：改好的存成数据文件夹里的
                                                polish-natural.md / polish-structured.md，听写就用你这份）
      neoless-hub transcribe <录音.wav|m4a…> [--json]
                                                用和听写一样的解码和语音识别转写录音文件
    通用选项：
      --data-dir <文件夹>                       数据文件夹（默认 ~/Library/Application Support/neoless-hub）
      --worker <地址>                           语音识别 worker（默认 http://127.0.0.1:18801）
    """

    public static func parse(_ arguments: [String]) throws -> HubCommandLine {
        var rest = arguments
        var dataDirectory: String?
        var workerURL: URL?
        var options: [String: String] = [:]
        var flags = Set<String>()
        var positional: [String] = []
        let valued: Set<String> = ["--port", "--name", "--server", "--qr", "--data-dir", "--worker", "--id",
                                   "--vocabulary", "--corrections", "--samples", "--natural-file", "--structured-file",
                                   "--out", "--limit", "--only", "--print-instructions"]
        let switches: Set<String> = ["--dry-run", "--force-offline", "--json", "--help", "-h"]
        while !rest.isEmpty {
            let arg = rest.removeFirst()
            if valued.contains(arg) {
                guard let value = rest.first, !value.hasPrefix("--") else { throw Failure(message: "\(arg) 后面缺少值") }
                rest.removeFirst()
                options[arg] = value
            } else if let eq = arg.firstIndex(of: "="), valued.contains(String(arg[..<eq])) {
                options[String(arg[..<eq])] = String(arg[arg.index(after: eq)...])
            } else if switches.contains(arg) {
                flags.insert(arg)
            } else if arg.hasPrefix("--") {
                throw Failure(message: "不认识的选项 \(arg)")
            } else {
                positional.append(arg)
            }
        }
        if let dir = options.removeValue(forKey: "--data-dir") { dataDirectory = (dir as NSString).expandingTildeInPath }
        if let text = options.removeValue(forKey: "--worker") {
            guard let url = URL(string: text), url.scheme == "http", let host = url.host,
                  ["127.0.0.1", "localhost", "::1"].contains(host) else {
                throw Failure(message: "--worker 只能是本机地址，比如 http://127.0.0.1:18801")
            }
            workerURL = url
        }
        func port() throws -> Int {
            guard let text = options.removeValue(forKey: "--port") else { return Hub.port }
            guard let value = Int(text), (1...65_535).contains(value) else { throw Failure(message: "--port 不对：\(text)") }
            return value
        }
        func path(_ option: String) -> String? {
            options.removeValue(forKey: option).map { ($0 as NSString).expandingTildeInPath }
        }
        func requiredPath(_ option: String, _ command: String) throws -> String {
            guard let value = path(option), !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw Failure(message: "\(command) 需要 \(option) <文件>")
            }
            return value
        }
        let name = positional.first
        let command: Command
        if flags.contains("--help") || flags.contains("-h") || name == nil || name == "help" {
            command = .help
        } else {
            switch name! {
            case "serve":
                command = .serve(port: try port())
            case "pair":
                guard let device = options.removeValue(forKey: "--name"), !device.trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw Failure(message: "pair 需要 --name <设备名>")
                }
                var server: URL?
                if let text = options.removeValue(forKey: "--server") {
                    guard let url = URL(string: text) else { throw Failure(message: "--server 不对：\(text)") }
                    server = url
                }
                command = .pair(name: device, server: server,
                                qr: options.removeValue(forKey: "--qr").map { ($0 as NSString).expandingTildeInPath })
            case "server":
                guard positional.count <= 2 else { throw Failure(message: "多余的参数 \(positional[2])") }
                if positional.count == 2 {
                    guard let url = URL(string: positional[1]), url.scheme != nil else {
                        throw Failure(message: "地址不对：\(positional[1])（要像 https://hub.example.com 这样）")
                    }
                    command = .server(address: url)
                } else {
                    command = .server(address: nil)
                }
            case "devices":
                command = .devices
            case "revoke":
                guard positional.count == 2 else { throw Failure(message: "revoke 需要一个设备名") }
                command = .revoke(name: positional[1])
            case "login":
                command = .login
            case "status":
                command = .status(port: try port())
            case "access":
                switch positional.count > 1 ? positional[1] : nil {
                case "set":
                    let id = options.removeValue(forKey: "--id")
                    if let id, id.trimmingCharacters(in: .whitespaces).isEmpty { throw Failure(message: "--id 后面缺少值") }
                    command = .access(.set(clientID: id))
                case "status": command = .access(.status)
                case "clear": command = .access(.clear)
                case "require":
                    switch positional.count > 2 ? positional[2] : nil {
                    case "on": command = .access(.require(true))
                    case "off": command = .access(.require(false))
                    default: throw Failure(message: "access require 后面要写 on 或 off")
                    }
                case let other?: throw Failure(message: "不认识的 access 命令 \(other)，可以用 set、status、clear、require")
                case nil: throw Failure(message: "access 后面要写 set、status、clear 或 require")
                }
            case "import-samples":
                command = .importSamples(SampleFiles(vocabulary: try requiredPath("--vocabulary", "import-samples"),
                                                     corrections: try requiredPath("--corrections", "import-samples"),
                                                     dryRun: flags.contains("--dry-run"),
                                                     forceOffline: flags.contains("--force-offline"), port: try port()))
            case "eval":
                if let text = options.removeValue(forKey: "--print-instructions") {
                    guard let mode = DictationMode(rawValue: text), mode.polishes else {
                        throw Failure(message: "--print-instructions 后面要写 natural 或 structured")
                    }
                    command = .eval(.printInstructions(mode))
                } else {
                    var run = EvalRun(samples: try requiredPath("--samples", "eval"))
                    run.naturalFile = path("--natural-file")
                    run.structuredFile = path("--structured-file")
                    run.out = path("--out")
                    if let text = options.removeValue(forKey: "--limit") {
                        guard let limit = Int(text), limit > 0 else { throw Failure(message: "--limit 要写正整数：\(text)") }
                        run.limit = limit
                    }
                    if let text = options.removeValue(forKey: "--only") {
                        let ids = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        guard !ids.isEmpty else { throw Failure(message: "--only 后面要写样本 id，用逗号分开") }
                        run.only = ids
                    }
                    command = .eval(.run(run))
                }
            case "transcribe":
                let files = positional.dropFirst().map { ($0 as NSString).expandingTildeInPath }
                guard !files.isEmpty else { throw Failure(message: "transcribe 后面要写录音文件") }
                command = .transcribe(files: Array(files), json: flags.contains("--json"))
            default:
                throw Failure(message: "不认识的命令 \(name!)")
            }
        }
        let used: Int
        switch command {
        case .revoke: used = 2
        case .server: used = positional.count
        case .access(.require): used = 3
        case .access: used = 2
        case .transcribe: used = positional.count
        default: used = 1
        }
        if positional.count > used { throw Failure(message: "多余的参数 \(positional[used])") }
        // Each switch belongs to one command.
        let owners: [String: String] = ["--dry-run": "import-samples", "--force-offline": "import-samples",
                                        "--json": "transcribe"]
        if command != .help, let stray = flags.subtracting(["--help", "-h"]).sorted().first(where: { owners[$0] != name }) {
            throw Failure(message: "\(stray) 只能用在 \(owners[stray] ?? "")")
        }
        if let extra = options.keys.sorted().first { throw Failure(message: "\(extra) 不能用在这个命令") }
        return HubCommandLine(command: command, dataDirectory: dataDirectory, workerURL: workerURL)
    }
}
