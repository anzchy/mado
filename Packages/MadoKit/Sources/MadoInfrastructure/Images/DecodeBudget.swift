import Foundation

public enum DecodeBudget {
    public static func bytesPerPixel(depth: Int, components: Int, hasAlpha: Bool, isFloat: Bool) -> Int {
        let bits = max(isFloat ? 32 : 1, min(64, depth))
        let channels = components >= 3 ? 4 : max(1, components) + (hasAlpha ? 1 : 0)
        let bytes = ((bits + 7) / 8) * channels
        return bits <= 8 ? max(4, bytes) : bytes
    }

    public static func sourceCost(width: Int, height: Int, budget: Int, bytesPerPixel: Int = 4) throws -> Int {
        let (row, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
        let (bytes, imageOverflow) = row.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, bytesPerPixel > 0, !rowOverflow, !imageOverflow, bytes <= budget else {
            throw ImageDecodeError.budgetExceeded
        }
        return bytes
    }
    /// Bounds ImageIO thumbnail output, including row alignment and either EXIF orientation.
    public static func outputCost(width: Int, height: Int, maximumPixelSize: Int, bytesPerPixel: Int, budget: Int) throws -> Int {
        _ = try sourceCost(width: width, height: height, budget: Int.max, bytesPerPixel: bytesPerPixel)
        guard maximumPixelSize > 0 else { throw ImageDecodeError.budgetExceeded }
        let scale = min(1, Double(maximumPixelSize) / Double(max(width, height)))
        let w = max(1, Int(ceil(Double(width) * scale))), h = max(1, Int(ceil(Double(height) * scale)))
        func aligned(_ width: Int, _ height: Int) throws -> Int {
            let (row, rowOverflow) = width.multipliedReportingOverflow(by: bytesPerPixel)
            let (rounded, roundOverflow) = row.addingReportingOverflow(63)
            let (bytes, overflow) = ((rounded / 64) * 64).multipliedReportingOverflow(by: height)
            guard !rowOverflow, !roundOverflow, !overflow, bytes <= budget else { throw ImageDecodeError.budgetExceeded }
            return bytes
        }
        return max(try aligned(w, h), try aligned(h, w))
    }
    public static func isHeavy(width: Int, height: Int) -> Bool {
        // Division avoids multiplying untrusted header dimensions.
        width > 0 && height > 0 && width > 12_000_000 / height
    }
}
