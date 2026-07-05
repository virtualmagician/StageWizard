import CoreGraphics

/// Maps a Vision-normalized point (0…1, bottom-left origin, in capture-buffer
/// space) to layer-local coordinates, honoring how the frame is drawn into
/// the layer (fit letterboxes, fill crops, stretch distorts). macOS layers
/// are bottom-left origin, so no vertical flip is needed.
public func mapNormalizedPoint(
    _ point: CGPoint,
    bufferSize: CGSize,
    layerSize: CGSize,
    fillMode: FillMode
) -> CGPoint {
    guard bufferSize.width > 0, bufferSize.height > 0,
          layerSize.width > 0, layerSize.height > 0 else { return .zero }

    switch fillMode {
    case .stretch:
        return CGPoint(x: point.x * layerSize.width, y: point.y * layerSize.height)
    case .fit, .fill:
        let scaleX = layerSize.width / bufferSize.width
        let scaleY = layerSize.height / bufferSize.height
        let scale = fillMode == .fit ? min(scaleX, scaleY) : max(scaleX, scaleY)
        let drawnWidth = bufferSize.width * scale
        let drawnHeight = bufferSize.height * scale
        let originX = (layerSize.width - drawnWidth) / 2
        let originY = (layerSize.height - drawnHeight) / 2
        return CGPoint(
            x: originX + point.x * drawnWidth,
            y: originY + point.y * drawnHeight
        )
    }
}
