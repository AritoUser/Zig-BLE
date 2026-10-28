# Security Policy & Threat Model (`Zig-BLE`)

## Supported Versions

| Version | Supported |
| ------- | --------- |
| `1.2.x` | Yes       |
| `< 1.2` | No        |

## Reporting a Vulnerability

If you discover a security vulnerability in **Zig-BLE** (such as buffer handling bugs in protocol parsers, cryptographic flaws in `src/crypto/`, or privilege/authorization bypasses in D-Bus or WinRT backends), please report it privately rather than opening a public issue:

1. **GitHub Private Vulnerability Reporting**: Use the repository's **Security -> Report a vulnerability** advisory form.
2. **Response Timeline**: We aim to acknowledge reports within **48 hours** and provide a remediation plan or patch within **14 days**.

---

## Threat Model & Security Architecture

### 1. Untrusted Over-The-Air (OTA) & IPC Inputs
All bytes received from Bluetooth controllers, remote BLE devices, or local IPC sockets are treated as untrusted:
- **Advertising & Extended Advertising (`src/core/advertising.zig`)**: Zero-allocation bounded TLV iterators with strict length validation and UTF-8 sanitization.
- **Attribute Protocol (`src/core/att.zig`) & EATT (`src/core/eatt.zig`)**: Strict bounds checking, single-request-in-flight sequential flow control, 30-second transaction timeout enforcement, L2CAP credit-exhaustion protection, and per-bearer fault isolation.
- **Security Manager Protocol (`src/crypto/smp.zig`)**: Validates P-256 curve points via `std.crypto.ecc.P256.fromSec1` (preventing invalid-curve attacks), enforces state-machine ordering (rejecting unexpected or duplicate confirm/random PDUs), and uses constant-time comparisons (`std.crypto.timing_safe.eql`) for MAC/confirm verification.
- **D-Bus Wire Protocol (`src/dbus/wire/`) & Pairing Agent (`src/agent.zig`)**: Validates alignment padding, container recursion depth, and D-Bus object path syntax. Unregistered pairing callbacks default to **strict rejection** (`org.bluez.Error.Rejected`) to prevent silent "Just Works" downgrade attacks.

### 2. Cryptographic Primitives & Entropy (`src/crypto/toolbox.zig`)
- **Official Bluetooth Core Spec Test Vectors**: All cryptographic functions (`e`, `ah`, `c1`, `s1`, `f4`, `f5`, `f6`, `g2`, `h6`, `h7`, `signAtt`, `verifyAttSign`, `gattHash`, `sih`) are continuously verified against official Bluetooth Core Specification (Vol 3, Part H, Appendix D) and RFC 4493 test vectors.
- **CSPRNG Fail-Closed Design**: Random number generation queries OS entropy (`getrandom` on Linux, `SystemFunction036` / `RtlGenRandom` on Windows) and returns `CryptoError.EntropyUnavailable` if the OS CSPRNG fails—never falling back to a predictable or fixed-seed PRNG.
- **RPA `prand` Validation**: Enforces Bluetooth Core Spec Vol 6, Part B, 1.3.2.2 (`prand` 22 random bits are neither all `0`s nor all `1`s).

### 3. Bond Storage & Key Material at Rest (`src/storage/bond_store.zig`)
- **Authenticated Encryption**: `BondStore` encrypts `LTK`, `IRK`, and `CSRK` using **AES-128-CTR** with a fresh 128-bit CSPRNG nonce per serialization and authenticates the entire record table with a 16-byte **AES-CMAC** tag verified in constant time.
- **OS Key Wrapping & File Permissions**:
  - **Windows**: Supports hardware/user-bound key protection via Windows **DPAPI** (`CryptProtectData` / `CryptUnprotectData`).
  - **Linux / POSIX**: Enforces `0600` (`S_IRUSR | S_IWUSR`) owner-only file permissions on bond files, rejecting world- or group-accessible key files with `BondStoreError.InsecureFilePermissions`, and persists changes atomically via `.tmp` + `fsync` + `rename`.
- **Memory Zeroization**: Calling `deinit()`, `remove()`, or `clear()` overwrites sensitive key material in RAM via `std.crypto.secureZero`.

### 4. Required OS Privileges
- **Linux BlueZ D-Bus Backend**: Requires access to the system D-Bus bus (`org.bluez`).
- **Linux Raw HCI (`HciController` / `HciBackend`) & L2CAP CoC**: Opening `AF_BLUETOOTH` raw sockets requires `CAP_NET_RAW` and `CAP_NET_ADMIN` capabilities:
  ```bash
  sudo setcap 'cap_net_raw,cap_net_admin+eip' ./zig-out/bin/Zig_BLE
  ```
- **Windows WinRT Backend**: Requires Bluetooth radio access enabled in Windows Privacy Settings.

