//! # Bluetooth Low Energy (BLE) Cryptography & Security Manager
//!
//! Compliant with Bluetooth Core Specification v5.4 / v6.0, Vol 3, Part H.
//!
//! Submodules:
//! - `toolbox`: AES-128, AES-CMAC, RPA resolution/generation (`ah`), confirm (`c1`, `f4`),
//!   key generation (`s1`, `f5`), check (`f6`), numeric comparison (`g2`), link key conversion (`h6`),
//!   ATT signature (`signAtt`, `verifyAttSign`), GATT database hash (`gattHash`), and CSIP RSI (`sih`, `generateRsi`).
//! - `smp`: Security Manager Protocol (SMP) PDU definitions, zero-copy parsers, and serializers (L2CAP CID 0x0006).

pub const toolbox = @import("toolbox.zig");
pub const smp = @import("smp.zig");

// Direct re-exports of common toolbox functions
pub const e = toolbox.e;
pub const eBe = toolbox.eBe;
pub const ahBe = toolbox.ahBe;
pub const ahLe = toolbox.ahLe;
pub const resolveRpa = toolbox.resolveRpa;
pub const generateRpa = toolbox.generateRpa;
pub const c1 = toolbox.c1;
pub const s1 = toolbox.s1;
pub const f4 = toolbox.f4;
pub const f5 = toolbox.f5;
pub const f6 = toolbox.f6;
pub const g2 = toolbox.g2;
pub const h6 = toolbox.h6;
pub const signAtt = toolbox.signAtt;
pub const verifyAttSign = toolbox.verifyAttSign;
pub const gattHash = toolbox.gattHash;
pub const sih = toolbox.sih;
pub const generateRsi = toolbox.generateRsi;

// Direct re-exports of common SMP types
pub const SmpOpcode = smp.SmpOpcode;
pub const IoCapability = smp.IoCapability;
pub const AuthReq = smp.AuthReq;
pub const KeyDistribution = smp.KeyDistribution;
pub const PairingFailedReason = smp.PairingFailedReason;
pub const KeypressNotificationType = smp.KeypressNotificationType;
pub const SmpPdu = smp.SmpPdu;
pub const PairingRequest = smp.PairingRequest;
pub const PairingResponse = smp.PairingResponse;
pub const PairingConfirm = smp.PairingConfirm;
pub const PairingRandom = smp.PairingRandom;
pub const PairingFailed = smp.PairingFailed;
pub const EncryptionInformation = smp.EncryptionInformation;
pub const MasterIdentification = smp.MasterIdentification;
pub const IdentityInformation = smp.IdentityInformation;
pub const IdentityAddressInformation = smp.IdentityAddressInformation;
pub const SigningInformation = smp.SigningInformation;
pub const SecurityRequest = smp.SecurityRequest;
pub const PairingPublicKey = smp.PairingPublicKey;
pub const PairingDhKeyCheck = smp.PairingDhKeyCheck;
pub const PairingKeypressNotification = smp.PairingKeypressNotification;

test {
    _ = toolbox;
    _ = smp;
}
