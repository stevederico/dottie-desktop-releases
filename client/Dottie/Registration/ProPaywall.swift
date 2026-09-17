import Foundation
import AppKit

/// Dottie Pro free-credit exhaustion → Stripe Checkout paywall.
///
/// Server `admit()` returns 429 `{ "error": "free credit used", "paid_required": true }`.
/// Collection UI is **hosted Checkout in the system browser** — no in-app card UI.

enum ProPaywallError: Equatable {
    case freeCreditUsed
    case dailyLimit
    case spendingCap
    case other
}

enum ProPaywall {
    /// Parse a relay/gateway error body or message for paywall routing.
    static func classify(httpStatus: Int? = nil, body: Data? = nil, message: String? = nil) -> ProPaywallError {
        if let body, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            if let err = obj["error"] as? String {
                return classifyErrorString(err)
            }
            // Relay sometimes only sets paid_required without error string.
            if obj["paid_required"] as? Bool == true { return .freeCreditUsed }
        }
        if let message {
            let lower = message.lowercased()
            if lower.contains("free credit used") || lower.contains("paid_required") {
                return .freeCreditUsed
            }
            if lower.contains("spending cap reached") { return .spendingCap }
            if lower.contains("daily limit reached") { return .dailyLimit }
            // Failover summary: `All providers failed: dottiepro(429): free credit used`
            // or status-only `dottiepro(429)` after free-credit admit (body may be missing).
            if lower.contains("free credit") { return .freeCreditUsed }
            if lower.contains("dottiepro(429)") || lower.contains("dottiepro( 429)") {
                // Prefer free-credit wall over generic daily when Pro is the only provider.
                return .freeCreditUsed
            }
        }
        if httpStatus == 429 {
            // Generic 429 without body — treat as daily unless message says free credit.
            return .dailyLimit
        }
        return .other
    }

    static func classifyErrorString(_ err: String) -> ProPaywallError {
        switch err {
        case "free credit used": return .freeCreditUsed
        case "daily limit reached": return .dailyLimit
        case "spending cap reached": return .spendingCap
        default: return .other
        }
    }

    /// User-facing copy for the free-credit wall (Title Case buttons elsewhere).
    static let freeCreditTitle = "Free Pro Trial Used"
    static let freeCreditMessage =
        "Your free Dottie Pro credit is used up. Subscribe for continued Grok access, add your own xAI key, or switch to Local models."

    /// Notification posted when free credit is exhausted mid-session.
    static let freeCreditUsedNotification = Notification.Name("com.example.dottie.proFreeCreditUsed")

    /// Open Stripe Checkout in the default browser. Returns false if the
    /// checkout call failed (no network / Stripe not configured).
    @discardableResult
    static func openCheckout() async -> Bool {
        do {
            let url = try await DottieAPIClient.shared.createProCheckoutURL()
            await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            return true
        } catch {
            AppLogger.shared.warn("[ProPaywall] checkout failed: \(error)")
            return false
        }
    }

    /// Open Customer Portal when already subscribed.
    @discardableResult
    static func openPortal() async -> Bool {
        do {
            let url = try await DottieAPIClient.shared.createProPortalURL()
            await MainActor.run {
                NSWorkspace.shared.open(url)
            }
            return true
        } catch {
            AppLogger.shared.warn("[ProPaywall] portal failed: \(error)")
            return false
        }
    }

    /// File a refund request for operator review (nothing changes at Stripe
    /// until it's approved — keeps "burn the quota, then refund" from being a
    /// one-click move). Returns a user-facing sentence on success, nil on
    /// failure (logged); 409 = already pending, also a success message.
    static func requestRefund() async -> String? {
        do {
            let r = try await DottieAPIClient.shared.requestProRefund()
            return "Refund requested. We'll review it and reply to \(r.email) within a few days. Your subscription stays active until then."
        } catch DottieAPIError.badStatus(409) {
            return "A refund request is already open — we'll be in touch by email."
        } catch {
            AppLogger.shared.warn("[ProPaywall] refund request failed: \(error)")
            return nil
        }
    }
}

/// Shape of POST /api/pro/refund: `{ ok, status: "pending", id, email }`.
struct ProRefundResult: Equatable {
    var id: Int
    var email: String

    static func decode(_ data: Data) throws -> ProRefundResult {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["ok"] as? Bool == true else {
            throw DottieAPIError.decodingFailed
        }
        return ProRefundResult(
            id: (obj["id"] as? NSNumber)?.intValue ?? 0,
            email: obj["email"] as? String ?? "your account email"
        )
    }
}

/// Shape of GET /api/pro/status (expanded for paywall).
struct ProStatus: Equatable {
    var enabled: Bool
    var paid: Bool
    var freeCreditExhausted: Bool
    var freeTokensUsed: Int
    var freeTokensLimit: Int
    var freeRequestsUsed: Int
    var freeRequestsLimit: Int
    var requestsToday: Int
    var requestsLimit: Int

    var freeTokensRemaining: Int {
        if paid { return freeTokensLimit }
        return max(0, freeTokensLimit - freeTokensUsed)
    }

    /// 0…1 of free credit **used** (empty = unused, full = depleted). Bar fills as you spend.
    var freeTokensUsedFraction: Double {
        if paid { return 0 }
        if freeCreditExhausted { return 1 }
        guard freeTokensLimit > 0 else { return 0 }
        let used = min(freeTokensLimit, max(0, freeTokensUsed))
        return min(1, Double(used) / Double(freeTokensLimit))
    }

    /// Trailing Usage label (right side of row — not a subtitle).
    /// Depleted: "100% Free Usage Depleted"; else "N% Used"; paid: "Subscribed".
    var usageTrailingLabel: String {
        if paid { return "Subscribed" }
        if freeCreditExhausted || freeTokensRemaining == 0 { return "100% Free Usage Depleted" }
        if freeTokensLimit > 0 {
            let pct = Int((freeTokensUsedFraction * 100).rounded())
            return "\(pct)% Used"
        }
        return "—"
    }

    var isUsageDepleted: Bool {
        !paid && (freeCreditExhausted || freeTokensRemaining == 0)
    }

    /// Alias for paywall / test connection copy paths.
    var statusLabel: String {
        if isUsageDepleted { return "Free Usage Depleted" }
        return usageTrailingLabel
    }

    var usageLabel: String { usageTrailingLabel }

    static func decode(_ data: Data) throws -> ProStatus {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DottieAPIError.decodingFailed
        }
        func int(_ key: String) -> Int {
            if let i = obj[key] as? Int { return i }
            if let n = obj[key] as? NSNumber { return n.intValue }
            return 0
        }
        return ProStatus(
            enabled: obj["enabled"] as? Bool ?? false,
            paid: obj["paid"] as? Bool ?? false,
            freeCreditExhausted: obj["free_credit_exhausted"] as? Bool ?? false,
            freeTokensUsed: int("free_tokens_used"),
            freeTokensLimit: int("free_tokens_limit"),
            freeRequestsUsed: int("free_requests_used"),
            freeRequestsLimit: int("free_requests_limit"),
            requestsToday: int("requests_today"),
            requestsLimit: int("requests_limit")
        )
    }
}
