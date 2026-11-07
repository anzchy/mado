import MadoApplication

extension ViewerImageFailure {
    public var messageKey: String {
        switch self {
        case .corruptImage: "The file may be damaged or its format unreadable."
        case .unsupportedFormat: "This image format is not supported."
        case .resourceLimit: "This image exceeds the available resources."
        case .sourceChanged: "The file changed again while it was being opened."
        case .access: "Access to this image is unavailable."
        }
    }
}
