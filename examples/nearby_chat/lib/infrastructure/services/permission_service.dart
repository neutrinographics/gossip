import 'package:permission_handler/permission_handler.dart';

/// Service for handling runtime permissions for Nearby Connections.
class PermissionService {
  /// Requests all permissions needed for Nearby Connections.
  ///
  /// Returns true if all permissions are granted, false otherwise.
  Future<bool> requestNearbyPermissions() async {
    // Request all required permissions for Nearby Connections
    final statuses = await [
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
      Permission.bluetoothScan,
      Permission.nearbyWifiDevices,
      Permission.locationWhenInUse,
    ].request();

    // Check if all permissions are granted
    final allGranted = statuses.values.every(
      (status) => status.isGranted || status.isLimited,
    );

    return allGranted;
  }

  /// Checks if all necessary permissions are already granted.
  Future<bool> hasNearbyPermissions() async {
    final bluetoothAdvertise = await Permission.bluetoothAdvertise.status;
    final bluetoothConnect = await Permission.bluetoothConnect.status;
    final bluetoothScan = await Permission.bluetoothScan.status;
    final nearbyWifi = await Permission.nearbyWifiDevices.status;
    final location = await Permission.locationWhenInUse.status;

    return (bluetoothAdvertise.isGranted || bluetoothAdvertise.isLimited) &&
        (bluetoothConnect.isGranted || bluetoothConnect.isLimited) &&
        (bluetoothScan.isGranted || bluetoothScan.isLimited) &&
        (nearbyWifi.isGranted || nearbyWifi.isLimited) &&
        (location.isGranted || location.isLimited);
  }

  /// Opens app settings if permissions were permanently denied.
  Future<void> openAppSettings() async {
    await openAppSettings();
  }
}
