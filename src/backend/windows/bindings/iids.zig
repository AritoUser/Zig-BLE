//! # Core WinRT & Bluetooth Interface GUIDs (Windows 10 SDK 10.0.19041.0)
const GUID = @import("types.zig").GUID;

pub const IID_IUnknown = GUID.parse("00000000-0000-0000-c000-000000000046");
pub const IID_IInspectable = GUID.parse("af86e2e0-b12d-4c6a-9c5a-d7aa65101e90");
pub const IID_IAgileObject = GUID.parse("94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90");
pub const IID_IActivationFactory = GUID.parse("00000035-0000-0000-c000-000000000046");
pub const IID_IAsyncInfo = GUID.parse("00000036-0000-0000-c000-000000000046");
pub const IID_IClosable = GUID.parse("30d5a829-7fa4-4026-83bb-d75bae4ea99e");
pub const IID_IDeferral = GUID.parse("d6269732-3b7f-46a7-b40b-4fdca2a2c693");

// BluetoothAdapter
pub const IID_IBluetoothAdapterStatics = GUID.parse("8b02fb6a-ac4c-4741-8661-8eab7d17ea9f");
pub const IID_IBluetoothAdapter = GUID.parse("7974f04c-5f7a-4a34-9225-a855f84b1a8b");

// BluetoothLEAdvertisementWatcher & Args
pub const IID_IBluetoothLEAdvertisementWatcher = GUID.parse("a6ac336f-f3d3-4297-8d6c-c81ea6623f40");
pub const IID_IBluetoothLEAdvertisementReceivedEventArgs = GUID.parse("27987ddf-e596-41be-8d43-9e6731d4a913");
pub const IID_IBluetoothLEAdvertisement = GUID.parse("066fb2b7-33d1-4e7d-8367-cf81d0f79653");
pub const IID_IBluetoothLEAdvertisementReceivedEventArgs2 = GUID.parse("12d9c87b-0399-5f0e-a348-53b02b6b162e");
pub const IID_IPropertyValue = GUID.parse("4bd682dd-7554-40e9-9a9b-82654ede7e62");
pub const IID_IBluetoothLEManufacturerData = GUID.parse("912dba18-6963-4533-b061-4694dafb34e5");
pub const IID_IBluetoothLEManufacturerDataFactory = GUID.parse("c09b39f8-319a-441e-8de5-66a81e877a6c");
pub const IID_IBluetoothLEAdvertisementDataSection = GUID.parse("d7213314-3a43-40f9-b6f0-92bfefc34ae3");
pub const IID_IBluetoothLEAdvertisementDataSectionFactory = GUID.parse("e7a40942-a845-4045-bf7e-3e9971db8a6b");
pub const IID_IBluetoothLEAdvertisementPublisher = GUID.parse("cde820f9-d9fa-43d6-a264-ddd8b7da8b78");
pub const IID_IBluetoothLEAdvertisementPublisherFactory = GUID.parse("5c5f065e-b863-4981-a1af-1c544d8b0c0d");
pub const IID_ITypedEventHandler_Watcher_Received = GUID.parse("90eb4eca-d465-5ea0-a61c-033c8c5ecef2");

// BluetoothLEDevice & GattSession
pub const IID_IBluetoothLEDeviceStatics = GUID.parse("c8cf1a19-f0b6-4bf0-8689-41303de2d9f4");
pub const IID_IBluetoothLEDeviceStatics2 = GUID.parse("5f12c06b-3bac-43e8-ad16-563271bd41c2");
pub const IID_IBluetoothLEDevice = GUID.parse("b5ee2f7b-4ad8-4642-ac48-80a0b500e887");
pub const IID_IBluetoothLEDevice2 = GUID.parse("26f062b3-7aee-4d31-baba-b1b9775f5916");
pub const IID_IBluetoothLEDevice3 = GUID.parse("aee9e493-44ac-40dc-af33-b2c13c01ca46");
pub const IID_IBluetoothLEDevice4 = GUID.parse("2b605031-2248-4b2f-acf0-7cee36fc5870");
pub const IID_IBluetoothDeviceId = GUID.parse("c17949af-57c1-4642-bcce-e6c06b20ae76");
pub const IID_IBluetoothDeviceIdStatics = GUID.parse("a7884e67-3efb-4f31-bbc2-810e09977404");
pub const IID_IGattSession = GUID.parse("d23b5143-e04e-4c24-999c-9c256f9856b1");
pub const IID_IGattSessionStatics = GUID.parse("2e65b95c-539f-4db7-82a8-73bdbbf73ebf");
pub const IID_ITypedEventHandler_BluetoothLEDevice_IInspectable = GUID.parse("a90661e2-372e-5d1e-bbbb-b8a2ce0e7c4d");

