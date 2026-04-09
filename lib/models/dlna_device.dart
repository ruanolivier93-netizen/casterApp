class DlnaDevice {
  final String name;
  final String manufacturer;
  final String location;
  final String controlUrl;            // AVTransport control URL
  final String? renderingControlUrl; // RenderingControl URL (volume)

  const DlnaDevice({
    required this.name,
    required this.manufacturer,
    required this.location,
    required this.controlUrl,
    this.renderingControlUrl,
  });

  @override
  bool operator ==(Object other) => other is DlnaDevice && other.location == location;

  @override
  int get hashCode => location.hashCode;
}
