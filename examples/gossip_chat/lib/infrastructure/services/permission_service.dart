import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Service for handling runtime permissions for Nearby Connections.
class PermissionService {
  /// Requests all permissions needed for Nearby Connections.
  ///
  /// Returns true if all permissions are granted, false otherwise.
  Future<bool> requestNearbyPermissions() async {
    // iOS and Android have different permission requirements
    // Note: On Android 12+ with BLUETOOTH_SCAN declared with neverForLocation,
    // location permission is not required for BLE scanning.
    final permissions = Platform.isIOS
        ? [Permission.bluetooth, Permission.locationWhenInUse]
        : [
            Permission.bluetoothAdvertise,
            Permission.bluetoothConnect,
            Permission.bluetoothScan,
            Permission.nearbyWifiDevices,
          ];

    // Request all required permissions for Nearby Connections
    final statuses = await permissions.request();

    // Log each permission status for debugging
    for (final entry in statuses.entries) {
      debugPrint('Permission ${entry.key}: ${entry.value}');
    }

    // Check if all permissions are granted
    final allGranted = statuses.values.every(
      (status) => status.isGranted || status.isLimited,
    );

    debugPrint('All permissions granted: $allGranted');
    return allGranted;
  }

  /// Checks if all necessary permissions are already granted.
  Future<bool> hasNearbyPermissions() async {
    if (Platform.isIOS) {
      final bluetooth = await Permission.bluetooth.status;
      final location = await Permission.locationWhenInUse.status;
      return (bluetooth.isGranted || bluetooth.isLimited) &&
          (location.isGranted || location.isLimited);
    } else {
      final bluetoothAdvertise = await Permission.bluetoothAdvertise.status;
      final bluetoothConnect = await Permission.bluetoothConnect.status;
      final bluetoothScan = await Permission.bluetoothScan.status;
      final nearbyWifi = await Permission.nearbyWifiDevices.status;

      return (bluetoothAdvertise.isGranted || bluetoothAdvertise.isLimited) &&
          (bluetoothConnect.isGranted || bluetoothConnect.isLimited) &&
          (bluetoothScan.isGranted || bluetoothScan.isLimited) &&
          (nearbyWifi.isGranted || nearbyWifi.isLimited);
    }
  }

  /// Opens app settings if permissions were permanently denied.
  Future<void> openSettings() async {
    await openAppSettings();
  }

  /// Requests camera permission for QR code scanning.
  ///
  /// Returns true if permission is granted, false otherwise.
  Future<bool> requestCameraPermission() async {
    final status = await Permission.camera.request();
    debugPrint('Permission camera: $status');
    return status.isGranted || status.isLimited;
  }

  /// Checks if camera permission is already granted.
  Future<bool> hasCameraPermission() async {
    final status = await Permission.camera.status;
    return status.isGranted || status.isLimited;
  }
}
