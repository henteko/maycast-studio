import Foundation

public enum MaycastIPC {
    public static let version = "0.0.1"

    /// Marker line that child services print on stdout immediately after starting,
    /// containing a base64-encoded NSXPCListenerEndpoint.
    public static let endpointMarker = "MAYCAST_ENDPOINT:"
}
