enum CastProtocol { dlna, chromecast }

class DlnaDevice {
  final CastProtocol protocol;
  final String name;
  final String manufacturer;
  final String location;
  final String controlUrl;            // AVTransport control URL (DLNA only)
  final String? renderingControlUrl; // RenderingControl URL (DLNA only)
  // Chromecast-specific
  final String? chromecastHost;
  final int? chromecastPort;

  const DlnaDevice({
    this.protocol = CastProtocol.dlna,
    required this.name,
    required this.manufacturer,
    required this.location,
    required this.controlUrl,
    this.renderingControlUrl,
    this.chromecastHost,
    this.chromecastPort,
  });

  @override
  bool operator ==(Object other) => other is DlnaDevice && other.location == location;

  @override
  int get hashCode => location.hashCode;
}
