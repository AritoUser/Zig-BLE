//! # Bluetooth Security Manager Protocol (SMP) Engine
//!
//! Conforms strictly to Bluetooth Core Specification Vol 3, Part H.
//! Modularized into submodules under `smp/` for readability and maintainability.
const std = @import("std");

pub const types_mod = @import("smp/types.zig");
pub const pdu_mod = @import("smp/pdu.zig");
pub const ecdh_mod = @import("smp/ecdh.zig");
pub const state_machine_mod = @import("smp/state_machine.zig");

// Re-exports from types.zig
pub const SmpOpcode = types_mod.SmpOpcode;
pub const IoCapability = types_mod.IoCapability;
pub const AuthReq = types_mod.AuthReq;
pub const KeyDistribution = types_mod.KeyDistribution;
pub const PairingFailedReason = types_mod.PairingFailedReason;
pub const KeypressNotificationType = types_mod.KeypressNotificationType;
pub const SmpError = types_mod.SmpError;
pub const SMP_CID = types_mod.SMP_CID;
pub const SMP_TIMEOUT_MS = types_mod.SMP_TIMEOUT_MS;
pub const SmpRole = types_mod.SmpRole;
pub const PairingMethod = types_mod.PairingMethod;
pub const SmpState = types_mod.SmpState;

// Re-exports from pdu.zig
pub const Address = pdu_mod.Address;
pub const AddressType = pdu_mod.AddressType;
pub const PairingRequest = pdu_mod.PairingRequest;
pub const PairingResponse = pdu_mod.PairingResponse;
pub const PairingConfirm = pdu_mod.PairingConfirm;
pub const PairingRandom = pdu_mod.PairingRandom;
pub const PairingFailed = pdu_mod.PairingFailed;
pub const EncryptionInformation = pdu_mod.EncryptionInformation;
pub const MasterIdentification = pdu_mod.MasterIdentification;
pub const IdentityInformation = pdu_mod.IdentityInformation;
pub const IdentityAddressInformation = pdu_mod.IdentityAddressInformation;
pub const SigningInformation = pdu_mod.SigningInformation;
pub const SecurityRequest = pdu_mod.SecurityRequest;
pub const PairingPublicKey = pdu_mod.PairingPublicKey;
pub const PairingDhKeyCheck = pdu_mod.PairingDhKeyCheck;
pub const PairingKeypressNotification = pdu_mod.PairingKeypressNotification;
pub const SmpPdu = pdu_mod.SmpPdu;

// Re-exports from ecdh.zig
pub const EcdhKeyPair = ecdh_mod.EcdhKeyPair;
pub const generateEcdhKeyPair = ecdh_mod.generateEcdhKeyPair;
pub const computeDhKey = ecdh_mod.computeDhKey;
pub const selectPairingMethod = ecdh_mod.selectPairingMethod;

// Re-exports from state_machine.zig
pub const SmpStateMachine = state_machine_mod.SmpStateMachine;

test {
    _ = @import("smp/tests.zig");
}
