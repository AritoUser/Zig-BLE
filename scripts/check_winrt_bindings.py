#!/usr/bin/env python3
"""Checks the WinRT bindings against the Windows SDK headers (needs the Windows SDK).

A wrong IID makes WinRT reject an object with E_NOINTERFACE and a wrong vtable order calls
the wrong method. Neither shows up without real WinRT, so mock tests and CI cannot find them.

    python scripts/check_winrt_bindings.py [path to Include/<version>]
"""
import glob
import re
import sys

BINDINGS = "src/backend/windows/bindings"
# Not declared with MIDL_INTERFACE in winrt/*.h; values from objidl.h, activation.idl and robuffer.h.
OUTSIDE_WINRT = {
    "IID_IUnknown": "00000000-0000-0000-c000-000000000046",
    "IID_IAgileObject": "94ea2b94-e9cc-49e0-c0ff-ee64ca8f5b90",
    "IID_IActivationFactory": "00000035-0000-0000-c000-000000000046",
    "IID_IBufferByteAccess": "905a0fef-bc53-11df-8c49-001e4fc686da",
}
BASE_METHODS = {"QueryInterface", "AddRef", "Release", "GetIids", "GetRuntimeClassName", "GetTrustLevel"}


def load_sdk(include_dir):
    interfaces = {}  # name -> (iid, methods)
    delegates = {}  # lower-case iid -> typedef text
    for path in glob.glob(include_dir + "/winrt/*.h"):
        text = open(path, encoding="utf-8", errors="replace").read()
        for m in re.finditer(r'MIDL_INTERFACE\("([0-9a-fA-F-]{36})"\)\s*(\w+)\s*:\s*public\s*(\w+)\s*\{(.*?)\n\s*\};', text, re.S):
            methods = re.findall(r"STDMETHODCALLTYPE\s+(\w+)\s*\(", m.group(4))
            interfaces.setdefault(m.group(2), (m.group(1).lower(), methods))
        for chunk in text.split('struct __declspec(uuid("')[1:]:
            typedef = re.search(r"typedef\s+(ITypedEventHandler<[^\n]*?>)\s+__F", chunk)
            if typedef:
                delegates.setdefault(chunk[:36].lower(), typedef.group(1))
    return interfaces, delegates


def main():
    include = sys.argv[1] if len(sys.argv) > 1 else sorted(glob.glob("C:/Program Files (x86)/Windows Kits/10/Include/10.0.*"))[-1]
    interfaces, delegates = load_sdk(include)
    print(f"SDK {include}: {len(interfaces)} interfaces, {len(delegates)} typed delegates")
    problems = 0

    iids = dict(re.findall(r'pub const (IID_\w+) = GUID\.parse\("([^"]+)"\)', open(f"{BINDINGS}/iids.zig", encoding="utf-8").read()))
    for name, value in iids.items():
        value = value.lower()
        iface = name[4:]
        if name in OUTSIDE_WINRT:
            expected = OUTSIDE_WINRT[name]
        elif iface.startswith("ITypedEventHandler_"):
            if value in delegates:
                print(f"  {name}\n      = {delegates[value]}")
            else:
                print(f"IID not in SDK: {name} {value}")
                problems += 1
            continue
        elif iface in interfaces:
            expected = interfaces[iface][0]
        else:
            print(f"interface not in SDK: {name} {value}")
            problems += 1
            continue
        if value != expected:
            print(f"wrong IID: {name} is {value}, SDK says {expected}")
            problems += 1

    checked = 0
    for path in glob.glob(f"{BINDINGS}/interfaces/*.zig"):
        text = open(path, encoding="utf-8").read()
        for m in re.finditer(r"pub const (I\w+)Vtbl = extern struct \{(.*?)\n\};", text, re.S):
            name, body = m.group(1), m.group(2)
            if name not in interfaces:
                continue
            ours = [f for f in re.findall(r"^\s*(\w+):", body, re.M) if f not in BASE_METHODS]
            theirs = interfaces[name][1]
            checked += 1
            if ours != theirs[: len(ours)] or len(ours) != len(theirs):
                # Trailing entries may be left out: they are never called through this table.
                if ours != theirs[: len(ours)]:
                    print(f"vtable order differs: {name}\n  ours: {ours}\n  SDK:  {theirs}")
                    problems += 1
    print(f"{len(iids)} IIDs and {checked} vtables checked, {problems} problems")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
