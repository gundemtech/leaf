//
//  LoopbackCallbackListener.swift
//  Leaf
//
//  Phase 4.1 — minimal HTTP server on 127.0.0.1:47823 for receiving the OAuth
//  redirect from Linear. Live only for the duration of a single flow:
//  start → first valid callback → respond → cancel.
//

import Foundation
import LeafCore
import Network
import os

nonisolated private let listenerLogger = Logger(
  subsystem: "tech.gundem.leaf.app", category: "linear-oauth-listener")

enum LoopbackCallbackError: Error {
  case timeout
  case bindFailed(String)
  case parseFailed
  case listenerFailed(String)
}

nonisolated enum LoopbackCallbackListener {
  /// Bind to `127.0.0.1:port`, wait for the first `GET /callback?...`,
  /// send a minimal HTML page, return the `URLComponents` query.
  /// Cancel the listener on timeout or Task cancellation. The caller extracts
  /// the `code`/`state`/`error` parameters from the returned `URLComponents`.
  static func awaitCallback(
    port: UInt16,
    timeout: Duration = .seconds(60),
    graceOnCancel: Duration = .seconds(60),
    providerLabel: String = "Linear"
  ) async throws -> URLComponents {
    let nwPort = NWEndpoint.Port(rawValue: port) ?? NWEndpoint.Port.any
    let parameters = NWParameters.tcp
    // After an app-side cancel we keep the previous listener alive for a grace
    // window (see onCancel), so a retry on the same fixed port must be able to
    // rebind without waiting out the socket's lingering close.
    parameters.allowLocalEndpointReuse = true
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
      host: NWEndpoint.Host(LinearOAuthEndpoints.redirectHost),
      port: nwPort
    )

    let listener: NWListener
    do {
      listener = try NWListener(using: parameters)
    } catch {
      throw LoopbackCallbackError.bindFailed(String(describing: error))
    }

    let queue = DispatchQueue(label: "tech.gundem.leaf.linear-callback")
    let coordinator = CallbackCoordinator(listener: listener, port: port, queue: queue)
    // Evict any lingering grace-listener left by a just-cancelled flow on this
    // port so this fresh flow owns the socket.
    ListenerRegistry.shared.register(listener, port: port)

    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<URLComponents, Error>) in
        coordinator.arm(continuation)

        listener.stateUpdateHandler = { state in
          switch state {
          case .failed(let error):
            listenerLogger.error("listener failed: \(String(describing: error), privacy: .public)")
            coordinator.settle(
              .failure(LoopbackCallbackError.listenerFailed(String(describing: error))))
            // A failed socket can never serve a drain — tear it down now rather
            // than holding it (and the registry slot) until the grace deadline.
            coordinator.closeListener()
          case .cancelled:
            // Torn down by a normal finish, the drain path, or eviction by a
            // newer flow on this port. Retire the grace timer and make sure the
            // awaiting task is resumed (a no-op if it already was). Without this,
            // an evicted listener would leave its task hanging until timeout.
            coordinator.listenerDidCancel()
          default:
            break
          }
        }

        listener.newConnectionHandler = { connection in
          connection.start(queue: queue)
          connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, _, error in
            if let error {
              listenerLogger.error(
                "connection receive error: \(String(describing: error), privacy: .public)")
              connection.cancel()
              return
            }
            // App-side cancel already fired and the awaiting task is gone. Greet
            // any late provider redirect with the branded "cancelled" page —
            // never a success page, the user backed out in the app — then close.
            if coordinator.isAppCancelled {
              sendResponse(
                on: connection, status: "200 OK", body: htmlCancelled(providerLabel: providerLabel))
              coordinator.closeListener()
              return
            }
            guard let data, let line = parseRequestLine(data) else {
              sendResponse(
                on: connection, status: "400 Bad Request", body: htmlError("Bad request"))
              return
            }

            // Build URL components from "/callback?<query>" path-and-query.
            let urlString = "http://\(LinearOAuthEndpoints.redirectHost):\(port)\(line)"
            guard let components = URLComponents(string: urlString) else {
              sendResponse(
                on: connection, status: "400 Bad Request", body: htmlError("Invalid callback URL"))
              coordinator.settle(.failure(LoopbackCallbackError.parseFailed))
              return
            }

            // If `error` arrived in the query — still serve the final page
            // (the user should see a meaningful message in the browser),
            // then the caller (LinearOAuthService) interprets error/state/code.
            let isError = components.queryItems?.contains(where: { $0.name == "error" }) ?? false
            let body =
              isError
              ? htmlCancelled(providerLabel: providerLabel)
              : htmlSuccess(providerLabel: providerLabel)
            sendResponse(on: connection, status: "200 OK", body: body)
            coordinator.settle(.success(components))
          }
        }

        listener.start(queue: queue)

        // No callback within the window — give up and tear down. Cancellable so
        // a finished flow releases the coordinator/listener immediately instead
        // of pinning them until the deadline.
        coordinator.startTimeout(afterMilliseconds: milliseconds(timeout))
      }
    } onCancel: {
      // App-side cancel (e.g. the LoginView "×"). Hand the work to the listener
      // queue so it is ordered against the connection/timeout handlers (no torn
      // read of the drain flag): mark the flow cancelled — so a late provider
      // redirect is drained with the branded "cancelled" page instead of the
      // browser's connection-refused error — and keep the listener for the grace
      // window before self-closing. The awaiting task resumes on the normal
      // timeout (or when the listener is finally cancelled), unchanged for
      // callers; the UI has already moved on.
      let graceMs = milliseconds(graceOnCancel)
      queue.async { coordinator.cancelGracefully(graceMilliseconds: graceMs) }
    }
  }

  // MARK: - Internals

  /// Whole milliseconds of a `Duration`, including the sub-second part, clamped
  /// to a non-negative `Int` (so a sub-second value doesn't truncate to 0 and a
  /// huge one doesn't overflow). `components` splits into whole seconds +
  /// attoseconds; 1 ms = 1e15 attoseconds.
  private static func milliseconds(_ duration: Duration) -> Int {
    let c = duration.components
    let subMs = c.attoseconds / 1_000_000_000_000_000
    let secMs = c.seconds.multipliedReportingOverflow(by: 1000)
    if secMs.overflow { return .max }
    let total = secMs.partialValue.addingReportingOverflow(subMs)
    if total.overflow { return .max }
    return Int(clamping: max(0, total.partialValue))
  }

  /// Parse first line `GET /callback?<query> HTTP/1.1` and return path-and-query
  /// (`/callback?...`). Returns nil if the format is not an HTTP request.
  private static func parseRequestLine(_ data: Data) -> String? {
    // Read up to first \r\n.
    guard let crlf = data.firstRange(of: Data("\r\n".utf8)),
      let line = String(data: data[..<crlf.lowerBound], encoding: .utf8)
    else { return nil }

    let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }
    let method = String(parts[0])
    let target = String(parts[1])
    guard method == "GET", target.hasPrefix("/") else { return nil }
    return target
  }

  private static func sendResponse(on connection: NWConnection, status: String, body: String) {
    let bytes = Data(body.utf8)
    let headers = """
      HTTP/1.1 \(status)\r
      Content-Type: text/html; charset=utf-8\r
      Content-Length: \(bytes.count)\r
      Connection: close\r
      \r

      """
    var payload = Data(headers.utf8)
    payload.append(bytes)
    connection.send(
      content: payload,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }

  // Leaf-branded browser pages. Each returns a full, self-contained HTML
  // document (inline CSS, embedded logo) — the loopback listener serves a
  // single fixed Content-Length response with no asset server, so nothing may
  // reference an external URL. Visual language mirrors leaf-web tokens.css and
  // the Supabase auth emails. One template drives every provider + state.

  private static func htmlSuccess(providerLabel: String) -> String {
    let label = htmlEscape(providerLabel)
    return htmlPage(
      kind: .success,
      title: "Leaf is connected to \(label).",
      subtitle: "You can close this window and return to the app.",
      tabTitle: "Leaf — \(label) connected"
    )
  }

  private static func htmlCancelled(providerLabel: String) -> String {
    let label = htmlEscape(providerLabel)
    return htmlPage(
      kind: .cancelled,
      title: "\(label) connection cancelled.",
      subtitle: "You can close this window and try again from Leaf.",
      tabTitle: "Leaf — \(label) cancelled"
    )
  }

  private static func htmlError(_ message: String) -> String {
    htmlPage(
      kind: .error,
      title: htmlEscape(message),
      subtitle: "Please return to Leaf and try connecting again.",
      tabTitle: "Leaf — error"
    )
  }

  /// Minimal HTML-escape for interpolated text (defense in depth — provider
  /// labels are hardcoded "Google"/"GitHub"/"Linear"/"Slack", but sanitize
  /// anyway so interpolation can't inject a broken page on future expansion).
  private static func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private enum CallbackPageKind { case success, cancelled, error }

  /// Stroke-only glyph for the status badge (single-quoted attrs so the SVG
  /// nests inside the Swift string literal without escaping).
  private static func iconPath(for kind: CallbackPageKind) -> String {
    switch kind {
    case .success: return "<path d='M5 12.6l4.3 4.3L19 7.2'/>"
    case .cancelled: return "<path d='M7 7l10 10M17 7L7 17'/>"
    case .error: return "<path d='M12 6.7v7'/><path d='M12 17.2h.02'/>"
    }
  }

  private static func kindClass(for kind: CallbackPageKind) -> String {
    switch kind {
    case .success: return "k-ok"
    case .cancelled: return "k-warn"
    case .error: return "k-error"
    }
  }

  private static func htmlPage(
    kind: CallbackPageKind,
    title: String,
    subtitle: String,
    tabTitle: String
  ) -> String {
    return """
      <!DOCTYPE html><html lang="en"><head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(tabTitle)</title>
      <style>\(callbackPageCSS)</style>
      </head>
      <body>
      <div class="wrap">
      <div class="card \(kindClass(for: kind))">
      <div class="badge"><svg viewBox="0 0 24 24" aria-hidden="true">\(iconPath(for: kind))</svg></div>
      <h1>\(title)</h1>
      <p class="sub">\(subtitle)</p>
      </div>
      <div class="foot"><img class="mark mark-light" src="\(leafMarkInk)" alt=""><img class="mark mark-dark" src="\(leafMarkWhite)" alt=""><b>Leaf</b> · leaf.gundem.tech</div>
      </div>
      </body></html>
      """
  }

  // Design tokens + layout, inline. Light by default, dark via
  // prefers-color-scheme; motion gated by prefers-reduced-motion.
  private static let callbackPageCSS = """
    :root{
    --canvas:#FAFAF9;--card:#FFFFFF;--text:#0C0A09;--muted:#787176;--faint:#A8A29E;
    --accent-sub:#DCFCE7;--accent-em:#16A34A;--warn:#D97706;--danger:#DC2626;--border:#E7E5E4;
    --font:-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text",Inter,sans-serif;
    --mono:"JetBrains Mono",ui-monospace,SFMono-Regular,Menlo,monospace;
    color-scheme:light dark;
    }
    @media (prefers-color-scheme:dark){:root{
    --canvas:#0A0A0B;--card:#131316;--text:#F4F4F7;--muted:#7E7E89;--faint:#595962;
    --accent-sub:#14532D;--accent-em:#86EFAC;--warn:#F59E0B;--danger:#EF4444;--border:#1D1D22;
    }}
    *{box-sizing:border-box;margin:0;padding:0}
    html,body{height:100%}
    body{background:var(--canvas);color:var(--text);font-family:var(--font);-webkit-font-smoothing:antialiased;display:flex;align-items:center;justify-content:center;min-height:100vh;padding:28px}
    .wrap{display:flex;flex-direction:column;align-items:center;gap:18px;width:100%;max-width:460px}
    .card{width:100%;max-width:440px;background:var(--card);border:1px solid var(--border);border-radius:16px;padding:44px 38px 38px;text-align:center;box-shadow:0 4px 14px rgba(0,0,0,.06);animation:rise .45s cubic-bezier(.2,0,0,1) both}
    .badge{width:64px;height:64px;border-radius:50%;display:grid;place-items:center;margin:0 auto 24px;background:var(--ib);animation:pop .55s .08s cubic-bezier(.18,.89,.32,1.28) both}
    .badge svg{width:30px;height:30px;stroke:var(--ic);stroke-width:2.6;fill:none;stroke-linecap:round;stroke-linejoin:round}
    .k-ok{--ic:var(--accent-em);--ib:var(--accent-sub)}
    .k-warn{--ic:var(--warn);--ib:color-mix(in srgb,var(--warn) 16%,transparent)}
    .k-error{--ic:var(--danger);--ib:color-mix(in srgb,var(--danger) 14%,transparent)}
    h1{font-size:21px;line-height:1.3;font-weight:600;letter-spacing:-.012em;color:var(--text)}
    .sub{margin-top:10px;font-size:15px;line-height:1.55;color:var(--muted)}
    .foot{display:inline-flex;align-items:center;gap:7px;font-family:var(--mono);font-size:11px;letter-spacing:.03em;color:var(--faint)}
    .foot img{width:13px;height:13px;opacity:.85}
    .foot b{font-family:var(--font);font-weight:600;letter-spacing:-.01em;color:var(--muted)}
    .mark-dark{display:none}
    @media (prefers-color-scheme:dark){.card{box-shadow:0 6px 20px rgba(0,0,0,.55)}.mark-light{display:none}.mark-dark{display:inline-block}}
    @keyframes rise{from{opacity:0;transform:translateY(12px)}to{opacity:1;transform:none}}
    @keyframes pop{0%{transform:scale(.6);opacity:0}60%{transform:scale(1.06)}100%{transform:scale(1)}}
    @media (prefers-reduced-motion:reduce){.card,.badge{animation:none}}
    """

  // Leaf mark, embedded so the page is self-contained. Ink mark for light
  // backgrounds, white mark for dark. Source PNGs (1x):
  // leaf-web/public/assets/logo/leaf-dark-1x.png and leaf-1x.png.
  private static let leafMarkInk =
    "data:image/png;base64,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"
  private static let leafMarkWhite =
    "data:image/png;base64,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"
}

