import Foundation
import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
import AppKit

struct Slide {
    let imagePath: String?
    let badge: String
    let title: String
    let subtitle: String
    let caption: String
    let durationSec: Double
}

let args = CommandLine.arguments
let framesDir = args.count > 1 ? args[1] : "demo-frames"
let outPath = args.count > 2 ? args[2] : "demo-frames/demo.mp4"

let slides: [Slide] = [
    Slide(
        imagePath: nil,
        badge: "HSK CHAIN HORIZON HACKATHON · SEOUL · TRACK 1: AI AGENT TRADING",
        title: "SpreadPilot HSK",
        subtitle: "Cross-Venue CEX ↔ HSKSwap Spread Arbitrage, Liquidity-Aware TWAP Splitter & Conversational Risk-Rail Agent",
        caption: "Live HSK Mainnet 177 Pools · Deployed on HSKChain Testnet 133 · 24/24 Foundry Tests (1,536 Fuzz Runs)",
        durationSec: 5.0
    ),
    Slide(
        imagePath: "\(framesDir)/01-dashboard-live.png",
        badge: "01 · LIVE HSK MAINNET (177) & TESTNET (133) TELEMETRY + CEX SPREAD MATRIX",
        title: "Real-Time HSKSwap V3 Pool Reads vs Gate.io & Binance Spot",
        subtitle: "Detects live WHSK/USDT 0.05% vs 0.30% inter-pool & CEX dislocations and sizes TWAP slices to preserve edge",
        caption: "Zero mock feeds · Direct eth_call slot0()/liquidity() on HSK Mainnet + live Testnet 133 vault receipts on right",
        durationSec: 9.0
    ),
    Slide(
        imagePath: "\(framesDir)/02-conservative-rails.png",
        badge: "02 · CONVERSATIONAL AI POLICY COPILOT -> ON-CHAIN RISK RAILS",
        title: "Natural Language Updates Max Slice, Cooldown & Stop-Loss Atomically",
        subtitle: "\"Switch to conservative, cap slice $120, cooldown 45s, stop-loss 2.5%\" emits Before -> After Diff & ABI Calldata",
        caption: "Anchored on-chain via updatePolicy(policy, chatIntentHash) · Verified live TX 0x809f674a...e97d305f on HSK 133",
        durationSec: 9.5
    ),
    Slide(
        imagePath: "\(framesDir)/03-twap-staged.png",
        badge: "03 · LIQUIDITY-AWARE TWAP SPLITTING & AUTONOMOUS SLICE EXECUTION",
        title: "Splits $450 WHSK Into Optimal Slices — Saving Thin-Pool Price Impact",
        subtitle: "HSKSwapLiquidityLens computes single-shot vs TWAP impact and executes Slice #1 while updating live positions & PnL",
        caption: "Live HSK Testnet 133 proof: 2 slices executed (+3.9975 tUSDT edge, 1,372 bps cumulative impact saved)",
        durationSec: 9.5
    ),
    Slide(
        imagePath: "\(framesDir)/04-allowlist-refusal.png",
        badge: "04 · TARGET ASSET ALLOWLIST & VERIFIABLE ON-CHAIN REFUSAL PROOFS",
        title: "Restricts Assets to WHSK & WETH Only — Logs Cryptographic Refusal on WBTC",
        subtitle: "When WBTC is disabled or spread falls below minNetEdgeBps, SpreadPilot refuses safely without moving funds",
        caption: "On-chain logRefusedOpportunity() proof live on HSK 133: 0xc3faa789...deeb161a (REFUSAL_SPREAD_BELOW_MIN)",
        durationSec: 9.5
    ),
    Slide(
        imagePath: "\(framesDir)/05-breaker-tripped.png",
        badge: "05 · AUTOMATIC MARK-TO-MARKET STOP-LOSS CIRCUIT BREAKER",
        title: "Drawdown Shock Trips On-Chain Circuit Breaker & Freezes Active TWAPs",
        subtitle: "reportMarkToMarketAndCheckStopLoss() locks agent execution immediately; owner retains unconditional withdraw()",
        caption: "Live HSK 133 TX 0x130ad06a...07182e5d tripped breaker -> Slice #3 blocked & proven on-chain (0xe7dcf09d...)",
        durationSec: 9.5
    ),
    Slide(
        imagePath: "\(framesDir)/06-owner-reset-armed.png",
        badge: "06 · NON-CUSTODIAL OWNER RECOVERY & LIVE TESTNET EXPLORER AUDIT TRAIL",
        title: "Only Portfolio Owner Can Reset Circuit Breaker & Re-Anchor HWM",
        subtitle: "Every policy change, TWAP slice, refusal proof & breaker event links directly to HSKChain Testnet Blockscout",
        caption: "Vault 0xA681677D5c9142751682D384a92eA9c125782A51 · Lens 0xfF1E8e50...7edA · 9 confirmed E2E TXs",
        durationSec: 9.0
    ),
    Slide(
        imagePath: nil,
        badge: "SPREADPILOT HSK · OPEN-SOURCE MIT · HSK CHAIN TESTNET 133 LIVE",
        title: "Scan. Split. Protect On-Chain.",
        subtitle: "24/24 Foundry Tests (1,536 Fuzz Runs, 0 Warnings) · 5/5 Vitest · 0 Browser Console Errors",
        caption: "GitHub: z121245017-ai/spreadpilot-hsk  |  Live Desk: z121245017-ai.github.io/spreadpilot-hsk",
        durationSec: 5.0
    )
]

