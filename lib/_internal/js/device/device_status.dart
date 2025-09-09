enum DeviceState {
  destroyed,
  unregistered,
  registering,
  registered,
}

DeviceState parseDeviceState(String state) {
  final lower = state.toLowerCase();
  return DeviceState.values.firstWhere(
    (e) => e.name == lower,
    orElse: () => DeviceState.unregistered,
  );
}