/// Owns the single resume of `awaitCallback`'s continuation and the lifetime of
/// its `NWListener`.
///   * `settle` — success / parse-error / timeout / listener-failed: resume the
///     task once and retire the timeout backstop. Tears the listener down for a
///     normal finish; an app-cancelled flow keeps it for the grace timer so the
///     drain window survives.
///   * `cancelGracefully` — app-side cancel, dispatched onto the listener queue
///     so it is ordered against the connection/timeout handlers: flip the drain
///     flag (late redirects get the branded "cancelled" page) and schedule a
///     self-close after the grace window.
///   * `listenerDidCancel` — the `.cancelled` state (normal teardown / drain /
///     eviction): retire the grace timer and ensure the task resumed.
/// `continuation`/`settled`/timers are touched from both the queue and the
/// arming task, so an NSLock guards every field; the drain flag is additionally
/// serialized on the queue (cancelGracefully + all settle callers run there).
nonisolated private final class CallbackCoordinator: @unchecked Sendable {
  private let lock = NSLock()
  private let listener: NWListener
  private let port: UInt16
  private let queue: DispatchQueue
  private var continuation: CheckedContinuation<URLComponents, Error>?
  private var settled = false
  private var appCancelled = false
  private var timeoutItem: DispatchWorkItem?
  private var graceItem: DispatchWorkItem?

  init(listener: NWListener, port: UInt16, queue: DispatchQueue) {
    self.listener = listener
    self.port = port
    self.queue = queue
  }

  func arm(_ continuation: CheckedContinuation<URLComponents, Error>) {
    lock.lock()
    if settled {
      // A cancel (or terminal outcome) raced ahead of arming — resume now so the
      // continuation is never leaked. `.timeout` is the outcome every caller
      // already handles for an abandoned flow.
      lock.unlock()
      continuation.resume(throwing: LoopbackCallbackError.timeout)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  /// Schedule the no-callback timeout as a cancellable item, so a finished flow
  /// releases the coordinator (and its listener) at once rather than at the
  /// deadline.
  func startTimeout(afterMilliseconds ms: Int) {
    let item = DispatchWorkItem { [weak self] in
      self?.settle(.failure(LoopbackCallbackError.timeout))
    }
    lock.lock()
    timeoutItem = item
    lock.unlock()
    queue.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
  }

  var isAppCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return appCancelled
  }

  /// App-side cancel. MUST run on the listener `queue` (dispatched by onCancel)
  /// so the drain flag is set in order with the handlers that read it. Resumes
  /// the awaiting task promptly (as `.timeout`, which every caller already
  /// handles) so the abandoned flow doesn't linger until the timeout, while the
  /// listener lives on for the grace window to drain a late redirect, then
  /// self-closes.
  func cancelGracefully(graceMilliseconds ms: Int) {
    lock.lock()
    appCancelled = true
    let skip = settled || graceItem != nil
    lock.unlock()
    guard !skip else { return }
    let item = DispatchWorkItem { [weak self] in self?.closeListener() }
    lock.lock()
    graceItem = item
    lock.unlock()
    queue.asyncAfter(deadline: .now() + .milliseconds(ms), execute: item)
    // Resume the awaiting task now; `keepListenerForDrain` keeps the socket up.
    settle(.failure(LoopbackCallbackError.timeout))
  }

  /// Terminal outcome: resume the awaiting task at most once and retire the
  /// timeout backstop. Tears the listener down for a normal finish; an app-
  /// cancelled flow keeps it for the grace timer so the drain window survives.
  func settle(_ result: Result<URLComponents, Error>) {
    lock.lock()
    if settled {
      lock.unlock()
      return
    }
    settled = true
    let continuation = self.continuation
    self.continuation = nil
    let keepListenerForDrain = appCancelled
    let timeoutItem = self.timeoutItem
    self.timeoutItem = nil
    lock.unlock()
    timeoutItem?.cancel()
    if !keepListenerForDrain { closeListener() }
    continuation?.resume(with: result)
  }

  /// The listener reached `.cancelled` (normal teardown, drain, or eviction by a
  /// newer flow on this port). Retire the now-pointless grace timer and make
  /// sure the task is resumed (a no-op if it already was).
  func listenerDidCancel() {
    lock.lock()
    let graceItem = self.graceItem
    self.graceItem = nil
    lock.unlock()
    graceItem?.cancel()
    settle(.failure(LoopbackCallbackError.timeout))
  }

  /// Cancel + unregister the listener and retire the pending grace timer.
  /// Idempotent (NWListener.cancel and the identity-checked unregister both
  /// tolerate repeats); the resulting `.cancelled` state drives
  /// `listenerDidCancel`.
  func closeListener() {
    lock.lock()
    let graceItem = self.graceItem
    self.graceItem = nil
    lock.unlock()
    graceItem?.cancel()
    ListenerRegistry.shared.unregister(listener, port: port)
    listener.cancel()
  }
}

/// Tracks the live listener per loopback port so a fresh flow can evict a
/// lingering grace-listener (kept alive after an app-side cancel) and reclaim
/// the socket. Keyed by port — the fixed ports (Supabase 47825, Slack 47824)
/// are the ones that can collide on an immediate retry.
nonisolated private final class ListenerRegistry: @unchecked Sendable {
  static let shared = ListenerRegistry()
  private let lock = NSLock()
  private var byPort: [UInt16: NWListener] = [:]

  func register(_ listener: NWListener, port: UInt16) {
    lock.lock()
    let previous = byPort[port]
    byPort[port] = listener
    lock.unlock()
    previous?.cancel()  // evict the lingering grace-listener so we can rebind
  }

  func unregister(_ listener: NWListener, port: UInt16) {
    lock.lock()
    if byPort[port] === listener {
      byPort.removeValue(forKey: port)
    }
    lock.unlock()
  }
}
