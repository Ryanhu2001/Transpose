import Foundation

func runResultPlacementChecks() throws -> Int {
    let size = CGSize(width: 390, height: 220)
    let display = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let regions = [
        CGRect(x: 80, y: 250, width: 440, height: 360),
        CGRect(x: 1000, y: 230, width: 400, height: 420),
        CGRect(x: 200, y: 280, width: 1100, height: 260),
        CGRect(x: 150, y: 20, width: 1100, height: 280)
    ]
    for region in regions {
        let result = ResultPlacement.frame(size: size, near: CGPoint(x: region.maxX, y: region.minY), avoiding: region, visibleFrame: display)
        guard display.insetBy(dx: 10, dy: 10).contains(result), !result.intersects(region) else {
            throw AppError.message("译文窗遮住圈选原文，或移出了屏幕。")
        }
    }
    let external = CGRect(x: -1920, y: -240, width: 1920, height: 1080)
    let region = CGRect(x: -1800, y: 100, width: 700, height: 400)
    let result = ResultPlacement.frame(size: size, near: CGPoint(x: region.maxX, y: region.minY), avoiding: region, visibleFrame: external)
    guard external.insetBy(dx: 10, dy: 10).contains(result), !result.intersects(region) else {
        throw AppError.message("副屏圈选的译文位置错误。")
    }
    let large = ResultPlacement.frame(size: CGSize(width: 390, height: 520), near: .zero,
                                      avoiding: display.insetBy(dx: 25, dy: 25), visibleFrame: display)
    guard display.insetBy(dx: 10, dy: 10).contains(large) else {
        throw AppError.message("接近全屏的圈选使译文移出屏幕。")
    }
    let start = CGRect(x: 100, y: 500, width: 400, height: 220)
    let minimum = CGSize(width: 310, height: 140)
    let enlarged = ResultWindowSizing.resizedFrame(start: start, delta: CGSize(width: 450, height: -400), minimum: minimum, visibleFrame: display)
    guard enlarged.size == CGSize(width: 850, height: 620), enlarged.minX == start.minX, enlarged.maxY == start.maxY else {
        throw AppError.message("拖动角标未按指针方向缩放，或改变了窗口左上角。")
    }
    let smallest = ResultWindowSizing.resizedFrame(start: start, delta: CGSize(width: -1000, height: 1000), minimum: minimum, visibleFrame: display)
    guard smallest.size == minimum else { throw AppError.message("译文窗口可被缩小到无法操作。") }
    let bounded = ResultWindowSizing.resizedFrame(start: start, delta: CGSize(width: 10000, height: -10000), minimum: minimum, visibleFrame: display)
    guard display.insetBy(dx: 10, dy: 10).contains(bounded) else { throw AppError.message("缩放角标使译文窗口超出屏幕。") }
    let externalStart = CGRect(x: -1600, y: 100, width: 400, height: 220)
    let externalResult = ResultWindowSizing.resizedFrame(start: externalStart, delta: CGSize(width: 500, height: -100), minimum: minimum, visibleFrame: external)
    guard externalResult.size == CGSize(width: 900, height: 320), externalResult.maxY == externalStart.maxY else {
        throw AppError.message("副屏缩放错误。")
    }
    let offscreenStarts = [CGRect(x: 1300, y: 500, width: 400, height: 220),
                           CGRect(x: 200, y: -120, width: 400, height: 220)]
    for offscreenStart in offscreenStarts {
        let recovered = ResultWindowSizing.resizedFrame(start: offscreenStart, delta: .zero, minimum: minimum, visibleFrame: display)
        guard recovered.width >= minimum.width, recovered.height >= minimum.height,
              display.insetBy(dx: 10, dy: 10).contains(recovered) else {
            throw AppError.message("屏幕边缘缩放使译文窗口小于可操作尺寸。")
        }
    }
    return 12
}