let width = 1280
let height = 720
let fps: Int32 = 30

func loadImage(_ path: String) -> CGImage? {
    let url = URL(fileURLWithPath: path)
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

func drawText(_ ctx: CGContext, text: String, rect: CGRect, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor, align: NSTextAlignment = .center, mono: Bool = false) {
    let font: NSFont = mono
        ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: weight)
        : NSFont.systemFont(ofSize: fontSize, weight: weight)
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.lineBreakMode = .byWordWrapping
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
    let nsStr = NSAttributedString(string: text, attributes: attrs)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    nsStr.draw(in: rect)
    NSGraphicsContext.restoreGraphicsState()
}

func renderSlideBuffer(_ slide: Slide, pool: CVPixelBufferPool) -> CVPixelBuffer? {
    var pbOut: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return nil }
    CVPixelBufferLockBaseAddress(pb, [])
    defer { CVPixelBufferUnlockBaseAddress(pb, []) }
    guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
    let bpr = CVPixelBufferGetBytesPerRow(pb)
    guard let ctx = CGContext(
        data: base, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bpr,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    ) else { return nil }

    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)

    // Obsidian background (#070b10)
    ctx.setFillColor(NSColor(red: 0.027, green: 0.043, blue: 0.063, alpha: 1.0).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Top emerald/cyan accent bar
    ctx.setFillColor(NSColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 0.95).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: 4))
    ctx.setFillColor(NSColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.95).cgColor)
    ctx.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: 4))

    let emerald = NSColor(red: 0.204, green: 0.827, blue: 0.600, alpha: 1.0)
    let cyan = NSColor(red: 0.490, green: 0.827, blue: 0.988, alpha: 1.0)
    let whiteSoft = NSColor(red: 0.920, green: 0.945, blue: 0.975, alpha: 1.0)
    let muted = NSColor(red: 0.555, green: 0.630, blue: 0.720, alpha: 1.0)

    if let imgPath = slide.imagePath, let cgImg = loadImage(imgPath) {
        drawText(ctx, text: slide.badge, rect: CGRect(x: 40, y: 18, width: 1200, height: 22), fontSize: 13, weight: .bold, color: cyan, mono: true)
        drawText(ctx, text: slide.title, rect: CGRect(x: 40, y: 42, width: 1200, height: 34), fontSize: 24, weight: .bold, color: whiteSoft)
        drawText(ctx, text: slide.subtitle, rect: CGRect(x: 50, y: 78, width: 1180, height: 26), fontSize: 14.5, weight: .regular, color: muted)

        let aspect = CGFloat(cgImg.width) / CGFloat(max(1, cgImg.height))
        let maxH: CGFloat = 516
        let maxW: CGFloat = 1140
        var drawW = maxH * aspect
        var drawH = maxH
        if drawW > maxW { drawW = maxW; drawH = maxW / aspect }
        let frameRect = CGRect(x: (CGFloat(width) - drawW) / 2, y: 114 + (maxH - drawH) / 2, width: drawW, height: drawH)

        let bezel = frameRect.insetBy(dx: -8, dy: -8)
        ctx.setFillColor(NSColor(red: 0.045, green: 0.075, blue: 0.110, alpha: 1.0).cgColor)
        ctx.fill(bezel)
        ctx.setStrokeColor(NSColor(red: 0.220, green: 0.741, blue: 0.973, alpha: 0.50).cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(bezel)

        ctx.saveGState()
        ctx.translateBy(x: frameRect.origin.x, y: frameRect.origin.y + frameRect.size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(cgImg, in: CGRect(origin: .zero, size: frameRect.size))
        ctx.restoreGState()

        ctx.setFillColor(NSColor(red: 0.055, green: 0.095, blue: 0.135, alpha: 1.0).cgColor)
        ctx.fill(CGRect(x: 40, y: 650, width: 1200, height: 48))
        ctx.setStrokeColor(NSColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 0.55).cgColor)
        ctx.setLineWidth(1.0)
        ctx.stroke(CGRect(x: 40, y: 650, width: 1200, height: 48))
        drawText(ctx, text: slide.caption, rect: CGRect(x: 56, y: 663, width: 1168, height: 26), fontSize: 14.5, weight: .semibold, color: emerald, mono: true)
    } else {
        let box = CGRect(x: 90, y: 140, width: 1100, height: 440)
        ctx.setFillColor(NSColor(red: 0.051, green: 0.078, blue: 0.114, alpha: 1.0).cgColor)
        ctx.fill(box)
        ctx.setStrokeColor(NSColor(red: 0.063, green: 0.725, blue: 0.506, alpha: 0.65).cgColor)
        ctx.setLineWidth(2.0)
        ctx.stroke(box)
        drawText(ctx, text: slide.badge, rect: CGRect(x: 120, y: 196, width: 1040, height: 28), fontSize: 15, weight: .bold, color: cyan, mono: true)
        drawText(ctx, text: slide.title, rect: CGRect(x: 120, y: 252, width: 1040, height: 76), fontSize: 56, weight: .bold, color: whiteSoft)
        drawText(ctx, text: slide.subtitle, rect: CGRect(x: 130, y: 348, width: 1020, height: 72), fontSize: 21, weight: .medium, color: muted)
        drawText(ctx, text: slide.caption, rect: CGRect(x: 120, y: 468, width: 1040, height: 44), fontSize: 15.5, weight: .semibold, color: emerald, mono: true)
    }
    return pb
}

