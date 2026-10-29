//! # Bluetooth Attribute Protocol (ATT) Engine
//!
//! Strictly conforms to the Bluetooth Core Specification (v5.4 / v6.0), Volume 3, Part F.
//! Modularized into submodules under `att/` for readability and maintainability.
const std = @import("std");

pub const types_mod = @import("att/types.zig");
pub const pdu_mod = @import("att/pdu.zig");
pub const bearer_mod = @import("att/bearer.zig");
pub const client_mod = @import("att/client.zig");

// Re-exports from types.zig
pub const AttErrorCode = types_mod.AttErrorCode;
pub const AttOpcode = types_mod.AttOpcode;
pub const AttError = types_mod.AttError;

// Re-exports from pdu.zig
pub const ErrorResponse = pdu_mod.ErrorResponse;
pub const ExchangeMtuRequest = pdu_mod.ExchangeMtuRequest;
pub const ExchangeMtuResponse = pdu_mod.ExchangeMtuResponse;
pub const FindInformationRequest = pdu_mod.FindInformationRequest;
pub const FindInformationResponse = pdu_mod.FindInformationResponse;
pub const FindByTypeValueRequest = pdu_mod.FindByTypeValueRequest;
pub const FindByTypeValueResponse = pdu_mod.FindByTypeValueResponse;
pub const ReadByTypeRequest = pdu_mod.ReadByTypeRequest;
pub const ReadByTypeResponse = pdu_mod.ReadByTypeResponse;
pub const ReadRequest = pdu_mod.ReadRequest;
pub const ReadResponse = pdu_mod.ReadResponse;
pub const ReadBlobRequest = pdu_mod.ReadBlobRequest;
pub const ReadBlobResponse = pdu_mod.ReadBlobResponse;
pub const ReadByGroupTypeRequest = pdu_mod.ReadByGroupTypeRequest;
pub const ReadByGroupTypeResponse = pdu_mod.ReadByGroupTypeResponse;
pub const WriteRequest = pdu_mod.WriteRequest;
pub const WriteResponse = pdu_mod.WriteResponse;
pub const WriteCommand = pdu_mod.WriteCommand;
pub const PrepareWriteRequest = pdu_mod.PrepareWriteRequest;
pub const ExecuteWriteRequest = pdu_mod.ExecuteWriteRequest;
pub const PrepareWriteResponse = pdu_mod.PrepareWriteResponse;
pub const ExecuteWriteResponse = pdu_mod.ExecuteWriteResponse;
pub const ReadMultipleRequest = pdu_mod.ReadMultipleRequest;
pub const ReadMultipleResponse = pdu_mod.ReadMultipleResponse;
pub const SignedWriteCommand = pdu_mod.SignedWriteCommand;
pub const HandleValueNotification = pdu_mod.HandleValueNotification;
pub const HandleValueIndication = pdu_mod.HandleValueIndication;
pub const HandleValueConfirmation = pdu_mod.HandleValueConfirmation;
pub const AttPdu = pdu_mod.AttPdu;

// Re-exports from bearer.zig
pub const ATT_CID = bearer_mod.ATT_CID;
pub const DEFAULT_ATT_MTU = bearer_mod.DEFAULT_ATT_MTU;
pub const MAX_ATT_MTU = bearer_mod.MAX_ATT_MTU;
pub const TRANSACTION_TIMEOUT_MS = bearer_mod.TRANSACTION_TIMEOUT_MS;
pub const BearerState = bearer_mod.BearerState;
pub const ClientRxEvent = bearer_mod.ClientRxEvent;
pub const AttServerAttribute = bearer_mod.AttServerAttribute;
pub const PreparedWriteEntry = bearer_mod.PreparedWriteEntry;
pub const AttBearer = bearer_mod.AttBearer;

// Re-exports from client.zig
pub const ServiceDiscoveryClient = client_mod.ServiceDiscoveryClient;
pub const LongReadClient = client_mod.LongReadClient;
pub const QueuedWriteClient = client_mod.QueuedWriteClient;

test {
    _ = @import("att/tests.zig");
}
