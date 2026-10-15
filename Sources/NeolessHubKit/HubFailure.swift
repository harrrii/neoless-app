import Foundation
import NeolessCloud
import NeolessCore

/// An error answer: the HTTP status and the `{"error", "code", "retryable"}` body, in plain Chinese.
public struct HubFailure: Error, Equatable, Sendable {
    public var status: Int
    public var body: HubErrorBody

    public init(_ status: Int, _ error: String, code: String, retryable: Bool = false) {
        self.status = status
        body = HubErrorBody(error: error, code: code, retryable: retryable)
    }

    public static func badRequest(_ why: String = "请求的格式不对") -> HubFailure {
        HubFailure(400, why, code: HubErrorCode.badRequest)
    }

    public static let unauthorized = HubFailure(401, "这台设备的密钥不对，请重新配对", code: HubErrorCode.unauthorized)
    public static let forbidden = HubFailure(403, "这台设备已被移除，请重新配对", code: HubErrorCode.forbidden)
    public static let notFound = HubFailure(404, "Neo 上没有这条记录", code: HubErrorCode.notFound)
    public static let noRoute = HubFailure(404, "没有这个接口", code: HubErrorCode.notFound)
    public static let conflict = HubFailure(409, "词典已在别的设备上改过，请刷新后再改", code: HubErrorCode.conflict)
    public static let habitsConflict = HubFailure(409, "习惯已在别的设备上改过，请刷新后再改", code: HubErrorCode.conflict)
    public static let audioTooLarge = HubFailure(413, "录音太大，Neo 只收 12 MB 以内的录音", code: HubErrorCode.tooLarge)
    public static let jsonTooLarge = HubFailure(413, "内容太大，Neo 只收 256 KB 以内的请求", code: HubErrorCode.tooLarge)
    public static let audioTooLong = HubFailure(413, "录音太长，Neo 只识别 10 分钟以内的录音", code: HubErrorCode.tooLarge)
    public static let textTooLong = HubFailure(413, "文字太长，Neo 不收", code: HubErrorCode.tooLarge)
    public static let vocabularyTooLarge = HubFailure(413, "词典太大，Neo 只收 1 MB 以内", code: HubErrorCode.tooLarge)
    public static let habitsTooLarge = HubFailure(413, "习惯太多或太长，Neo 不收", code: HubErrorCode.tooLarge)
    public static let unsupportedMedia = HubFailure(415, "Neo 不认识这种音频格式", code: HubErrorCode.unsupportedMedia)
    public static let decodeFailed = HubFailure(422, "Neo 解不开这段录音", code: HubErrorCode.decodeFailed)
    public static let rateLimited = HubFailure(429, "请求太频繁，稍后再试", code: HubErrorCode.rateLimited, retryable: true)
    public static let asrUnavailable = HubFailure(503, "Neo 的语音识别暂时不可用", code: HubErrorCode.asrUnavailable,
                                                  retryable: true)
    public static let internalError = HubFailure(500, "Neo 出错了，稍后再试", code: HubErrorCode.internalError, retryable: true)
    /// `requireAccess` is on and the request did not come through Cloudflare Access: Access in front of the hub is off
    /// or set up wrong (pairing again would not help).
    public static let accessRequired = HubFailure(403, "Neo 只收经过 Cloudflare 门禁的请求，这次没有经过：检查 Cloudflare 上的 Access 设置",
                                                  code: HubErrorCode.accessRequired)

    /// `…/repolish` when ChatGPT did not answer: the dictation keeps its text, the device says why. The reason is
    /// the few words a fallback carries ("整理超时", "ChatGPT 登录已失效"), not the app's sentence that ends in
    /// "在设置里重新登录": the login is the Neo's, which a device's settings cannot fix.
    public static func polishFailed(_ error: Error) -> HubFailure {
        let retryable: Bool
        switch error as? PolishError {
        case .notSignedIn?, .http(401, _)?, .http(403, _)?: retryable = false
        default: retryable = true
        }
        return HubFailure(503, PolishFailure.short(error), code: HubErrorCode.polishFailed, retryable: retryable)
    }
}

extension HubFallback {
    /// Why a dictation was typed as the original: "已输入原文" and the few words the capsule shows ("整理超时").
    static func polishFailed(_ error: Error) -> HubFallback {
        let reason = PolishFailure.short(error)
        let parts = FailureText.fallback(FailureText.typedRaw(reason: reason))
        return HubFallback(title: parts?.title ?? "已输入原文", reason: parts?.reason ?? reason)
    }
}