let outURL = URL(fileURLWithPath: outPath)
try? FileManager.default.removeItem(at: outURL)
let writer = try AVAssetWriter(outputURL: outURL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 2_800_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
        AVVideoMaxKeyFrameIntervalKey: 60
    ]
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)
guard let pool = adaptor.pixelBufferPool else { fatalError("No pool") }

var currentFrame: Int64 = 0
for slide in slides {
    guard let pb = renderSlideBuffer(slide, pool: pool) else { fatalError("Render failed: \(slide.title)") }
    let count = Int64(slide.durationSec * Double(fps))
    var offset: Int64 = 0
    while offset < count {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        adaptor.append(pb, withPresentationTime: CMTime(value: currentFrame + offset, timescale: fps))
        offset += 15
    }
    currentFrame += count
}
if let last = slides.last, let pb = renderSlideBuffer(last, pool: pool) {
    while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
    adaptor.append(pb, withPresentationTime: CMTime(value: currentFrame, timescale: fps))
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()
if writer.status == .completed {
    let bytes = (try FileManager.default.attributesOfItem(atPath: outPath)[.size] as? Int64) ?? 0
    print(String(format: "Rendered demo video: %@ (%.1fs, %lld bytes)", outPath, Double(currentFrame) / Double(fps), bytes))
} else {
    fatalError("Writer failed: \(String(describing: writer.error))")
}
