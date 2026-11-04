import Testing
@testable import Samplers

@Test func smcFourCharacterCodes() {
    #expect(SMCCodec.fourCC("Tp01") == 0x54703031)
    #expect(SMCCodec.fourCC("#KEY") == 0x234b4559)
    #expect(SMCCodec.name(0x666c7420) == "flt ")
    for name in ["Tp01", "Tg0A", "#KEY", "flt "] {
        #expect(SMCCodec.name(SMCCodec.fourCC(name)!) == name)
    }
    #expect(SMCCodec.fourCC("abc") == nil)
    #expect(SMCCodec.fourCC("abcde") == nil)
    #expect(SMCCodec.fourCC("éab") == nil)
}

@Test func smcKeyFiltering() {
    let float = SMCCodec.fourCC("flt ")!
    #expect(SMCCodec.isTemperature(key: 0x54703031, type: float, size: 4))
    #expect(SMCCodec.isTemperature(key: 0x54673041, type: float, size: 4))
    #expect(SMCCodec.isTemperature(key: 0x54423031, type: float, size: 4))
    #expect(!SMCCodec.isTemperature(key: 0x46703031, type: float, size: 4))
    #expect(!SMCCodec.isTemperature(key: 0x54703031, type: float, size: 8))
    #expect(!SMCCodec.isTemperature(key: 0x54703031, type: SMCCodec.fourCC("sp78")!, size: 4))
    #expect(SMCCodec.isCPUTemperature(0x54703031))
    #expect(!SMCCodec.isCPUTemperature(0x54673041))
    #expect(SMCCodec.isGPUTemperature(0x54673041))
    #expect(!SMCCodec.isGPUTemperature(0x54423031))
}

@Test func smcFloatDecoding() {
    let cases: [([UInt8], Double)] = [([0, 0, 0x80, 0x3f], 1), ([0, 0, 0x89, 0x42], 68.5),
                                    ([0, 0, 0x20, 0xc0], -2.5), ([0, 0, 0, 0], 0)]
    for (bytes, expected) in cases {
        #expect(bytes.withUnsafeBytes { SMCCodec.float($0) } == expected)
    }
    #expect([UInt8](repeating: 0, count: 3).withUnsafeBytes { SMCCodec.float($0) } == nil)
    #expect([UInt8](arrayLiteral: 0, 0, 0x80, 0x7f).withUnsafeBytes { SMCCodec.float($0) } == .infinity)
    #expect([UInt8](arrayLiteral: 0, 0, 0xc0, 0x7f).withUnsafeBytes { SMCCodec.float($0)?.isNaN } == true)
    let unaligned: [UInt8] = [0xff, 0, 0, 0x89, 0x42]
    #expect(unaligned.withUnsafeBytes { SMCCodec.float(UnsafeRawBufferPointer(rebasing: $0[1...])) } == 68.5)
}

@Test func smcMessageMatchesCLayout() {
    #expect(MemoryLayout<SMCKeyData>.size == 80)
    #expect(MemoryLayout<SMCKeyData>.stride == 80)
    #expect(MemoryLayout<SMCKeyData>.alignment == 4)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.version) == 4)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.limitVersion) == 12)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.dataSize) == 28)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.result) == 40)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.command) == 42)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.data32) == 44)
    #expect(MemoryLayout<SMCKeyData>.offset(of: \.bytes) == 48)
}
