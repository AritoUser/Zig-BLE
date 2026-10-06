//! # L2CAP (Logical Link Control and Adaptation Protocol)
//!
//! Provides direct L2CAP Connection-Oriented Channel (CoC) streaming
//! over Linux `AF_BLUETOOTH`, and complete zero-copy LE L2CAP Signaling PDUs (CID 0x0005).

pub const socket = @import("socket.zig");
pub const L2capSocket = socket.L2capSocket;
pub const sockaddr_l2 = socket.sockaddr_l2;
pub const SocketType = socket.SocketType;
pub const L2capError = socket.L2capError;
pub const SecurityLevel = socket.SecurityLevel;
pub const bt_security = socket.bt_security;
pub const l2cap_options = socket.l2cap_options;
pub const l2cap_conninfo = socket.l2cap_conninfo;
pub const AcceptedConnection = socket.AcceptedConnection;
pub const toKernelBdAddr = socket.toKernelBdAddr;
pub const fromKernelBdAddr = socket.fromKernelBdAddr;

pub const signaling = @import("signaling.zig");
pub const L2capSignalingPdu = signaling.L2capSignalingPdu;
pub const SignalingOpcode = signaling.SignalingOpcode;
pub const L2capHeader = signaling.L2capHeader;
pub const SignalingHeader = signaling.SignalingHeader;
pub const L2capSignalingError = signaling.L2capSignalingError;

// Channel ID constants
pub const CID_NULL = signaling.CID_NULL;
pub const CID_SIGNALING_BREDR = signaling.CID_SIGNALING_BREDR;
pub const CID_CONNECTIONLESS = signaling.CID_CONNECTIONLESS;
pub const CID_AMP_MANAGER = signaling.CID_AMP_MANAGER;
pub const CID_ATT = signaling.CID_ATT;
pub const CID_LE_SIGNALING = signaling.CID_LE_SIGNALING;
pub const CID_SMP = signaling.CID_SMP;
pub const CID_SMP_BREDR = signaling.CID_SMP_BREDR;
pub const CID_LE_DYNAMIC_START = signaling.CID_LE_DYNAMIC_START;
pub const CID_LE_DYNAMIC_END = signaling.CID_LE_DYNAMIC_END;

// Signaling Command PDU types
pub const CommandRejectReason = signaling.CommandRejectReason;
pub const CommandRejectRsp = signaling.CommandRejectRsp;
pub const DisconnectionReq = signaling.DisconnectionReq;
pub const DisconnectionRsp = signaling.DisconnectionRsp;
pub const ConnParamUpdateReq = signaling.ConnParamUpdateReq;
pub const ConnParamUpdateRsp = signaling.ConnParamUpdateRsp;
pub const ConnParamUpdateResult = signaling.ConnParamUpdateResult;
pub const LeCreditBasedConnReq = signaling.LeCreditBasedConnReq;
pub const LeCreditBasedConnRsp = signaling.LeCreditBasedConnRsp;
pub const LeCreditConnResult = signaling.LeCreditConnResult;
pub const LeFlowControlCredit = signaling.LeFlowControlCredit;
pub const CreditBasedConnReq = signaling.CreditBasedConnReq;
pub const CreditBasedConnRsp = signaling.CreditBasedConnRsp;
pub const EnhancedCreditConnResult = signaling.EnhancedCreditConnResult;
pub const CreditBasedReconfigureReq = signaling.CreditBasedReconfigureReq;
pub const CreditBasedReconfigureRsp = signaling.CreditBasedReconfigureRsp;
pub const ReconfigureResult = signaling.ReconfigureResult;

// Framing helpers
pub const encodeFrame = signaling.encodeFrame;
pub const decodeFrame = signaling.decodeFrame;

pub const acl_reassembler = @import("acl_reassembler.zig");
pub const AclReassembler = acl_reassembler.AclReassembler;
pub const L2capFrame = acl_reassembler.L2capFrame;
pub const PbFlag = acl_reassembler.PbFlag;

test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    _ = socket;
    _ = signaling;
    _ = acl_reassembler;
}