// DeviceInformation & Pairing (Windows.Devices.Enumeration)
pub const IID_IDeviceInformation = GUID.parse("aba0fb95-4398-489d-8e44-e6130927011f");
pub const IID_IDeviceInformation2 = GUID.parse("f156a638-7997-48d9-a10c-269d46533f48");
pub const IID_IDeviceInformationPairing = GUID.parse("2c4769f5-f684-40d5-8469-e8dbaab70485");
pub const IID_IDeviceInformationPairing2 = GUID.parse("f68612fd-0aee-4328-85cc-1c742bb1790d");
pub const IID_IDeviceInformationCustomPairing = GUID.parse("85138c02-4ee6-4914-8370-107a39144c0e");
pub const IID_IDevicePairingRequestedEventArgs = GUID.parse("f717fc56-de6b-487f-8376-0180aca69963");
pub const IID_IDevicePairingResult = GUID.parse("072b02bf-dd95-4025-9b37-de51adba37b7");
pub const IID_IDeviceUnpairingResult = GUID.parse("66f44ad3-79d9-444b-92cf-a92ef72571c7");
pub const IID_ITypedEventHandler_CustomPairing_PairingRequested = GUID.parse("fa65231f-4178-5de1-b2cc-03e22d7702b4");

// GATT Client Services & Characteristics
pub const IID_IGattDeviceServicesResult = GUID.parse("171dd3ee-016d-419d-838a-576cf475a3d8");
pub const IID_IGattDeviceService = GUID.parse("ac7b7c05-b33c-47cf-990f-6b8f5577df71");
pub const IID_IGattDeviceService3 = GUID.parse("b293a950-0c53-437c-a9b3-5c3210c6e569");
pub const IID_IGattCharacteristicsResult = GUID.parse("1194945c-b257-4f3e-9db7-f68bc9a9aef2");
pub const IID_IGattCharacteristic = GUID.parse("59cb50c1-5934-4f68-a198-eb864fa44e6b");
pub const IID_IGattCharacteristic3 = GUID.parse("3f3c663e-93d4-406b-b817-db81f8ed53b3");
pub const IID_IGattDescriptorsResult = GUID.parse("9bc091f3-95e7-4489-8d25-ff81955a57b9");
pub const IID_IGattDescriptor = GUID.parse("92055f2b-8084-4344-b4c2-284de19a8506");
pub const IID_IGattReadResult2 = GUID.parse("a10f50a0-fb43-48af-baaa-638a5c6329fe");
pub const IID_IGattReadResult = GUID.parse("63a66f08-1aea-4c4c-a50f-97bae474b348");
pub const IID_IGattWriteResult = GUID.parse("4991ddb1-cb2b-44f7-99fc-d29a2871dc9b");
pub const IID_IGattValueChangedEventArgs = GUID.parse("d21bdb54-06e3-4ed8-a263-acfac8ba7313");
pub const IID_ITypedEventHandler_Characteristic_ValueChanged = GUID.parse("c1f420f6-6292-5760-a2c9-9ddf98683cfc");

// GATT Server (GattServiceProvider, IGattLocalService, IGattLocalCharacteristic)
pub const IID_IGattServiceProvider = GUID.parse("7822b3cd-2889-4f86-a051-3f0aed1c2760");
pub const IID_IGattServiceProviderStatics = GUID.parse("31794063-5256-4054-a4f4-7bbe7755a57e");
pub const IID_IGattServiceProviderResult = GUID.parse("764696d8-c53e-428c-8a48-67afe02c3ae6");
pub const IID_IGattServiceProviderAdvertisingParameters = GUID.parse("e2ce31ab-6315-4c22-9bd7-781dbc3d8d82");
pub const IID_IGattLocalService = GUID.parse("f513e258-f7f7-4902-b803-57fcc7d6fe83");
pub const IID_IGattLocalCharacteristic = GUID.parse("aede376d-5412-4d74-92a8-8deb8526829c");
pub const IID_IGattLocalCharacteristicParameters = GUID.parse("faf73db4-4cff-44c7-8445-040e6ead0063");
pub const IID_IGattLocalCharacteristicResult = GUID.parse("7975de9b-0170-4397-9666-92f863f12ee6");
pub const IID_IGattReadRequestedEventArgs = GUID.parse("93497243-f39c-484b-8ab6-996ba486cfa3");
pub const IID_IGattReadRequest = GUID.parse("f1dd6535-6acd-42a6-a4bb-d789dae0043e");
pub const IID_IGattWriteRequestedEventArgs = GUID.parse("2dec8bbe-a73a-471a-94d5-037deadd0806");
pub const IID_IGattWriteRequest = GUID.parse("aeb6a9ed-de2f-4fc2-a9a8-94ea7844f13d");
pub const IID_ITypedEventHandler_GattLocalCharacteristic_ReadRequested = GUID.parse("218a3e4a-aa9d-500e-bca7-047751bb10a3");
pub const IID_ITypedEventHandler_GattLocalCharacteristic_WriteRequested = GUID.parse("ed61a2fb-7d2a-5ba3-8ebf-8ad878e539a9");

// Storage Streams (IBuffer & CryptographicBuffer)
pub const IID_IBuffer = GUID.parse("905a0fe0-bc53-11df-8c49-001e4fc686da");
pub const IID_IBufferByteAccess = GUID.parse("905a0fef-bc53-11df-8c49-001e4fc686da");
pub const IID_ICryptographicBufferStatics = GUID.parse("320b7e22-3cb0-4cdf-8663-1d28910065eb");

