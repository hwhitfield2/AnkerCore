import Foundation

enum OggOpusMuxerError: Error {
    case emptyAudio
}

enum OggOpusMuxer {
    private static let frameSize = 160
    private static let samplesPerFrame: UInt64 = 960

    static func mux(rawFrames raw: Data) throws -> Data {
        guard !raw.isEmpty else { throw OggOpusMuxerError.emptyAudio }
        var frames: [Data] = []
        var offset = 0
        while offset < raw.count {
            let end = min(offset + frameSize, raw.count)
            var frame = Data(raw[offset ..< end])
            while frame.count > 1, frame.last == 0 { frame.removeLast() }
            frames.append(frame)
            offset = end
        }

        let serial: UInt32 = 0x41524B52
        var output = Data()
        output.append(page(packets: [opusHead()], serial: serial, sequence: 0, granule: 0, bos: true))
        output.append(page(packets: [opusTags()], serial: serial, sequence: 1, granule: 0))

        var sequence: UInt32 = 2
        var granule: UInt64 = 0
        for start in stride(from: 0, to: frames.count, by: 50) {
            let end = min(start + 50, frames.count)
            let batch = Array(frames[start ..< end])
            granule += samplesPerFrame * UInt64(batch.count)
            output.append(page(
                packets: batch,
                serial: serial,
                sequence: sequence,
                granule: granule,
                eos: end == frames.count
            ))
            sequence &+= 1
        }
        return output
    }

    private static func opusHead() -> Data {
        var data = Data("OpusHead".utf8)
        data.append(contentsOf: [1, 1]) // version, mono
        data.append(littleEndian(UInt16(3840)))
        data.append(littleEndian(UInt32(48_000)))
        data.append(littleEndian(UInt16(0))) // output gain
        data.append(0) // channel mapping family
        return data
    }

    private static func opusTags() -> Data {
        let vendor = Data("AnkerCore".utf8)
        var data = Data("OpusTags".utf8)
        data.append(littleEndian(UInt32(vendor.count)))
        data.append(vendor)
        data.append(littleEndian(UInt32(0)))
        return data
    }

    private static func page(
        packets: [Data],
        serial: UInt32,
        sequence: UInt32,
        granule: UInt64,
        bos: Bool = false,
        eos: Bool = false
    ) -> Data {
        var lacing: [UInt8] = []
        var body = Data()
        for packet in packets {
            body.append(packet)
            var remaining = packet.count
            while remaining >= 255 {
                lacing.append(255)
                remaining -= 255
            }
            lacing.append(UInt8(remaining))
        }

        var headerType: UInt8 = 0
        if bos { headerType |= 0x02 }
        if eos { headerType |= 0x04 }
        var result = Data("OggS".utf8)
        result.append(0)
        result.append(headerType)
        result.append(littleEndian(granule))
        result.append(littleEndian(serial))
        result.append(littleEndian(sequence))
        result.append(contentsOf: [0, 0, 0, 0])
        result.append(UInt8(lacing.count))
        result.append(contentsOf: lacing)
        result.append(body)

        let crc = oggCRC(result)
        result.replaceSubrange(22 ..< 26, with: littleEndian(crc))
        return result
    }

    private static func oggCRC(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                crc = (crc & 0x80000000) != 0
                    ? (crc << 1) ^ 0x04C11DB7
                    : crc << 1
            }
        }
        return crc
    }

    private static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        var value = value.littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}
